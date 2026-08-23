# Management Scripts

A collection of convenience scripts for managing Proxmox VE, Linux systems, GPU settings, development environments, downloads, and local tooling.

## Available Scripts

Each listed utility links to a matching `.md` file that explains requirements, usage, important side effects, and configuration notes. Script behavior is unchanged by this documentation update.

| Script | Description | Documentation |
|---|---|---|
| [CIVIT_Download.sh](CIVIT_Download.sh) | Download one or more Civitai model files using an API token from `CIVIT_API`. | [CIVIT_Download.sh.md](CIVIT_Download.sh.md) |
| [acl_audit.sh](acl_audit.sh) | Audit owner/group/mode and ACL data for a directory and its direct children. | [acl_audit.sh.md](acl_audit.sh.md) |
| [acl_audit_user.sh](acl_audit_user.sh) | Build per-user effective-access and default-ACL matrices for first-layer directories. | [acl_audit_user.sh.md](acl_audit_user.sh.md) |
| [build_vulkan_gpu.sh](build_vulkan_gpu.sh) | Rebuild a local `llama.cpp` checkout with Vulkan enabled and CUDA disabled. | [build_vulkan_gpu.sh.md](build_vulkan_gpu.sh.md) |
| [codex_quota.py](codex_quota.py) | Export Codex daily token usage to JSON/CSV and plot recent usage in the terminal. | [codex_quota.py.md](codex_quota.py.md) |
| [daily_start_VM.sh](daily_start_VM.sh) | Apply an interactive Proxmox VM startup policy with safety and VLAN checks. | [daily_start_VM.md](daily_start_VM.md) |
| [download_hf.sh](download_hf.sh) | Download a Hugging Face dataset with retry behavior. | [download_hf.sh.md](download_hf.sh.md) |
| [fan.sh](fan.sh) | Placeholder fan-control script that currently performs no actions. | [fan.sh.md](fan.sh.md) |
| [game_fan.sh](game_fan.sh) | Put the NVIDIA GPU fan in manual mode at 60%. | [game_fan.sh.md](game_fan.sh.md) |
| [get_boot_order.sh](get_boot_order.sh) | List Proxmox VMs and containers in configured startup order. | [get_boot_order.sh.md](get_boot_order.sh.md) |
| [get_py_env_detail.sh](get_py_env_detail.sh) | Find Python virtual environments and export package details with `pip freeze`. | [get_py_env_detail.md](get_py_env_detail.md) |
| [get_repo_size.sh](get_repo_size.sh) | Report Git repository sizes together with upstream/remote information. | [get_repo_size.sh.md](get_repo_size.sh.md) |
| [get_vev_size.sh](get_vev_size.sh) | Report disk usage for discovered Python virtual environments. | [get_vev_size.sh.md](get_vev_size.sh.md) |
| [install-codex-sqlite-tmpfs.sh](install-codex-sqlite-tmpfs.sh) | Move per-user Codex SQLite storage to private directories under `/dev/shm`. | [install-codex-sqlite-tmpfs.sh.md](install-codex-sqlite-tmpfs.sh.md) |
| [install_metube.sh](install_metube.sh) | Install Docker and deploy MeTube as a self-hosted media downloader. | [install_metube.sh.md](install_metube.sh.md) |
| [install_nvm.sh](install_nvm.sh) | Install per-user NVM and a selected Node.js version without relying on system npm. | [install_nvm.sh.md](install_nvm.sh.md) |
| [install_python.sh](install_python.sh) | Install selected Python versions and Miniforge into a custom base directory. | [install_python.md](install_python.md) |
| [install_xray_v6.sh](install_xray_v6.sh) | Interactively install Xray VLESS + REALITY with optional networking and routing features. | [install_xray_v6.sh.md](install_xray_v6.sh.md) |
| [latex-build.sh](latex-build.sh) | Compile explicit LaTeX files or automatically rebuild the newest outdated `.tex` file. | [latex-build.sh.md](latex-build.sh.md) |
| [lim_power_low.sh](lim_power_low.sh) | Apply a lower NVIDIA GPU power-limit profile (default 200 W) and clocks. | [lim_power_low.sh.md](lim_power_low.sh.md) |
| [lim_power.sh](lim_power.sh) | Apply an NVIDIA GPU power limit (default 350 W) and clock settings. | [lim_power.sh.md](lim_power.sh.md) |
| [ltree](ltree) | Print directory trees with depth limiting and optional file output. | [ltree.md](ltree.md) |
| [maxfan.sh](maxfan.sh) | Put the NVIDIA GPU fan in manual mode at 95%. | [maxfan.sh.md](maxfan.sh.md) |
| [offfan.sh](offfan.sh) | Disable manual NVIDIA GPU fan control and return to automatic mode. | [offfan.sh.md](offfan.sh.md) |
| [onfan_30.sh](onfan_30.sh) | Put the NVIDIA GPU fan in manual mode at 30%. | [onfan_30.sh.md](onfan_30.sh.md) |
| [onfan_max.sh](onfan_max.sh) | Put the NVIDIA GPU fan in manual mode at 90%. | [onfan_max.sh.md](onfan_max.sh.md) |
| [onfan.sh](onfan.sh) | Set NVIDIA GPU manual fan speed to a caller-provided percentage. | [onfan.sh.md](onfan.sh.md) |
| [proxy.sh](proxy.sh) | Export HTTP, HTTPS, and SOCKS proxy environment variables for the current shell context. | [proxy.sh.md](proxy.sh.md) |
| [pve_manager.sh](pve_manager.sh) | Provide an interactive Proxmox administration menu for drive and VM-clone workflows. | [pve_manager.md](pve_manager.md) |
| [qm_list_nic_bridges_color.sh](qm_list_nic_bridges_color.sh) | Show Proxmox VM NIC bridge and VLAN information with colorized output. | [qm_list_nic_bridges_color.md](qm_list_nic_bridges_color.md) |
| [reset_clone_VM.sh](reset_clone_VM.sh) | Reset cloned-VM identity, networking state, and Tailscale registration. | [reset_clone_VM.md](reset_clone_VM.md) |
| [reset_power.sh](reset_power.sh) | Reset NVIDIA GPU power and clock settings to the script's configured profile. | [reset_power.sh.md](reset_power.sh.md) |
| [restart_gui.sh](restart_gui.sh) | Restart the LightDM display manager. | [restart_gui.sh.md](restart_gui.sh.md) |
| [stop_ollama.sh](stop_ollama.sh) | Stop all currently running Ollama models. | [stop_ollama.sh.md](stop_ollama.sh.md) |
| [syslink_builder.sh](syslink_builder.sh) | Create a mirrored symlink tree from multiple configured source directories. | [syslink_builder.sh.md](syslink_builder.sh.md) |
| [xray_set.sh](xray_set.sh) | Export HTTP, HTTPS, and SOCKS proxy variables for an Xray proxy endpoint. | [xray_set.sh.md](xray_set.sh.md) |
