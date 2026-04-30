# 01 — Provision the Supabase-host VM on Proxmox

**Bead:** `pssh-81b`
**Goal:** Stand up an Ubuntu 24.04 LTS VM on the Proxmox box at `10.0.0.84` with the spec the rest of the runbook assumes (4 vCPU / 8 GB RAM / 50 GB disk, static IP `10.0.0.85`, your SSH key authorised). All steps below are reproducible — run this doc top-to-bottom from a clean Proxmox and you get the same VM every time.

There are two ways: **(A) Proxmox CLI via `qm` over SSH** (preferred — every step is a copy-pasteable command) and **(B) Proxmox web GUI** (fallback). Pick one. The CLI path is canonical because it's what re-deployment depends on.

---

## Prerequisites

**Where you run things.** Every command in this doc runs from your **dev workstation** — i.e. your local terminal (Windows + Git Bash, macOS Terminal, or any Linux shell). Heredocs of the form `ssh root@10.0.0.84 bash <<'PROX' … PROX` open an SSH connection to Proxmox, execute the script remotely, and drop you back to your local prompt automatically. You should **never** need to be at an interactive `root@pve:~#` prompt while following this doc.

**Passwordless SSH to Proxmox.** All the heredocs assume `ssh root@10.0.0.84 'echo OK'` works without prompting for a password. Bootstrap that once, before section 0:

```bash
# 1. Make an SSH keypair (skip if 'ls ~/.ssh/*.pub' already lists one)
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)"
# Press Enter through the prompts: default path, no passphrase (or set one if you prefer)

# 2. Authorise that key on Proxmox — last time you'll type the root password
ssh-copy-id root@10.0.0.84

# 3. Confirm key auth works
ssh root@10.0.0.84 'echo OK'
# Expect: OK    (no password prompt)
```

If step 3 still asks for a password, step 2 didn't take — re-run it, watch the output for "Number of key(s) added", and try again.

The same key gets baked into the new Supabase-host VM in section A.2, so once you've done this you can `ssh ubuntu@10.0.0.85` later with no extra setup.

**Find your LAN gateway and DNS.** The values in section 0 below default to `10.0.0.2` (gateway) and `10.0.0.105` (DNS) — the values for *this* author's network. They are almost certainly different on yours. Discover yours **before** running any of the `qm` commands in section A:

```bash
# Default gateway: the router-facing address your dev workstation sends
# packets through to reach the Internet
ipconfig | grep -iE 'default gateway'                        # Windows / Git Bash
# or
ip route | awk '/^default/ {print "Default Gateway: " $3}'   # macOS / Linux

# DNS servers
ipconfig //all | grep -iE 'dns servers'                      # Windows / Git Bash
# or
resolvectl status | grep -E 'Current DNS Server|DNS Servers' # macOS / Linux
```

If your gateway and DNS are not `10.0.0.2` / `10.0.0.105`, **edit the values in section 0's table and section A.2's `--ipconfig0` and `--nameserver` flags before running anything**. This file is the source of truth — keep it accurate for your environment, not mine.

---

## 0. Inputs you'll need

Gather these before you start. If any are wrong, fix them in this doc *before* running commands so the file stays the source of truth.

| Variable | Value used in this guide | How to find/change yours |
|---|---|---|
| Proxmox host | `10.0.0.84` | LAN |
| Proxmox SSH user | `root` | default for PVE; substitute if you've moved off root |
| Storage pool (VM disks) | `local-lvm` | `pvesm status` — pick a thin-pool that has free space |
| Storage pool (ISOs/images) | `local` | `pvesm status` — usually `local` for content `iso,vztmpl` |
| Network bridge | `vmbr0` | `ip -br link \| grep vmbr` |
| LAN gateway | `10.0.0.2` | see "Find your LAN gateway and DNS" above |
| LAN DNS (primary) | `10.0.0.105` | see "Find your LAN gateway and DNS" above |
| LAN DNS (fallback) | `1.1.1.1` | leave as-is unless you forbid public DNS |
| Template VMID | `9000` | any unused id; `9000+` is a Proxmox convention for templates |
| VM VMID | `200` | any unused id |
| VM name | `pss-supabase-host` | matches the repo name |
| VM IP | `10.0.0.85/24` | confirm not in use: `ping -c1 10.0.0.85` from your dev box should fail |
| SSH key | the public key you SSH from | `cat ~/.ssh/id_ed25519.pub` (or your key of choice) |

