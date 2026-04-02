#!/bin/sh
set -e

NSC_HOME=/etc/nats/nsc
NKEYS_PATH=/etc/nats/nkeys
CREDS_DIR=/etc/nats/creds
RESOLVER_DIR=$CREDS_DIR/resolver
USERS_DIR=$CREDS_DIR/users

export NSC_HOME NKEYS_PATH

if [ ! -f "$CREDS_DIR/.initialized" ]; then
  echo "[entrypoint] First boot — generating operator, accounts, users..."

  mkdir -p "$NSC_HOME" "$NKEYS_PATH" "$RESOLVER_DIR" "$USERS_DIR"

  nsc add operator -n MyOperator --sys
  nsc add account  -n MyAccount
  nsc add user -a MyAccount -n admin
  nsc add user -a MyAccount -n publisher
  nsc add user -a MyAccount -n consumer

  nsc edit user -a MyAccount -n admin     --allow-pub ">"        --allow-sub ">"
  nsc edit user -a MyAccount -n publisher --allow-pub "events.>" --deny-sub ">"
  nsc edit user -a MyAccount -n consumer  --deny-pub ">"         --allow-sub "events.>,payment.>"

  # Export operator JWT (after system account is set)
  nsc describe operator --raw > "$CREDS_DIR/operator.jwt"

  # ── Export account JWTs to resolver dir named by public account key ──
  # The full resolver requires files named <AccountPublicKey>.jwt, not <AccountName>.jwt.
  for account in SYS MyAccount; do
    raw=$(nsc describe account -n "$account" --raw 2>/dev/null) || continue
    # base64url-decode the JWT payload segment to extract the 'sub' field (account public key)
    payload=$(printf '%s' "$raw" | cut -d. -f2 | tr -- '-_' '+/')
    mod=$(( ${#payload} % 4 ))
    [ "$mod" -eq 2 ] && payload="${payload}=="
    [ "$mod" -eq 3 ] && payload="${payload}="
    sub=$(printf '%s' "$payload" | base64 -d 2>/dev/null | grep -o '"sub":"[^"]*"' | cut -d'"' -f4)
    [ -n "$sub" ] && printf '%s\n' "$raw" > "${RESOLVER_DIR}/${sub}.jwt"
  done

  # Copy creds from where nsc actually put them
  cp "$NKEYS_PATH/creds/MyOperator/MyAccount/admin.creds"     "$USERS_DIR/admin.creds"
  cp "$NKEYS_PATH/creds/MyOperator/MyAccount/publisher.creds" "$USERS_DIR/publisher.creds"
  cp "$NKEYS_PATH/creds/MyOperator/MyAccount/consumer.creds"  "$USERS_DIR/consumer.creds"

  touch "$CREDS_DIR/.initialized"
  echo "[entrypoint] Setup complete."
else
  echo "[entrypoint] Already initialized — skipping setup."
fi

exec nats-server -c /etc/nats/nats.conf