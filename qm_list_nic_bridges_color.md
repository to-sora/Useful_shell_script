# qm_list_nic_bridges_color

List Proxmox QEMU VMs and display each VM’s NICs with bridge + VLAN info, with optional ANSI colors.

## What it does
- Runs `qm list` to show VMID / Name / Status (colored by status).
- For each VM, runs `qm config <VMID>` and parses `netX:` lines.
- Prints NIC model, `bridge=<vmbrX>`, and VLAN tag (`tag`/`vid`).

## Requirements
- Proxmox VE host with `qm` available
- Bash
- Color auto-disables if stdout is not a TTY or `NO_COLOR` is set.

## Usage
Source it, then run:
```bash
./your_script.sh
````

## Output fields

* VM header: `VMID NAME STATUS`
* NIC lines: `netX <model> bridge=<bridge> vlan=<tag|vid|->`

```
```
