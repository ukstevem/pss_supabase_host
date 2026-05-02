#!/usr/bin/env bash
# scripts/print_connections.sh — print self-hosted Supabase connection details
# as a markdown sheet. Pulls live values from the VM each invocation;
# nothing cached, nothing written to repo by this script.
#
# Usage:
#   ./scripts/print_connections.sh                    # print to terminal
#   ./scripts/print_connections.sh > connections.md   # save locally (gitignored)
#
# The output is a full markdown reference: Studio URL + dashboard creds,
# Kong base URL + anon/service-role keys, Postgres connection strings for
# DBeaver / pgAdmin / psql.

set -euo pipefail

VM_HOST="${VM_HOST:-ubuntu@10.0.0.85}"
VM_IP="${VM_HOST##*@}"

# Pull a single key=value from the merged supabase env on the VM.
get() {
  ssh -o ConnectTimeout=5 "${VM_HOST}" "grep -E '^${1}=' /opt/supabase/docker/.env | head -1 | sed 's/^${1}=//'"
}

# Pre-flight: confirm we can ssh
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${VM_HOST}" "echo OK" >/dev/null 2>&1; then
  echo "ERROR: cannot ssh to ${VM_HOST}" >&2
  exit 1
fi

POSTGRES_PASSWORD=$(get POSTGRES_PASSWORD)
ANON_KEY=$(get ANON_KEY)
SERVICE_ROLE_KEY=$(get SERVICE_ROLE_KEY)
JWT_SECRET=$(get JWT_SECRET)
DASHBOARD_USERNAME=$(get DASHBOARD_USERNAME)
DASHBOARD_PASSWORD=$(get DASHBOARD_PASSWORD)
POOLER_TENANT_ID=$(get POOLER_TENANT_ID)

cat <<EOF
# Self-hosted Supabase — connection details

> Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by \`scripts/print_connections.sh\`.
> **This file contains live secrets — keep it local.** \`connections.md\` is gitignored
> so saving it in the repo root is safe; do not commit it to other repos.

## Studio (admin UI)

| | |
|---|---|
| URL | http://${VM_IP}:8000/ |
| Auth | HTTP Basic Auth — browser pops an OS credential dialog |
| Username | \`${DASHBOARD_USERNAME}\` |
| Password | \`${DASHBOARD_PASSWORD}\` |

## Kong API (REST / Auth / Realtime / Storage)

Base URL: \`http://${VM_IP}:8000\`

| Service | Path |
|---|---|
| REST (auto-generated from public schema) | \`/rest/v1/<table>\` |
| Auth (GoTrue) | \`/auth/v1/...\` |
| Realtime (websockets) | \`/realtime/v1/...\` |
| Storage | \`/storage/v1/...\` |

### Anon key — client-side, RLS-gated

\`\`\`
${ANON_KEY}
\`\`\`

Use as either header:
- \`apikey: <anon-key>\`
- \`Authorization: Bearer <anon-key>\`

### Service role key — server-side, bypasses RLS

\`\`\`
${SERVICE_ROLE_KEY}
\`\`\`

⚠️ Treat as fully privileged. Don't ship to browsers/mobile. Same header pattern as anon key.

### Quick curl examples

\`\`\`bash
# List 5 parts via REST as anon (will be subject to RLS policies on public.parts)
curl "http://${VM_IP}:8000/rest/v1/parts?limit=5&select=*" \\
  -H "apikey: ${ANON_KEY}" \\
  -H "Authorization: Bearer ${ANON_KEY}"

# List 5 parts as service_role (bypasses RLS — sees everything)
curl "http://${VM_IP}:8000/rest/v1/parts?limit=5&select=*" \\
  -H "apikey: ${SERVICE_ROLE_KEY}" \\
  -H "Authorization: Bearer ${SERVICE_ROLE_KEY}"

# Sign in a user (returns a JWT you can then use as Authorization)
curl "http://${VM_IP}:8000/auth/v1/token?grant_type=password" \\
  -H "apikey: ${ANON_KEY}" \\
  -H "Content-Type: application/json" \\
  -d '{"email":"some@user.com","password":"theirpassword"}'
\`\`\`

## Postgres (via Supavisor pooler — for DBeaver / pgAdmin / psql)

| | |
|---|---|
| Host | \`${VM_IP}\` |
| Port | \`5432\` (session pool — recommended for IDE clients) |
| Port (alt) | \`6543\` (transaction pool — for connection-per-query workloads) |
| Database | \`postgres\` |
| User | \`postgres.${POOLER_TENANT_ID}\` |
| Password | \`${POSTGRES_PASSWORD}\` |
| SSL | not required (LAN-only) |

### Connection string

\`\`\`
postgresql://postgres.${POOLER_TENANT_ID}:${POSTGRES_PASSWORD}@${VM_IP}:5432/postgres
\`\`\`

### psql

\`\`\`bash
PGPASSWORD='${POSTGRES_PASSWORD}' psql \\
  "host=${VM_IP} port=5432 user=postgres.${POOLER_TENANT_ID} dbname=postgres"
\`\`\`

## Postgres (bypass pooler — for SQL admin via the VM)

Useful for DDL, server-side functions, true superuser operations the pooler doesn't reliably handle.

\`\`\`bash
# As 'postgres' role (NOT a superuser in PG17 — fine for queries, fails on TRUNCATE auth tables etc.)
ssh ${VM_HOST} 'docker exec -it supabase-db psql -U postgres -d postgres'

# As 'supabase_admin' (true superuser via container Unix socket trust auth — no password needed)
ssh ${VM_HOST} 'docker exec -it supabase-db psql -U supabase_admin -d postgres'
\`\`\`

## JWT secret (for signing custom JWTs in tests)

\`\`\`
${JWT_SECRET}
\`\`\`

Use to sign your own JWTs with custom \`role\` / \`sub\` / \`exp\` claims if you need to test things the standard anon/service_role keys don't cover. \`scripts/gen_secrets.py\` shows the HS256-signing recipe.

---

If anything here doesn't work (a key has been rotated, the VM is down, etc.), regenerate this file with \`./scripts/print_connections.sh > connections.md\`.
EOF
