# 02 — OS hardening on the Supabase VM

**Bead:** `pssh-cgj`
**Goal:** Bring the freshly-cloud-init'd VM at `10.0.0.85` to a hardened baseline before any service runs on it. Idempotent — re-running this doc on the same VM should produce the same end state, not double up.

This step is purely about the OS. No Docker, no Supabase yet — those are `pssh-8bv` and `pssh-fj1`.

---

## Prerequisites

- Bead `pssh-81b` closed: VM up at `10.0.0.85`, `ssh ubuntu@10.0.0.85 'echo OK'` works without password.
- Same dev workstation expectations as `01_proxmox_vm.md` — every command runs from your local terminal, never from an interactive `ubuntu@pss-supabase-host:~$` prompt.

---

## What this changes

| Concern | Before | After |
|---|---|---|
| Default user | `ubuntu` (sudo via key auth, NOPASSWD) | unchanged — we keep the cloud-init user |
| Root SSH login | `prohibit-password` (cloud-image default; root has no password anyway) | explicit `PermitRootLogin no` |
| SSH password auth | enabled (no point — no passwords set, but config still permits it) | `PasswordAuthentication no` |
| Firewall | inactive — anything could reach any port | UFW: default deny incoming, allow outgoing, named LAN rules for 22/8000/5432 |
| Brute-force defence | none | `fail2ban` running, default `sshd` jail enabled |
| Timezone | `UTC` | `Europe/London` (configurable in inputs) |
| Security patches | manual | `unattended-upgrades` enabled — daily |
| QEMU guest agent | flag set in `qm` config but daemon not installed | `qemu-guest-agent` installed and running, so Proxmox can do graceful shutdown and IP reporting |
| Package state | whatever the cloud image shipped | `apt upgrade` applied so we start at a current patch level |

Why each one matters: the moment we put Postgres on this box (later beads), the firewall and SSH posture stop being academic. We harden first, then layer services on a known-good base.

---

## 0. Inputs

| Variable | Default in this guide | Change if... |
|---|---|---|
| VM IP | `10.0.0.85` | `01` set a different IP |
| VM user | `ubuntu` | you renamed or replaced the cloud-init user |
| LAN CIDR | `10.0.0.0/24` | your subnet differs (check `ip a` on dev box) |
| Timezone | `Europe/London` | you're elsewhere — `timedatectl list-timezones` to find your zone |

---

## 1. Run the hardening

Run this **whole block** as one paste from your dev workstation. It SSHes in as `ubuntu`, runs everything via `sudo`, and exits.

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
set -euo pipefail

LAN_CIDR=10.0.0.0/24
TZ=Europe/London

echo "==> 1/7 apt update + upgrade (current patch level)"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  upgrade

echo "==> 2/7 install hardening tools + guest agent"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  fail2ban ufw unattended-upgrades qemu-guest-agent

echo "==> 3/7 set timezone to ${TZ}"
sudo timedatectl set-timezone "${TZ}"

echo "==> 4/7 SSH hardening (drop-in conf, sshd_config untouched)"
# Drop-in is idempotent: re-running the script overwrites this one file
# to the same content. /etc/ssh/sshd_config remains stock.
sudo tee /etc/ssh/sshd_config.d/00-pss-hardening.conf >/dev/null <<'SSHCONF'
# Managed by docs/02_os_bootstrap.md (bead pssh-cgj). Overwrite to update.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
SSHCONF
sudo sshd -t   # validate; if this fails the next reload is skipped automatically because of set -e
sudo systemctl reload ssh

echo "==> 5/7 UFW: default deny in, allow out, LAN-only allowlist"
# Reset wipes any previous rules so re-running is deterministic.
sudo ufw --force reset >/dev/null
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from "${LAN_CIDR}" to any port 22   proto tcp comment 'SSH'
sudo ufw allow from "${LAN_CIDR}" to any port 8000 proto tcp comment 'Supabase Kong (gateway) — opened ahead of pssh-fj1'
sudo ufw allow from "${LAN_CIDR}" to any port 5432 proto tcp comment 'Postgres direct access (dev tools) — opened ahead of pssh-fj1'
sudo ufw --force enable

echo "==> 6/7 fail2ban (default sshd jail)"
sudo systemctl enable --now fail2ban

echo "==> 7/7 unattended security upgrades"
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'APTAUTO'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APTAUTO
sudo systemctl enable --now unattended-upgrades

