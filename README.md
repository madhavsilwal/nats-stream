# NATS JetStream — Operator-Mode Docker Setup

A self-contained NATS server running in **operator mode** with JetStream enabled. All keys, JWTs, and credentials are generated automatically on first boot and persisted in a Docker volume.

---

## Architecture

```
Operator: MyOperator
└── Account: SYS          (system account — internal server use only)
└── Account: MyAccount
    ├── User: admin        (pub/sub on everything: >)
    ├── User: publisher    (pub on events.>)
    └── User: consumer     (sub on events.>, payment.>)
```

The server uses the **full JWT resolver** — account JWTs are stored on disk and can be updated live without restarting.

---

## File Overview

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage build: compiles `nsc` from source, bundles with `nats:2.12-alpine` |
| `docker-compose.yaml` | Runs the container, maps ports, mounts two named volumes |
| `nats.conf` | Server config: operator JWT path, full resolver dir, JetStream limits |
| `entrypoint.sh` | First-boot init: creates operator/accounts/users, exports JWTs and creds |

### Volumes

| Volume | Mounted at | Contains |
|---|---|---|
| `nats-creds` | `/etc/nats/creds` | Operator JWT, resolver JWTs, user `.creds` files |
| `nats-data` | `/data/jetstream` | JetStream message store |

Volumes survive `docker compose restart` and `docker compose up --build`. Only `docker compose down -v` wipes them.

---

## Initial Setup

### Prerequisites

- Docker with Compose v2
- [`nats` CLI](https://github.com/nats-io/natscli) installed locally

### Start the server

```sh
docker compose up -d --build
```

On first boot the entrypoint:

1. Creates operator `MyOperator` with a built-in `SYS` system account
2. Creates account `MyAccount` with three users and their permission sets
3. Writes the operator JWT to `/etc/nats/creds/operator.jwt`
4. Writes account JWTs to `/etc/nats/creds/resolver/` named by account public key (required by the full resolver)
5. Copies user creds to `/etc/nats/creds/users/`

Check the logs:

```sh
docker logs nats-js
```

Expected final lines:

```
[entrypoint] Setup complete.
[INF] Server is ready
```

Subsequent restarts skip init and print `Already initialized — skipping setup.`

---

## Configuration

### nats.conf

```
server_name: nats-jetstream-1
host: "0.0.0.0"
port: 4222

operator: "/etc/nats/creds/operator.jwt"

resolver: {
  type:         full
  dir:          "/etc/nats/creds/resolver"
  allow_delete: false
  interval:     "2m"
}

jetstream {
  store_dir:        "/data/jetstream"
  max_memory_store: 1GB
  max_file_store:   10GB
}

http_port: 8222
```

The `full` resolver means the server holds all account JWTs locally and can accept live updates via the system account API (`nsc push`).

### User permissions

| User | Publish | Subscribe |
|---|---|---|
| `admin` | `>` | `>` |
| `publisher` | `events.>` | denied (`>`) |
| `consumer` | denied (`>`) | `events.>`, `payment.>` |

---

## Obtaining Credentials

Copy creds from the container to your local machine:

```sh
docker cp nats-js:/etc/nats/creds/users/admin.creds     ./admin.creds
docker cp nats-js:/etc/nats/creds/users/publisher.creds ./publisher.creds
docker cp nats-js:/etc/nats/creds/users/consumer.creds  ./consumer.creds
```

---

## Usage

All commands connect to `nats://localhost:4222`.

### Subscribe (consumer)

```sh
nats sub --creds consumer.creds 'payment.>' -s nats://localhost:4222
nats sub --creds consumer.creds 'events.>'  -s nats://localhost:4222
```

### Publish (publisher)

```sh
nats pub --creds publisher.creds events.order.created '{"id":1}' -s nats://localhost:4222
nats pub --creds publisher.creds events.user.signup   '{"id":2}' -s nats://localhost:4222
```

### Admin (full access)

```sh
nats sub --creds admin.creds '>' -s nats://localhost:4222
nats pub --creds admin.creds any.subject 'hello' -s nats://localhost:4222
```

### Monitoring (HTTP)

```sh
curl http://localhost:8222/varz      # server info
curl http://localhost:8222/accountz  # accounts
curl http://localhost:8222/jsz       # JetStream stats
```

---

## Revoking Credentials

Revoking a user **does not require a restart**. The updated account JWT is pushed live to the server via the system account.

### Revoke a user

```sh
docker exec nats-js sh -c '
  export NSC_HOME=/etc/nats/nsc NKEYS_PATH=/etc/nats/nkeys
  nsc revocations add-user -a MyAccount -n consumer
  nsc push -a MyAccount \
    --account-jwt-server-url nats://localhost:4222 \
    --system-account SYS \
    --system-user sys
'
```

The user's existing connection is dropped and any reconnect attempt will receive `Authorization Violation`.

### Verify revocation

```sh
nats sub --creds consumer.creds 'payment.>' -s nats://localhost:4222
# nats: error: nats: Authorization Violation
```

### List all revoked users

```sh
docker exec nats-js sh -c '
  export NSC_HOME=/etc/nats/nsc NKEYS_PATH=/etc/nats/nkeys
  nsc revocations list-users -a MyAccount
'
```

---

## Restoring Credentials

Remove the revocation and push the updated account JWT — no restart needed.

```sh
docker exec nats-js sh -c '
  export NSC_HOME=/etc/nats/nsc NKEYS_PATH=/etc/nats/nkeys
  nsc revocations delete-user -a MyAccount -n consumer
  nsc push -a MyAccount \
    --account-jwt-server-url nats://localhost:4222 \
    --system-account SYS \
    --system-user sys
'
```

The existing `.creds` file on disk is unchanged — access is controlled entirely by the revocation list embedded in the account JWT on the server. The user can reconnect immediately.

### Verify access is restored

```sh
nats sub --creds consumer.creds 'payment.>' -s nats://localhost:4222
# 00:44:49 Subscribing on payment.>
```

---

## Full Reset

Wipes all volumes — operator, keys, JWTs, and JetStream data are all regenerated on next boot.

```sh
docker compose down -v
docker compose up -d --build
```

> All previously issued `.creds` files become invalid after a reset because new keys are generated.

---

## How the Full Resolver Works

The `full` resolver requires account JWT files to be named by their **account public key** (e.g. `ACK2...24P.jwt`), not by account name. The entrypoint decodes the JWT payload to extract the `sub` field (the public key) and writes each file with the correct name. Without this, the server cannot look up accounts and returns `Authorization Violation` on every connect.

When `nsc push` is called, it uses the NATS system account's `$SYS.REQ.ACCOUNT.*.CLAIMS.UPDATE` API to update the in-memory and on-disk JWT simultaneously — no server reload required.
