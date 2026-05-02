# 06 — Migrate schema + data from cloud Supabase (one-shot)

**Bead:** `pssh-yp3`
**Goal:** Use `pg_dump` against the cloud Supabase project to capture the **public** schema (tables + RLS policies + functions + triggers + indexes + sequences + data) and the rows from the Supabase-managed `auth` tables that public-schema FKs depend on. Restore into the self-hosted Postgres at `10.0.0.85`. Verify the self-hosted side looks right. After this bead, the dev Supabase has the same dataset as the cloud Supabase, frozen at dump time.

This is a **one-shot** migration. If you want it kept live on an ongoing basis, that's `pssh-3ve` (logical replication) — a follow-up after we've proven app integration in `pssh-y3s`.

> **Networking caveat — IPv4 add-on**: Supabase's free Direct connection (`db.<ref>.supabase.co`) is **IPv6 only**. The Session pooler (IPv4) and IPv4 access to the Direct connection are both behind a paid **IPv4 add-on** ($4/mo at time of writing). Most home/SMB LANs don't have working IPv6 routing (the LAN this was built on is behind a SonicWall that doesn't advertise IPv6 prefixes), so the VM at `10.0.0.85` cannot reach the cloud DB without one of two things: (a) the IPv4 add-on enabled on the cloud project, or (b) IPv6 enabled on the LAN router/firewall. Pragmatically: enable the add-on for the duration of the migration, run sections 1–4 from the VM, then cancel the add-on. Two-machine workflow (dump elsewhere, scp to VM) is documented in section 2 as a fallback.

> **Cloud password ≠ API key**: Supabase has multiple "secrets" that look superficially similar. The migration needs the **Database password** (Settings → Database → "Database password"), *not* the service-role key (`sb_secret_…` or the longer `eyJhbG…` JWT, used in API headers, *not* a Postgres role's password). Easy mistake — Postgres will reject the API key with `password authentication failed`, and after a few attempts will auto-ban the source IP (see "IP banned" in Troubleshooting).

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
| **Database password** | "Database password" section. If you don't know it, click **Reset database password** — it'll generate a fresh one. *Save it somewhere; you can't read it again.* |
| **Session pooler URI** | "Connection string" section → **URI** tab → switch to **"Session pooler"**. Copy the full URI; it'll have `[YOUR-PASSWORD]` as a placeholder where the real password goes. |

> **Why Session pooler, not Direct connection?** Supabase's "Direct connection" host (`db.<ref>.supabase.co`) resolves to **IPv6 only**. Most home/Proxmox LANs don't have IPv6 routing, so `pg_dump` against the direct host fails with "connection refused" even though DNS works. The Session pooler is IPv4-reachable, supports the session-level state `pg_dump` requires, and is exactly what Supabase recommends for migrations. (We can't use the Transaction pooler at port 6543 — that one breaks `pg_dump` because it doesn't preserve session state across statements.)

> **Don't paste the password in this chat.** Put the URI (with the real password substituted in for `[YOUR-PASSWORD]`) in `.env.cloud` (gitignored, see step 0 below) and the migration heredocs will source it. The value is forwarded over SSH (encrypted) to the VM, never written to the VM's disk.

---

## 0. Inputs — set up `.env.cloud` once

Copy the committed template to `.env.cloud` (gitignored) and fill in your values:

```bash
# From the repo root on your dev workstation
cp .env.cloud.example .env.cloud
chmod 600 .env.cloud
# Edit .env.cloud in your editor of choice and fill in:
#   CLOUD_DB_URL, EXTRA_SCHEMAS (optional), TABLES (optional)
```

The shape of `.env.cloud`:

```bash
# Full Session pooler URI from the dashboard, with [YOUR-PASSWORD] replaced by your actual password.
# Example shape (yours will differ in region and ref):
CLOUD_DB_URL='postgresql://postgres.xyzabcdefghij:your-real-pw@aws-0-eu-west-2.pooler.supabase.com:5432/postgres'

EXTRA_SCHEMAS=""                                    # e.g. "reporting analytics" if you have non-public schemas
TABLES="public.profiles public.orders auth.users"   # for the row-count verification step
```

**Quote the URI** with single quotes — the password embedded in it may contain shell-special characters like `$`, `!`, `` ` ``, or `\`.

The remaining inputs are derived or fixed:

| Var | Value | Source |
|---|---|---|
| Local DB | `supabase-db` container | per `pssh-fj1` |
| Working dir on VM | `/opt/pss-supabase-host/migration` | created by step 1 |

---

## 1. Install postgresql-client on the VM

We need `pg_dump` and `psql` on the VM. **Critical**: the client major version must be **≥** the cloud server's major version. Cloud Supabase is on PG17, so we need `postgresql-client-17`. Ubuntu 24.04's default repo only ships up to v16, so we add PostgreSQL's official apt repo:

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
set -euo pipefail

echo "==> add PG official apt repo (Ubuntu 24.04 default repos top out at v16)"
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null

echo "==> install postgresql-client-17"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-client-17

echo "==> migration working dir"
mkdir -p /opt/pss-supabase-host/migration
chmod 700 /opt/pss-supabase-host/migration

echo "==> verify"
pg_dump --version  # should report 17.x; if cloud is later upgraded to 18, install -18 here
VM
```

> **Why ≥ server version**: pg_dump is *forwards*-compatible (newer client can dump older servers) but not backwards. A v16 client trying to dump a v17 server aborts with `aborting because of server version mismatch`.

---

## 2. Generate the dump files (anywhere with cloud connectivity)

> **Why this isn't run from the VM**: Supabase's Direct connection (`db.<ref>.supabase.co`) is **IPv6 only**. The Session/Transaction poolers (which are IPv4) are now behind Supabase's paid IPv4 add-on. On a typical home/SMB LAN without IPv6 routing — including this one, behind a SonicWall that doesn't advertise IPv6 prefixes — the VM has no path to the cloud DB at all. So we produce the dump on a machine that *does* have a working route to the cloud, then transfer the resulting SQL files to the VM in section 3.

### Pick where you'll run pg_dump

Any one of these works. Pick the least-friction option for your situation.

| Option | Effort | Notes |
|---|---|---|
| **Phone tether (mobile data)** | 2 min | Most UK mobile networks are IPv6-native on 4G/5G. Tether your dev workstation's internet through your phone, then `pg_dump` works against the IPv6 Direct connection. Drop the tether when done. |
| **Any other Linux/macOS machine that already has IPv6** | 0–5 min | A home server, a colleague's machine, an existing cloud server with IPv6. |
| **Temporary cheap cloud VM** | 10 min, ~$0.01 | DigitalOcean / Linode / Hetzner all default to dual-stack IPv4+IPv6 and bill by the hour. Spin one up, run the dump, scp results down, destroy. |
| **Hurricane Electric tunnel broker on this VM** | 20 min, free | tunnelbroker.net gives you a routable IPv6 /64 over IPv4. Requires the SonicWall to allow IP protocol 41 outbound. Pure config; no money. |
| **Pay Supabase for the IPv4 add-on** | instant, ~$4/mo | Then the Session pooler URL we set up earlier works directly from this VM. No further config. |

### Run pg_dump

Once you're on a machine that has a working route to the cloud Supabase, **install postgresql-client-16 if it isn't there**, then load `.env.cloud` (or set `CLOUD_DB_URL` directly) and run:

```bash
# This block is run on whichever machine you chose above — NOT necessarily the VM.
# .env.cloud lives in the repo; if you're not on your dev workstation, copy/recreate it
# wherever you are. The CLOUD_DB_URL should be the IPv6 Direct connection URI:
#   postgresql://postgres:<password>@db.<project-ref>.supabase.co:5432/postgres?sslmode=require

set -a; source .env.cloud; set +a
mkdir -p ./migration && chmod 700 ./migration

# Build --schema args: always public, plus any extras
SCHEMA_ARGS="--schema=public"
for s in ${EXTRA_SCHEMAS}; do
  SCHEMA_ARGS="${SCHEMA_ARGS} --schema=${s}"
done

echo "==> 1/3 dump schema (DDL only)"
pg_dump "${CLOUD_DB_URL}" \
  ${SCHEMA_ARGS} \
  --schema-only \
  --no-owner --no-privileges \
  --no-publications --no-subscriptions \
  -f ./migration/schema.sql

echo "==> 2/3 dump data (COPY format, no DDL)"
pg_dump "${CLOUD_DB_URL}" \
  ${SCHEMA_ARGS} \
  --data-only \
  --no-owner --no-privileges \
  --disable-triggers \
  -f ./migration/data.sql

echo "==> 3/3 dump auth.* rows (data only — auth schema is provided by self-hosted GoTrue)"
pg_dump "${CLOUD_DB_URL}" \
  --table=auth.users \
  --table=auth.identities \
  --table=auth.sessions \
  --table=auth.refresh_tokens \
  --data-only \
  --no-owner --no-privileges \
  --disable-triggers \
  -f ./migration/auth.sql

ls -la ./migration/
wc -l ./migration/*.sql
```

The `--no-owner --no-privileges` flags strip cloud-specific role names from the dump (cloud uses roles like `supabase_admin`, etc.). On restore, everything ends up owned by the local `postgres` user. The `--disable-triggers` flag wraps data inserts in `SET session_replication_role = replica` so FK constraints don't fail the load.

End state of this section: three SQL files (`schema.sql`, `data.sql`, `auth.sql`) on the machine where you ran the dump.

---

## 3. Transfer the dump files to the VM

From wherever the SQL files ended up:

```bash
# If you ran the dump from your dev workstation, the files are in ./migration/ — adjust if elsewhere.
scp -r ./migration/*.sql ubuntu@10.0.0.85:/opt/pss-supabase-host/migration/

# Quick sanity check on the receiving end
ssh ubuntu@10.0.0.85 'ls -la /opt/pss-supabase-host/migration/ && wc -l /opt/pss-supabase-host/migration/*.sql'
```

The directory was created as part of section 1; permissions should already be correct (`700`, owned by `ubuntu`).

---

## 4. Restore into self-hosted

Two important nuances vs. a vanilla pg_restore:

1. **Drop the empty default `public` schema first.** Supabase's container init creates an empty `public` schema; the dump's `CREATE SCHEMA public` then conflicts. `DROP SCHEMA public CASCADE` is safe because the default is empty.
2. **Run as `supabase_admin`, not `postgres`, for the data restores.** In `supabase/postgres:17.x`, the `postgres` role is **not** a superuser (changed from PG15). The dump's `--disable-triggers` emits `ALTER TABLE ... DISABLE TRIGGER ALL`, which requires superuser. Only `supabase_admin` is. Trust auth via the local Unix socket inside the container means no password needed for the in-container `-U supabase_admin` connection.

The schema restore can run as `postgres` (it's just DDL), but the auth and data restores must use `supabase_admin`.

```bash
# Step A: drop the default empty public schema so the dump's CREATE SCHEMA works
ssh ubuntu@10.0.0.85 'docker exec -i supabase-db psql -U postgres -d postgres -c "DROP SCHEMA public CASCADE;"'

# Step B: restore the schema (DDL)
ssh ubuntu@10.0.0.85 'docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < /opt/pss-supabase-host/migration/schema.sql 2>&1 | tail -30'

# Step C: restore auth.* data — must come BEFORE public data due to FKs (run as supabase_admin)
ssh ubuntu@10.0.0.85 'docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < /opt/pss-supabase-host/migration/auth.sql 2>&1 | tail -20'

# Step D: restore public.* data (the slow one — minutes for tens of MB; run as supabase_admin)
ssh ubuntu@10.0.0.85 'docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < /opt/pss-supabase-host/migration/data.sql 2>&1 | tail -30'
```

`-v ON_ERROR_STOP=1` makes psql exit on the first error rather than plowing through. The dump finishes with a series of `setval` calls; seeing those in step D's tail output is the signal it completed.

Common errors and how to read them:
- `schema "public" already exists` — you skipped step A. Run it, then retry from step B.
- `must be owner of table users` / `permission denied: "..." is a system trigger` — you ran step C or D as `postgres` instead of `supabase_admin`. The `postgres` role is non-superuser in PG17 supabase image so it can't disable triggers. Re-run with `-U supabase_admin`.
- `aborting because of server version mismatch` (during dump in section 2) — your `pg_dump` client is older than the server. Install `postgresql-client-17` from PG's official apt repo (covered in section 1).
- `relation "<thing>" already exists` — schema.sql ran twice without a DROP in between. Run step A again, then re-do steps B/C/D in order.
- `violates foreign key constraint "<...>_user_id_fkey"` — auth.users hadn't been loaded yet. Re-run in the C-then-D order shown above.
- `extension "<x>" is not available` — cloud DB has an extension self-hosted doesn't. `docker exec supabase-db psql -U postgres -c '\dx'` shows what's installed; install the missing one on self-hosted before retrying.

### Step E: re-apply standard Supabase role grants

**Critical** — without this step, PostgREST returns `403 Forbidden` silently on every REST call. Studio still works (it connects as `supabase_admin`), but apps using the `anon` / `authenticated` / `service_role` keys can't see anything.

Why: `pg_dump --no-privileges` strips ALL grant statements, including the standard `GRANT TO anon, authenticated, service_role` lines that Supabase's init normally applies on a fresh install. Restore brings back tables/functions but with no API-role permissions on them.

Run after step D:

```bash
cat scripts/sql/post_restore_grants.sql \
  | ssh ubuntu@10.0.0.85 'docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1'
```

(With `JUMP_HOST=root@10.0.0.84` prefix if on VPN.)

The script GRANTs `USAGE` on the `public` schema and `ALL` on all tables / sequences / functions to the three Supabase API roles, plus sets `ALTER DEFAULT PRIVILEGES` so future objects you create in `public` (e.g. via Studio) also get the grants automatically.

`scripts/resync.sh` applies this automatically as the final step of its restore phase since 2026-05-02.

---

## 5. Verify

Two parts: (a) confirm self-hosted is in a sensible state on its own; (b) optionally compare against cloud if you still have a way to reach the cloud DB.

### 5a. Self-hosted sanity check

This is the part you should always run.

```bash
ssh ubuntu@10.0.0.85 \
  "TABLES='${TABLES:-public.profiles public.orders auth.users}' bash" <<'VM'
set -euo pipefail

printf "%-30s %15s\n" "Table" "Self-hosted rows"
printf "%-30s %15s\n" "-----" "----------------"

for t in ${TABLES}; do
  local_count=$(docker exec -i supabase-db psql -U postgres -d postgres -tAc "SELECT count(*) FROM ${t}" 2>/dev/null || echo "ERR")
  printf "%-30s %15s\n" "${t}" "${local_count}"
done
VM
```

Expected: non-zero counts on tables you know have data; no `ERR`s.

Sample query — pick one app entity and confirm it looks right. From self-hosted Studio's SQL editor:

```sql
SELECT id, created_at FROM public.profiles ORDER BY created_at DESC LIMIT 5;
```

### 5b. Optional: compare against cloud row counts

Only meaningful if you can still reach the cloud DB (i.e. you're back on the same machine you used in step 2, with `CLOUD_DB_URL` set). Run this from there — *not* the VM:

```bash
set -a; source .env.cloud; set +a

printf "%-30s %15s\n" "Table" "Cloud rows"
printf "%-30s %15s\n" "-----" "----------"

for t in ${TABLES}; do
  cloud_count=$(psql "${CLOUD_DB_URL}" -tAc "SELECT count(*) FROM ${t}" 2>/dev/null || echo "ERR")
  printf "%-30s %15s\n" "${t}" "${cloud_count}"
done
```

Eyeball the two tables side-by-side. Any divergence is either drift (rows added/changed on cloud after the dump time) or a restore failure on a specific table.

---

## Acceptance checklist (for `pssh-yp3`)

- [ ] `schema.sql`, `data.sql`, `auth.sql` produced (section 2) and present in `/opt/pss-supabase-host/migration/` on the VM after the scp (section 3), all non-empty
- [ ] Restore in section 4 completed without `ERROR` lines (other than benign warnings about plpgsql etc.)
- [ ] Self-hosted row-count check (section 5a): non-zero counts on tables you know have data, no `ERR`s
- [ ] Sample SQL query against self-hosted Studio returns the expected data
- [ ] `auth.users` populated — `SELECT email FROM auth.users LIMIT 5;` from self-hosted Studio's SQL Editor returns real cloud emails
- [ ] (Optional) cloud-vs-self-hosted row counts (section 5b) match within drift tolerance

When the first five are ✓ (the optional sixth is bonus), close the bead: `bd close pssh-yp3`.

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
docker compose down -v   # named-volume wipe; does NOT touch the bind-mounted db data
sudo rm -rf volumes/db/data   # bind-mount survives 'down -v' — must be removed manually
docker compose up -d
sleep 90   # wait for db to be healthy again
VM
```

---

## Troubleshooting

### `aborting because of server version mismatch` during `pg_dump`
Your `pg_dump` is older than the cloud server. Cloud Supabase has been on PG17 since late 2024. Install `postgresql-client-17` from PG's official apt repo — section 1 covers the exact commands.

### `password authentication failed for user "postgres"` against cloud
The value in `CLOUD_DB_PASSWORD` (or your inline URL) isn't the Database password. Common causes:
- **You used a service-role key** (`sb_secret_...` or `eyJhbG...`) instead. Those go in API request headers, not as a Postgres password. Get the actual Database password from Settings → Database → "Database password".
- **Stray whitespace / partial paste**. `echo "Password length: ${#CLOUD_DB_PASSWORD}"` — Supabase reset passwords are usually 24+ chars; if yours is shorter you've copied a fragment.
- **Reset hasn't propagated**. Wait 30 s after a reset before retrying.

### `Connection refused` to cloud after several failed auth attempts
**Supabase auto-bans the source IP after a few failed Postgres auth attempts** — symptom changes from `password authentication failed` to TCP refusal. Fix:
1. Dashboard → Settings → Database → **Banned IPs** section. Find your office's NAT'd IP and unban it.
2. Make absolutely sure the password is correct before retrying — *do not retry blindly*; each fail re-counts toward the ban.

### `must be owner of table users` / `permission denied: "..." is a system trigger` during restore
You ran step C or D as `-U postgres`. In `supabase/postgres:17.x`, the `postgres` role is **not** a superuser. Re-run with `-U supabase_admin` — it has trust auth via the local Unix socket inside the container, so no password needed.

### `schema "public" already exists` during schema restore
You skipped the DROP step. Run step A in section 4, then retry from step B.

### `database files are incompatible with server` after changing PG image tag
Supabase compose mounts the Postgres data dir as a **bind-mount** (`./volumes/db/data` on the VM filesystem), not a named docker volume. `docker compose down -v` removes named volumes but not bind-mounts. When changing major versions, manually `sudo rm -rf /opt/supabase/docker/volumes/db/data` before restarting.

### Dump only resolves to IPv6 (`2a05:...` from `getent hosts`)
You don't have the Supabase IPv4 add-on enabled, *or* your network has working IPv6. Check the dashboard for the IPv4 add-on toggle. If you don't want to pay, see section 2's table of alternative places to run the dump (phone tether is usually the easiest free option for UK mobile networks).

---

## What's next

Closing `pssh-yp3` brings us closer to `pssh-y3s` (wiring `platform-portal/.env` and verifying with one app), but `pssh-y3s` also depends on `pssh-2iy` (storage bucket sync). Whichever of those two you do next is up to you — they don't depend on each other.
