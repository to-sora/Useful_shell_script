#!/bin/bash
set -euo pipefail
# Usage: ./wg-add-user.sh <LAST_OCTET>
# Example: ./wg-add-user.sh 7  (Creates user with IP 10.8.0.7)

# 1. Load Environment Variables
if [ -f .env ]; then
    source .env
else
    echo "Error: .env file not found."
    exit 1
fi

# 2. Validate Input
if [[ ! ${1:-} =~ ^[1-9][0-9]{0,2}$ ]] || (( 10#$1 < 2 || 10#$1 > 254 )); then
    echo "Usage: $0 <LAST_OCTET>"
    echo "Example: $0 7"
    exit 1
fi

USER_ID=$1
USER_IP="${SUBNET_PREFIX}.${USER_ID}"
CLIENT_NAME="user${USER_ID}"
PRIV_KEY_FILE="${CLIENT_NAME}_private.key"
PUB_KEY_FILE="${CLIENT_NAME}_public.key"
CONF_FILE="${CLIENT_NAME}.conf"

# 3. Read Server Public Key
if [ -f "$SERVER_PUB_KEY_PATH" ]; then
    SERVER_PUB_KEY=$(cat "$SERVER_PUB_KEY_PATH")
else
    echo "Error: Server public key file not found at $SERVER_PUB_KEY_PATH"
    exit 1
fi

echo "Generating configuration for $CLIENT_NAME ($USER_IP)..."

# 4. Generate Keys
wg genkey | tee $PRIV_KEY_FILE | wg pubkey > $PUB_KEY_FILE
USER_PRIV_KEY=$(cat $PRIV_KEY_FILE)
USER_PUB_KEY=$(cat $PUB_KEY_FILE)

# 5. Create Client Config File
cat > $CONF_FILE <<EOF
[Interface]
PrivateKey = $USER_PRIV_KEY
Address = $USER_IP/32
DNS = $DNS_SERVER

[Peer]
PublicKey = $SERVER_PUB_KEY
Endpoint = $SERVER_ENDPOINT_IP:$SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

echo "Created client config: $CONF_FILE"

# 6. Update Server Config
# Check if peer already exists to avoid duplicates
temp_config=$(mktemp "${WG_CONFIG_PATH}.XXXXXX")
trap 'rm -f -- "$temp_config"' EXIT
awk -v ip="$USER_IP/32" 'BEGIN { RS="\\[Peer\\]"; FS="\n"; ORS="" } NR==1 { print; next } { for (i=1; i<=NF; i++) { line=$i; sub(/#.*/, "", line); gsub(/[[:space:]]/, "", line); if (line=="AllowedIPs=" ip) next } printf "[Peer]%s", $0 }' "$WG_CONFIG_PATH" > "$temp_config"
cat >> "$temp_config" <<EOF

[Peer]
# $CLIENT_NAME
PublicKey = $USER_PUB_KEY
AllowedIPs = $USER_IP/32
EOF
mv -- "$temp_config" "$WG_CONFIG_PATH"
echo "Updated server config: $WG_CONFIG_PATH"

# 7. Apply Changes
# Use syncconf to reload without disrupting current connections
WG_STRIPPED=$(wg-quick strip "$WG_CONFIG_PATH")
wg syncconf wg0 /dev/stdin <<< "$WG_STRIPPED"
echo "WireGuard configuration reloaded. Done."
