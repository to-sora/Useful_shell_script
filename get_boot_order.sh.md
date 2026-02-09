# get_boot_order.sh

List Proxmox VMs and containers in startup order.

## Requirements
- Run on Proxmox VE host
- Read access to `/etc/pve/qemu-server/` and `/etc/pve/lxc/`

## Usage
```bash
./get_boot_order.sh
```

## Notes
- Only shows VMs/containers with `onboot: 1` in their configuration.
- Sorts by `startup: order=N` value (lowest first).
- VMs without explicit order are treated as order 9999.
- Output is one VM/container ID per line in boot sequence.
