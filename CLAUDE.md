# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a collection of shell scripts for managing Proxmox VE environments and Linux system administration tasks. The scripts are organized as standalone utilities with accompanying `.md` documentation files.

## Script Architecture

### Documentation Pattern
Each `.sh` script has a corresponding `.md` file with the same name that documents:
- Requirements and dependencies
- Usage examples
- Configuration notes

When modifying scripts, update the corresponding `.md` file to reflect changes.

### Common Script Categories

1. **Proxmox VM Management**
   - VM cloning, startup policies, network configuration
   - Drive offload/reload operations (for backup access)
   - VM identity reset and Tailscale re-registration

2. **NVIDIA GPU Control**
   - Fan speed control scripts (`onfan*.sh`, `offfan.sh`, `maxfan.sh`, `game_fan.sh`)
   - Power limit management (`lim_power.sh`, `lim_power_low.sh`, `reset_power.sh`)
   - Use `nvidia-settings` and `nvidia-smi` for GPU operations

3. **Python Environment Management**
   - `install_python.sh`: Installs multiple Python versions (3.8, 3.10, 3.11, 3.13) and Miniforge
   - Creates a custom BASE_DIR structure with `bin/`, `opt/`, `CACHE/`, `shims/`
   - Provides wrapper scripts (`py38`, `py10`, `py11`, `py13`, `python3-11`, `pip3-13`, etc.)
   - Conda wrappers: `cbase`, `cenv <envname>`
   - Supports selective version installation with `--py "3.13 3.11"` flag
   - See `SKILL.md` for usage patterns with existing installations

4. **Utility Scripts**
   - Repository size analysis (`get_repo_size.sh`)
   - Virtual environment inspection (`get_vev_size.sh`, `get_py_env_detail.sh`)
   - Proxy configuration (`proxy.sh`, `xray_set.sh`)
   - Directory tree visualization (`ltree`)

## Key Scripts

### pve_manager.sh
Interactive menu-driven Proxmox administration tool:
- References scripts in `vm_script/` subdirectory (may not exist in all deployments)
- Handles drive offload/reload for VMs 100, 102, 103
- VM 200 cloning with VLAN configuration (20=Win, 21=Danger, 30=Safe, 31=Mgmt)
- Includes helper functions `run_script()`, `pause()`

### daily_start_VM.sh
VM startup policy controller with VLAN enforcement:
- Exclusive VMs: 100, 102, 103 (checked for disk counts)
- Forbidden VMs: 104 (safety stop), 200 (template)
- Core/Infrastructure VM: 106
- VLAN groups: (10,11), (20,21), (30,31)
- Multi-phase startup: Safety → Infrastructure → VLAN Audit → Exclusive VMs → Remaining VMs

### reset_clone_VM.sh
Post-clone VM identity reset:
- Resets `/etc/machine-id` and `/var/lib/dbus/machine-id`
- Restarts network services and renews DHCP
- Wipes Tailscale state and re-registers with new hostname
- Includes Proxmox host detection safety check
- Requires `tailscale` and `systemd-machine-id-setup`

### install_python.sh
Multi-version Python installer:
- Run as normal user (not root/sudo)
- Syntax: `bash install_python.sh <BASE_DIR> [--reuse] [--skip-apt] [--skip-gpg] [--no-bashrc] [--no-sudo] [--py "3.13 3.11"]`
- Python versions: 3.8.19, 3.10.18, 3.11.13, 3.13.11 (compiled from source)
- Validates Python downloads with OpenPGP signatures (unless `--skip-gpg`)
- Installs dependencies via apt (unless `--skip-apt`)
- Selective installation: Use `--py "3.13 3.11"` to install only specific versions
- Creates version-specific entry points in `<BASE_DIR>/bin/` (py38, py10, py11, py13)
- Optionally modifies `~/.bashrc` to add BASE_DIR to PATH (unless `--no-bashrc`)

## Development Guidelines

### Testing Scripts
Most scripts require specific environments:
- Proxmox scripts: Must run on Proxmox VE host with `qm` command
- GPU scripts: Require NVIDIA drivers and `nvidia-smi`/`nvidia-settings`
- VM reset script: Must run inside a Proxmox VM guest

Test in appropriate environments or use dry-run modes where available.

### Script Conventions
- Use `set -euo pipefail` for robust error handling
- Include `trap` for better error diagnostics (see `install_python.sh:16`)
- Validate user input before destructive operations
- Check for required dependencies with `command -v` or `have()` helper
- Use clear confirmation prompts for dangerous operations
- Include usage functions for parameter documentation

### VLAN Configuration
When working with VM network scripts, valid VLAN tags are:
- 10, 11: Grouped together (switching allowed)
- 20, 21: Grouped together (20=Win, 21=Danger)
- 30, 31: Grouped together (30=Safe, 31=Mgmt)

### Proxmox VM IDs
Common VM ID conventions in these scripts:
- 100, 102, 103: Exclusive VMs (Windows/Passthrough/Ubuntu)
- 104: Safety stop VM (must never be running)
- 106: Core infrastructure VM
- 107: Deny VM (hidden)
- 200: Template VM for cloning
- 201+: Cloned VMs

## Common Commands

### Testing scripts
```bash
# Dry-run or read-only scripts
bash script_name.sh --help
bash script_name.sh  # Most scripts are interactive

# Scripts requiring specific environments
bash pve_manager.sh  # Run on Proxmox host
bash reset_clone_VM.sh <hostname>  # Run inside cloned VM
```

### Working with Python installations
```bash
# Install all Python versions (3.8, 3.10, 3.11, 3.13)
bash install_python.sh /path/to/basedir

# Install only specific versions
bash install_python.sh /path/to/basedir --py "3.13 3.11"

# Use installed versions (after adding to PATH)
py11 bash -c 'python -V'
py13 python script.py
python3-13 -m pip install package
cenv myenv python script.py
```

### GPU management
```bash
# Set fan speed
bash onfan.sh 60  # 60% fan speed
bash maxfan.sh    # 95% fan speed

# Set power limit
bash lim_power.sh 350      # 350W limit
bash lim_power_low.sh 200  # 200W limit
```

## File Organization

- Root directory contains all scripts and their `.md` documentation
- No deep directory structure
- Each script is standalone (dependencies listed in `.md` files)
- `vm_script/` subdirectory referenced by `pve_manager.sh` (may be deployment-specific)
