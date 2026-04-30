# Skill: PSS Standalone App

**Drop this file into any PSS app repo at `docs/SKILL_pss_standalone_app.md` (or paste it into another Claude chat) to teach an assistant how this ecosystem fits together and what rules to follow when modifying a standalone app.**

You are working inside a **PSS standalone app repo**. There are several of them (e.g. `pss-matl-cert`, `pss-<appname>`), each extracted from the `platform-portal` monorepo so it can be built, deployed, and rolled back on its own.

---

## Core architecture — read before touching anything

- Users enter at **one** nginx gateway (port 3000 on host 10.0.0.75).
- The gateway proxies `/<appname>/` to a container named `<appname>` on a shared external Docker network called **`platform_net`**.
- Each app has:
  - A **port** reserved for it — never change it unilaterally. Check `platform-portal/docs/PORTS.md` for the authoritative list.
  - A **basePath** (`/<appname>`) matching the nginx route, set in `next.config.ts`.
  - A **service name** matching its container name, used by nginx DNS.
- Apps are deployed from `ghcr.io/ukstevem/<appname>:<tag>`. Tags are git SHAs **plus** `:latest`. Rollback = change the tag in `docker-compose.app.yml` and `up -d`.

The host is a Raspberry Pi (ARM64). **Never** build images on the Pi — it runs out of memory. Build on the dev machine with `docker buildx --platform linux/arm64 --push`.

---

## Invariants you must not break

1. **Never change the app's port** unless `docs/PORTS.md` is updated **and** `platform-portal/docker/nginx/production.conf` is updated **and** both are pushed.
2. **Never rename the Docker service / container.** nginx resolves it by name on `platform_net`.
3. **Never drop `basePath`** from `next.config.ts`. Removing it breaks every relative link once the gateway fronts the app.
4. **Never commit `.env`.** Every variable the app reads must appear in `.env.example` (value may be blank). The **canonical `.env` lives with the gateway** at `platform-portal/.env`; each standalone compose file references it via `env_file: ../platform-portal/.env`. Edit secrets there, not here.
5. **Never delete the `platform_net` network.** It is shared with every other PSS service on the host.
6. **Never add `--no-verify`, `--no-gpg-sign`, or skip hooks** unless the user explicitly asks.
7. **Build-time `NEXT_PUBLIC_*` vars** must be passed as Docker `--build-arg`, not only in `environment:`. Changing them requires a **rebuild**, not a restart.
8. **Keep `.dockerignore` in place** (at `app/.dockerignore`). It excludes the host's `node_modules` and `.next` from the build context. Without it, Windows-path symlinks from local `npm install` overlay the container's clean `node_modules` and the build fails with `Module not found: Can't resolve '@platform/*'`.

---

## How to make changes

### App code

Standard Next.js work. Respect existing component patterns. If a shared component (sidebar, auth button) was vendored from `platform-portal/packages/*`, changes must be **mirrored upstream** or the apps will drift visually.

### Adding an environment variable

1. **Secrets / cross-app values** (Supabase keys, gateway URLs, doc service URL): add to `platform-portal/.env` — the canonical file. This repo's `docker-compose.app.yml` already picks it up via `env_file: ../platform-portal/.env`.
2. **App-specific values** (anything only this app uses): add to `.env.example` here with a blank or sample value, and to `docker-compose.app.yml` `environment:` block.
3. **Build-time client-visible values**: prefix with `NEXT_PUBLIC_*`, declare as `ARG` + `ENV` in the Dockerfile, and pass via `--build-arg` in `build.sh`. Changing these requires a **rebuild**, not a restart.
4. Document it in the README.

### Changing a port — **only if absolutely necessary**

Port change is a coordinated edit across three places, in this order:
1. `platform-portal/docs/PORTS.md` (PR first, discuss before merging).
2. `platform-portal/docker/nginx/production.conf` — both `location` and `upstream`/`set $...` entries.
3. This repo's `docker-compose.app.yml`, `Dockerfile` `EXPOSE`, and `next.config.ts` if relevant.

Rebuild gateway image + app image. Deploy gateway **after** the app is up on the new port to avoid a proxy gap.

### Building & pushing

```bash
docker buildx build \
  --platform linux/arm64 \
  --build-arg NEXT_PUBLIC_SUPABASE_URL="$NEXT_PUBLIC_SUPABASE_URL" \
  --build-arg NEXT_PUBLIC_SUPABASE_ANON_KEY="$NEXT_PUBLIC_SUPABASE_ANON_KEY" \
  -t ghcr.io/ukstevem/<appname>:$(git rev-parse --short HEAD) \
  -t ghcr.io/ukstevem/<appname>:latest \
  --push \
  .
```

### Deploying on the Pi

```bash
ssh pi@10.0.0.75
cd /opt/pss-<appname>
git pull
docker compose -f docker-compose.app.yml pull
docker compose -f docker-compose.app.yml up -d
```

No gateway restart needed unless nginx config changed.

### Rolling back

Edit `docker-compose.app.yml`:
```yaml
image: ghcr.io/ukstevem/<appname>:<previous-sha>
```
Then:
```bash
docker compose -f docker-compose.app.yml up -d
```

The gateway keeps proxying to the same service name — users see at most a few seconds of interruption on that one app.

---

## What this repo is not

- **Not** part of the `platform-portal` monorepo. Do not add it to the monorepo's `pnpm-workspace.yaml` or `docker-compose.yml`. If you see those references, they are historical — delete them.
- **Not** a place to centralise shared UI. If you need to update the sidebar for every app, that work belongs in `platform-portal/packages/ui` (or the future `@pss/ui` npm package) — not duplicated here.
- **Not** self-exposing to the public internet. The app binds to its port on the internal network; the gateway is the only entry point.

---

## Where to look

| Question                               | File                                                |
|----------------------------------------|-----------------------------------------------------|
| Which port is mine?                    | `platform-portal/docs/PORTS.md`                     |
| How does the gateway route me?         | `platform-portal/docker/nginx/production.conf`      |
| How do I extract another app like me?  | `platform-portal/docs/APP_EXTRACTION_GUIDE.md`      |
| What env vars do I need?               | `./.env.example`                                    |
| How do I run locally?                  | `./README.md` → "local development"                 |

---

## When in doubt

Ask the user before:
- Changing the port, service name, or basePath.
- Editing `production.conf` from a non-gateway repo.
- Removing any field named `platform_net`, `external: true`, or `ghcr.io/ukstevem/...`.
- Force-pushing, rewriting history on `main`, or deleting branches.

These are coordination points. Get them wrong and every other PSS app breaks at the same moment.
