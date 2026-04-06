# NATS JetStream — Operator-Mode Docker Setup

A self-contained NATS server running in **operator mode** with JetStream enabled. All keys, JWTs, and credentials are generated automatically on first boot from `entities.yaml` and persisted in a Docker volume.

---

## Architecture

Entities are defined declaratively in `entities.yaml`. On first boot the entrypoint reads this file and creates all operators, accounts and users via `nsc`.

```
entities.yaml
  operators:
    - name: madhav (primary, sys)
        accounts:
          - debug-users → admin, publisher, consumer
          - test-users  → tester
    - name: silwal
        accounts: []
```

The server uses the **full JWT resolver** — account JWTs are stored on disk and can be updated live without restarting.

---

## File Overview

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage build: compiles `nsc` from source, downloads `yq`, bundles with `nats:2.12-alpine` |
| `docker-compose.yaml` | Runs the container, maps ports, mounts two named volumes |
| `nats.conf` | Server config: operator JWT path, full resolver dir, JetStream limits |
| `entrypoint.sh` | First-boot init: parses `entities.yaml` via `yq`, creates operators/accounts/users, exports JWTs and creds |
| `entities.yaml` | Declarative definition of operators, accounts, users and their permissions |

### Volumes

| Volume | Mounted at | Contains |
|---|---|---|
| `nats-creds` | `/etc/nats/creds` | Operator JWT, resolver JWTs, user `.creds` files |
| `nats-data` | `/data/jetstream` | JetStream message store |

Volumes survive `docker compose restart` and `docker compose up --build`. Only `docker compose down -v` wipes them.

---

## entities.yaml