If any of these change, update the table here **first**, then re-run only the affected sections — that's what makes this re-runnable.

---

## A. CLI path (canonical)

Run everything in this section from your dev workstation, SSHing into Proxmox.

> ### ⚠️ How to paste these blocks
>
> Every fenced `bash` block below is **one paste**. Select from the opening ```` ```bash ```` line to the closing ```` ``` ```` and paste it whole into your terminal. Do **not** select the inner `qm ...` lines on their own — they reference shell variables (like `${TEMPLATE_VMID}`) that are defined earlier in the same block. If you paste a fragment, those variables expand to nothing and you'll see `400 not enough arguments` from `qm`.
>
> If you'd rather work interactively (one command at a time), substitute the literal value in for each variable as you go (e.g. `9000` instead of `${TEMPLATE_VMID}`).

### A.1 — One-time: build the Ubuntu 24.04 cloud-init template

This produces a reusable Proxmox template (`VMID 9000`) that any future VM clones from. **You only do this once per Proxmox host.** Skip to A.2 if the template already exists (`qm list | grep 9000`).

```bash
ssh root@10.0.0.84 bash <<'PROX'
set -euo pipefail

TEMPLATE_VMID=9000
STORAGE=local-lvm
IMG_DIR=/var/lib/vz/template/iso
IMG_NAME=noble-server-cloudimg-amd64.img
IMG_URL=https://cloud-images.ubuntu.com/noble/current/${IMG_NAME}

# 1. Download the official Ubuntu 24.04 LTS cloud image (idempotent)
mkdir -p "${IMG_DIR}"
[ -f "${IMG_DIR}/${IMG_NAME}" ] || wget -O "${IMG_DIR}/${IMG_NAME}" "${IMG_URL}"

# 2. Create a stub VM, then configure it via independent qm-set calls.
#    Splitting across multiple qm commands (instead of one long backslash-
#    continued qm create) means a partial paste still gets a clear error
#    rather than silently misbehaving.
qm create ${TEMPLATE_VMID} --name ubuntu-24.04-cloudinit
qm set ${TEMPLATE_VMID} --memory 2048 --cores 2 --cpu host
qm set ${TEMPLATE_VMID} --net0 virtio,bridge=vmbr0
qm set ${TEMPLATE_VMID} --scsihw virtio-scsi-pci
qm set ${TEMPLATE_VMID} --serial0 socket --vga serial0
qm set ${TEMPLATE_VMID} --agent enabled=1

# 3. Import the cloud image as the boot disk on STORAGE
qm importdisk ${TEMPLATE_VMID} "${IMG_DIR}/${IMG_NAME}" ${STORAGE}

# 4. Attach the imported disk and a cloud-init drive
qm set ${TEMPLATE_VMID} --scsi0 ${STORAGE}:vm-${TEMPLATE_VMID}-disk-0,discard=on,ssd=1
qm set ${TEMPLATE_VMID} --ide2 ${STORAGE}:cloudinit
qm set ${TEMPLATE_VMID} --boot order=scsi0
qm set ${TEMPLATE_VMID} --ipconfig0 ip=dhcp

# 5. Convert to template (locks it; clones now point at this)
qm template ${TEMPLATE_VMID}

echo "Template ${TEMPLATE_VMID} ready."
PROX
```

Verify:

```bash
ssh root@10.0.0.84 "qm list | grep 9000"
# Expect: 9000 ubuntu-24.04-cloudinit  stopped  ...
```

### A.2 — Clone the template into the Supabase-host VM

First, copy your SSH public key over to Proxmox so `qm set --sshkey` can read it from a file (the cleanest cross-shell approach):

```bash
# On your dev workstation
scp ~/.ssh/id_ed25519.pub root@10.0.0.84:/tmp/dev_pubkey
# adjust the path if you use a different key (e.g. id_rsa.pub)
```

Then run the clone + cloud-init configuration on Proxmox:

