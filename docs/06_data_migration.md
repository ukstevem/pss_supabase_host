# 06 — Migrate schema + data from cloud Supabase (one-shot)

**Bead:** `pssh-yp3`
**Goal:** Use `pg_dump` against the cloud Supabase project to capture the **public** schema (tables + RLS policies + functions + triggers + indexes + sequences + data) and the rows from the Supabase-managed `auth` tables that public-schema FKs depend on. Restore into the self-hosted Postgres at `10.0.0.85`. Verify by row-count comparison on the largest tables. After this bead, the dev Supabase has the same dataset as the cloud Supabase, frozen at dump time.

This is a **one-shot** migration. If you want it kept live on an ongoing basis, that's `pssh-3ve` (logical replication) — a follow-up after we've proven app integration in `pssh-y3s`.

---

## Prerequisites

- `pssh-fj1` closed: self-hosted Supabase is up at `10.0.0.85:8000`, all services healthy.
- You can log into the cloud Supabase dashboard at https://supabase.com/dashboard.
- You know which cloud project to migrate from (or there's only one, easy).

---

## What gets migrated, what doesn't

| What | From cloud | To self-hosted | Notes |
|---|---|---|---|
| `public` schema definitions | dumped | restored | Tables, RLS policies, fns, triggers, indexes, sequences, default privileges |
| `public` schema data | dumped (COPY format) | restored | All rows, all tables |
| `auth.users`, `auth.identities`, `auth.sessions`, `auth.refresh_tokens` rows | dumped (data only) | restored | Schema is provided by self-hosted GoTrue; we only move rows |
| Custom user-defined schemas | dumped *if you list them* | restored | Edit `EXTRA_SCHEMAS` in step 4 |
| `storage.objects` / `storage.buckets` metadata | **not in this bead** | — | Handled by `pssh-2iy` (storage sync) |
| Edge functions code | **not migrated automatically** | — | Use `supabase functions deploy` separately if needed |
| Supabase-managed schemas (`auth` schema, `storage` schema, `realtime`, `supabase_functions`, `pgsodium`, `vault`, `extensions`, `graphql`, `graphql_public`) | **not dumped** | recreated by self-hosted stack | Each container's init scripts own these; never copy them |
| Extensions (`pg_graphql`, `pgvector`, `pg_stat_statements`, etc.) | **not dumped explicitly** | already installed by `supabase/postgres` image | If you've added a non-standard extension on cloud, install it on self-hosted manually before restore |

### Two gotchas to know about up-front

1. **`pgsodium`-encrypted columns** — if the cloud DB encrypts columns via `pgsodium`, the keys are server-side and not portable. The dumped ciphertext can't be decrypted by the self-hosted instance with a different key. Workaround is project-specific (decrypt on cloud first, or share the master key). Not common for typical PSS apps; skip unless you hit it.
2. **Foreign keys from `public.*` to `auth.users`** — these are common (e.g. `public.profiles.id REFERENCES auth.users(id)`). We load `auth.users` rows **before** `public` data, with `session_replication_role = replica` set so the FK checks don't fight us during the restore.

---

## Information you need to gather

Open the cloud project in https://supabase.com/dashboard, then go to **Project Settings → Database**.

| You need | Where it is |
|---|---|
| **Project ref** | Top of the Database page, labelled "Reference ID" (e.g. `xyzabcdefghij`). It's the same ID that's in the project URL `https://xyzabcdefghij.supabase.co`. |
| **Database password** | "Database password" section. If you don't know it, click **Reset database password** — it'll generate a fresh one. *Save it somewhere; you can't read it again.* |
| **Direct connection host** | "Connection string" → "URI" tab → switch to **"Direct connection"** (NOT "Transaction pooler" or "Session pooler"). The host will be `db.<project-ref>.supabase.co`. We need direct because pg_dump uses statements pooler doesn't reliably handle. |

> **Don't paste the password in this chat.** When the migration script asks for it, type it directly in your local terminal — the value is captured into a shell variable and only ever travels over the SSH tunnel to the VM.

---

## 0. Inputs

| Var | Default | Source |
|---|---|---|
| `CLOUD_PROJECT_REF` | (you provide) | dashboard reference ID |
| `CLOUD_DB_PASSWORD` | (you provide) | dashboard, prompted at run-time |
| `CLOUD_HOST` | `db.${CLOUD_PROJECT_REF}.supabase.co` | derived |
| `CLOUD_USER` | `postgres` | dashboard default |
| `CLOUD_DB` | `postgres` | dashboard default |
| `CLOUD_PORT` | `5432` | direct connection |
| `EXTRA_SCHEMAS` | `""` (empty) | space-separated list, e.g. `"reporting analytics"` if you have custom non-public schemas |
| Local DB | `supabase-db` container | (per `pssh-fj1`) |
| Working dir on VM | `/opt/pss-supabase-host/migration` | created by step 1 |

---

## 1. Install postgresql-client on the VM

We need `pg_dump` and `psql` on the VM itself (rather than running them inside the `supabase-db` container) so the dumped SQL files land on the VM's filesystem and can be restored cleanly.

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
set -euo pipefail
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-client-16
mkdir -p /opt/pss-supabase-host/migration
chmod 700 /opt/pss-supabase-host/migration
echo "pg_dump version:"
pg_dump --version
VM
```

`postgresql-client-16` is fine to dump from a 15 server — pg_dump is forwards-compatible. (If you're on a newer Ubuntu, `-17` works the same.)

---

## 2. Test connectivity to the cloud DB

```bash
# Type the password when prompted; it goes into a local var only,
# then transits over SSH (encrypted) to the VM.
read -s -p "Cloud Supabase DB password: " CLOUD_DB_PASSWORD
echo  # newline after the silent prompt

# Set your project ref here (from the dashboard)
CLOUD_PROJECT_REF=xyzabcdefghij    # <-- EDIT THIS

ssh ubuntu@10.0.0.85 \
  "CLOUD_PROJECT_REF='${CLOUD_PROJECT_REF}' CLOUD_DB_PASSWORD='${CLOUD_DB_PASSWORD}' bash" <<'VM'
set -euo pipefail

CLOUD_HOST="db.${CLOUD_PROJECT_REF}.supabase.co"

echo "--- DNS resolution ---"
getent hosts "${CLOUD_HOST}" || { echo "Could not resolve ${CLOUD_HOST}"; exit 1; }

echo "--- TCP connectivity ---"
nc -z -w 5 "${CLOUD_HOST}" 5432 && echo "  connect OK" || { echo "  connect FAILED"; exit 1; }

echo "--- SQL ping ---"
PGPASSWORD="${CLOUD_DB_PASSWORD}" psql \
  "postgresql://postgres@${CLOUD_HOST}:5432/postgres?sslmode=require" \
  -c "SELECT version(), current_database(), current_user;"
VM
```

You should see Postgres' version banner, `current_database = postgres`, `current_user = postgres`. If DNS, TCP, or SQL fails, fix that before going further (typically: wrong project ref, IP firewall on the cloud project, or wrong password).

---

## 3. Dump from cloud

This produces three SQL files in `/opt/pss-supabase-host/migration/`:

- `schema.sql` — `public` schema DDL
- `data.sql` — `public` schema data (COPY format)
- `auth.sql` — rows from `auth.users` / `auth.identities` / `auth.sessions` / `auth.refresh_tokens`

```bash
read -s -p "Cloud Supabase DB password: " CLOUD_DB_PASSWORD
echo
CLOUD_PROJECT_REF=xyzabcdefghij    # <-- EDIT THIS
EXTRA_SCHEMAS=""                   # <-- e.g. "reporting analytics" if you have non-public schemas

ssh ubuntu@10.0.0.85 \
  "CLOUD_PROJECT_REF='${CLOUD_PROJECT_REF}' CLOUD_DB_PASSWORD='${CLOUD_DB_PASSWORD}' EXTRA_SCHEMAS='${EXTRA_SCHEMAS}' bash" <<'VM'
set -euo pipefail

CLOUD_HOST="db.${CLOUD_PROJECT_REF}.supabase.co"
DUMP_DIR=/opt/pss-supabase-host/migration
CONN="postgresql://postgres:${CLOUD_DB_PASSWORD}@${CLOUD_HOST}:5432/postgres?sslmode=require"

# Build --schema args: always public, plus any extras the user listed
SCHEMA_ARGS="--schema=public"
for s in ${EXTRA_SCHEMAS}; do
  SCHEMA_ARGS="${SCHEMA_ARGS} --schema=${s}"
done

echo "==> 1/3 dump schema (DDL only)"
pg_dump "${CONN}" \
  ${SCHEMA_ARGS} \
  --schema-only \
  --no-owner --no-privileges \
  --no-publications --no-subscriptions \
  -f "${DUMP_DIR}/schema.sql"

echo "==> 2/3 dump data (COPY format, no DDL)"
pg_dump "${CONN}" \
  ${SCHEMA_ARGS} \
  --data-only \
  --no-owner --no-privileges \
  --disable-triggers \
  -f "${DUMP_DIR}/data.sql"

echo "==> 3/3 dump auth.* rows (data only — auth schema is provided by self-hosted GoTrue)"
pg_dump "${CONN}" \
  --table=auth.users \
  --table=auth.identities \
  --table=auth.sessions \
  --table=auth.refresh_tokens \
  --data-only \
  --no-owner --no-privileges \
  --disable-triggers \
  -f "${DUMP_DIR}/auth.sql"

ls -la "${DUMP_DIR}/"
echo "--- sizes ---"
wc -l "${DUMP_DIR}"/*.sql
VM
```

The `--no-owner --no-privileges` flags strip cloud-specific role names from the dump (cloud uses roles like `postgres`, `supabase_admin`, etc.). On restore, everything ends up owned by the local `postgres` user. The `--disable-triggers` flag wraps data inserts in `SET session_replication_role = replica` so FK constraints don't fail the load.

---

## 4. Restore into self-hosted

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
set -euo pipefail
DUMP_DIR=/opt/pss-supabase-host/migration

restore_into_db() {
  local sql_file=$1
  echo "==> restoring $(basename "${sql_file}") into supabase-db..."
  docker exec -i supabase-db psql \
    -U postgres -d postgres \
    -v ON_ERROR_STOP=1 \
    -f - < "${sql_file}" \
    | tail -20
}

# Order:
# 1. schema (creates public.* tables — auth.users already exists, provided by GoTrue)
# 2. auth data (auth.users rows — must come BEFORE public data because of FKs)
# 3. public data (now FKs to auth.users will resolve)
restore_into_db "${DUMP_DIR}/schema.sql"
restore_into_db "${DUMP_DIR}/auth.sql"
restore_into_db "${DUMP_DIR}/data.sql"

echo "==> done"
VM
```

`-v ON_ERROR_STOP=1` makes psql exit on the first error (otherwise it'll plow through and you only notice problems hours later). If something fails, the message will be in the last 20 lines piped via `tail`.

Common errors and how to read them:
- `relation "<thing>" already exists` — schema.sql ran twice. Either you re-ran step 4, or there are leftover tables from a previous attempt. Drop the public schema and try again (see Rollback below).
- `violates foreign key constraint "<...>_user_id_fkey"` — auth.users hadn't been loaded yet. Re-run with `auth.sql` before `data.sql` (already the order in the script).
- `extension "<x>" is not available` — cloud DB has an extension self-hosted doesn't. `docker exec supabase-db psql -U postgres -c '\dx'` shows what's installed; install the missing one on self-hosted before retrying.

---

## 5. Verify

Compare row counts on the largest tables, between cloud and self-hosted. Adjust the `TABLES` list to whatever's representative for your project — it's used both ways.

```bash
read -s -p "Cloud Supabase DB password: " CLOUD_DB_PASSWORD
echo
CLOUD_PROJECT_REF=xyzabcdefghij    # <-- EDIT THIS
TABLES="public.users public.profiles public.orders auth.users"   # <-- EDIT FOR YOUR SCHEMA

ssh ubuntu@10.0.0.85 \
  "CLOUD_PROJECT_REF='${CLOUD_PROJECT_REF}' CLOUD_DB_PASSWORD='${CLOUD_DB_PASSWORD}' TABLES='${TABLES}' bash" <<'VM'
set -euo pipefail
CLOUD_CONN="postgresql://postgres:${CLOUD_DB_PASSWORD}@db.${CLOUD_PROJECT_REF}.supabase.co:5432/postgres?sslmode=require"

printf "%-30s %15s %15s %s\n" "Table" "Cloud" "Self-hosted" "Diff"
printf "%-30s %15s %15s %s\n" "-----" "-----" "-----------" "----"

for t in ${TABLES}; do
  cloud_count=$(psql "${CLOUD_CONN}" -tAc "SELECT count(*) FROM ${t}" 2>/dev/null || echo "ERR")
  local_count=$(docker exec -i supabase-db psql -U postgres -d postgres -tAc "SELECT count(*) FROM ${t}" 2>/dev/null || echo "ERR")
  if [ "${cloud_count}" = "${local_count}" ]; then
    diff="OK"
  else
    diff=$(( cloud_count - local_count ))
  fi
  printf "%-30s %15s %15s %s\n" "${t}" "${cloud_count}" "${local_count}" "${diff}"
done
VM
```

Expected: `OK` for every row. Any non-zero diff means data drift (rows added on cloud after dump, or restore failure on a specific table). Drift is fine if you know about it; `ERR` on either side means the table doesn't exist there.

Sample query: pick one app entity and confirm it round-trips. From self-hosted Studio's SQL editor:

```sql
SELECT id, created_at FROM public.profiles ORDER BY created_at DESC LIMIT 5;
```

Compare against the same query in cloud Studio.

---

## Acceptance checklist (for `pssh-yp3`)

- [ ] `pg_dump` ran cleanly against cloud — `schema.sql`, `data.sql`, `auth.sql` exist in `/opt/pss-supabase-host/migration/`, all non-empty
- [ ] Restore in step 4 completed without `ERROR` lines (other than benign warnings about plpgsql etc.)
- [ ] Row-count comparison in step 5: every table in `TABLES` reports `OK`
- [ ] Sample SQL query against self-hosted Studio returns the expected data
- [ ] An existing cloud-side user can sign in via the self-hosted Studio's SQL Editor (run `SELECT id, email FROM auth.users LIMIT 5;` — emails should match cloud)
- [ ] No app-rebuild required yet (we haven't pointed apps at the new instance — that's `pssh-y3s`)

When all six are ✓, close the bead: `bd close pssh-yp3`.

---

## Rollback / start over

If a restore goes wrong and you want to wipe the schema and try again:

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
docker exec -i supabase-db psql -U postgres -d postgres <<'SQL'
-- Drop all public schema objects, then recreate the empty schema
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO postgres;
GRANT ALL ON SCHEMA public TO public;
COMMENT ON SCHEMA public IS 'standard public schema';

-- Wipe auth data (the schema itself stays — provided by GoTrue)
TRUNCATE auth.users CASCADE;
SQL
VM
```

Then re-run step 4. Don't re-run step 3 unless cloud data has changed; the dump files are still valid.

For a *full* reset back to "stack just came up, empty DB":

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
cd /opt/supabase/docker
docker compose down -v   # wipes ALL volumes including the database
docker compose up -d
sleep 60   # wait for db to be healthy again
VM
```

---

## What's next

Closing `pssh-yp3` brings us closer to `pssh-y3s` (wiring `platform-portal/.env` and verifying with one app), but `pssh-y3s` also depends on `pssh-2iy` (storage bucket sync). Whichever of those two you do next is up to you — they don't depend on each other.
