# 07 — Sync storage buckets from cloud to self-hosted

**Bead:** `pssh-2iy`
**Direction:** ONE-WAY only — cloud → self-hosted. Self-hosted is a dev sandbox; nothing from there ever flows back to cloud (per the project-level constraint, see `bd memories data-flow-cloud-to-selfhosted-only`).

**Status at time of writing (2026-05-01):** the cloud Supabase project for PSS uses **no storage buckets**. All app data is in Postgres tables, migrated by `pssh-yp3`. So nothing to actually sync — but the procedure is documented below for if/when an app starts using Supabase Storage.

---

## Prerequisites

- `pssh-fj1` closed: self-hosted Supabase running.
- `.env.cloud` populated with `CLOUD_PROJECT_REF` and `CLOUD_SERVICE_ROLE_KEY` (the JWT-format key from **Settings → API → "Legacy API keys" → service_role**, *not* `sb_secret_*` — the storage REST API rejects the latter with `Invalid Compact JWS`).
- Self-hosted service-role key — already present at `/opt/pss-supabase-host/.env` on the VM as `SERVICE_ROLE_KEY` (per `pssh-9fi`).

---

## 1. Survey: are there any buckets to sync?

```bash
set -a; source .env.cloud; set +a

ssh ubuntu@10.0.0.85 \
  "CLOUD_PROJECT_REF='${CLOUD_PROJECT_REF}' CLOUD_SERVICE_ROLE_KEY='${CLOUD_SERVICE_ROLE_KEY}' bash" <<'VM'
set -euo pipefail
CLOUD_URL="https://${CLOUD_PROJECT_REF}.supabase.co"

curl -s "${CLOUD_URL}/storage/v1/bucket" \
  -H "apikey: ${CLOUD_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${CLOUD_SERVICE_ROLE_KEY}" \
  | python3 -c "
import json, sys
buckets = json.load(sys.stdin)
if not isinstance(buckets, list):
    print('ERROR:', buckets); sys.exit(1)
for b in buckets:
    print(f'  {b[\"name\"]:30s}  public={b.get(\"public\", False)}  created={b.get(\"created_at\", \"\")[:10]}')
print(f'Total buckets: {len(buckets)}')
"
VM
```

Two outcomes:
- **`Total buckets: 0`** — nothing to sync. Skip to "Acceptance" below.
- **One or more buckets listed** — proceed to section 2.

---

## 2. Sync (only if buckets exist)

**Approach**: Python script using requests + Supabase Storage REST API. Reads from cloud (with `service_role` key), writes to self-hosted (with self-hosted's `service_role` key). No third-party tools needed.

The script is **not yet committed** because at time of writing no project needs it. When that changes, sketch the script as `scripts/sync_storage.py`. Outline:

1. **List cloud buckets** — `GET /storage/v1/bucket`. For each bucket:
   - Ensure the bucket exists self-hosted with same `public` flag — `POST /storage/v1/bucket` (idempotent: `409 already exists` is a non-error).
   - List all objects — `POST /storage/v1/object/list/<bucket>` with `{"prefix":"","limit":1000}`. Paginate if >1000.
   - For each object: `GET /storage/v1/object/<bucket>/<path>` from cloud → `POST /storage/v1/object/<bucket>/<path>` to self-hosted. Set `x-upsert: true` header so re-runs are idempotent.

2. **Cloud auth**: `apikey` and `Authorization: Bearer` headers both set to `CLOUD_SERVICE_ROLE_KEY` (the legacy JWT — see Prereqs).

3. **Self-hosted auth**: same pattern but base URL is `http://10.0.0.85:8000` and key is the self-hosted `SERVICE_ROLE_KEY` from `/opt/pss-supabase-host/.env`.

4. **Idempotency**: re-running the script after partial failure should be safe. Use `x-upsert: true` on uploads. Skip cloud→self-hosted copies where the destination object's `etag` matches.

5. **One-way safety**: the script reads cloud + writes self-hosted. It must **never** write to cloud. Add a hard assertion at the top of the script: `assert "supabase.co" not in TARGET_URL, "Target must not be cloud"`. Per `bd memories data-flow-cloud-to-selfhosted-only`.

When this gets implemented, drop the script at `scripts/sync_storage.py` and put a "Run it" subsection here with the exact invocation.

---

## Acceptance checklist (for `pssh-2iy`)

- [ ] Survey (section 1) executed; bucket count noted
- [ ] If non-zero: sync completed; sample object downloads cleanly via self-hosted (`curl http://10.0.0.85:8000/storage/v1/object/<bucket>/<path>`)
- [ ] If zero: this doc updated with a note when storage is added

When the survey returns `0` (current state), close: `bd close pssh-2iy`.

---

## What's next

Closing `pssh-2iy` (combined with `pssh-yp3` already closed) unblocks `pssh-y3s` — wiring `platform-portal/.env` to the new self-hosted instance and verifying one PSS standalone app boots and operates against it. That's the proof-of-end-to-end step: at the end of `pssh-y3s`, you have a real PSS app running against this dev Supabase.
