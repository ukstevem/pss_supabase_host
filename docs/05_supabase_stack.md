# 05 — Bring up the Supabase self-hosted stack

**Bead:** `pssh-fj1`
**Goal:** Clone the Supabase self-hosted compose stack, merge our generated secrets into its `.env` template, configure URLs so Studio and Kong are reachable from the LAN at `http://10.0.0.85:{3000,8000}`, pull all images, `docker compose up -d`, and verify every service is healthy. After this bead, you have a running but **empty** Supabase — schema/data migration is the next bead (`pssh-yp3`).

---

## Prerequisites

- `pssh-9fi` closed: `/opt/pss-supabase-host/.env` exists on the VM with all six secrets, mode `600`.
- `pssh-8bv` closed: `docker compose version` works for the `ubuntu` user.
- Internet on the VM (we'll be pulling ~2 GB of images).

---

## 1. What we're standing up

Supabase's [self-hosted compose stack](https://github.com/supabase/supabase/tree/master/docker) brings up these containers:

| Service | Container | Host port | Purpose |
|---|---|---|---|
| **Postgres** | `supabase-db` | `5432` | The database |
| **Kong** | `supabase-kong` | `8000`, `8443` | API gateway — REST / Realtime / Auth / Storage all behind this |
| **GoTrue** | `supabase-auth` | (internal) | Auth service |
| **PostgREST** | `supabase-rest` | (internal) | REST API auto-generated from Postgres schema |
| **Realtime** | `realtime-dev.supabase-realtime` | (internal) | Websockets for `pg_listen` notifications |
| **Storage** | `supabase-storage` | (internal) | S3-compatible object storage backed by local volume |
| **imgproxy** | `supabase-imgproxy` | (internal) | On-the-fly image transformation |
| **Edge Runtime** | `supabase-edge-functions` | (internal) | Deno runtime for Edge Functions |
| **Postgres-Meta** | `supabase-meta` | (internal) | Postgres metadata API used by Studio |
| **Studio** | `supabase-studio` | `3000` | Admin dashboard |
| **Vector** | `supabase-vector` | (internal) | Logs aggregator into the analytics DB |
| **Pooler** | `supabase-pooler` | `6543` | Supavisor connection pooler |
| **Analytics** | `supabase-analytics` | (internal) | Logflare backend |

LAN-reachable ports (post-bring-up): `3000` (Studio), `8000` (Kong = the actual API surface), `5432` (direct Postgres). UFW gets a rule for 3000 too, alongside the 22/8000/5432 from `pssh-cgj`.

> Note on ports: Docker's iptables rules bypass UFW (see `docs/03_docker_install.md`), so any `-p X:X` published port is reachable from the LAN regardless of UFW. We add the UFW rule for 3000 anyway as documentation — `ufw status` reads as the canonical "what's exposed on this host."

---

## 2. Inputs

| Variable | Default | Change if... |
|---|---|---|
| Supabase repo path on VM | `/opt/supabase` | rare; coordinate with anyone else SSHing in |
| Compose working dir | `/opt/supabase/docker` | Supabase canonical; don't change |
| Our secrets file | `/opt/pss-supabase-host/.env` | (per `pssh-9fi`) |
| Studio external URL | `http://10.0.0.85:8000` | VM IP changed |
| Kong public URL | `http://10.0.0.85:8000` | VM IP changed |
| LAN CIDR (UFW source) | `10.0.0.0/24` | per `pssh-cgj` inputs |

If any change, update this table **first**.

---

## 3. Run the bring-up

Paste the **whole** block. It's idempotent — re-running on an already-deployed stack is a no-op for clone/UFW and a recreate-if-needed for the containers.

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
set -euo pipefail

SUPABASE_DIR=/opt/supabase
COMPOSE_DIR=${SUPABASE_DIR}/docker
PSS_DIR=/opt/pss-supabase-host
LAN_CIDR=10.0.0.0/24
PUBLIC_URL=http://10.0.0.85:8000

echo "==> 1/6 clone supabase/supabase (shallow)"
if [ ! -d "${SUPABASE_DIR}/.git" ]; then
  sudo git clone --depth 1 https://github.com/supabase/supabase ${SUPABASE_DIR}
  sudo chown -R ubuntu:ubuntu ${SUPABASE_DIR}
else
  echo "  already cloned at ${SUPABASE_DIR} — git pull to refresh"
  cd ${SUPABASE_DIR} && git pull --ff-only origin master || true
fi

# Pin the SHA we have so future redeploys can target it
SUPABASE_SHA=$(cd ${SUPABASE_DIR} && git rev-parse HEAD)
echo "${SUPABASE_SHA}" > ${PSS_DIR}/supabase-pinned-sha.txt
echo "  pinned to ${SUPABASE_SHA:0:12}"

echo "==> 2/6 build merged .env at ${COMPOSE_DIR}/.env"
# Start from supabase's template so we get every variable they expect.
cp ${COMPOSE_DIR}/.env.example ${COMPOSE_DIR}/.env

# Overlay our generated secrets (and any other PSS-specific overrides
# we put in /opt/pss-supabase-host/.env) onto the supabase template.
while IFS='=' read -r key val; do
  [ -z "${key}" ] && continue
  case "${key}" in '#'*) continue ;; esac
  if grep -q "^${key}=" ${COMPOSE_DIR}/.env; then
    # Replace existing line. '|' is safe as delimiter — JWTs use [A-Za-z0-9_-.] only.
    sed -i "s|^${key}=.*|${key}=${val}|" ${COMPOSE_DIR}/.env
  else
    echo "${key}=${val}" >> ${COMPOSE_DIR}/.env
  fi
