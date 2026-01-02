Reset a cloned Linux VM identity + re-register Tailscale with a new hostname.

## Requirements
- Linux with systemd
- tailscale + tailscaled installed
- Run as root or a sudo user

## Warning
Network may restart and SSH can drop. Prefer VM console.
Safety guard: refuses to run if the system hostname matches `Proxmox` (intended Proxmox host).  
If your Proxmox host uses a different hostname, update `PROXMOX_HOSTNAME` in the script.

## Usage
```bash
chmod +x reset_clone_VM.sh
./reset_clone_VM.sh <tailscale-hostname>
````

Example:

```bash
./reset_clone_VM.sh standard-201
```

Hostname rule: 1–63 chars, only letters/digits/hyphen.
Type `I UNDERSTAND` when prompted.

```



```
