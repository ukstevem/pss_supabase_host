#!/usr/bin/env bash
# scripts/resync.sh — refresh the self-hosted Supabase dev instance from cloud.
#
# Direction: ONE-WAY only — cloud → self-hosted. Never the reverse.
# Safe to re-run. Wipes and reloads the dev DB; cloud is read-only throughout.
#
# What this does:
#   1. Pre-flight checks (.env.cloud, ssh, cloud reachability)
#   2. Confirms with user before any destructive op
#   3. Re-dumps public schema + data + auth.users rows from cloud
#   4. Drops public schema on self-hosted
#   5. Restores schema (as postgres) + auth + data (as supabase_admin)
#   6. Row-count verification on TABLES from .env.cloud
#
# Usage:
#   scripts/resync.sh                  # interactive (recommended)
#   scripts/resync.sh --yes-i-am-sure  # non-interactive, for automation
#   scripts/resync.sh --help
#
# Prerequisites: see docs/08_resync.md.

set -euo pipefail

# --- defaults ---
VM_HOST="${VM_HOST:-ubuntu@10.0.0.85}"
ENV_FILE="${ENV_FILE:-.env.cloud}"

# If JUMP_HOST is set (e.g. JUMP_HOST=root@10.0.0.84 when on VPN with a
# non-LAN source IP), bounce all ssh through it. UFW on the VM gates
# port 22 to 10.0.0.0/24 source; the jump host is on that subnet so
# its outbound to the VM passes UFW.
SSH_OPTS=()
if [[ -n "${JUMP_HOST:-}" ]]; then
  SSH_OPTS+=(-J "${JUMP_HOST}")
fi

# --- parse args ---
SKIP_CONFIRM=0
for arg in "$@"; do
  case "$arg" in
    --yes-i-am-sure) SKIP_CONFIRM=1 ;;
    -h|--help)
      sed -n '2,/^set -euo pipefail$/p' "$0" | sed 's/^# \?//' | head -n -1
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      echo "Try --help" >&2
      exit 1
      ;;
  esac
done

# --- pre-flight ---
echo "==> pre-flight"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "  FAIL: ${ENV_FILE} not found in $(pwd)."
  echo "        Run from repo root after copying .env.cloud.example -> .env.cloud and filling values."
  exit 1
fi

# Source it
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

# Required vars
for v in CLOUD_PROJECT_REF CLOUD_DB_PASSWORD; do
  if [[ -z "${!v:-}" ]]; then
    echo "  FAIL: ${v} not set in ${ENV_FILE}"
    exit 1
  fi
done

# ONE-WAY safety guard: target must NOT be a cloud Supabase host.
# Per bd memory: data-flow-cloud-to-selfhosted-only.
if [[ "${VM_HOST}" == *"supabase.co"* ]] || [[ "${VM_HOST}" == *"pooler.supabase.com"* ]]; then
  echo "  FAIL: VM_HOST '${VM_HOST}' looks like a cloud Supabase URL."
  echo "        This script writes only to self-hosted; never to cloud."
  exit 1
fi

# Test SSH
if ! ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 -o BatchMode=yes "${VM_HOST}" "echo OK" >/dev/null 2>&1; then
  echo "  FAIL: cannot ssh to ${VM_HOST}. Check SSH keys + LAN."
  if [[ -z "${JUMP_HOST:-}" ]]; then
    echo "        On VPN with a non-LAN source IP? Set JUMP_HOST and retry:"
    echo "          JUMP_HOST=root@10.0.0.84 ./scripts/resync.sh"
  fi
  exit 1
fi
echo "  ssh ${VM_HOST}: OK"

# Test cloud DB reachability from the VM
echo "  cloud DB reach: testing..."
if ssh "${SSH_OPTS[@]}" "${VM_HOST}" "PGPASSWORD='${CLOUD_DB_PASSWORD}' psql 'host=db.${CLOUD_PROJECT_REF}.supabase.co port=5432 user=postgres dbname=postgres sslmode=require connect_timeout=10' -tAc 'SELECT 1' 2>/dev/null | grep -q '^1$'"; then
  echo "  cloud DB reach: OK"
else
  echo "  FAIL: cannot reach cloud DB from ${VM_HOST}."
  echo "        Check: IPv4 add-on enabled on Supabase project, CLOUD_DB_PASSWORD correct, IP not in cloud's banned-IPs list."
  exit 1
fi

# --- summary + confirm ---
echo ""
echo "==> READY TO REFRESH"
echo "    source (read-only): db.${CLOUD_PROJECT_REF}.supabase.co"
echo "    target (overwrite): ${VM_HOST}"
echo "    extra schemas:      ${EXTRA_SCHEMAS:-(none -- public only)}"
echo ""
echo "    Will:"
echo "      - DROP SCHEMA public CASCADE on self-hosted (wipes current dev data)"
echo "      - re-dump schema + data + auth.users from cloud"
echo "      - restore into self-hosted"
echo ""
echo "    Will NOT touch cloud."
echo ""

