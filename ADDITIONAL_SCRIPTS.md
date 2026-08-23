# Additional Script Guide

These scripts currently use inline configuration or help instead of a dedicated
manual. Review the script and replace its local paths before use. None of the
commands below are read-only unless the table explicitly says so.

| Script | Purpose | Important effects and requirements |
|---|---|---|
| `acl_audit.sh` | Audit the target directory and its direct children. | Read-only ACL inspection using `find`, `getfacl`, and `stat`; writes a debug log under `/tmp` unless another path is supplied. |
| `acl_audit_user.sh` | Build directory-by-user access and default-ACL matrices. | Read-only ACL and account inspection using `getfacl`, `getent`, and `stat`; can copy the report with `xclip`. |
| `build_vulkan_gpu.sh` | Rebuild `llama.cpp` with the Vulkan backend. | Deletes `~/llama_cpp_iGPU/build-vk`; expects a Vulkan SDK under `~/vulkan/1.4.349.0`. |
| `install-codex-sqlite-tmpfs.sh` | Put per-user Codex SQLite storage on `/dev/shm`. | Must run as root; writes `/etc/tmpfiles.d`, `/etc/profile.d`, and each eligible user's Codex config after creating a timestamped backup. Data in tmpfs does not survive reboot. |
| `install_nvm.sh` | Install a pinned NVM release and Node.js for the current user. | Downloads and runs the NVM installer, updates shell startup configuration, and can install Codex through npm. Review the downloaded installer before allowing it to run. |
| `install_xray_v6.sh` | Install and configure an Xray VLESS/REALITY server. | Root-only, interactive system installer that can change packages, firewall, routing, services, and network configuration. Use only after reviewing every selected option and keeping an out-of-band recovery session open. |
| `latex-build.sh` | Compile supplied TeX files or the newest outdated configured file. | Requires `pdflatex`; default search directories are hard-coded near the top of the script and PDF opening is WSL-oriented. |
| `re_scan_quota.sh` | Rebuild filesystem quota data. | Root-only and disruptive: temporarily disables quotas, runs `quotacheck`, and enables quotas again after two explicit confirmations. |
| `update_scripts.sh` | Regenerate the NVIDIA fan-control helper scripts. | Overwrites `maxfan.sh`, `onfan.sh`, `onfan_30.sh`, and `offfan.sh`, then marks every top-level `.sh` executable. Commit or back up local changes first. |

## General Safety

1. Read the target script and check its paths, device IDs, users, ports, and service names.
2. Run audit commands without `sudo` where possible. Use a separate terminal for disruptive storage or network changes.
3. Keep generated logs free of credentials before sharing them.
4. Review `git diff` after any script that rewrites files.
