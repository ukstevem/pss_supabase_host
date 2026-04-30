# 03 — Install Docker Engine + compose plugin

**Bead:** `pssh-8bv`
**Goal:** Install Docker Engine and the `docker compose` v2 plugin from Docker's official apt repository on the hardened VM. After this, `docker run …` and `docker compose up -d` work for the `ubuntu` user without `sudo`. The next bead (`pssh-9fi` → `pssh-fj1`) starts using these to bring Supabase up.

We deliberately avoid two alternatives:
- **Snap** (`snap install docker`) — confined paths, awkward storage layout, breaks volumes for some compose stacks.
- **Ubuntu's `docker.io` package** — chronically out of date.

The official apt repo is the predictable, supported path.

---

## Prerequisites

- Bead `pssh-cgj` closed (VM hardened, key auth, internet working).
- `ssh ubuntu@10.0.0.85 'echo OK'` succeeds without password prompt.

---

## What this changes

| Concern | Before | After |
|---|---|---|
| Docker | not installed | `docker-ce`, `docker-ce-cli`, `containerd.io` from `download.docker.com` apt repo |
| Compose | not installed | `docker-compose-plugin` v2 (`docker compose` subcommand, *not* the legacy `docker-compose`) |
| Buildx | not installed | `docker-buildx-plugin` (we won't use it on the VM, but Docker recommends it as a default; tiny disk cost) |
| Group membership | only `sudo` group | `ubuntu` user added to `docker` group → `docker …` runs without `sudo` |
| Conflicting packages | none on cloud image | defensively removed: `docker.io`, `docker-doc`, `docker-compose`, `docker-compose-v2`, `podman-docker`, `containerd`, `runc` |
| Daemon | n/a | running, enabled at boot |

---

## 1. Run the install

Paste the **whole** block as one chunk into Git Bash:

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
set -euo pipefail

echo "==> 1/5 remove any conflicting packages (defensive — cloud image has none, safe to rerun)"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y "$pkg" 2>/dev/null || true
done

echo "==> 2/5 install prerequisites for adding the Docker apt repo"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl

echo "==> 3/5 add Docker's official apt repo (signed-by GPG key)"
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Write the repo file. dpkg gives us the arch, /etc/os-release gives the codename.
ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "==> 4/5 apt update + install Docker Engine + compose + buildx"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

echo "==> 5/5 add ubuntu user to docker group (takes effect on next SSH login)"
sudo usermod -aG docker ubuntu

echo "==> docker version (smoke from sudo since current shell hasn't picked up group yet)"
sudo docker version --format '{{.Server.Version}} (server) / {{.Client.Version}} (client)'
sudo docker compose version

echo "==> done. Disconnect and reconnect to use docker without sudo."
VM
```

Why the `sudo` smoke test at the end: Linux applies group membership at session/login time. Adding `ubuntu` to the `docker` group while we're already SSH'd in doesn't take effect for *this* session — only for the next one. Verifying with `sudo docker …` confirms the daemon is up regardless. The non-sudo verification happens in step 2 below in a fresh session.

---

## 2. Verify (in a fresh SSH session)

The new SSH session inherits the updated group membership.

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
set -euo pipefail

echo "--- groups (should include 'docker') ---"
id -nG

echo "--- docker without sudo ---"
docker version --format '{{.Server.Version}} (server) / {{.Client.Version}} (client)'

echo "--- docker compose ---"
docker compose version

echo "--- end-to-end: pull + run + remove a tiny image ---"
docker run --rm hello-world | tail -5

echo "--- daemon status ---"
sudo systemctl is-active docker
sudo systemctl is-enabled docker
VM
```

Expected:
- `id -nG` includes `docker`
- `docker version`, `docker compose version` print without "permission denied" or "Cannot connect to the Docker daemon"
- `hello-world` prints the canonical "Hello from Docker!" lines
- `docker` service `active` and `enabled`

---

## Acceptance checklist (for `pssh-8bv`)

- [ ] `docker --version` reports a current Docker CE (e.g. `Docker version 27.x` or later)
- [ ] `docker compose version` reports v2 (e.g. `v2.30.x` or later) — *not* the legacy v1 format
- [ ] `ubuntu` user is in `docker` group (`id -nG` shows `docker`)
- [ ] `docker run --rm hello-world` succeeds without `sudo`
- [ ] `systemctl is-active docker` → `active`, `is-enabled` → `enabled`
- [ ] No `docker.io` Ubuntu package installed (`dpkg -l | grep -E '^ii\s+docker.io'` empty)

When all six are ✓, close the bead: `bd close pssh-8bv`. That unblocks `pssh-9fi` (generate Supabase secrets), which is the last prep before we actually start Supabase containers in `pssh-fj1`.

---

## A note on UFW + Docker

Docker Engine writes iptables rules that **bypass UFW**. Practically: a container started with `-p 8000:8000` is reachable from anywhere that can route to the VM, regardless of what `ufw status` says — UFW's rule for port 8000 isn't what's gating access. For our setup this is benign:
- The VM lives on the LAN at `10.0.0.85` with no port forwarding from the router.
- The Supabase ports we'll publish (`8000` Kong, `5432` Postgres) are ports we *want* reachable from the LAN anyway.
- UFW still meaningfully gates non-Docker traffic (the SSH allow rule, future direct services).

If you ever need strict firewalling of Docker-published ports, the standard fix is to put `{"iptables": false}` in `/etc/docker/daemon.json` and manually add iptables/UFW rules per service — significantly more friction. Not worth it for a LAN-only dev box.

---

## Rollback

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
sudo systemctl disable --now docker.service docker.socket containerd.service
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo rm -rf /var/lib/docker /var/lib/containerd
sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
sudo deluser ubuntu docker || true
sudo apt-get autoremove -y
VM
```

Removes the binaries, image storage, repo, and group membership. Doesn't undo the LAN allow for ports 8000/5432 in UFW — those stay regardless.

---

## What's next

Closing `pssh-8bv` unblocks `pssh-9fi` (generate Supabase JWT secret + derived anon/service keys + dashboard creds + postgres password). That bead is offline work — generating secrets, writing them into a `.env` file on the VM and a sanitised `.env.example` in this repo. Then `pssh-fj1` brings the actual Supabase stack online.
