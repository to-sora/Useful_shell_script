# Management Scripts

A collection of convenience scripts for managing Proxmox VE and Linux environments.

## Available Scripts

Each script has a matching `.md` file with requirements and usage examples.

| Script | Description | Documentation |
|---|---|---|
| [CIVIT_Download.sh](CIVIT_Download.sh) | Download Civitai model files using an API token. | [CIVIT_Download.sh.md](CIVIT_Download.sh.md) |
| [daily_start_VM.sh](daily_start_VM.sh) | Interactive Proxmox VM startup policy helper/template. | [daily_start_VM.md](daily_start_VM.md) |
| [download_hf.sh](download_hf.sh) | Download a Hugging Face dataset with retries. | [download_hf.sh.md](download_hf.sh.md) |
| [fan.sh](fan.sh) | Placeholder script (no actions). | [fan.sh.md](fan.sh.md) |
| [game_fan.sh](game_fan.sh) | Set GPU fan manual mode to 60%. | [game_fan.sh.md](game_fan.sh.md) |
| [get_boot_order.sh](get_boot_order.sh) | List Proxmox VMs and containers in startup order. | [get_boot_order.sh.md](get_boot_order.sh.md) |
| [get_py_env_detail.sh](get_py_env_detail.sh) | Scan for Python venvs and export `pip freeze` output. | [get_py_env_detail.md](get_py_env_detail.md) |
| [get_repo_size.sh](get_repo_size.sh) | Report Git repo sizes and upstream info. | [get_repo_size.sh.md](get_repo_size.sh.md) |
| [get_vev_size.sh](get_vev_size.sh) | Report sizes of Python virtual environments. | [get_vev_size.sh.md](get_vev_size.sh.md) |
| [install_python.sh](install_python.sh) | Install multiple Python versions and Miniforge on Ubuntu. | [install_python.md](install_python.md) |
| [install_metube.sh](install_metube.sh) | Install Docker and deploy MeTube (YouTube downloader). | [install_metube.sh.md](install_metube.sh.md) |
| [lim_power_low.sh](lim_power_low.sh) | Set a lower GPU power limit (default 200W) and apply clocks. | [lim_power_low.sh.md](lim_power_low.sh.md) |
| [lim_power.sh](lim_power.sh) | Set a GPU power limit (default 350W) and apply clocks. | [lim_power.sh.md](lim_power.sh.md) |
| [ltree](ltree) | Print directory trees with depth limits and optional output. | [ltree.md](ltree.md) |
| [maxfan.sh](maxfan.sh) | Set GPU fan manual mode to 95%. | [maxfan.sh.md](maxfan.sh.md) |
| [offfan.sh](offfan.sh) | Disable manual GPU fan control (auto mode). | [offfan.sh.md](offfan.sh.md) |
| [onfan_30.sh](onfan_30.sh) | Set GPU fan manual mode to 30%. | [onfan_30.sh.md](onfan_30.sh.md) |
| [onfan_max.sh](onfan_max.sh) | Set GPU fan manual mode to 90%. | [onfan_max.sh.md](onfan_max.sh.md) |
| [onfan.sh](onfan.sh) | Set GPU fan manual mode to a provided value. | [onfan.sh.md](onfan.sh.md) |
| [proxy.sh](proxy.sh) | Set HTTP/HTTPS/SOCKS proxy environment variables. | [proxy.sh.md](proxy.sh.md) |
| [pve_manager.sh](pve_manager.sh) | Interactive Proxmox admin menu (drive offload/reload, clone). | [pve_manager.md](pve_manager.md) |
| [qm_list_nic_bridges_color.sh](qm_list_nic_bridges_color.sh) | List Proxmox VMs with NIC bridge/VLAN info (color). | [qm_list_nic_bridges_color.md](qm_list_nic_bridges_color.md) |
| [reset_clone_VM.sh](reset_clone_VM.sh) | Reset a cloned VM identity and re-register Tailscale. | [reset_clone_VM.md](reset_clone_VM.md) |
| [reset_power.sh](reset_power.sh) | Reset GPU power and clock settings to a profile. | [reset_power.sh.md](reset_power.sh.md) |
| [restart_gui.sh](restart_gui.sh) | Restart the LightDM display manager. | [restart_gui.sh.md](restart_gui.sh.md) |
| [stop_ollama.sh](stop_ollama.sh) | Stop all running Ollama models. | [stop_ollama.sh.md](stop_ollama.sh.md) |
| [syslink_builder.sh](syslink_builder.sh) | Create symlinks mirroring files from multiple source directories. | [syslink_builder.sh.md](syslink_builder.sh.md) |
| [xray_set.sh](xray_set.sh) | Set HTTP/HTTPS/SOCKS proxy variables for xray. | [xray_set.sh.md](xray_set.sh.md) |
