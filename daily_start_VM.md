# Daily Startup Controller V7 (Proxmox)

A reference Bash script for **interactive VM startup** on Proxmox VE with:
- Forbidden/deny VM enforcement
- Core “infra” VM handling
- Global VLAN policy audit
- Exclusive-VM resource locking + disk presence checks
- Optional VLAN switching within allowed pairs

## Intended use
Use this as a **template**. It assumes a specific lab policy (VM IDs, bridge name, VLAN tags, reload scripts). You must adapt the config section before running.

---

## What you must change (edit these lines)
Edit **top “CONFIGURATION” block**:

1) VM policy sets (change IDs to match your environment)
- `EXCLUSIVE_VMS=(100 102 103)`
- `FORBIDDEN_VMS=(104 200)`  (hard stop/hide)
- `CORE_VM=106`              (infra VM, exempt)
- `DENY_VM=107`              (hidden + stop if running)

2) VLAN allowlist (change tags you permit)
- `VALID_TAGS=" 10 11 20 21 30 31 "`

3) VLAN switching pairs (edit to your allowed groups)
- `VLAN_GROUPS["10"]="10,11"` etc.

4) Expected extra disks for exclusive VMs
- `EXPECTED_DISKS["100"]=2` etc.

5) **Your main bridge name** (critical)
- Search: `bridge=MAIN_br`
- Replace `MAIN_br` with your actual Proxmox bridge (e.g. `vmbr0`)

6) Reload script path (if you use the auto-fix)
- `bash "$HOME/pve-admin/vm_script/Reload_VM$TARGET_ID.sh"`
Update directory and naming to your own scripts, or remove this feature.

---

## Security model (how it prevents mistakes)
### Layer 1: Hard stops
- If VM **104** is running, the script exits immediately.
- Other `FORBIDDEN_VMS` require explicit confirmation to stop; declining exits.

### Layer 2: Visibility control
- `FORBIDDEN_VMS`, `CORE_VM`, and `DENY_VM` are **hidden** from the startup selection menu.

### Layer 3: VLAN compliance gate
- Before starting anything, it audits **all VMs**:
  - Must use `bridge=<MAIN_BRIDGE>`
  - `tag` must be in `VALID_TAGS`
- If violations exist, you must confirm to continue.

### Layer 4: Exclusive resource lock
- For `EXCLUSIVE_VMS`, it blocks startup if any other exclusive VM is running.

### Layer 5: Disk presence check (exclusive only)
- Verifies `scsi1..scsi9` count meets `EXPECTED_DISKS[VMID]`.
- Optional: runs a reload/fix script, then re-checks.

---

## Assumptions (you must keep or modify)
- Runs on **Proxmox VE host** as root (needs `qm`, `/etc/pve/qemu-server/*.conf`).
- VM names have **no spaces** (name parsing uses `awk '{print $2}'`).
- VLAN is expressed as `tag=<num>` in NIC lines; missing `tag` becomes `Untagged` (treated as violation unless you add it to `VALID_TAGS`).
- VLAN switching modifies **only `net0`**.
- Disk check counts only `scsi[1-9]:` entries (adapt if you use SATA/NVMe/virtio-scsi naming).

---

## Sub-scripts / dependencies
Optional helper scripts (only used for exclusive VMs when disks are missing):
- `~/pve-admin/vm_script/Reload_VM<VMID>.sh`

If you do not have these, remove or replace the “Run Reload…” block.

---

## How to run
1) Edit the config section at the top (VM IDs, bridge, VLANs, reload path).
2) Run on the Proxmox host:
```bash
bash daily_startup_controller_v7.sh
