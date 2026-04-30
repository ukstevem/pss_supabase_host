# 04 — Generate Supabase self-hosted secrets

**Bead:** `pssh-9fi`
**Goal:** Generate the secrets the Supabase self-hosted stack needs (JWT_SECRET, derived ANON_KEY/SERVICE_ROLE_KEY, POSTGRES_PASSWORD, DASHBOARD_USERNAME/PASSWORD), write them to `/opt/pss-supabase-host/.env` on the VM with strict permissions, and commit the placeholder template (`.env.example`) to the repo. **Do not** reuse secrets from the existing cloud Supabase project — this self-hosted instance gets fresh ones, so a leak on either side doesn't compromise the other.

---

## Prerequisites

- Bead `pssh-8bv` closed: Docker installed, `ssh ubuntu@10.0.0.85` works without password.
- This repo cloned and up-to-date on your dev workstation: `git pull` recently.

---

## What gets generated

| Variable | Purpose | Source | Notes |
|---|---|---|---|
| `JWT_SECRET` | HS256 signing key for the two derived JWTs | 64-char random URL-safe alphanumeric | Rotation forces every PSS standalone app to be **rebuilt** — `NEXT_PUBLIC_SUPABASE_ANON_KEY` is baked in at Docker build time, not runtime |
| `ANON_KEY` | Client-side JWT, `role=anon` | `HS256(JWT_SECRET, {role:anon, iss:supabase, exp:+10y})` | Safe for browsers; RLS gates access |
| `SERVICE_ROLE_KEY` | Server-side JWT, `role=service_role` | `HS256(JWT_SECRET, {role:service_role, iss:supabase, exp:+10y})` | Bypasses RLS — treat as fully privileged |
| `POSTGRES_PASSWORD` | Postgres superuser password | 32-char random alphanumeric | |
| `DASHBOARD_USERNAME` | Supabase Studio admin login | Default `supabase`, override with `--dashboard-username` | |
| `DASHBOARD_PASSWORD` | Supabase Studio admin password | 24-char random alphanumeric | |

The generator is `scripts/gen_secrets.py` — stdlib-only, no PyJWT dep. Builds the JWTs from base64url + HMAC-SHA256 directly so the dependency surface is the Python that ships with Ubuntu.

---

## 1. Generate and install the .env on the VM

Paste the **whole** block. It uploads the script, runs it on the VM with output redirected straight into `/opt/pss-supabase-host/.env` (so the secrets never touch the dev workstation's filesystem in plain form), then secures the file.

```bash
# Push the generator script to the VM
scp scripts/gen_secrets.py ubuntu@10.0.0.85:/tmp/gen_secrets.py

# Generate + install the .env
ssh ubuntu@10.0.0.85 bash <<'VM'
set -euo pipefail

sudo mkdir -p /opt/pss-supabase-host
sudo chown ubuntu:ubuntu /opt/pss-supabase-host

python3 /tmp/gen_secrets.py > /opt/pss-supabase-host/.env
chmod 600 /opt/pss-supabase-host/.env
rm /tmp/gen_secrets.py

echo "--- /opt/pss-supabase-host/.env ---"
ls -la /opt/pss-supabase-host/.env

echo "--- summary (values truncated to 6 chars to keep secrets out of scrollback) ---"
awk -F= '{ printf "%-22s = %s...\n", $1, substr($2, 1, 6) }' /opt/pss-supabase-host/.env
VM
```

You should see:
- `-rw------- 1 ubuntu ubuntu` for the file (mode 600)
- Six lines, one per variable, with the value field showing the first 6 chars followed by `...`

Sample (your secrets will differ — these are illustrative only):
```
JWT_SECRET             = K7nQ4P...
ANON_KEY               = eyJhbG...
SERVICE_ROLE_KEY       = eyJhbG...
POSTGRES_PASSWORD      = M8cR2L...
DASHBOARD_USERNAME     = supaba...
DASHBOARD_PASSWORD     = X3vH9F...
```

---

## 2. Sanity-check the JWTs

Optional but worth doing once — confirm the ANON_KEY and SERVICE_ROLE_KEY decode correctly with the JWT_SECRET. Run on the VM:

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
set -euo pipefail
source /opt/pss-supabase-host/.env

decode_jwt() {
  # JWTs are header.payload.sig — base64url-decode the payload (middle part)
  python3 -c "
import base64, json, sys
parts = sys.argv[1].split('.')
def b64url_decode(s):
    return base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))
