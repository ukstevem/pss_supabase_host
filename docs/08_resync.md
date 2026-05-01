# 08 — Periodic re-sync (refresh dev from cloud)

**Bead:** `pssh-3ve`
**Goal:** Refresh the self-hosted Supabase dev instance from cloud on demand. Use whenever you want the dev DB to reflect recent cloud state — daily, weekly, before a sprint, after a schema migration on cloud, etc.

> **Direction: ONE-WAY only — cloud → self-hosted.** Self-hosted is a dev sandbox that gets repopulated from cloud. Changes made in self-hosted (test data, exploratory schema, dev migrations) are *deliberately destroyed* by every re-sync. Nothing from self-hosted ever flows back to cloud.

This is *not* logical replication. We considered it — it's bidirectional risk: any divergence on self-hosted (a developer poking at the dev DB, a test migration, etc.) breaks the subscription or, worse, propagates back to cloud. A periodic full refresh is simpler and safer for a dev-only target.

---

## Prerequisites

- `pssh-yp3` closed: postgresql-client-17 installed on the VM, the migration procedure has run successfully at least once.
- `pssh-fj1` closed: self-hosted Supabase is up and running.
- `.env.cloud` (in repo root, gitignored) populated with `CLOUD_PROJECT_REF`, `CLOUD_DB_PASSWORD`, optional `EXTRA_SCHEMAS` and `TABLES`. See `.env.cloud.example` for shape.
- IPv4 access to cloud Supabase from the VM. Either the IPv4 add-on is enabled (recommended for routine use) or you've established IPv6 routing on the LAN.

---

## Run it

From your repo root on the dev workstation:

```bash
./scripts/resync.sh
```

(First time: `chmod +x scripts/resync.sh` if needed.)

The script:

1. **Pre-flight checks** — `.env.cloud` exists, required vars set, SSH to VM works, cloud DB reachable, target is *not* a cloud URL (one-way safety guard).
2. **Confirms** with you before doing anything destructive ("yes" prompt). The summary shows exactly what's about to happen.
3. **Step 1/3 dump from cloud** — re-runs `pg_dump` for schema + data + `auth.users` rows. Old dump files are timestamped and archived under `/opt/pss-supabase-host/migration/.archive/` (rollback breadcrumb).
4. **Step 2/3 restore** — `DROP SCHEMA public CASCADE` then re-runs schema (as `postgres`) + auth + data (as `supabase_admin`, since PG17 needs superuser to disable triggers).
5. **Step 3/3 row counts** — runs `SELECT count(*)` against each table in your `TABLES` env var, prints a table.

Total wall-clock time on a typical dataset (sub-100 MB): about 1–2 minutes, dominated by the data restore.

---

## Non-interactive (cron / CI)

Skip the confirmation prompt:

```bash
./scripts/resync.sh --yes-i-am-sure
```

Use case: schedule a weekly refresh via cron on a workstation that has SSH access to the VM. Example crontab line (07:00 every Monday):

```
0 7 * * 1 cd /path/to/pss-supabase-host && ./scripts/resync.sh --yes-i-am-sure >> ~/resync.log 2>&1
```

This fully automates the dev refresh. The script's pre-flight checks abort cleanly if anything's wrong (cloud unreachable, IPv4 add-on dropped, password rotated etc.) — no destructive op runs unless every check passes.

---

## What gets preserved across a re-sync

- **VM-level config** — Docker, UFW, hardening, secrets at `/opt/pss-supabase-host/.env`. Untouched.
- **Self-hosted Supabase stack** — running, untouched.
- **Auth/storage/realtime/etc. supabase-managed schemas** — untouched (the script only drops `public`, not the supabase-managed schemas; auth.users *rows* are wiped and reloaded but the auth *schema* stays).
- **Storage buckets** (when applicable) — currently no-op since project has no buckets. If buckets get added, `pssh-2iy`'s sync procedure should be wired into this script as an extra step.

## What gets DESTROYED on the self-hosted side

- The entire `public` schema (tables, rows, functions, triggers, indexes, RLS policies). Recreated from cloud.
- Existing rows in `auth.users` / `auth.identities` / `auth.sessions` / `auth.refresh_tokens` — replaced with cloud's current rows.

If you've been doing dev work in self-hosted and have something you want to keep — *export it before running re-sync*. The script's confirmation prompt is your last chance.

---

## Acceptance checklist (for `pssh-3ve`)

- [ ] `scripts/resync.sh` exists, executable
- [ ] First run completes end-to-end with the interactive confirm (`yes` answer)
- [ ] Pre-flight `FAIL` paths tested — script aborts cleanly when:
  - `.env.cloud` is missing
  - `VM_HOST` is changed to a `*.supabase.co` URL (one-way safety guard)
  - Cloud DB unreachable (turn off IPv4 add-on briefly to test)
- [ ] Row-count step shows the same numbers as a fresh `pssh-yp3` run
- [ ] Archive directory `/opt/pss-supabase-host/migration/.archive/` has the previous run's dumps with timestamps

When the first three are ✓, close: `bd close pssh-3ve`. (The fourth and fifth are nice-to-have; the third is the load-bearing safety property.)

---

## Troubleshooting

**`pre-flight: FAIL: cannot reach cloud DB`** — Most common cause: IPv4 add-on dropped or auto-cancelled. Re-enable in dashboard. Other causes: cloud DB password rotated (update `.env.cloud`), source IP banned (check Banned IPs section in dashboard).

**Restore step prints `ERROR` lines** — Same triage as `pssh-yp3` section 4. Most common: schema mismatch because cloud's PG version got bumped beyond self-hosted's. Fix: bump self-hosted to the new version per `pssh-fj1` rollback procedure (image-tag swap + bind-mount wipe), then re-run.

**Script hangs on dump step** — `pg_dump` waiting for cloud response. With IPv4 add-on enabled this should be quick. If hung >5 min, Ctrl-C and check cloud project status in the dashboard.

---

## What's next

Closing `pssh-3ve` is the last piece of "keeping the dev instance fresh" work. Doesn't unblock anything — `pssh-y3s` (app integration) is independent and was already ready when we re-jigged this bead's deps.