```bash
ssh root@10.0.0.84 bash <<'PROX'
set -euo pipefail

TEMPLATE_VMID=9000
VM_VMID=200
VM_NAME=pss-supabase-host
STORAGE=local-lvm
DISK_GB=50          # final disk size; cloud image starts ~2 GB and we resize up
RAM_MB=8192
CORES=4
GATEWAY=10.0.0.2
DNS="10.0.0.105 1.1.1.1"
IPADDR=10.0.0.85/24
PUBKEY_FILE=/tmp/dev_pubkey

[ -f "${PUBKEY_FILE}" ] || { echo "Missing ${PUBKEY_FILE} — run the scp step above first"; exit 1; }

# 1. Full clone (independent disk; not linked) so the template can be rebuilt later without breaking us
qm clone ${TEMPLATE_VMID} ${VM_VMID} --name ${VM_NAME} --full true --storage ${STORAGE}

# 2. Resources
qm set ${VM_VMID} --memory ${RAM_MB} --cores ${CORES} --cpu host

# 3. Resize the boot disk up to ${DISK_GB}G
qm resize ${VM_VMID} scsi0 ${DISK_GB}G

# 4. Cloud-init: user, SSH key, static IP, DNS
qm set ${VM_VMID} --ciuser ubuntu
qm set ${VM_VMID} --sshkey ${PUBKEY_FILE}
qm set ${VM_VMID} --ipconfig0 ip=${IPADDR},gw=${GATEWAY}
qm set ${VM_VMID} --nameserver "${DNS}"
qm set ${VM_VMID} --searchdomain local

# 5. Start it
qm start ${VM_VMID}

# 6. Tidy up the uploaded pubkey (cloud-init has it now; no need to keep on Proxmox)
rm -f "${PUBKEY_FILE}"

echo "VM ${VM_VMID} (${VM_NAME}) started."
PROX
```

The VM takes ~30–60 s to finish first-boot cloud-init (resize the FS, install your SSH key, apply network config). You can watch progress in the Proxmox web console (`Console` tab on VMID 200) — when you see `login:` and the IP is shown, it's ready.

### A.3 — Smoke test from your dev workstation

```bash
# DNS / ARP shouldn't matter since IP is static — try direct IP first
ssh-keygen -R 10.0.0.85   # clear any stale host key from previous tests
ssh ubuntu@10.0.0.85 'echo "hostname=$(hostname); cores=$(nproc); ram=$(free -h | awk "/^Mem:/ {print \$2}"); disk=$(df -h / | awk "NR==2 {print \$2}"); ip=$(hostname -I)"'
```

Expected output:

```
hostname=pss-supabase-host; cores=4; ram=7.7Gi; disk=49G; ip=10.0.0.85
```

