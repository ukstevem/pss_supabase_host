# 05 — Bring up the Supabase self-hosted stack

**Bead:** `pssh-fj1`
**Goal:** Clone the Supabase self-hosted compose stack, merge our generated secrets into its `.env` template, configure URLs so the LAN can reach Studio and the API at `http://10.0.0.85:8000`, pull all images, `docker compose up -d`, and verify every service is healthy. After this bead, you have a running but **empty** Supabase — schema/data migration is the next bead (`pssh-yp3`).

> **Studio access**, briefly: Supabase's current self-hosted compose does **not** publish Studio on a host port. Studio runs internally on `studio:3000` inside the docker network, and Kong proxies `http://<host>:8000/` to it. The proxy is gated by HTTP Basic Auth using `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` (you'll get a browser credential dialog, not a styled login form). So the only host ports that matter LAN-side are **8000** (Kong → REST/Auth/Realtime/Storage/Studio), **8443** (Kong TLS, unused for us), **5432** and **6543** (Postgres pooler).

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
| **Postgres** | `supabase-db` | (internal — accessed via pooler) | The database |
| **Kong** | `supabase-kong` | `8000`, `8443` | API gateway — REST / Realtime / Auth / Storage / Studio all behind this |
| **GoTrue** | `supabase-auth` | (internal) | Auth service |
| **PostgREST** | `supabase-rest` | (internal) | REST API auto-generated from Postgres schema |
| **Realtime** | `realtime-dev.supabase-realtime` | (internal) | Websockets for `pg_listen` notifications |
| **Storage** | `supabase-storage` | (internal) | S3-compatible object storage backed by local volume |
| **imgproxy** | `supabase-imgproxy` | (internal) | On-the-fly image transformation |
| **Edge Runtime** | `supabase-edge-functions` | (internal) | Deno runtime for Edge Functions |
| **Postgres-Meta** | `supabase-meta` | (internal) | Postgres metadata API used by Studio |
| **Studio** | `supabase-studio` | (internal — reached via Kong on 8000) | Admin dashboard |
| **Vector** | `supabase-vector` | (internal) | Logs aggregator into the analytics DB |
| **Pooler** | `supabase-pooler` | `5432`, `6543` | Supavisor connection pooler — the only Postgres entry point from outside the docker network |
| **Analytics** | `supabase-analytics` | (internal) | Logflare backend |

LAN-reachable ports (post-bring-up): `8000` (Kong — REST + Studio), `5432`/`6543` (Postgres via pooler). The UFW rules established in `pssh-cgj` cover these. **No port-3000 rule is needed** — Studio is not host-published.

> Note on ports: Docker's iptables rules bypass UFW (see `docs/03_docker_install.md`), so any `-p X:X` published port is reachable from the LAN regardless of UFW. UFW rules are still useful as documentation — `ufw status` reads as the canonical "what's exposed on this host" — but they're not load-bearing for Docker-published ports.

---

## 2. Inputs

| Variable | Default | Change if... |
|---|---|---|
| Supabase repo path on VM | `/opt/supabase` | rare; coordinate with anyone else SSHing in |
| Compose working dir | `/opt/supabase/docker` | Supabase canonical; don't change |
| Our secrets file | `/opt/pss-supabase-host/.env` | (per `pssh-9fi`) |
| **Postgres image tag** | `supabase/postgres:17.6.1.113` | **Pin to match the cloud project's Postgres major version**. Cloud Supabase has been on PG17 since late 2024; using PG15 here causes pg_dump output from cloud to fail to restore into self-hosted. Find latest stable 17.x tags with the docker-hub query in step 1. |
| Studio external URL | `http://10.0.0.85:8000` | VM IP changed |
| Kong public URL | `http://10.0.0.85:8000` | VM IP changed |
| LAN CIDR (UFW source) | `10.0.0.0/24` | per `pssh-cgj` inputs |

If any change, update this table **first**.

> **Why pin the Postgres image** — Supabase's `master` branch sometimes points its compose at older Postgres tags (we cloned at a point where it was `15.8.1.085`). The data migration in `pssh-yp3` dumps from cloud (PG17), and a cross-major-version restore fails due to pg_dump emitting v17-only psql metacommands like `\restrict` that v15 doesn't recognise. Pinning self-hosted to the same major version up front avoids the whole class of issue.

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
PG_IMAGE_TAG=17.6.1.113   # see "Inputs" — pin to match cloud's PG major version

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

echo "==> 3/6 pin postgres image to ${PG_IMAGE_TAG} (matches cloud's PG major version — see 'Inputs')"
sudo sed -i "s|supabase/postgres:[0-9][0-9.]*|supabase/postgres:${PG_IMAGE_TAG}|g" ${COMPOSE_DIR}/docker-compose.yml
echo "Now using:"
grep "supabase/postgres" ${COMPOSE_DIR}/docker-compose.yml | head -3

echo "==> 4/6 docker compose pull (this takes a while — ~2 GB on first run)"
cd ${COMPOSE_DIR}
docker compose pull

echo "==> 5/6 docker compose up -d"
docker compose up -d

