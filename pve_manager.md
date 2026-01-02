# pve_manager.sh (Proxmox Admin Manager)

Interactive menu wrapper for common Proxmox admin workflows:
1) Offload drives from VMs 100/102/103 to the host  
2) Reload drives back to VMs 100/102/103  
3) Clone VM 200 into a new “standard” VM (with VLAN + bridge set)

## Requirements
- Run on Proxmox VE host as root (needs `qm`, `/etc/pve`, and permissions to stop/start/clone/set).
- Bash.
- Supporting scripts exist under: `./vm_script/` (relative to this file).

## Directory layout
```

pve-admin/
pve_manager.sh
vm_script/
Unload_VM100.sh  Reload_VM100.sh
Unload_VM102.sh  Reload_VM102.sh
Unload_VM103.sh  Reload_VM103.sh

````

## What you must change to adapt
Edit near the top:
- `SCRIPT_DIR="$(dirname "$0")/vm_script"`  
  Change if your scripts are stored elsewhere.

Edit inside **Task 3 (Clone VM 200)** if your environment differs:
- Source VM ID: `qm clone 200 ...` (change `200` if needed)
- Storage target: `--storage vm-os` (change `vm-os` to your storage name)
- Bridge name: `bridge=MAIN_br` (replace `MAIN_br` with your Proxmox bridge, e.g. `vmbr0`)
- Allowed VLAN tags prompt/validation: currently only `20|21|30|31`  
  Update the “Available VLAN Tags” text and the `case` block.

Optional: update the post-clone instruction:
- `run './reset.sh $NEW_NAME' inside it`  
  Replace with your actual in-guest reset script name/path (e.g. `reset_clone_VM.sh`).

## Security / safety model
- All destructive actions (stop/unload/reload/clone) are **interactive** and require `y/n` confirmation.
- Clone target ID validation:
  - Must be numeric
  - Must not already exist (`qm status <id>` used as existence check)
- Clone summary printed before execution for operator review.

## Menu options
### 1) Offload Drives
Prompts per VM (100/102/103). If confirmed, runs:
- `Unload_VM100.sh`, `Unload_VM102.sh`, `Unload_VM103.sh`

### 2) Reload Drives
Prompts per VM (100/102/103). If confirmed, runs:
- `Reload_VM100.sh`, `Reload_VM102.sh`, `Reload_VM103.sh`

### 3) Clone VM 200
Prompts for:
- New VM ID (must not exist)
- New VM name
- VLAN tag (limited to 20/21/30/31)
- Clone type: full clone (`--full 1`) or linked clone (`--full 0`)

Then executes:
- `qm clone 200 <NEW_ID> --name "<NEW_NAME>" --storage vm-os --full <0|1>`
- `qm set <NEW_ID> --net0 virtio,bridge=MAIN_br,firewall=1,tag=<VLAN_TAG>`
  (Redefining `net0` also generates a new MAC)

## Assumptions
- VM IDs 100/102/103 exist and your `vm_script/` contains the matching unload/reload scripts.
- VM 200 is the “standard template” VM intended for cloning.
- Your network policy uses `net0` on the specified bridge and VLAN tags.
- Script is run interactively in a terminal (uses `clear` and `read -p`).

## Run
```bash
cd ~/pve-admin
bash pve_manager.sh
````

```
```