All operators, accounts and users are defined in `entities.yaml`. The entrypoint parses this file at startup using [`yq`](https://github.com/mikefarah/yq).

See [`entities.sample.yaml`](entities.sample.yaml) for a fully commented reference with multiple operators, accounts, permission styles (scalar vs list), and edge cases. Copy it to `entities.yaml` and customize.

### Schema

```yaml
operators:
  - name: <operator-name>
    sys: true|false              # create a SYS system account for this operator
    primary: true|false          # optional — marks this operator as the server's operator
    accounts:
      - name: <account-name>
        jetstream: true|false    # optional — enable JetStream for this account (default: false)
        users:
          - name: <user-name>
            allow-pub: "<subject>" | ["<subject1>", "<subject2>"]
            deny-pub:  "<subject>" | ["<subject1>", "<subject2>"]
            allow-sub: "<subject>" | ["<subject1>", "<subject2>"]
            deny-sub:  "<subject>" | ["<subject1>", "<subject2>"]
```

- **`primary`**: The operator with `primary: true` has its JWT written to `/etc/nats/creds/operator.jwt` (the file referenced by `nats.conf`). If no operator has `primary: true`, the **first operator in the list** is used as primary.
- **`sys`**: When `true`, a `SYS` system account is created for that operator.
- **`jetstream`**: When `true` on an account, JetStream is enabled for that account with `--js-enable 1`, tier 1, 1 GB memory storage, and 10 GB disk storage.
- Permission values can be a single subject string or a YAML list. Lists are joined with commas (e.g. `events.>,payment.>`). Subjects containing `$` (e.g. `$JS.API.>`) are supported.

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

1. Parses `entities.yaml` using `yq`
2. Creates all operators (with `--sys` where specified)
3. Creates all accounts and users with their permission sets
4. Writes the **primary** operator JWT to `/etc/nats/creds/operator.jwt`
5. Writes account JWTs to `/etc/nats/creds/resolver/` named by account public key (required by the full resolver)
6. Copies user creds to `/etc/nats/creds/users/` with collision-safe names

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

> **Changing entities.yaml:** If the creds volume already contains `operator.jwt`, the entrypoint will skip initialization. To apply changes to `entities.yaml`, either reset volumes (`docker compose down -v`) or set `FORCE_INIT=true` (see [Force Re-initialization](#force-re-initialization)).

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

---

## Obtaining Credentials

Credentials are stored in `/etc/nats/creds/users/` with naming convention:

```
<operator>-<account>-<user>.creds
```

For the example `entities.yaml` above:

```sh
docker cp nats-js:/etc/nats/creds/users/madhav-debug-users-admin.creds     ./madhav-debug-users-admin.creds
docker cp nats-js:/etc/nats/creds/users/madhav-debug-users-publisher.creds ./madhav-debug-users-publisher.creds
docker cp nats-js:/etc/nats/creds/users/madhav-debug-users-consumer.creds  ./madhav-debug-users-consumer.creds
docker cp nats-js:/etc/nats/creds/users/madhav-test-users-tester.creds     ./madhav-test-users-tester.creds
```

The primary operator's system account creds are also available with a short alias:

```sh
docker cp nats-js:/etc/nats/creds/users/sys.creds ./sys.creds
```

All operator sys creds are available at:

```sh
docker cp nats-js:/etc/nats/creds/users/<operator>-SYS-sys.creds ./<operator>-sys.creds
```

---

## Usage

All commands connect to `nats://localhost:4222`.

### Subscribe (consumer)

```sh
nats sub --creds madhav-debug-users-consumer.creds 'payment.>' -s nats://localhost:4222
nats sub --creds madhav-debug-users-consumer.creds 'events.>'  -s nats://localhost:4222
```

### Publish (publisher)

```sh
nats pub --creds madhav-debug-users-publisher.creds events.order.created '{"id":1}' -s nats://localhost:4222
nats pub --creds madhav-debug-users-publisher.creds events.user.signup   '{"id":2}' -s nats://localhost:4222
```

### Admin (full access)

```sh
nats sub --creds madhav-debug-users-admin.creds '>' -s nats://localhost:4222
nats pub --creds madhav-debug-users-admin.creds any.subject 'hello' -s nats://localhost:4222
```

### Test account user

```sh
nats sub --creds madhav-test-users-tester.creds 'test.>' -s nats://localhost:4222
nats pub --creds madhav-test-users-tester.creds test.ping 'pong' -s nats://localhost:4222
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
  nsc revocations add-user -a debug-users -n consumer
  nsc push -a debug-users \
    --account-jwt-server-url nats://localhost:4222 \
    --system-account SYS \
    --system-user sys
'
```

The user's existing connection is dropped and any reconnect attempt will receive `Authorization Violation`.

### Verify revocation

```sh
nats sub --creds madhav-debug-users-consumer.creds 'payment.>' -s nats://localhost:4222
# nats: error: nats: Authorization Violation
```

### List all revoked users

```sh
docker exec nats-js sh -c '
  export NSC_HOME=/etc/nats/nsc NKEYS_PATH=/etc/nats/nkeys
  nsc revocations list-users -a debug-users
'
```

---

## Restoring Credentials

Remove the revocation and push the updated account JWT — no restart needed.

```sh
docker exec nats-js sh -c '
  export NSC_HOME=/etc/nats/nsc NKEYS_PATH=/etc/nats/nkeys
  nsc revocations delete-user -a debug-users -n consumer
  nsc push -a debug-users \
    --account-jwt-server-url nats://localhost:4222 \
    --system-account SYS \
    --system-user sys
'
```

The existing `.creds` file on disk is unchanged — access is controlled entirely by the revocation list embedded in the account JWT on the server. The user can reconnect immediately.

### Verify access is restored

```sh
nats sub --creds madhav-debug-users-consumer.creds 'payment.>' -s nats://localhost:4222
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

### Force Re-initialization

If you want to re-run the entrypoint initialization without destroying the JetStream data volume, set `FORCE_INIT=true`:

```sh
docker compose down
FORCE_INIT=true docker compose up -d
```

This re-parses `entities.yaml` and recreates all operators, accounts and users. Existing JetStream message data is preserved.

> **Warning:** Force re-initialization generates new keys, so all previously issued `.creds` files become invalid.

---

## How the Full Resolver Works

The `full` resolver requires account JWT files to be named by their **account public key** (e.g. `ACK2...24P.jwt`), not by account name. The entrypoint decodes the JWT payload to extract the `sub` field (the public key) and writes each file with the correct name. Without this, the server cannot look up accounts and returns `Authorization Violation` on every connect.

When `nsc push` is called, it uses the NATS system account's `$SYS.REQ.ACCOUNT.*.CLAIMS.UPDATE` API to update the in-memory and on-disk JWT simultaneously — no server reload required.
