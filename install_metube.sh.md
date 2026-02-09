# install_metube.sh

Install Docker and deploy MeTube (YouTube downloader) as a container.

## Requirements
- Ubuntu/Debian system
- Run as root
- Internet access to download.docker.com and ghcr.io

## What it does
1. Installs Docker CE from official repository
2. Creates user `btuser` and group `btshare` if they don't exist
3. Sets up download directory with proper permissions (2775 with setgid)
4. Configures MeTube with cookie support for authenticated downloads
5. Runs MeTube container with auto-restart policy

## Usage
```bash
sudo ./install_metube.sh
```

## Configuration
Edit the top of the script before running:
- `METUBE_PORT="8081"` - Web UI port
- `DOWNLOAD_DIR="/mnt/downloads/metube"` - Where files are saved
- `COOKIE_FILE="/home/user/cookies.txt"` - Browser cookies for authenticated sites
- `RUN_USER="btuser"` - Container user
- `RUN_GROUP="btshare"` - Container group (setgid on download dir)

## Post-install
After successful installation:
- Web UI: `http://<server-ip>:8081`
- Downloads appear in `DOWNLOAD_DIR`
- Container restarts automatically unless manually stopped

## Notes
- If a container named `metube` exists, it will be removed and recreated.
- YTDL options include subtitle download (EN/ZH/JA) and retry logic.
- The `COOKIE_FILE` must exist and contain valid cookies if needed for auth.