print(json.dumps(json.loads(b64url_decode(parts[1])), indent=2))
" "$1"
}

echo "--- ANON_KEY payload ---"
decode_jwt "$ANON_KEY"
echo ""
echo "--- SERVICE_ROLE_KEY payload ---"
decode_jwt "$SERVICE_ROLE_KEY"
VM
```

Expect each payload to look like:
```json
{
  "role": "anon",                  // or "service_role" for the other
  "iss": "supabase",
  "iat": 1730000000,               // ~now
  "exp": 2045000000                // ~10 years from now
}
```

If both decode cleanly with `role` matching the variable name, the JWTs are valid.

---

## Acceptance checklist (for `pssh-9fi`)

- [ ] `/opt/pss-supabase-host/.env` exists on the VM, mode `600`, owned by `ubuntu:ubuntu`
- [ ] File contains all six variables, none blank
- [ ] `JWT_SECRET` is exactly 64 alphanumeric chars
- [ ] `ANON_KEY` decodes to JSON with `role: "anon"`, `iss: "supabase"`, future `exp`
- [ ] `SERVICE_ROLE_KEY` decodes to JSON with `role: "service_role"`, `iss: "supabase"`, future `exp`
- [ ] `.env.example` is committed in this repo with placeholder (blank) values for the same six variables
- [ ] `.env` is in `.gitignore` (so a stray copy in the repo never gets pushed)

When all seven are ✓, close the bead: `bd close pssh-9fi`. That unblocks `pssh-fj1` — the actual Supabase stack bring-up, where these secrets get consumed.

---

## Rotation

Different rotation policies for different secrets:

**Rotate everything (worst case — full compromise):**
```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
sudo cp /opt/pss-supabase-host/.env /opt/pss-supabase-host/.env.bak.$(date +%Y%m%d-%H%M%S)
python3 /opt/pss-supabase-host/scripts/gen_secrets.py > /tmp/.env.new
sudo mv /tmp/.env.new /opt/pss-supabase-host/.env
sudo chmod 600 /opt/pss-supabase-host/.env
sudo chown ubuntu:ubuntu /opt/pss-supabase-host/.env
VM
```
Then in `pssh-fj1`'s working directory: `docker compose down && docker compose up -d`. Then in **every** PSS standalone app: rebuild and redeploy because `NEXT_PUBLIC_SUPABASE_ANON_KEY` (baked at build time) has changed.

**Rotate only POSTGRES_PASSWORD / DASHBOARD_PASSWORD (no app rebuild):**
```bash
JWT_SECRET=$(grep ^JWT_SECRET= /opt/pss-supabase-host/.env | cut -d= -f2-)
python3 scripts/gen_secrets.py --jwt-secret "${JWT_SECRET}" > new.env
```
Manually merge the rotated values into `/opt/pss-supabase-host/.env`. ANON_KEY / SERVICE_ROLE_KEY stay valid because JWT_SECRET is preserved. Apps don't need rebuilds.

**Why JWT_SECRET rotation cascades:** the apps embed the ANON_KEY at *build time* (`--build-arg NEXT_PUBLIC_SUPABASE_ANON_KEY=...` per `docs/SKILL_pss_standalone_app.md`). Rotating JWT_SECRET produces a new ANON_KEY, which means the running app's baked-in key no longer signs valid for the new instance. Rebuild required.

---

## Rollback

There's no graceful rollback for a key rotation that's already been applied — the old keys are gone. Two preventative measures:
1. The rotation script writes a backup to `/opt/pss-supabase-host/.env.bak.<timestamp>` before overwriting. Keep these for at least one rotation cycle.
2. Use `bd note pssh-9fi "rotated YYYY-MM-DD because <reason>"` to keep an audit trail.

If you accidentally rotated and need the old values back: `sudo mv /opt/pss-supabase-host/.env.bak.<timestamp> /opt/pss-supabase-host/.env && docker compose down && docker compose up -d` (in the Supabase compose dir).

---

## What's next

Closing `pssh-9fi` unblocks `pssh-fj1` — clone the supabase/supabase repo, wire `/opt/pss-supabase-host/.env` to its docker-compose, `docker compose up -d`, and we have a running Supabase. That's the long-awaited "actually a Supabase" step.
