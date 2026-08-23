# install_xray_v6.sh

Interactive root installer for Xray VLESS + REALITY with optional multi-user configuration, Nginx fallback, Cloudflare WARP routing, ad blocking, UFW, BBR, and ML-DSA-65 support.

## Requirements
- Run as `root` or with `sudo`
- Supported Linux environment with package management available (`apt`/`apt-get` or `yum` paths are handled by the script)
- Internet access for Go, Xray source/releases, routing data, and optional components
- Common tools such as `curl`, `wget`, `git`, `jq`, `qrencode`, `openssl`, and a build toolchain; the script installs required packages where supported

## Usage
```bash
sudo bash install_xray_v6.sh
```

The script is interactive. It asks for the listening port, REALITY SNI, optional Nginx/WARP/ad-block/UFW/BBR/autostart/ML-DSA features, and the number of users.

## Notes
- The default listening port is `443` and the default REALITY SNI choice is `www.microsoft.com`.
- Supports creating multiple UUID/client profiles and can detect an existing Xray installation on re-run.
- When an existing configuration is found, the script can retain existing keys/users and add more users instead of regenerating everything.
- Xray is built from source using a recent Go toolchain when the installed Xray version does not already match the latest detected release.
- Optional WARP routing includes a JP-media mode for selected services and geosite rules.
- Optional UFW and BBR settings modify host networking/firewall configuration; review the interactive summary before confirming.
- This script makes system-wide networking and service changes. Use it on a host where those changes are intended and keep a recovery path for SSH/firewall mistakes.
