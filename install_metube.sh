#!/usr/bin/env bash
set -euo pipefail

# ---- Config (edit as needed) ----
METUBE_PORT="8081"
DOWNLOAD_DIR="/mnt/downloads/metube"
STATE_DIR="/mnt/downloads/metube/.metube"
TEMP_DIR="/mnt/downloads/metube"
COOKIE_FILE="/home/user/cookies.txt"
RUN_USER="btuser"
RUN_GROUP="btshare"
ENV_FILE="/home/user/metube.env"

# ---- Install Docker (Ubuntu) ----
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# ---- Users, dirs, permissions ----
getent group "$RUN_GROUP" >/dev/null 2>&1 || groupadd "$RUN_GROUP"
if ! id -u "$RUN_USER" >/dev/null 2>&1; then
  useradd -m -s /usr/sbin/nologin -G "$RUN_GROUP" "$RUN_USER"
fi

mkdir -p "$DOWNLOAD_DIR"
chown -R "$RUN_USER":"$RUN_GROUP" "$DOWNLOAD_DIR"
chmod -R 2775 "$DOWNLOAD_DIR"

RUN_UID="$(id -u "$RUN_USER")"
RUN_GID="$(getent group "$RUN_GROUP" | cut -d: -f3)"

# ---- MeTube env ----
cat <<ENV_EOF > "$ENV_FILE"
DOWNLOAD_DIR=/downloads/metube
STATE_DIR=/downloads/metube/.metube
TEMP_DIR=/downloads/metube
HOST=0.0.0.0
PORT=${METUBE_PORT}
UMASK=002
UID=${RUN_UID}
GID=${RUN_GID}
YTDL_OPTIONS={"cookiefile":"/cookies/cookies.txt","writesubtitles":true,"writeautomaticsub":true,"subtitleslangs":["en","zh","ja"],"subtitlesformat":"srt","ignoreerrors":true,"sleep_interval":1,"max_sleep_interval":5,"retries":5}
ENV_EOF

# ---- Run container ----
if docker ps -a --format '{{.Names}}' | grep -q '^metube$'; then
  docker rm -f metube
fi

docker run -d \
  --name metube \
  --restart unless-stopped \
  -p "${METUBE_PORT}:8081" \
  --env-file "$ENV_FILE" \
  -v /mnt/downloads:/downloads \
  -v "${COOKIE_FILE}:/cookies/cookies.txt:ro" \
  ghcr.io/alexta69/metube

cat <<MSG
MeTube installed and running.
Web UI: http://<server-ip>:${METUBE_PORT}
Downloads: ${DOWNLOAD_DIR}
MSG
