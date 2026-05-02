# Handoff prompt — wiring platform-portal to self-hosted Supabase

This is a prompt to paste into a fresh AI chat session that's working on the **`platform-portal`** repo. It conveys enough context for that session to help wire dev (and only dev) at the self-hosted Supabase instance built by this repo (`pss-supabase-host`), while leaving production untouched.

Below the divider is the prompt itself — copy from `<<<` to `>>>` and paste it whole.

---

```
<<<
# Context

I have a Next.js monorepo at `platform-portal` (Windows path: `C:\Dev\PSS\platform-portal`).
It hosts several PSS standalone apps (their architecture and conventions are
documented in `docs/SKILL_pss_standalone_app.md` inside the platform-portal repo,
and an identical copy lives in `C:\Dev\PSS\pss-supabase-host\docs\SKILL_pss_standalone_app.md`).

All those apps currently point at a **cloud Supabase production project** at
`https://hguvsjpmiyeypfcuvvko.supabase.co`. The cloud project is the source of
truth for data.

I've just stood up a **self-hosted Supabase dev instance** on a Proxmox VM at
`http://10.0.0.85:8000`. Full setup runbooks are in `C:\Dev\PSS\pss-supabase-host`
(particularly `docs/05_supabase_stack.md`). The self-hosted instance:

- Runs Postgres 17.6 + the Supabase stack (auth, REST/PostgREST, storage,
  realtime, Studio, edge functions, supavisor pooler) — same shape as cloud.
- Has schema and data parity with cloud, refreshed via a one-way sync script
  (`scripts/resync.sh` in pss-supabase-host). The refresh is one-way only:
  cloud → self-hosted, never the reverse.
- Is reachable on the LAN (or via Proxmox jump host on VPN).

# What I want

Wire the platform-portal **dev container** to use the self-hosted Supabase,
while keeping production builds (CI / GHCR-pushed images / Pi deployments)
pointing at cloud.

I need two distinct env configurations and a clean way to select between them.

# Constraints I cannot bend

1. **NEXT_PUBLIC_SUPABASE_URL** and **NEXT_PUBLIC_SUPABASE_ANON_KEY** are baked
   at Docker build time, not read at runtime (per
   `docs/SKILL_pss_standalone_app.md` invariant 7). Switching between cloud and
   self-hosted requires rebuilding the app's Docker image.
2. Production is the source of truth for data. Self-hosted is a sandbox refreshed
   from production. The handoff must NOT introduce anything that risks dev → prod
   data flow.
3. Dev workflow (e.g. `npm run dev`, dev container) is the ONLY path that should
   use self-hosted. Production CI / image builds / Pi deploys must continue to
   use cloud env values.
4. Don't commit secrets. The cloud anon key is technically public-safe (it's
   designed for browser shipment), but the current convention in
   `platform-portal/.env` is "canonical, gitignored, real values live there" —
   keep that pattern.

# Connection details for the self-hosted instance

- Studio (admin UI):       `http://10.0.0.85:8000/`        (HTTP Basic Auth)
- Kong API base URL:       `http://10.0.0.85:8000`         (use as NEXT_PUBLIC_SUPABASE_URL)
- ANON_KEY:                run `./scripts/print_connections.sh > connections.md` from
                           `C:\Dev\PSS\pss-supabase-host` (use `JUMP_HOST=root@10.0.0.84`
                           prefix if on the SonicWall VPN). Open the resulting
                           `connections.md` for the actual value.
- SERVICE_ROLE_KEY:        in the same `connections.md` (admin only — don't ship to clients)
- Postgres pooler:         `10.0.0.85:5432`, user/password in `connections.md`

The cloud equivalents are in cloud Supabase dashboard → Settings → API. Project ref is `hguvsjpmiyeypfcuvvko`.

# Reference docs (in pss-supabase-host)

- `docs/SKILL_pss_standalone_app.md` — how standalone apps and platform-portal fit
  together; build/deploy patterns; the gateway architecture
- `docs/05_supabase_stack.md` — self-hosted stack layout
- `docs/08_resync.md` — how dev gets refreshed from cloud (one-way only)

# Help I'd like

Look at platform-portal as it stands today and propose a clean approach for:

1. Splitting the canonical env into two files — e.g. `.env.development` (self-hosted)
   and `.env.production` (cloud, the existing real values). The production one is
   the existing canonical file; the development one is new.
2. Selecting which env file is used at Docker build time (the `--build-arg` flow
   per `docs/SKILL_pss_standalone_app.md`), with sensible defaults:
   - `npm run dev` / local dev container → uses development env (self-hosted)
   - Production image build via `docker buildx --push` → uses production env (cloud)
3. Making sure the production CI / build path picks up production env automatically,
   never dev. Even if a developer accidentally has `.env.development` filled in,
   the production build path should ignore it.
4. Documenting the new flow in the platform-portal repo so other devs know which
   env they're hitting in dev vs prod, and how to flip between them locally if
   they need to test against cloud explicitly (rare, but possible).
5. **Post-rotation refresh** — when self-hosted credentials are rotated (via
   the `scripts/gen_secrets.py` flow in `pss-supabase-host`), the rotated
   `ANON_KEY` / `SERVICE_ROLE_KEY` / `JWT_SECRET` invalidate any app already
   built against the old values. The dev `.env.development` here in platform-portal
   must be regenerated from `connections.md` (produced by
   `pss-supabase-host/scripts/print_connections.sh`), and any dev images already
   built against old keys must be rebuilt. Document this dependency clearly in
   platform-portal's README so it doesn't surprise anyone. Cloud rotation is
   independent — different keys, different rotation cadence.

# Process

Don't change anything yet. Walk me through:

- The current state of platform-portal's env handling (so we both share a baseline)
- Your proposed approach for the split
- Anywhere you see ambiguity or risk

Then we implement once we agree on the design.
>>>
```

---

## Notes for the user (you)

- This prompt is self-contained — it doesn't assume the platform-portal session has any of the bd context, memories, or chat history from the pss-supabase-host work.
- Once you start the platform-portal chat, you can refer back to `connections.md` (gitignored, in the pss-supabase-host repo root) for live values when the session asks for them.
- The platform-portal session may want to read files in the pss-supabase-host repo (especially `docs/SKILL_pss_standalone_app.md`) — that's expected and fine; those docs are committed and stable.
- If the platform-portal session proposes anything that would change cloud Supabase, push back. The constraint is one-way: dev mirrors cloud, never the other direction.