done < ${PSS_DIR}/.env

# Configure LAN-facing URLs so Studio's "API URL" and Kong's CORS work
# from the dev workstation. Default values point at localhost which only
# works from the VM itself.
sed -i "s|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=${PUBLIC_URL}|" ${COMPOSE_DIR}/.env
sed -i "s|^SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=${PUBLIC_URL}|" ${COMPOSE_DIR}/.env

chmod 600 ${COMPOSE_DIR}/.env

echo "==> 3/6 add UFW rule for Studio (port 3000)"
sudo ufw allow from "${LAN_CIDR}" to any port 3000 proto tcp comment 'Supabase Studio admin (pssh-fj1)' || true

echo "==> 4/6 docker compose pull (this takes a while — ~2 GB on first run)"
cd ${COMPOSE_DIR}
docker compose pull

echo "==> 5/6 docker compose up -d"
docker compose up -d

echo "==> 6/6 wait for services to settle, then report"
sleep 30
docker compose ps
echo ""
echo "Studio:  http://10.0.0.85:3000   (login with DASHBOARD_USERNAME / DASHBOARD_PASSWORD from /opt/pss-supabase-host/.env)"
echo "Kong:    http://10.0.0.85:8000   (API surface)"
echo "Postgres: 10.0.0.85:5432         (direct connection; password is POSTGRES_PASSWORD from .env)"
VM
```

The `docker compose pull` step is the long one. Expect 5–10 minutes on a typical home connection — it's pulling ~13 images totalling ~2 GB. The `up -d` itself is fast (~30 s for everything to start).

---

## 4. Verify

Wait another minute past `up -d` so all containers finish their initial setup (especially `supabase-db` which restores its initial schema), then:

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
set -euo pipefail
cd /opt/supabase/docker

echo "--- compose ps (expect every service 'running' or 'healthy') ---"
docker compose ps

echo ""
echo "--- any unhealthy or restarting? ---"
docker compose ps --format json | python3 -c "
import json, sys
ok = True
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    svc = json.loads(line)
    state = svc.get('State', '')
    health = svc.get('Health', '')
    name = svc.get('Service', svc.get('Name', '?'))
    if state != 'running' or (health and health != 'healthy'):
        print(f'  {name}: state={state} health={health!r}')
        ok = False
print('  (all services running and healthy)' if ok else '  ^^ investigate above ^^')
"

echo ""
echo "--- Kong returns 401 for unauthenticated REST call (expected — proves it's wired) ---"
curl -sI --max-time 5 http://localhost:8000/rest/v1/ | head -3

echo ""
echo "--- Kong returns 200 with anon key (proves auth is wired) ---"
ANON_KEY=$(grep ^ANON_KEY= /opt/supabase/docker/.env | cut -d= -f2-)
curl -sI --max-time 5 -H "apikey: ${ANON_KEY}" http://localhost:8000/rest/v1/ | head -3
VM
```