if [[ "${SKIP_CONFIRM}" -ne 1 ]]; then
  read -r -p "Continue? (yes/no): " confirm
  if [[ "${confirm}" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# --- step 1: dump ---
echo ""
echo "==> step 1/3: dump from cloud"
ssh "${SSH_OPTS[@]}" "${VM_HOST}" \
  "PGPASSWORD='${CLOUD_DB_PASSWORD}' CLOUD_PROJECT_REF='${CLOUD_PROJECT_REF}' EXTRA_SCHEMAS='${EXTRA_SCHEMAS:-}' bash" <<'VM'
set -euo pipefail
DUMP_DIR=/opt/pss-supabase-host/migration
HOST=db.${CLOUD_PROJECT_REF}.supabase.co
CONNARGS="host=${HOST} port=5432 user=postgres dbname=postgres sslmode=require connect_timeout=10"

# Archive previous dumps with timestamp suffix (rollback breadcrumb).
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "${DUMP_DIR}/.archive"
for f in schema.sql auth.sql data.sql; do
  [[ -f "${DUMP_DIR}/${f}" ]] && mv "${DUMP_DIR}/${f}" "${DUMP_DIR}/.archive/${f}.${TS}"
done

SCHEMA_ARGS="--schema=public"
for s in ${EXTRA_SCHEMAS}; do
  SCHEMA_ARGS="${SCHEMA_ARGS} --schema=${s}"
done

echo "  schema..."
pg_dump "${CONNARGS}" ${SCHEMA_ARGS} \
  --schema-only --no-owner --no-privileges \
  --no-publications --no-subscriptions \
  -f "${DUMP_DIR}/schema.sql"
echo "  data..."
pg_dump "${CONNARGS}" ${SCHEMA_ARGS} \
  --data-only --no-owner --no-privileges --disable-triggers \
  -f "${DUMP_DIR}/data.sql"
echo "  auth..."
pg_dump "${CONNARGS}" \
  --table=auth.users --table=auth.identities \
  --table=auth.sessions --table=auth.refresh_tokens \
  --data-only --no-owner --no-privileges --disable-triggers \
  -f "${DUMP_DIR}/auth.sql"

echo "  fresh dump:"
wc -l "${DUMP_DIR}"/*.sql
VM

# --- step 2: restore ---
echo ""
echo "==> step 2/3: restore on self-hosted"

# Wipe public schema completely. Cascades drop all public tables/funcs/policies.
echo "  drop public schema..."
ssh "${SSH_OPTS[@]}" "${VM_HOST}" 'docker exec -i supabase-db psql -U postgres -d postgres -c "DROP SCHEMA public CASCADE;" 2>&1 | tail -1'

# Wipe the auth.* tables we'll be reloading. Without this, auth.sql's COPY
# hits duplicate-key conflicts on re-runs (auth.users keeps rows from the
# previous load until something explicitly clears them). RESTART IDENTITY
# resets sequence values; CASCADE handles any cross-schema FKs from the
# supabase-managed schemas (storage etc.).
echo "  truncate auth tables..."
ssh "${SSH_OPTS[@]}" "${VM_HOST}" 'docker exec -i supabase-db psql -U supabase_admin -d postgres -c "TRUNCATE auth.users, auth.identities, auth.sessions, auth.refresh_tokens RESTART IDENTITY CASCADE;" 2>&1 | tail -1'

echo "  schema..."
ssh "${SSH_OPTS[@]}" "${VM_HOST}" 'docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < /opt/pss-supabase-host/migration/schema.sql 2>&1 | grep -E "^ERROR" | head -5 || true'
echo "  auth (as supabase_admin)..."
ssh "${SSH_OPTS[@]}" "${VM_HOST}" 'docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < /opt/pss-supabase-host/migration/auth.sql 2>&1 | grep -E "^ERROR" | head -5 || true'
echo "  data (as supabase_admin)..."
ssh "${SSH_OPTS[@]}" "${VM_HOST}" 'docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < /opt/pss-supabase-host/migration/data.sql 2>&1 | grep -E "^ERROR" | head -5 || true'

# Re-apply standard Supabase role grants on public. pg_dump --no-privileges
# strips these; without them PostgREST returns 403 silently because anon /
# authenticated / service_role have no SELECT on the migrated tables.
echo "  apply standard supabase grants..."
ssh "${SSH_OPTS[@]}" "${VM_HOST}" 'docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1' \
  < scripts/sql/post_restore_grants.sql \
  2>&1 | grep -E "^ERROR" | head -5 || true

# --- step 3: verify ---
echo ""
echo "==> step 3/3: row counts (from TABLES in .env.cloud)"

ssh "${SSH_OPTS[@]}" "${VM_HOST}" "TABLES='${TABLES:-auth.users}' bash" <<'VM'
set -euo pipefail
printf "%-35s %15s\n" "Table" "Rows"
printf "%-35s %15s\n" "-----" "----"
for t in ${TABLES}; do
  c=$(docker exec -i supabase-db psql -U postgres -d postgres -tAc "SELECT count(*) FROM ${t}" 2>/dev/null || echo "ERR")
  printf "%-35s %15s\n" "${t}" "${c}"
done
VM

echo ""
echo "==> done. Dev DB refreshed at $(date)."