echo "==> 6/6 wait for services to settle, then report"
sleep 30
docker compose ps
echo ""
echo "Studio:   http://10.0.0.85:8000/  (HTTP Basic Auth — DASHBOARD_USERNAME / DASHBOARD_PASSWORD from /opt/pss-supabase-host/.env)"
echo "Kong API: http://10.0.0.85:8000   (REST/Auth/Realtime/Storage — apps use ANON_KEY or SERVICE_ROLE_KEY in headers)"
echo "Postgres: 10.0.0.85:5432          (via pooler; user 'postgres', password is POSTGRES_PASSWORD from .env)"
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
# Print the dashboard credentials (you'll need them for the Basic Auth dialog)
ssh ubuntu@10.0.0.85 'grep -E "^DASHBOARD_(USERNAME|PASSWORD)=" /opt/pss-supabase-host/.env'

# Kong reachability — anonymous REST should be 401
curl -sI --max-time 5 http://10.0.0.85:8000/rest/v1/ | head -3
# Expect: HTTP/1.1 401 (unauthenticated REST call from LAN — proves Kong is reachable + Auth is enforcing)

# Kong root — Basic Auth challenge for Studio
curl -sI --max-time 5 http://10.0.0.85:8000/ | head -3
# Expect: HTTP/1.1 401 with 'WWW-Authenticate: Basic realm="service"'
```

Open `http://10.0.0.85:8000/` in your browser. The browser pops an OS-level **"Sign in to access this site"** dialog (HTTP Basic Auth — *not* a styled login form). Enter `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` and you'll land on Supabase Studio's project view. Empty schema, no tables yet — that's the next bead.

---

## Acceptance checklist (for `pssh-fj1`)

- [ ] `docker compose ps` shows every service in `running` state, healthchecks `healthy` where defined
- [ ] `curl -I http://10.0.0.85:8000/rest/v1/` returns `401` (Kong + Auth working)
- [ ] `curl -I -H "apikey: <ANON>" http://10.0.0.85:8000/rest/v1/` returns `200`
- [ ] `curl -I http://10.0.0.85:8000/` returns `401` with `WWW-Authenticate: Basic realm="service"` (Kong gates Studio)
- [ ] Studio loads at `http://10.0.0.85:8000/` after passing the browser's Basic Auth dialog
- [ ] You can run a SQL query in Studio's SQL Editor: `SELECT version();` returns Postgres ≥ 15
- [ ] `/opt/pss-supabase-host/supabase-pinned-sha.txt` records the supabase commit SHA

When all seven are ✓, close the bead: `bd close pssh-fj1`. That unblocks `pssh-yp3` (schema/data migration), `pssh-2iy` (storage bucket sync), and `pssh-ryl` (backup runbook) — they can be worked in parallel.

---

## Troubleshooting

**`docker compose pull` errors: `manifest unknown` / `pull access denied`** — usually transient. Retry. If persistent, your DNS or routing is interfering with `registry-1.docker.io` or `ghcr.io`. Confirm with `curl -I https://registry-1.docker.io/v2/`.

**A container is `Restarting (1)`** — `docker compose logs <service> --tail 100` shows why. The most common cause is a typo / blank in `.env` — re-check that step 2 of the bring-up populated all six secrets.

**`supabase-db` is unhealthy** — usually permission or volume issue. `docker compose down -v` (the `-v` wipes volumes, full reset) and `docker compose up -d` again. **Note:** `-v` destroys data. Only do this before the migration in `pssh-yp3` lands real data.

**Studio loads but shows "Failed to fetch"** — Studio's frontend is calling the API at `SUPABASE_PUBLIC_URL`. If that's still `http://localhost:8000` (the supabase template default), browser CORS blocks the call from your dev workstation. Re-check that step 2 of the bring-up overrode `SUPABASE_PUBLIC_URL` and `API_EXTERNAL_URL` to `http://10.0.0.85:8000`.

**Browser keeps asking for Basic Auth credentials in a loop** — the password the browser is sending doesn't match `DASHBOARD_PASSWORD` in `/opt/supabase/docker/.env`. Either you typed wrong, or Kong was started before the env was finalised. Restart Kong: `docker compose restart kong`. Then retry — clear the saved credentials in the browser if it cached the wrong ones (devtools → Application → Storage, or just use a private window).

**Studio appears to load but is stuck on "Connecting…"** — usually `supabase-db` finished healthcheck but `supabase-meta` (which Studio queries) hasn't caught up. Wait 30 s; if persistent, `docker compose restart meta studio`.

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
VM
```

This puts you back to the state at the end of `pssh-9fi` — VM hardened, Docker installed, secrets file in place, no Supabase running.

---

## Cleanup if you followed an older revision of this doc

An earlier revision added a UFW rule for port 3000 thinking Studio was directly host-published. It isn't (Studio runs on `studio:3000` inside the docker network only; Kong proxies on 8000). The rule does nothing harmful but is misleading — drop it:

```bash
ssh ubuntu@10.0.0.85 'sudo ufw delete allow from 10.0.0.0/24 to any port 3000 2>/dev/null || true'
```

---

## What's next

Closing `pssh-fj1` unblocks three parallel beads — they don't depend on each other and can be worked in any order:

- **`pssh-yp3`** — `pg_dump` / `pg_restore` the public schema + `auth.users` from the existing cloud Supabase project into this self-hosted instance.
- **`pssh-2iy`** — Sync storage buckets from cloud to self-hosted.
- **`pssh-ryl`** — Set up cron-driven `pg_dump` backups + tested restore procedure.

`pssh-yp3` and `pssh-2iy` both feed into `pssh-y3s` (wire `platform-portal/.env` to the new instance and verify with one PSS app) — that's where you'll see a standalone app actually running against this stack. `pssh-ryl` is independent of those and can slot in whenever.