(`7.7Gi` is the kernel-visible RAM after firmware reservation — that's fine.)

If SSH refuses with `Connection refused` or hangs, see **Troubleshooting** below.

---

## B. GUI path (fallback)

If you'd rather click through the Proxmox web UI for the first VM and only switch to the CLI for re-deployments later, here's the equivalent. Note: doing it this way means you don't get a re-runnable script — section A is the canonical version, and a future redeploy from this doc must use it.

1. **Datacenter → 10.0.0.84 → local → ISO Images → Download from URL**
   URL: `https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img`
   File name: `noble-server-cloudimg-amd64.img`
2. **Create VM**: VMID `200`, name `pss-supabase-host`, no ISO at OS step (we'll attach the cloud image later), system → defaults, hard disk → discard later, CPU → 4 cores `host`, memory → 8192 MiB, network → `vmbr0` virtio. Don't start.
3. SSH into Proxmox and import the cloud image as the disk:
   ```bash
   qm importdisk 200 /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img local-lvm
   qm set 200 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-200-disk-0,discard=on,ssd=1
   qm set 200 --ide2 local-lvm:cloudinit
   qm set 200 --boot order=scsi0
   qm set 200 --serial0 socket --vga serial0
   qm set 200 --agent enabled=1
   qm resize 200 scsi0 50G
   ```
4. Back in the GUI on VMID 200 → **Cloud-Init**: set User `ubuntu`, paste your SSH public key, IP Config (net0) `Static, 10.0.0.85/24, Gateway 10.0.0.2`, DNS `10.0.0.105 1.1.1.1` (or your LAN's actual values — see Prerequisites). Click **Regenerate Image**.
5. **Start** the VM.

Then run the smoke test from A.3.

---

## Verification checklist (acceptance criteria for `pssh-81b`)

- [ ] `ssh ubuntu@10.0.0.85` succeeds with key auth
- [ ] `nproc` reports `4`, `free -h` reports `7.7Gi` (or close), `df -h /` shows `~49G`
- [ ] `hostname` returns `pss-supabase-host`
- [ ] `ip a` shows `10.0.0.85/24` on the primary interface, default route via `10.0.0.1`
- [ ] Proxmox web UI shows the VM running with the agent reporting an IP
- [ ] This file (`docs/01_proxmox_vm.md`) is the only thing you needed to follow — no off-doc tribal knowledge required

When all six are ✓, close the bead: `bd close pssh-81b`.

---

## Troubleshooting

**SSH refuses connection / hangs** — cloud-init may not have finished. Open the Proxmox console for VMID 200 and watch the boot log; once you see `Cloud-init v. ... finished` and `login:`, retry. If it never finishes, check the cloud-init drive is attached (`qm config 200 | grep ide2`) and your SSH key is on the cloud-init tab.

**Wrong IP / DHCP-assigned IP** — re-run `qm set 200 --ipconfig0 ip=10.0.0.85/24,gw=10.0.0.1` and reboot the VM (`qm reboot 200`). Cloud-init re-applies network config on boot.

**`pvesm status` shows no LVM-thin pool** — your Proxmox install uses different storage. Run `pvesm status` to list available pools and substitute throughout. ZFS users: `local-zfs` is fine; thin-on-LVM-thick: `local-lvm` is fine; raw `dir` storage on `local` will also work but is slower for VMs.

**VM won't boot, "no bootable device"** — `qm set 200 --boot order=scsi0` was missed. Re-set, restart.

**Need to start over from a clean slate** — `qm stop 200; qm destroy 200` then re-run section A.2. The template (9000) doesn't need rebuilding.

**`400 not enough arguments` from `qm create`** — you pasted a fragment of the heredoc instead of the whole block, so a shell variable expanded to nothing. Recovery: `qm status 9000 2>/dev/null && qm destroy 9000` to clear any half-created VM, then re-paste the full A.1 fenced block in one go.

**Need to change the VM's gateway / DNS after first boot** — `qm set 200 --ipconfig0 ...` updates the cloud-init metadata on the Proxmox host, but the cloud-init drive presented to the VM does **not** automatically refresh; subsequent reboots still see stale data, and `cloud-init clean --logs && reboot` re-applies from the same stale drive. Don't fight it — bypass cloud-init's network management on the VM and own the netplan file directly:

```bash
ssh ubuntu@10.0.0.85 bash <<'VM'
set -euo pipefail

# Tell cloud-init to stop managing network on this VM
sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg > /dev/null <<'CCFG'
network: {config: disabled}
CCFG

# Replace cloud-init's netplan with our own static config
sudo rm -f /etc/netplan/50-cloud-init.yaml
sudo tee /etc/netplan/01-static.yaml > /dev/null <<'NETPLAN'
network:
  version: 2
  ethernets:
    eth0:
      addresses: [10.0.0.85/24]
      routes:
        - to: default
          via: 10.0.0.2
      nameservers:
        addresses: [10.0.0.105, 1.1.1.1]
        search: [powersystems.local]
NETPLAN
sudo chmod 600 /etc/netplan/01-static.yaml
sudo netplan apply
VM
```

Adjust `addresses`, `via`, `nameservers`, and `search` to match your LAN. After this, the VM's network is governed solely by `01-static.yaml` and survives any future cloud-init churn. Note: this is the recovery path; for the *first* deployment, getting the values right in the section A.2 `qm set --ipconfig0` flags is sufficient.

---

## Rollback / destroy

```bash
ssh root@10.0.0.84 'qm stop 200 || true; qm destroy 200'
```

This removes the VM and its disk. The template (`VMID 9000`) and cloud image are untouched — re-running section A.2 rebuilds the VM in ~1 minute.

---

## What this VM does NOT yet have

Everything beyond "it boots and you can SSH in":

- No non-root sudo workflow beyond the default `ubuntu` user → bead **`pssh-cgj`** (OS hardening) handles users, fail2ban, UFW, unattended-upgrades.
- No Docker → bead **`pssh-8bv`**.
- No Supabase → bead **`pssh-fj1`**.

Don't try to consolidate those into this step — keeping each bead's scope tight is what makes the runbook re-runnable in pieces.