Then from your **dev workstation**:

```bash
# Studio — open in a browser
echo "Browse to: http://10.0.0.85:3000"
# Username and password come from /opt/pss-supabase-host/.env on the VM:
ssh ubuntu@10.0.0.85 'grep -E "^DASHBOARD_(USERNAME|PASSWORD)=" /opt/pss-supabase-host/.env'

# Kong reachability
curl -sI --max-time 5 http://10.0.0.85:8000/rest/v1/ | head -3
# Expect: HTTP/1.1 401 (unauthenticated REST call from LAN — proves Kong is reachable + Auth is enforcing)
```

Open `http://10.0.0.85:3000` in your browser, paste the dashboard creds, and you should land on Supabase Studio's project view. Empty schema, no tables yet — that's the next bead.

---

## Acceptance checklist (for `pssh-fj1`)

- [ ] `docker compose ps` shows every service in `running` state, healthchecks `healthy` where defined
- [ ] `curl -I http://10.0.0.85:8000/rest/v1/` returns `401` (Kong + Auth working)
- [ ] `curl -I -H "apikey: <ANON>" http://10.0.0.85:8000/rest/v1/` returns `200`
- [ ] Studio loads at `http://10.0.0.85:3000` from your dev workstation's browser
- [ ] Login with `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` succeeds
- [ ] You can run a SQL query in Studio's SQL Editor: `SELECT version();` returns Postgres ≥ 15
- [ ] `/opt/pss-supabase-host/supabase-pinned-sha.txt` records the supabase commit SHA
- [ ] UFW shows the new 3000 rule (`sudo ufw status | grep 3000`)

When all eight are ✓, close the bead: `bd close pssh-fj1`. That unblocks both `pssh-yp3` (schema/data migration from cloud) and `pssh-2iy` (storage bucket sync) — they can be worked in parallel.

---

## Troubleshooting

**`docker compose pull` errors: `manifest unknown` / `pull access denied`** — usually transient. Retry. If persistent, your DNS or routing is interfering with `registry-1.docker.io` or `ghcr.io`. Confirm with `curl -I https://registry-1.docker.io/v2/`.

**A container is `Restarting (1)`** — `docker compose logs <service> --tail 100` shows why. The most common cause is a typo / blank in `.env` — re-check that step 2 of the bring-up populated all six secrets.

**`supabase-db` is unhealthy** — usually permission or volume issue. `docker compose down -v` (the `-v` wipes volumes, full reset) and `docker compose up -d` again. **Note:** `-v` destroys data. Only do this before the migration in `pssh-yp3` lands real data.

**Studio loads but shows "Failed to fetch"** — Studio is calling the API at `SUPABASE_PUBLIC_URL`. If you're hitting Studio at `http://10.0.0.85:3000` but `SUPABASE_PUBLIC_URL` is `http://localhost:8000`, browser CORS will block. Re-check that step 2 set both URLs to `http://10.0.0.85:8000`.

**Studio login fails with valid creds** — Studio's auth middleware reads `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` from the env at *container start*. If you changed them after `up -d`, restart Studio: `docker compose restart studio`.

**Kong returns 502/504 to all routes** — one of the upstream services (auth, rest, realtime, storage) is down. `docker compose ps` will tell you which.

---

## Rollback

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
cd /opt/supabase/docker
docker compose down            # stops + removes containers, keeps volumes (data preserved)
# OR
docker compose down -v         # plus removes volumes (fresh start, data lost)
VM
```

To fully purge:
```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
cd /opt/supabase/docker
docker compose down -v --remove-orphans
sudo rm -rf /opt/supabase
sudo ufw delete allow from 10.0.0.0/24 to any port 3000 || true
VM
```

This puts you back to the state at the end of `pssh-9fi` — VM hardened, Docker installed, secrets file in place, no Supabase running.

---

## What's next

Closing `pssh-fj1` unblocks two parallel beads:

- **`pssh-yp3`** — `pg_dump` / `pg_restore` the public schema + auth.users from your existing cloud Supabase project into this self-hosted instance.
- **`pssh-2iy`** — Sync storage buckets from cloud to self-hosted.

Both feed into `pssh-y3s` (wire `platform-portal/.env` to the new instance and verify with one app), which is where you'll see a PSS standalone app actually running against this stack.
