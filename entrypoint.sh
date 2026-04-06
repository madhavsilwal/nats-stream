#!/bin/sh
set -e

NSC_HOME=/etc/nats/nsc
NKEYS_PATH=/etc/nats/nkeys
CREDS_DIR=/etc/nats/creds
RESOLVER_DIR=$CREDS_DIR/resolver
USERS_DIR=$CREDS_DIR/users
ENTITIES=/etc/nats/entities.yaml

export NSC_HOME NKEYS_PATH

# ── Helper: extract a permission value (scalar or list) and join list items with commas ──
get_perm() {
  # $1 = yq path to the permission key (e.g. .operators[0].accounts[0].users[0].allow-pub)
  # Returns the value, joining YAML sequences with commas
  local path="$1"
  local tag
  tag=$(yq e "$path | tag" "$ENTITIES")
  if [ "$tag" = "!!seq" ]; then
    yq e "$path | join(\",\")" "$ENTITIES"
  else
    yq e "$path" "$ENTITIES"
  fi
}

# ── Helper: write account JWT to resolver dir by public key ──
write_resolver_jwt() {
  # $1 = account name
  local account="$1"
  local raw
  raw=$(nsc describe account -n "$account" --raw 2>/dev/null) || return 0
  if [ -z "$raw" ] || [ "$raw" = "null" ]; then
    return 0
  fi
  local payload
  payload=$(printf '%s' "$raw" | cut -d. -f2 | tr -- '-_' '+/')
  local mod=$(( ${#payload} % 4 ))
  [ "$mod" -eq 2 ] && payload="${payload}=="
  [ "$mod" -eq 3 ] && payload="${payload}="
  local sub
  sub=$(printf '%s' "$payload" | base64 -d 2>/dev/null | grep -o '"sub":"[^"]*"' | cut -d'"' -f4)
  if [ -n "$sub" ]; then
    printf '%s\n' "$raw" > "${RESOLVER_DIR}/${sub}.jwt"
    echo "[entrypoint] Wrote resolver JWT for account: $account ($sub)"
  else
    echo "[entrypoint] WARNING: failed to extract account public key for $account" >&2
  fi
}

# ── Skip initialization if already done ──
if [ ! -f "$CREDS_DIR/operator.jwt" ] || [ "${FORCE_INIT}" = "true" ]; then
  if [ "${FORCE_INIT}" = "true" ] && [ -f "$CREDS_DIR/operator.jwt" ]; then
    echo "[entrypoint] FORCE_INIT set — re-initializing from entities.yaml..."
    # Clean previous state so nsc can recreate cleanly
    rm -rf "$NSC_HOME"/* "$NKEYS_PATH"/* "$RESOLVER_DIR"/* "$USERS_DIR"/*
  else
    echo "[entrypoint] First boot — generating operator, accounts, users from entities.yaml..."
  fi

  if [ ! -f "$ENTITIES" ]; then
    echo "[entrypoint] ERROR: $ENTITIES not found" >&2
    exit 1
  fi

  mkdir -p "$NSC_HOME" "$NKEYS_PATH" "$RESOLVER_DIR" "$USERS_DIR"

  # ── Determine number of operators ──
  n_ops=$(yq e '.operators | length' "$ENTITIES")
  if [ -z "$n_ops" ] || [ "$n_ops" = "0" ] || [ "$n_ops" = "null" ]; then
    echo "[entrypoint] ERROR: no operators defined in $ENTITIES" >&2
    exit 1
  fi

  PRIMARY_OP=""

  # ── Create operators, accounts, and users ──
  i=0
  while [ "$i" -lt "$n_ops" ]; do
    op_name=$(yq e ".operators[$i].name" "$ENTITIES")
    op_sys=$(yq e ".operators[$i].sys" "$ENTITIES")
    op_primary=$(yq e ".operators[$i].primary" "$ENTITIES")

    echo "[entrypoint] Creating operator: $op_name (sys=$op_sys, primary=$op_primary)"

    # Create operator
    if [ "$op_sys" = "true" ]; then
      nsc add operator -n "$op_name" --sys
    else
      nsc add operator -n "$op_name"
    fi

    # Determine primary operator
    if [ -z "$PRIMARY_OP" ] && [ "$op_primary" = "true" ]; then
      PRIMARY_OP="$op_name"
    fi

    # Create accounts for this operator
    n_accounts=$(yq e ".operators[$i].accounts | length" "$ENTITIES")
    j=0
    while [ "$j" -lt "$n_accounts" ]; do
      acc_name=$(yq e ".operators[$i].accounts[$j].name" "$ENTITIES")
      acc_js=$(yq e ".operators[$i].accounts[$j].jetstream" "$ENTITIES")
      echo "[entrypoint]   Creating account: $acc_name"
      nsc add account -n "$acc_name"

      # Enable JetStream for this account if flagged (--js-enable is exclusive of other js flags)
      if [ "$acc_js" = "true" ]; then
        echo "[entrypoint]     Enabling JetStream for account: $acc_name"
        nsc edit account -n "$acc_name" --js-enable 1
        nsc edit account -n "$acc_name" --js-tier 1 --js-mem-storage 1g --js-disk-storage 10g
      fi

      # Create users for this account
      n_users=$(yq e ".operators[$i].accounts[$j].users | length" "$ENTITIES")
      k=0
      while [ "$k" -lt "$n_users" ]; do
        user_name=$(yq e ".operators[$i].accounts[$j].users[$k].name" "$ENTITIES")
        echo "[entrypoint]     Creating user: $user_name"
        nsc add user -a "$acc_name" -n "$user_name"

        # Apply permissions directly (no eval) to avoid shell expansion of $ in values like $JS.API.>
        for perm_key in allow-pub deny-pub allow-sub deny-sub; do
          perm_path=".operators[$i].accounts[$j].users[$k].${perm_key}"
          perm_val=$(get_perm "$perm_path")
          if [ -n "$perm_val" ] && [ "$perm_val" != "null" ]; then
            echo "[entrypoint]       Setting --${perm_key} \"${perm_val}\""
            nsc edit user -a "$acc_name" -n "$user_name" --"${perm_key}" "$perm_val"
          fi
        done

        k=$((k + 1))
      done
      j=$((j + 1))
    done

    i=$((i + 1))
  done

  # Fallback: if no operator had primary:true, use the first operator
  if [ -z "$PRIMARY_OP" ]; then
    PRIMARY_OP=$(yq e '.operators[0].name' "$ENTITIES")
    echo "[entrypoint] No primary operator marked — using first: $PRIMARY_OP"
  fi

  # ── Export primary operator JWT ──
  nsc describe operator -n "$PRIMARY_OP" --raw > "$CREDS_DIR/operator.jwt"
  echo "[entrypoint] Exported operator JWT for: $PRIMARY_OP"

  # ── Export account JWTs to resolver dir ──
  i=0
  while [ "$i" -lt "$n_ops" ]; do
    op_name=$(yq e ".operators[$i].name" "$ENTITIES")
    op_sys=$(yq e ".operators[$i].sys" "$ENTITIES")

    # Select operator so nsc commands scope correctly
    nsc select operator "$op_name" >/dev/null 2>&1

    # If operator has sys account, export it
    if [ "$op_sys" = "true" ]; then
      write_resolver_jwt "SYS"
    fi

    # Export each account
    n_accounts=$(yq e ".operators[$i].accounts | length" "$ENTITIES")
    j=0
    while [ "$j" -lt "$n_accounts" ]; do
      acc_name=$(yq e ".operators[$i].accounts[$j].name" "$ENTITIES")
      write_resolver_jwt "$acc_name"
      j=$((j + 1))
    done

    i=$((i + 1))
  done

  # ── Copy creds files ──
  i=0
  while [ "$i" -lt "$n_ops" ]; do
    op_name=$(yq e ".operators[$i].name" "$ENTITIES")
    op_sys=$(yq e ".operators[$i].sys" "$ENTITIES")

    # Select operator so nsc commands scope correctly
    nsc select operator "$op_name" >/dev/null 2>&1

    # Copy sys creds if operator has sys account
    if [ "$op_sys" = "true" ]; then
      sys_creds="$NKEYS_PATH/creds/$op_name/SYS/sys.creds"
      if [ -f "$sys_creds" ]; then
        cp "$sys_creds" "$USERS_DIR/${op_name}-SYS-sys.creds"
        if [ "$op_name" = "$PRIMARY_OP" ]; then
          cp "$sys_creds" "$USERS_DIR/sys.creds"
        fi
        echo "[entrypoint] Copied sys creds for operator: $op_name"
      fi
    fi

    # Copy user creds
    n_accounts=$(yq e ".operators[$i].accounts | length" "$ENTITIES")
    j=0
    while [ "$j" -lt "$n_accounts" ]; do
      acc_name=$(yq e ".operators[$i].accounts[$j].name" "$ENTITIES")

      n_users=$(yq e ".operators[$i].accounts[$j].users | length" "$ENTITIES")
      k=0
      while [ "$k" -lt "$n_users" ]; do
        user_name=$(yq e ".operators[$i].accounts[$j].users[$k].name" "$ENTITIES")
        user_creds="$NKEYS_PATH/creds/$op_name/$acc_name/$user_name.creds"
        if [ -f "$user_creds" ]; then
          cp "$user_creds" "$USERS_DIR/${op_name}-${acc_name}-${user_name}.creds"
          echo "[entrypoint] Copied creds: ${op_name}-${acc_name}-${user_name}.creds"
        else
          echo "[entrypoint] WARNING: creds file not found: $user_creds" >&2
        fi
        k=$((k + 1))
      done
      j=$((j + 1))
    done

    i=$((i + 1))
  done

  echo "[entrypoint] Setup complete."
else
  echo "[entrypoint] Already initialized — skipping setup."
fi

exec nats-server -c /etc/nats/nats.conf
