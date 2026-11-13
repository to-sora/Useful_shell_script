#!/usr/bin/env bash
# WireGuard IPv4 server setup; client generator is deliberately UNCHANGED.
# Put this file beside generate_client.sh (or wg-add-user.sh), then run:
#   sudo bash ./wireguard-setup.sh
# Run the unchanged client FROM THAT SAME DIRECTORY so it finds .env:
#   cd /absolute/path/to/scripts && sudo bash ./generate_client.sh 7
# Use a NEW, unused client ID from 2..254. The old client generator overwrites
# keys on repeat IDs; this server-only update cannot repair that client bug.
# Its substring duplicate check also remains unchanged: verify that the exact
# new peer was added (for example, an existing .70 can cause .7 to be skipped).
# Existing wg0.conf, peers and keys are never overwritten or silently reloaded.
# No UFW enable/reset/default-policy changes. Keep VPS console access available.
# IPv4 only. Cloud firewall/security-group UDP access must be configured separately.

set -Eeuo pipefail
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

valid_ipv4() {
    local value=$1 octet
    local -a parts
    [[ $value =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a parts <<< "$value"
    for octet in "${parts[@]}"; do
        [[ $octet == 0 || $octet != 0* ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

valid_prefix() {
    local first=${1%%.*}
    valid_ipv4 "$1.1" || return 1
    (( 10#$first > 0 && 10#$first < 224 && 10#$first != 127 ))
}

valid_port() {
    [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 ))
}

valid_endpoint() {
    local label
    local -a labels
    valid_ipv4 "$1" && return 0
    [[ ${#1} -le 253 && $1 == *.* && $1 != *[!0-9.]* ]] && return 1
    [[ ${#1} -le 253 && $1 == *.* && $1 != .* && $1 != *. ]] || return 1
    IFS=. read -r -a labels <<< "$1"
    for label in "${labels[@]}"; do
        [[ $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 1
    done
}

ask() {
    local variable=$1 prompt=$2 default=$3 answer
    read -r -p "$prompt [$default]: " answer || die 'Input ended; no automatic answer assumed.'
    printf -v "$variable" '%s' "${answer:-$default}"
}

confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer || return 1
    [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]]
}

# Read data only: never source an existing .env as root.
env_value() {
    local key=$1 file=$2
    [[ -f $file ]] || return 0
    awk -v key="$key" '
        /^[[:space:]]*#/ {next}
        { line=$0; sub(/\r$/, "", line)
          if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
            sub(/^[^=]*=[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            if (line ~ /^"[^"]*"$/) line=substr(line,2,length(line)-2)
            value=line
          }
        }
        END {print value}
    ' "$file"
}

# Existing original-style wg0 configs have one of each Interface value.
# Unsupported/ambiguous configs stop safely rather than being rewritten.
interface_value() {
    local key=$1 file=$2
    awk -v key="$key" '
        { line=$0; sub(/#.*/, "", line); gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
          if (line ~ /^\[/) {inside=(line=="[Interface]"); next}
          if (inside && line ~ "^" key "[[:space:]]*=") {
            sub(/^[^=]*=[[:space:]]*/, "", line); value=line; count++
          }
        }
        END {if(count!=1) exit 2; print value}
    ' "$file"
}

write_new_secret() {
    local path=$1 value=$2
    [[ ! -e $path && ! -L $path ]] || die "Refusing to overwrite $path"
    (set -o noclobber; printf '%s\n' "$value" > "$path")
    chmod 600 "$path"
}

main() {
    [[ $EUID -eq 0 ]] || die 'Run with sudo or as root.'
    [[ $# -eq 0 ]] || die 'No command-line arguments supported; use the interactive prompts.'
    trap 'rc=$?; printf "ERROR: Setup stopped at line %s (status %s). Earlier changes may remain; no success is claimed.\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

    local SCRIPT_DIR ENV_FILE WG_DIR=/etc/wireguard WG_CONFIG_PATH
    # Resolve BEFORE any directory change. All later writes use absolute paths.
    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    ENV_FILE="$SCRIPT_DIR/.env"
    WG_CONFIG_PATH="$WG_DIR/wg0.conf"
    local command_name
    for command_name in ip awk systemctl sysctl flock mktemp install cmp; do
        command -v "$command_name" >/dev/null || die "Missing prerequisite: $command_name"
    done
    [[ -d /run/systemd/system ]] || die 'This installer requires a booted systemd Linux host.'
    [[ ! -L $WG_DIR && ! -L $WG_CONFIG_PATH && ! -L $ENV_FILE ]] || die 'Refusing symlinked config/output paths.'
    [[ ! -e $ENV_FILE || -f $ENV_FILE ]] || die "$ENV_FILE is not a regular file."
    exec 9>/run/lock/wireguard-setup-wg0.lock
    flock -n 9 || die 'Another setup is running. Do not run the client generator concurrently either.'

    local existing=0 active=0 SUBNET_PREFIX WG_PORT WAN_IFACE DNS_SERVER SERVER_IP
    local SERVER_PRIV_KEY SERVER_PUB_KEY live_key live_port address old_endpoint old_dns
    local firewall_mode=preserved ufw_status temp_env env_backup

    if [[ -e $WG_CONFIG_PATH ]]; then
        [[ -f $WG_CONFIG_PATH ]] || die "$WG_CONFIG_PATH is not a regular file."
        existing=1
        command -v wg >/dev/null || die 'Existing config found, but wg is missing. Install wireguard-tools first.'
        address=$(interface_value Address "$WG_CONFIG_PATH") || die 'Existing Address is missing or ambiguous; config left unchanged.'
        [[ $address == *.1/24 ]] || die 'Existing Address is not the original prefix.1/24 format; config left unchanged.'
        SUBNET_PREFIX=${address%.1/24}
        valid_prefix "$SUBNET_PREFIX" || die 'Existing subnet is incompatible with the unchanged client generator.'
        WG_PORT=$(interface_value ListenPort "$WG_CONFIG_PATH") || die 'Existing ListenPort is missing or ambiguous.'
        valid_port "$WG_PORT" || die 'Invalid existing ListenPort.'
        SERVER_PRIV_KEY=$(interface_value PrivateKey "$WG_CONFIG_PATH") || die 'Existing PrivateKey is missing or ambiguous.'
        SERVER_PUB_KEY=$(printf '%s\n' "$SERVER_PRIV_KEY" | wg pubkey) || die 'Existing config private key is invalid.'
        printf 'Existing wg0.conf: preserving all bytes, peers, hooks, addresses and port.\n'
    else
        if ip link show dev wg0 >/dev/null 2>&1; then
            die 'wg0 already exists without wg0.conf; refusing to replace its configuration.'
        fi
        [[ ! -e /etc/sysctl.d/99-wireguard-setup.conf && ! -L /etc/sysctl.d/99-wireguard-setup.conf ]] || die 'Existing 99-wireguard-setup.conf needs manual review before a new install; nothing was changed.'
        if systemctl is-active --quiet firewalld || systemctl is-active --quiet nftables; then
            die 'An active firewalld/nftables service needs a site-specific firewall plan; nothing has been installed.'
        fi
        confirm 'Install WireGuard dependencies and prepare a NEW wg0 server?' || die 'Canceled.'
        if command -v apt-get >/dev/null; then
            apt-get update
            apt-get install -y wireguard-tools curl ca-certificates iptables iproute2
        elif command -v dnf >/dev/null; then
            dnf install -y wireguard-tools curl ca-certificates iptables iproute
        else
            die 'Only apt-get or dnf based systems are supported.'
        fi
        for command_name in wg wg-quick curl iptables; do
            command -v "$command_name" >/dev/null || die "Dependency installation did not provide $command_name"
        done
        WAN_IFACE=$(ip -4 route show default | awk '$1=="default" {for(i=1;i<=NF;i++) if($i=="dev" && !seen++) print $(i+1)}')
        ask WAN_IFACE 'WAN interface' "$WAN_IFACE"
        [[ $WAN_IFACE =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || die 'Invalid interface name.'
        ip link show dev "$WAN_IFACE" >/dev/null 2>&1 || die "Interface $WAN_IFACE does not exist."
        [[ $WAN_IFACE != wg0 ]] || die 'WAN interface cannot be wg0.'
        ask SUBNET_PREFIX 'VPN subnet prefix' '10.8.0'
        valid_prefix "$SUBNET_PREFIX" || die 'Invalid three-octet IPv4 subnet prefix.'
        ask WG_PORT 'WireGuard UDP port' '51820'
        valid_port "$WG_PORT" || die 'UDP port must be 1..65535.'
        firewall_mode=iptables
        if command -v ufw >/dev/null; then
            ufw_status=$(LC_ALL=C ufw status) || die 'Cannot determine UFW state; refusing to select a different firewall mode.'
            if grep -qx 'Status: active' <<< "$ufw_status"; then
                firewall_mode=ufw
            elif ! grep -qx 'Status: inactive' <<< "$ufw_status"; then
                die 'Unrecognized UFW status; inspect the firewall manually.'
            fi
        fi
    fi

    # Verify both historical key files against the authoritative config, if any.
    local key_path
    for key_path in "$WG_DIR/server_private.key" "$WG_DIR/server_public.key"; do
        [[ ! -L $key_path && ( ! -e $key_path || -f $key_path ) ]] || die "Unsafe key path: $key_path"
    done
    if (( existing )); then
        if [[ -f $WG_DIR/server_private.key ]]; then
            [[ $(cat "$WG_DIR/server_private.key") == "$SERVER_PRIV_KEY" ]] || die 'server_private.key disagrees with wg0.conf; neither was changed.'
        fi
    elif [[ -f $WG_DIR/server_private.key ]]; then
        SERVER_PRIV_KEY=$(cat "$WG_DIR/server_private.key")
        SERVER_PUB_KEY=$(printf '%s\n' "$SERVER_PRIV_KEY" | wg pubkey) || die 'Existing private key is invalid.'
    elif [[ -e $WG_DIR/server_public.key ]]; then
        die 'Public key exists without a private key/config; refusing to rotate server identity.'
    else
        SERVER_PRIV_KEY=$(wg genkey)
        SERVER_PUB_KEY=$(printf '%s\n' "$SERVER_PRIV_KEY" | wg pubkey)
    fi
    if [[ -f $WG_DIR/server_public.key ]]; then
        [[ $(cat "$WG_DIR/server_public.key") == "$SERVER_PUB_KEY" ]] || die 'server_public.key disagrees with the private key; no key was overwritten.'
    fi
    if (( existing )); then
        if live_key=$(wg show wg0 public-key 2>/dev/null); then
            active=1
            [[ $live_key == "$SERVER_PUB_KEY" ]] || die 'Live wg0 key differs from disk; refusing to issue a misleading .env.'
            live_port=$(wg show wg0 listen-port)
            [[ $live_port == "$WG_PORT" ]] || die 'Live wg0 port differs from disk; resolve drift separately.'
        elif ip link show dev wg0 >/dev/null 2>&1; then
            die 'An incompatible wg0 interface exists; it was not modified.'
        fi
    fi

    old_dns=$(env_value DNS_SERVER "$ENV_FILE")
    valid_ipv4 "$old_dns" || old_dns=1.1.1.1
    ask DNS_SERVER 'Client DNS IPv4 address' "$old_dns"
    valid_ipv4 "$DNS_SERVER" || die 'DNS must be a single IPv4 address.'
    old_endpoint=$(env_value SERVER_ENDPOINT_IP "$ENV_FILE")
    if ! valid_endpoint "$old_endpoint"; then
        old_endpoint=''
        if command -v curl >/dev/null; then
            local candidate url
            for url in https://api.ipify.org https://icanhazip.com; do
                if candidate=$(curl -fsS4 --proto '=https' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null); then
                    if valid_ipv4 "$candidate"; then old_endpoint=$candidate; break; fi
                fi
            done
        fi
    fi
    ask SERVER_IP 'Public server IPv4 address or DNS hostname (verify it)' "$old_endpoint"
    valid_endpoint "$SERVER_IP" || die 'Invalid IPv4 address or DNS hostname.'
    printf '\nConfig: %s\nClient environment: %s\nEndpoint: %s:%s\nFirewall mode: %s\n' "$WG_CONFIG_PATH" "$ENV_FILE" "$SERVER_IP" "$WG_PORT" "$firewall_mode"
    printf 'Run this setup from the client-script folder. The old client reads .env from its current directory.\n'
    confirm 'Write the client environment and finish the selected setup?' || die 'Canceled before writing config/keys/environment.'

    install -d -m 700 "$WG_DIR"
    [[ -f $WG_DIR/server_private.key ]] || write_new_secret "$WG_DIR/server_private.key" "$SERVER_PRIV_KEY"
    [[ -f $WG_DIR/server_public.key ]] || write_new_secret "$WG_DIR/server_public.key" "$SERVER_PUB_KEY"

    if (( ! existing )); then
        # Never truncate a pre-existing config, even if one appeared mid-install.
        (set -o noclobber; cat > "$WG_CONFIG_PATH" <<EOF
[Interface]
Address = ${SUBNET_PREFIX}.1/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV_KEY}

PostUp = iptables -w -t nat -C POSTROUTING -s ${SUBNET_PREFIX}.0/24 -o ${WAN_IFACE} -m comment --comment wg0-setup -j MASQUERADE || iptables -w -t nat -A POSTROUTING -s ${SUBNET_PREFIX}.0/24 -o ${WAN_IFACE} -m comment --comment wg0-setup -j MASQUERADE
PostDown = iptables -w -t nat -D POSTROUTING -s ${SUBNET_PREFIX}.0/24 -o ${WAN_IFACE} -m comment --comment wg0-setup -j MASQUERADE || true
EOF
        )
        chmod 600 "$WG_CONFIG_PATH"
        if [[ $firewall_mode == ufw ]]; then
            # UFW is already active. Add only the VPN's rules; leave SSH and
            # global forwarding policy alone. These UFW rules persist on down.
            ufw allow "$WG_PORT/udp" comment 'WireGuard wg0'
            ufw route allow in on wg0 out on "$WAN_IFACE" from "$SUBNET_PREFIX.0/24"
        else
            # Never enable an inactive UFW. Scoped rules do not change policies
            # or existing SSH rules. Reassess these if enabling UFW later.
            cat >> "$WG_CONFIG_PATH" <<EOF
PostUp = iptables -w -C INPUT -p udp --dport ${WG_PORT} -m comment --comment wg0-setup -j ACCEPT || iptables -w -I INPUT -p udp --dport ${WG_PORT} -m comment --comment wg0-setup -j ACCEPT
PostUp = iptables -w -C FORWARD -i %i -o ${WAN_IFACE} -s ${SUBNET_PREFIX}.0/24 -m comment --comment wg0-setup -j ACCEPT || iptables -w -I FORWARD -i %i -o ${WAN_IFACE} -s ${SUBNET_PREFIX}.0/24 -m comment --comment wg0-setup -j ACCEPT
PostUp = iptables -w -C FORWARD -i ${WAN_IFACE} -o %i -d ${SUBNET_PREFIX}.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment wg0-setup -j ACCEPT || iptables -w -I FORWARD -i ${WAN_IFACE} -o %i -d ${SUBNET_PREFIX}.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment wg0-setup -j ACCEPT
PostDown = iptables -w -D INPUT -p udp --dport ${WG_PORT} -m comment --comment wg0-setup -j ACCEPT || true
PostDown = iptables -w -D FORWARD -i %i -o ${WAN_IFACE} -s ${SUBNET_PREFIX}.0/24 -m comment --comment wg0-setup -j ACCEPT || true
PostDown = iptables -w -D FORWARD -i ${WAN_IFACE} -o %i -d ${SUBNET_PREFIX}.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment wg0-setup -j ACCEPT || true
EOF
        fi
        # Dedicated persistence file; do not edit the global sysctl.conf.
        [[ ! -e /etc/sysctl.d/99-wireguard-setup.conf && ! -L /etc/sysctl.d/99-wireguard-setup.conf ]] || die 'Existing 99-wireguard-setup.conf needs manual review; it was not overwritten.'
        write_new_secret /etc/sysctl.d/99-wireguard-setup.conf 'net.ipv4.ip_forward = 1'
        sysctl -w net.ipv4.ip_forward=1
        systemctl enable --now wg-quick@wg0
        systemctl is-active --quiet wg-quick@wg0 || die 'wg-quick service did not become active; inspect journalctl -u wg-quick@wg0.'
        wg show wg0 >/dev/null || die 'wg0 is not available after service startup.'
        active=1
    elif (( active )); then
        printf 'Existing live wg0 left running: no restart, syncconf, peer update, or firewall change.\n'
    elif confirm 'Existing wg0 is not running. Start the PRESERVED config (including its existing hooks)?'; then
        command -v wg-quick >/dev/null || die 'wg-quick is missing.'
        systemctl enable --now wg-quick@wg0
        wg show wg0 >/dev/null || die 'Existing config did not start; inspect journalctl -u wg-quick@wg0.'
        active=1
    fi

    # Atomic .env update, with an unambiguous private backup on a rerun.
    if [[ -f $ENV_FILE ]]; then
        env_backup=$(mktemp "$SCRIPT_DIR/.env.backup.XXXXXX")
        install -m 600 -- "$ENV_FILE" "$env_backup"
        printf 'Previous environment backed up to %s\n' "$env_backup"
    fi
    temp_env=$(mktemp "$SCRIPT_DIR/.env.new.XXXXXX")
    cat > "$temp_env" <<EOF
SUBNET_PREFIX="${SUBNET_PREFIX}"
DNS_SERVER="${DNS_SERVER}"
SERVER_PUB_KEY_PATH="${WG_DIR}/server_public.key"
SERVER_ENDPOINT_IP="${SERVER_IP}"
SERVER_PORT="${WG_PORT}"
WG_CONFIG_PATH="${WG_CONFIG_PATH}"
EOF
    chmod 600 "$temp_env"
    mv -f -- "$temp_env" "$ENV_FILE"
    unset SERVER_PRIV_KEY
    printf '\nSetup completed. .env: %s\n' "$ENV_FILE"
    if (( active )); then
        printf 'wg0 is running; an actual client handshake/Internet test has NOT been performed.\n'
    else
        warn 'wg0 was deliberately left stopped. Client connections will not work until it is started.'
    fi
    printf 'Allow UDP %s in the VPS provider firewall/NAT. This script does not manage that.\n' "$WG_PORT"
    printf 'For the unchanged client, first: cd -- %q\n' "$SCRIPT_DIR"
    warn 'Use only a NEW unused client ID 2..254. Reusing IDs can break the unchanged client generator.'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