echo "==> done."
VM
```

**About the apt-get upgrade flags:** `Dpkg::Options::"--force-confdef"` + `--force-confold` make package updates non-interactive when a config file has changed locally — they keep the existing local file rather than prompting. On a fresh VM we have no local edits yet, so behaviour is the same as defaults; the flags matter the second time you run this script.

**About the UFW ports for 8000 and 5432:** they're opened *ahead* of the services that listen on them (Supabase Kong on 8000, Postgres on 5432, both stood up by `pssh-fj1`). Listing them here keeps the firewall declarative — `02` is the single place that defines the inbound surface, rather than each later bead bolting on a new rule. Nothing exploitable: the ports just have no listener until later.

---

## 2. Verify

Run this from your dev workstation. Each line should exit `0` and produce non-empty, sensible output.

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
set -euo pipefail

echo "--- timezone ---"
timedatectl | grep "Time zone"

echo "--- sshd config ---"
sudo sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication) '

echo "--- ufw status ---"
sudo ufw status verbose

echo "--- fail2ban ---"
sudo systemctl is-active fail2ban
sudo fail2ban-client status sshd | head -5

echo "--- unattended-upgrades ---"
sudo systemctl is-active unattended-upgrades
cat /etc/apt/apt.conf.d/20auto-upgrades

echo "--- guest agent ---"
sudo systemctl is-active qemu-guest-agent
VM
```

Expected (illustrative, exact wording varies by version):

- `Time zone: Europe/London (BST, +0100)` (or GMT in winter)
- `permitrootlogin no` / `passwordauthentication no` / `pubkeyauthentication yes`
- UFW: `Status: active`, default deny incoming / allow outgoing, three `ALLOW IN` rules from `10.0.0.0/24` for 22, 8000, 5432
- `fail2ban` and `unattended-upgrades` and `qemu-guest-agent` all `active`
- `fail2ban-client status sshd` shows the jail enabled with 0 currently banned

If anything is wrong, the section's small enough to re-run the whole `1. Run the hardening` block — it's idempotent.

---

## Acceptance checklist (for `pssh-cgj`)

- [ ] `ssh ubuntu@10.0.0.85` works (key auth, no password) — i.e. you didn't lock yourself out
- [ ] `ssh root@10.0.0.85` is rejected (root login disabled)
- [ ] UFW active, three LAN-allow rules visible, default policies are deny-in/allow-out
- [ ] `fail2ban-client status sshd` reports the jail running
- [ ] `unattended-upgrades` is enabled and `/etc/apt/apt.conf.d/20auto-upgrades` is the two-line file above
- [ ] `timedatectl` reports your chosen timezone
- [ ] Proxmox web UI shows the guest agent reporting an IP for VMID 200 (refresh the Summary tab)
- [ ] This doc was the only thing you needed to follow

When all eight are ✓, close the bead: `bd close pssh-cgj`.

---

## Recovery if you lock yourself out

Unlikely, but possible if the SSH key on the VM gets corrupted or you change the dev box's key without re-injecting. Two routes back in:

1. **Proxmox web console (noVNC):** Datacenter → 10.0.0.84 → VM 200 → Console. Login as `ubuntu` — but cloud images don't set a password by default, so you'll likely get `Login incorrect`. Workaround: in the Proxmox host shell, set a temporary password through cloud-init and reboot:
   ```bash
   ssh root@10.0.0.84
   qm set 200 --cipassword "$(openssl rand -base64 18)"
   qm reboot 200
   # use the password printed by openssl in the console; set up keys; then revert:
   qm set 200 --delete cipassword
   ```
2. **Reset and re-run from `01_proxmox_vm.md`:** `qm destroy 200` on Proxmox, re-clone from the template, re-run section 1 of *this* doc. Faster than recovering the in-place VM if there's nothing precious on it yet (and at this point, there isn't).

---

## Rollback (specific items)

You almost never need full rollback — re-run the script with edited inputs instead. But for individual reversals:

| To undo... | Run |
|---|---|
| The whole UFW config | `sudo ufw disable` (immediate); or `sudo ufw --force reset` |
| SSH hardening | `sudo rm /etc/ssh/sshd_config.d/00-pss-hardening.conf && sudo systemctl reload ssh` |
| Unattended upgrades | `sudo systemctl disable --now unattended-upgrades` |
| fail2ban | `sudo systemctl disable --now fail2ban` |

---

## What's next

`pssh-cgj` closing unblocks `pssh-8bv` (Docker Engine + compose plugin install). That's the next bead — and the last prerequisite before we start bringing up Supabase containers in `pssh-fj1`.
