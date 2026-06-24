#!/usr/bin/env bash
# ============================================================================
#  Xray VLESS + REALITY One-Click Installer  v5
#
#  v5 additions:
#    - Multi-user: generate N UUID/client sets, add users on re-run
#    - Nginx: print test URL + config path
#    - JP media unlock: Niconico, Pixiv, DLsite, Fanzia, Reddit, TikTok, geosite:jp
#    - IP check sites routed via WARP for verification
#  v4 re-run safety carried forward
# ============================================================================

set -uo pipefail

# ── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
banner(){ echo -e "\n${CYAN}${BOLD}$*${NC}"; }

require_var() {
    local name="$1" val="$2"
    if [[ -z "$val" ]]; then
        error "CRITICAL: $name is empty. Cannot continue. Check output above."
    fi
}

# ── Initialize every variable that might be referenced later ────────────────
XRAY_PORT=""
REALITY_SNI=""
OPT_NGINX="n"; OPT_WARP="n"; OPT_ADBLOCK="n"; OPT_UFW="y"
OPT_AUTOSTART="y"; OPT_MLDSA="n"; OPT_JP="n"; OPT_BBR="y"
NGINX_FALLBACK_PORT=""
NGINX_CONF_PATH=""
WARP_SOCKS_PORT=40000
NUM_USERS=1
declare -a UUIDS=()
PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
MLDSA_SEED=""; MLDSA_VERIFY=""
SERVER_IP=""
XRAY_DIR="/usr/local/bin"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_LOG_DIR="/var/log/xray"
XRAY_DAT_DIR="/usr/local/share/xray"
CLIENT_DIR="${XRAY_CONF_DIR}/clients"
XRAY_VER=""

# ── Root check ──────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run as root:  sudo bash $0"

# ── OS detection ────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID,,}"
else
    error "Cannot detect OS."
fi

# ── Detect existing installation ────────────────────────────────────────────
EXISTING_INSTALL=false
if [[ -x "${XRAY_DIR}/xray" && -f "${XRAY_CONF_DIR}/config.json" ]]; then
    EXISTING_INSTALL=true
fi

# ============================================================================
#  Interactive Options
# ============================================================================
banner "============================================================
   Xray VLESS + REALITY  One-Click Installer  v5
   Multi-User | Source Build | UFW | SNI | Post-Quantum
============================================================"

if $EXISTING_INSTALL; then
    echo ""
    warn "Existing Xray installation detected."
    EXISTING_VER=$("${XRAY_DIR}/xray" version 2>/dev/null | head -1 || true)
    [[ -n "$EXISTING_VER" ]] && info "Current: $EXISTING_VER"
    echo ""
fi

read -rp "$(echo -e "${CYAN}[1/7]${NC} Listening port [default: 443]: ")" INPUT_PORT
XRAY_PORT="${INPUT_PORT:-443}"
if ! [[ "$XRAY_PORT" =~ ^[0-9]+$ ]] || (( XRAY_PORT < 1 || XRAY_PORT > 65535 )); then
    error "Invalid port: $XRAY_PORT"
fi

# ── SNI Selection ───────────────────────────────────────────────────────────
banner "[2/7] Select REALITY SNI target domain.

  Requirements (from Xray official docs):
    - Support TLS 1.3 + H2
    - NOT behind shared CDN (CloudFlare/Akamai)
    - URL not redirected
    - Ideal: same ASN as your server, OCSP stapling
    - For ML-DSA-65: RSA cert, cert chain > 3500 bytes"
echo ""
echo "   1)  www.microsoft.com          2)  www.samsung.com"
echo "   3)  www.mozilla.org            4)  www.logitech.com"
echo "   5)  dl.google.com              6)  www.asus.com"
echo "   7)  www.nvidia.com             8)  gateway.icloud.com"
echo "   9)  www.ups.com               10)  www.amd.com"
echo "  11)  Custom domain"
echo ""

declare -A SNI_MAP=([1]="www.microsoft.com" [2]="www.samsung.com" [3]="www.mozilla.org"
    [4]="www.logitech.com" [5]="dl.google.com" [6]="www.asus.com" [7]="www.nvidia.com"
    [8]="gateway.icloud.com" [9]="www.ups.com" [10]="www.amd.com")

read -rp "$(echo -e "${CYAN}Select [1-11, default 1]: ${NC}")" SNI_CHOICE
SNI_CHOICE="${SNI_CHOICE:-1}"
if [[ "$SNI_CHOICE" == "11" ]]; then
    read -rp "Enter custom SNI domain: " REALITY_SNI
    [[ -z "$REALITY_SNI" ]] && error "SNI cannot be empty."
elif [[ -n "${SNI_MAP[$SNI_CHOICE]+x}" ]]; then
    REALITY_SNI="${SNI_MAP[$SNI_CHOICE]}"
else
    REALITY_SNI="www.microsoft.com"
fi
info "Selected SNI: $REALITY_SNI"

read -rp "$(echo -e "${CYAN}[3/7]${NC} Nginx hello-world fallback? (y/N): ")" OPT_NGINX
OPT_NGINX="${OPT_NGINX,,}"; [[ "$OPT_NGINX" != "y" ]] && OPT_NGINX="n"
read -rp "$(echo -e "${CYAN}[4/7]${NC} Cloudflare WARP media unlock? (y/N): ")" OPT_WARP
OPT_WARP="${OPT_WARP,,}"; [[ "$OPT_WARP" != "y" ]] && OPT_WARP="n"

# JP media unlock (requires WARP)
if [[ "$OPT_WARP" == "y" ]]; then
    read -rp "$(echo -e "${CYAN}[4a]${NC}  JP media unlock via WARP? (Pixiv,Niconico,DLsite,Fanzia,Reddit,TikTok,geosite:jp) (y/N): ")" OPT_JP
    OPT_JP="${OPT_JP,,}"; [[ "$OPT_JP" != "y" ]] && OPT_JP="n"
fi

read -rp "$(echo -e "${CYAN}[5/7]${NC} Ad-blocking routing rules? (y/N): ")" OPT_ADBLOCK
OPT_ADBLOCK="${OPT_ADBLOCK,,}"; [[ "$OPT_ADBLOCK" != "y" ]] && OPT_ADBLOCK="n"
read -rp "$(echo -e "${CYAN}[6/7]${NC} Configure UFW firewall? (Y/n): ")" OPT_UFW
OPT_UFW="${OPT_UFW,,}"; [[ "$OPT_UFW" == "n" ]] || OPT_UFW="y"
read -rp "$(echo -e "${CYAN}[7/7]${NC} Auto-start on boot? (Y/n): ")" OPT_AUTOSTART
OPT_AUTOSTART="${OPT_AUTOSTART,,}"; [[ "$OPT_AUTOSTART" == "n" ]] || OPT_AUTOSTART="y"
read -rp "$(echo -e "${CYAN}[BBR]${NC} Enable BBR congestion control? (Y/n) — may trigger QoS on cheap shared VPS: ")" OPT_BBR
OPT_BBR="${OPT_BBR,,}"; [[ "$OPT_BBR" == "n" ]] || OPT_BBR="y"
read -rp "$(echo -e "${CYAN}[PQ]${NC}  ML-DSA-65 post-quantum signature? (y/N): ")" OPT_MLDSA
OPT_MLDSA="${OPT_MLDSA,,}"; [[ "$OPT_MLDSA" != "y" ]] && OPT_MLDSA="n"

# ── Multi-user ──────────────────────────────────────────────────────────────
read -rp "$(echo -e "${CYAN}[Users]${NC} Number of user accounts to create [default: 1]: ")" INPUT_USERS
NUM_USERS="${INPUT_USERS:-1}"
if ! [[ "$NUM_USERS" =~ ^[0-9]+$ ]] || (( NUM_USERS < 1 || NUM_USERS > 50 )); then
    warn "Invalid user count, defaulting to 1."
    NUM_USERS=1
fi

# ── Re-run: offer to keep existing keys + users ───────────────────────────
REUSE_KEYS=false
EXISTING_UUIDS=()
if $EXISTING_INSTALL; then
    # Extract ALL existing UUIDs from server config
    while IFS= read -r uid; do
        [[ -n "$uid" ]] && EXISTING_UUIDS+=("$uid")
    done < <(grep -oP '"id"\s*:\s*"\K[^"]+' "${XRAY_CONF_DIR}/config.json" 2>/dev/null || true)

    OLD_PRIVKEY=$(grep -oP '"privateKey"\s*:\s*"\K[^"]+' "${XRAY_CONF_DIR}/config.json" 2>/dev/null | head -1 || true)
    OLD_SHORTID=$(grep -oP '"shortIds"\s*:\s*\["\K[^"]+' "${XRAY_CONF_DIR}/config.json" 2>/dev/null | head -1 || true)

    if [[ ${#EXISTING_UUIDS[@]} -gt 0 && -n "$OLD_PRIVKEY" && -n "$OLD_SHORTID" ]]; then
        echo ""
        info "Found ${#EXISTING_UUIDS[@]} existing user(s) in config:"
        for i in "${!EXISTING_UUIDS[@]}"; do
            info "  User $((i+1)): ${EXISTING_UUIDS[$i]}"
        done
        info "  PrivateKey: ${OLD_PRIVKEY:0:20}..."
        info "  ShortID   : $OLD_SHORTID"
        echo ""
        read -rp "$(echo -e "${YELLOW}Keep existing keys & users? (Y/n)${NC} — N regenerates everything: ")" KEEP_KEYS
        KEEP_KEYS="${KEEP_KEYS,,}"
        if [[ "$KEEP_KEYS" != "n" ]]; then
            REUSE_KEYS=true
            # Ask if adding more users
            read -rp "$(echo -e "${CYAN}Add more users on top of existing ${#EXISTING_UUIDS[@]}? [0 = no extra]: ${NC}")" EXTRA_USERS
            EXTRA_USERS="${EXTRA_USERS:-0}"
            [[ ! "$EXTRA_USERS" =~ ^[0-9]+$ ]] && EXTRA_USERS=0
            NUM_USERS=$(( ${#EXISTING_UUIDS[@]} + EXTRA_USERS ))
            info "Total users after update: $NUM_USERS (${#EXISTING_UUIDS[@]} existing + ${EXTRA_USERS} new)"
        else
            info "Will generate fresh keys and $NUM_USERS new user(s)."
        fi
    fi
fi

echo ""
info "Summary: port=$XRAY_PORT sni=$REALITY_SNI nginx=$OPT_NGINX warp=$OPT_WARP jp=$OPT_JP adblock=$OPT_ADBLOCK ufw=$OPT_UFW bbr=$OPT_BBR autostart=$OPT_AUTOSTART mldsa=$OPT_MLDSA users=$NUM_USERS reuse_keys=$REUSE_KEYS"
read -rp "Proceed? (Y/n): " CONFIRM
[[ "${CONFIRM,,}" == "n" ]] && exit 0

# ============================================================================
#  Step 1: Dependencies
# ============================================================================
banner "[Step 1/9] Dependencies..."
case "$OS_ID" in
    ubuntu|debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq curl wget git jq qrencode openssl coreutils \
            build-essential ca-certificates lsb-release >/dev/null 2>&1
        ;;
    centos|rhel|fedora|rocky|almalinux)
        yum install -y -q curl wget git jq qrencode openssl coreutils \
            gcc make ca-certificates >/dev/null 2>&1
        ;;
    *)
        apt-get update -qq
        apt-get install -y -qq curl wget git jq qrencode openssl coreutils \
            build-essential ca-certificates >/dev/null 2>&1
        ;;
esac
info "Dependencies OK."

# ============================================================================
#  Step 2: Install Go + Build Xray from source
# ============================================================================
banner "[Step 2/9] Go + Xray source build..."
mkdir -p "$XRAY_CONF_DIR" "$XRAY_LOG_DIR" "$XRAY_DAT_DIR" "$CLIENT_DIR"

# ── Pre-add Go to PATH (for re-run detection) ──────────────────────────────
[[ -d /usr/local/go/bin ]] && export PATH="/usr/local/go/bin:/root/go/bin:$PATH"
export GOPATH="/root/go"

# ── Install Go (idempotent) ────────────────────────────────────────────────
GO_REQUIRED_MINOR=23
need_go=true

if command -v go &>/dev/null; then
    CUR=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+' || true)
    if [[ -n "$CUR" ]]; then
        CUR_MINOR=$(echo "$CUR" | cut -d. -f2)
        if (( CUR_MINOR >= GO_REQUIRED_MINOR )); then
            info "Go $CUR already installed — skipping."
            need_go=false
        fi
    fi
fi

if $need_go; then
    GO_VER=$(curl -fsSL 'https://go.dev/dl/?mode=json' | jq -r '.[0].version' || true)
    [[ -z "$GO_VER" || "$GO_VER" == "null" ]] && error "Cannot determine latest Go version."
    info "Installing $GO_VER..."

    case "$(uname -m)" in
        x86_64)  GO_ARCH="amd64" ;;
        aarch64) GO_ARCH="arm64" ;;
        armv7l)  GO_ARCH="armv6l" ;;
        *)       error "Unsupported arch: $(uname -m)" ;;
    esac

    rm -rf /usr/local/go
    wget -q --show-progress -O /tmp/go.tar.gz "https://go.dev/dl/${GO_VER}.linux-${GO_ARCH}.tar.gz"
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm -f /tmp/go.tar.gz
    export PATH="/usr/local/go/bin:/root/go/bin:$PATH"
fi
info "Go: $(go version)"

# ── Build Xray (skip if same version) ──────────────────────────────────────
XRAY_TAG=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name' || true)
require_var "XRAY_TAG" "$XRAY_TAG"

SKIP_BUILD=false
if [[ -x "${XRAY_DIR}/xray" ]]; then
    INSTALLED_VER=$("${XRAY_DIR}/xray" version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    REMOTE_VER=$(echo "$XRAY_TAG" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || true)
    if [[ -n "$INSTALLED_VER" && "$INSTALLED_VER" == "$REMOTE_VER" ]]; then
        info "Xray $INSTALLED_VER already matches latest $XRAY_TAG — skipping build."
        SKIP_BUILD=true
    fi
fi

if ! $SKIP_BUILD; then
    info "Building Xray $XRAY_TAG from source..."

    # *** CRITICAL: stop running xray before replacing binary ***
    if systemctl is-active --quiet xray 2>/dev/null; then
        info "Stopping running xray service before binary replacement..."
        systemctl stop xray 2>/dev/null || true
        sleep 1
    fi

    BUILD_DIR="/tmp/xray-build-$$"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"

    git clone --depth 1 --branch "$XRAY_TAG" https://github.com/XTLS/Xray-core.git 2>&1 | tail -3
    cd Xray-core

    go mod download
    CGO_ENABLED=0 go build -o xray -trimpath -buildvcs=false \
        -gcflags="all=-l=4" \
        -ldflags="-X github.com/xtls/xray-core/core.build=${XRAY_TAG} -s -w -buildid=" \
        ./main 2>&1 | tail -5

    [[ ! -f xray ]] && error "Build failed: xray binary not produced."
    cp xray "$XRAY_DIR/xray"
    chmod +x "$XRAY_DIR/xray"
    cd / && rm -rf "$BUILD_DIR"
fi

XRAY_VER=$("$XRAY_DIR/xray" version | head -1 || true)
require_var "XRAY_VER" "$XRAY_VER"
info "Xray: $XRAY_VER"

# ── Geo data ────────────────────────────────────────────────────────────────
info "Downloading geoip.dat & geosite.dat..."
wget -q -O "$XRAY_DAT_DIR/geoip.dat"   "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"   || warn "geoip.dat download failed"
wget -q -O "$XRAY_DAT_DIR/geosite.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" || warn "geosite.dat download failed"
ln -sf "$XRAY_DAT_DIR/geoip.dat"   "$XRAY_DIR/geoip.dat"   2>/dev/null || true
ln -sf "$XRAY_DAT_DIR/geosite.dat" "$XRAY_DIR/geosite.dat" 2>/dev/null || true

# ============================================================================
#  Step 3: Verify SNI
# ============================================================================
banner "[Step 3/9] Verifying SNI: $REALITY_SNI ..."

TLS_PING_OUTPUT=$("$XRAY_DIR/xray" tls ping "$REALITY_SNI" 2>&1 || true)
echo "$TLS_PING_OUTPUT"

SNI_WARNINGS=""

if echo "$TLS_PING_OUTPUT" | grep -qi "TLS 1.3"; then
    info "[PASS] TLS 1.3"
elif echo "$TLS_PING_OUTPUT" | grep -qi "TLS 1.2"; then
    warn "[FAIL] Only TLS 1.2 — REALITY requires TLS 1.3"
    SNI_WARNINGS+="TLS1.2_only "
fi

if [[ "$OPT_MLDSA" == "y" ]]; then
    PQ_LINE=$(echo "$TLS_PING_OUTPUT" | grep -i "Post-Quantum" || true)
    if echo "$PQ_LINE" | grep -qi "true"; then
        info "[PASS] X25519MLKEM768"
    else
        warn "[WARN] X25519MLKEM768 not supported by target"
        SNI_WARNINGS+="no_PQ "
    fi

    CERT_LEN=$(echo "$TLS_PING_OUTPUT" | grep -i "total length" | grep -oP '\d{3,}' | head -1 || true)
    if [[ -n "$CERT_LEN" ]] && (( CERT_LEN >= 3500 )); then
        info "[PASS] Cert chain $CERT_LEN >= 3500"
    elif [[ -n "$CERT_LEN" ]]; then
        warn "[WARN] Cert chain $CERT_LEN < 3500"
    fi

    CERT_ALGO=$(echo "$TLS_PING_OUTPUT" | grep -i "publicKey algorithm" || true)
    if echo "$CERT_ALGO" | grep -qi "RSA"; then
        info "[PASS] RSA cert"
    elif echo "$CERT_ALGO" | grep -qi "ECDSA"; then
        warn "[WARN] ECDSA cert — ML-DSA-65 prefers RSA"
    fi
fi

[[ -n "$SNI_WARNINGS" ]] && warn "SNI warnings: $SNI_WARNINGS"

# ============================================================================
#  Step 4: Cryptographic Material  *** CRITICAL SECTION ***
# ============================================================================
banner "[Step 4/9] Cryptographic material..."

if $REUSE_KEYS; then
    # ── Reuse existing keys from config ─────────────────────────────────────
    PRIVATE_KEY="$OLD_PRIVKEY"
    SHORT_ID="$OLD_SHORTID"

    # Copy existing UUIDs
    for uid in "${EXISTING_UUIDS[@]}"; do
        UUIDS+=("$uid")
    done
    # Generate additional UUIDs if requested
    EXTRA_COUNT=$(( NUM_USERS - ${#EXISTING_UUIDS[@]} ))
    for (( i=0; i<EXTRA_COUNT; i++ )); do
        NEW_UUID=$("$XRAY_DIR/xray" uuid 2>&1 || true)
        require_var "NEW_UUID[$i]" "$NEW_UUID"
        UUIDS+=("$NEW_UUID")
        info "New User $((${#EXISTING_UUIDS[@]} + i + 1)) UUID: $NEW_UUID"
    done

    # Derive public key from private key
    X25519_DERIVE=$("$XRAY_DIR/xray" x25519 -i "$PRIVATE_KEY" 2>&1 || true)
    # NEW format: "Password: xxx" / OLD format: "Public key: xxx"
    PUBLIC_KEY=$(echo "$X25519_DERIVE" | awk '/^Password:/{print $2}' || true)
    [[ -z "$PUBLIC_KEY" ]] && PUBLIC_KEY=$(echo "$X25519_DERIVE" | awk '/^Public key:/{print $3}' || true)
    [[ -z "$PUBLIC_KEY" ]] && PUBLIC_KEY=$(echo "$X25519_DERIVE" | grep -iE "public|Password" | awk '{print $NF}' || true)
    require_var "PUBLIC_KEY (derived)" "$PUBLIC_KEY"

    # Reuse ML-DSA-65 seed if present
    if [[ "$OPT_MLDSA" == "y" ]]; then
        OLD_MLDSA_SEED=$(grep -oP '"mldsa65Seed"\s*:\s*"\K[^"]+' "${XRAY_CONF_DIR}/config.json" 2>/dev/null || true)
        if [[ -n "$OLD_MLDSA_SEED" ]]; then
            MLDSA_SEED="$OLD_MLDSA_SEED"
            # We need the verify key for client config; regenerate from seed if possible
            # For now just parse from existing client config
            MLDSA_VERIFY=$(grep -oP '"mldsa65Verify"\s*:\s*"\K[^"]+' "${CLIENT_DIR}/config_split_tunnel.json" 2>/dev/null || true)
            if [[ -n "$MLDSA_VERIFY" ]]; then
                info "Reusing ML-DSA-65 seed + verify key."
            else
                warn "ML-DSA-65 verify key not found in old client config — regenerating."
                MLDSA_OUTPUT=$("$XRAY_DIR/xray" mldsa65 2>&1 || true)
                MLDSA_SEED=$(echo "$MLDSA_OUTPUT" | awk '/^Seed:/{print $2}' || true)
                MLDSA_VERIFY=$(echo "$MLDSA_OUTPUT" | awk '/^Verify:/{print $2}' || true)
                [[ -z "$MLDSA_SEED" ]] && MLDSA_SEED=$(echo "$MLDSA_OUTPUT" | grep -i "seed" | awk '{print $NF}' || true)
                [[ -z "$MLDSA_VERIFY" ]] && MLDSA_VERIFY=$(echo "$MLDSA_OUTPUT" | grep -i "verify" | awk '{print $NF}' || true)
                if [[ -z "$MLDSA_SEED" || -z "$MLDSA_VERIFY" ]]; then
                    warn "ML-DSA-65 parsing failed — disabling."
                    OPT_MLDSA="n"; MLDSA_SEED=""; MLDSA_VERIFY=""
                fi
            fi
        else
            # Old config had no mldsa, generate fresh
            info "Previous install had no ML-DSA-65 — generating fresh keys..."
            MLDSA_OUTPUT=$("$XRAY_DIR/xray" mldsa65 2>&1 || true)
            MLDSA_SEED=$(echo "$MLDSA_OUTPUT" | awk '/^Seed:/{print $2}' || true)
            MLDSA_VERIFY=$(echo "$MLDSA_OUTPUT" | awk '/^Verify:/{print $2}' || true)
            [[ -z "$MLDSA_SEED" ]] && MLDSA_SEED=$(echo "$MLDSA_OUTPUT" | grep -i "seed" | awk '{print $NF}' || true)
            [[ -z "$MLDSA_VERIFY" ]] && MLDSA_VERIFY=$(echo "$MLDSA_OUTPUT" | grep -i "verify" | awk '{print $NF}' || true)
            if [[ -z "$MLDSA_SEED" || -z "$MLDSA_VERIFY" ]]; then
                warn "ML-DSA-65 parsing failed — disabling."
                OPT_MLDSA="n"; MLDSA_SEED=""; MLDSA_VERIFY=""
            fi
        fi
    fi

    info "Reused ${#EXISTING_UUIDS[@]} user(s), added $(( ${#UUIDS[@]} - ${#EXISTING_UUIDS[@]} )) new"
    info "Reused PrivateKey: ${PRIVATE_KEY:0:20}..."
    info "Derived PublicKey: ${PUBLIC_KEY:0:20}..."
    info "Reused ShortID   : $SHORT_ID"
    info "Total users      : ${#UUIDS[@]}"

else
    # ── Generate fresh keys ─────────────────────────────────────────────────
    for (( u=0; u<NUM_USERS; u++ )); do
        NEW_UUID=$("$XRAY_DIR/xray" uuid 2>&1 || true)
        require_var "UUID[user$((u+1))]" "$NEW_UUID"
        UUIDS+=("$NEW_UUID")
        info "User $((u+1)) UUID: $NEW_UUID"
    done

    X25519_OUTPUT=$("$XRAY_DIR/xray" x25519 2>&1 || true)
    info "x25519 raw output:"
    echo "$X25519_OUTPUT"

    # NEW format (v25.8.31+): "PrivateKey: xxx" / "Password: xxx" / "Hash32: xxx"
    # OLD format (< v25.8.31): "Private key: xxx" / "Public key: xxx"
    PRIVATE_KEY=$(echo "$X25519_OUTPUT" | awk '/^PrivateKey:/{print $2}' || true)
    PUBLIC_KEY=$(echo "$X25519_OUTPUT"  | awk '/^Password:/{print $2}' || true)
    # Fallback: old format
    [[ -z "$PRIVATE_KEY" ]] && PRIVATE_KEY=$(echo "$X25519_OUTPUT" | awk '/^Private key:/{print $3}' || true)
    [[ -z "$PUBLIC_KEY" ]]  && PUBLIC_KEY=$(echo "$X25519_OUTPUT"  | awk '/^Public key:/{print $3}' || true)
    # Last resort: grab last field from any matching line
    [[ -z "$PRIVATE_KEY" ]] && PRIVATE_KEY=$(echo "$X25519_OUTPUT" | grep -iE "private|PrivateKey" | awk '{print $NF}' || true)
    [[ -z "$PUBLIC_KEY" ]]  && PUBLIC_KEY=$(echo "$X25519_OUTPUT"  | grep -iE "public|Password"    | awk '{print $NF}' || true)
    require_var "PRIVATE_KEY" "$PRIVATE_KEY"
    require_var "PUBLIC_KEY"  "$PUBLIC_KEY"
    info "Private Key : $PRIVATE_KEY"
    info "Public Key  : $PUBLIC_KEY"

    SHORT_ID=$(openssl rand -hex 4 2>/dev/null || true)
    require_var "SHORT_ID" "$SHORT_ID"
    info "Short ID    : $SHORT_ID"

    # ML-DSA-65
    if [[ "$OPT_MLDSA" == "y" ]]; then
        info "Generating ML-DSA-65 keys..."
        MLDSA_OUTPUT=$("$XRAY_DIR/xray" mldsa65 2>&1 || true)
        info "mldsa65 raw output:"
        echo "$MLDSA_OUTPUT"

        # Actual source code output: "Seed: xxx\nVerify: xxx"
        MLDSA_SEED=$(echo "$MLDSA_OUTPUT" | awk '/^Seed:/{print $2}' || true)
        MLDSA_VERIFY=$(echo "$MLDSA_OUTPUT" | awk '/^Verify:/{print $2}' || true)
        # Fallback: case-insensitive last field
        [[ -z "$MLDSA_SEED" ]]   && MLDSA_SEED=$(echo "$MLDSA_OUTPUT" | grep -i "seed" | awk '{print $NF}' || true)
        [[ -z "$MLDSA_VERIFY" ]] && MLDSA_VERIFY=$(echo "$MLDSA_OUTPUT" | grep -i "verify" | awk '{print $NF}' || true)

        if [[ -n "$MLDSA_SEED" && -n "$MLDSA_VERIFY" ]]; then
            info "ML-DSA-65 Seed   : ${MLDSA_SEED:0:32}..."
            info "ML-DSA-65 Verify : ${MLDSA_VERIFY:0:32}..."
        else
            warn "ML-DSA-65 parsing failed — disabling PQ signature (install continues)."
            OPT_MLDSA="n"; MLDSA_SEED=""; MLDSA_VERIFY=""
        fi
    fi
fi

# ── Server IP ───────────────────────────────────────────────────────────────
SERVER_IP=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || true)
[[ -z "$SERVER_IP" ]] && SERVER_IP=$(curl -4 -fsSL --connect-timeout 5 icanhazip.com 2>/dev/null || true)
[[ -z "$SERVER_IP" ]] && SERVER_IP=$(curl -4 -fsSL --connect-timeout 5 api.ipify.org 2>/dev/null || true)
require_var "SERVER_IP" "$SERVER_IP"
info "Server IP   : $SERVER_IP"

# ============================================================================
#  Step 5: Nginx (optional)
# ============================================================================
if [[ "$OPT_NGINX" == "y" ]]; then
    banner "[Step 5/9] Nginx fallback..."
    if ! command -v nginx &>/dev/null; then
        case "$OS_ID" in
            ubuntu|debian) apt-get install -y -qq nginx >/dev/null 2>&1 ;;
            *)             yum install -y -q nginx >/dev/null 2>&1 ;;
        esac
    else
        info "Nginx already installed — skipping package install."
    fi
    NGINX_FALLBACK_PORT=8080
    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<'HTMLEOF'
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Welcome</title>
<style>body{display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;font-family:sans-serif;background:#667eea;color:#fff}.c{text-align:center;padding:3rem;border-radius:1rem;background:rgba(255,255,255,.1)}h1{font-size:2.5rem}</style>
</head><body><div class="c"><h1>Hello, World!</h1><p>Server OK</p></div></body></html>
HTMLEOF
    if [[ -d /etc/nginx/sites-available ]]; then
        cat > /etc/nginx/sites-available/xray-fallback <<NGEOF
server { listen 127.0.0.1:${NGINX_FALLBACK_PORT}; server_name _; root /var/www/html; index index.html; }
NGEOF
        ln -sf /etc/nginx/sites-available/xray-fallback /etc/nginx/sites-enabled/xray-fallback
        rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    else
        cat > /etc/nginx/conf.d/xray-fallback.conf <<NGEOF
server { listen 127.0.0.1:${NGINX_FALLBACK_PORT}; server_name _; root /var/www/html; index index.html; }
NGEOF
    fi
    systemctl restart nginx 2>/dev/null || true
    systemctl enable nginx >/dev/null 2>&1 || true
    info "Nginx fallback on 127.0.0.1:$NGINX_FALLBACK_PORT"

    # Print nginx config location and test info
    if [[ -d /etc/nginx/sites-available ]]; then
        NGINX_CONF_PATH="/etc/nginx/sites-available/xray-fallback"
    else
        NGINX_CONF_PATH="/etc/nginx/conf.d/xray-fallback.conf"
    fi
    info "Nginx config : $NGINX_CONF_PATH"
    info "Nginx test   : curl -s http://127.0.0.1:${NGINX_FALLBACK_PORT}/"
    info "  (Fallback only answers on 127.0.0.1 — Xray forwards non-REALITY traffic here)"
else
    info "[Step 5/9] Nginx — skipped."
fi

# ============================================================================
#  Step 6: WARP (optional)
# ============================================================================
if [[ "$OPT_WARP" == "y" ]]; then
    banner "[Step 6/9] Cloudflare WARP..."

    if ! command -v warp-cli &>/dev/null; then
        case "$OS_ID" in
            ubuntu|debian)
                curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
                    | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
                CODENAME=$(lsb_release -cs 2>/dev/null || true)
                [[ -z "$CODENAME" ]] && CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}")
                echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" \
                    | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
                apt-get update -qq
                apt-get install -y -qq cloudflare-warp >/dev/null 2>&1
                ;;
            centos|rhel|fedora|rocky|almalinux)
                rpm --import https://pkg.cloudflareclient.com/pubkey.gpg 2>/dev/null || true
                VER_ID="${VERSION_ID%%.*}"
                cat > /etc/yum.repos.d/cloudflare-warp.repo <<YUMEOF
[cloudflare-warp]
name=Cloudflare WARP
baseurl=https://pkg.cloudflareclient.com/rpm/${VER_ID}
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
YUMEOF
                yum install -y -q cloudflare-warp >/dev/null 2>&1
                ;;
            *) warn "WARP unsupported on $OS_ID"; OPT_WARP="n" ;;
        esac
    else
        info "warp-cli already installed — skipping package install."
    fi

    if [[ "$OPT_WARP" == "y" ]] && command -v warp-cli &>/dev/null; then
        systemctl start warp-svc 2>/dev/null || true
        sleep 2

        # Check if already registered (idempotent)
        WARP_STATUS=$(warp-cli status 2>&1 || true)
        if echo "$WARP_STATUS" | grep -qi "registration missing"; then
            info "Registering WARP..."
            warp-cli registration new 2>/dev/null || warp-cli register 2>/dev/null || true
        else
            info "WARP already registered — skipping registration."
        fi

        warp-cli mode proxy 2>/dev/null || true
        warp-cli proxy port ${WARP_SOCKS_PORT} 2>/dev/null || true
        warp-cli connect 2>/dev/null || true
        sleep 2
        info "WARP SOCKS5: 127.0.0.1:${WARP_SOCKS_PORT}"
    fi
else
    info "[Step 6/9] WARP — skipped."
fi

# ============================================================================
#  Step 7: Write Server Config
# ============================================================================
banner "[Step 7/9] Writing server config..."

# Build JSON fragments safely
ROUTING_RULES=""
[[ "$OPT_ADBLOCK" == "y" ]] && ROUTING_RULES+='{"domain":["geosite:category-ads-all"],"outboundTag":"block"},'
if [[ "$OPT_WARP" == "y" ]]; then
    # Global streaming unlock
    ROUTING_RULES+='{"domain":["geosite:netflix","geosite:disney","geosite:hulu","geosite:hbo","geosite:primevideo","geosite:spotify","geosite:openai","domain:nflxvideo.net","domain:netflix.com","domain:disneyplus.com","domain:spotify.com","domain:scdn.co"],"outboundTag":"warp-out"},'
    # IP check sites via WARP (so client can verify WARP IP with curl ifconfig.me)
    ROUTING_RULES+='{"domain":["domain:ifconfig.me","domain:icanhazip.com","domain:ipinfo.io","domain:api.ipify.org","domain:whatismyip.com","domain:checkip.amazonaws.com","domain:ip-api.com","domain:myip.com","domain:ip.me"],"outboundTag":"warp-out"},'
fi
if [[ "$OPT_JP" == "y" ]]; then
    # JP media unlock — verified geosite categories from v2fly/domain-list-community:
    #   geosite:niconico, geosite:pixiv, geosite:dlsite, geosite:dmm, geosite:tver, geosite:abema
    # Plus explicit domains for services without geosite entries
    # geoip:jp catches any remaining JP-IP-restricted services
    # Note: geosite:tiktok already in global WARP rules above
    ROUTING_RULES+='{"domain":["geosite:niconico","geosite:pixiv","geosite:dlsite","geosite:dmm","geosite:tver","geosite:abema","domain:fantia.jp","domain:fanzia.jp","domain:reddit.com","domain:redd.it","domain:redditstatic.com","domain:redditmedia.com","domain:booth.pm","domain:melonbooks.co.jp","domain:toranoana.jp","domain:animate.co.jp","domain:suruga-ya.com"],"outboundTag":"warp-out"},'
    ROUTING_RULES+='{"ip":["geoip:jp"],"outboundTag":"warp-out"},'
fi
ROUTING_RULES+='{"ip":["geoip:private"],"outboundTag":"block"}'

OUTBOUND_WARP=""
[[ "$OPT_WARP" == "y" ]] && OUTBOUND_WARP=',{"protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":'"${WARP_SOCKS_PORT}"'}]},"tag":"warp-out"}'

FALLBACK_JSON=""
[[ -n "$NGINX_FALLBACK_PORT" ]] && FALLBACK_JSON=',"fallbacks":[{"dest":'"${NGINX_FALLBACK_PORT}"'}]'

MLDSA_SERVER=""
[[ "$OPT_MLDSA" == "y" && -n "$MLDSA_SEED" ]] && MLDSA_SERVER=',"mldsa65Seed":"'"${MLDSA_SEED}"'"'

# ── Build multi-user clients JSON array ─────────────────────────────────────
CLIENTS_JSON=""
for i in "${!UUIDS[@]}"; do
    [[ $i -gt 0 ]] && CLIENTS_JSON+=","
    CLIENTS_JSON+='{"id":"'"${UUIDS[$i]}"'","flow":"xtls-rprx-vision"}'
done

# Backup old config if exists
[[ -f "${XRAY_CONF_DIR}/config.json" ]] && cp "${XRAY_CONF_DIR}/config.json" "${XRAY_CONF_DIR}/config.json.bak.$(date +%s)" 2>/dev/null || true

cat > "${XRAY_CONF_DIR}/config.json" <<EOF
{
  "log":{"loglevel":"warning","access":"${XRAY_LOG_DIR}/access.log","error":"${XRAY_LOG_DIR}/error.log"},
  "dns":{"servers":["https+local://1.1.1.1/dns-query","localhost"]},
  "routing":{"domainStrategy":"IPIfNonMatch","rules":[${ROUTING_RULES}]},
  "inbounds":[{
    "listen":"0.0.0.0","port":${XRAY_PORT},"protocol":"vless",
    "settings":{
      "clients":[${CLIENTS_JSON}],
      "decryption":"none"${FALLBACK_JSON}
    },
    "streamSettings":{
      "network":"raw","security":"reality",
      "realitySettings":{
        "show":false,
        "target":"${REALITY_SNI}:443","xver":0,
        "serverNames":["${REALITY_SNI}"],
        "privateKey":"${PRIVATE_KEY}",
        "shortIds":["${SHORT_ID}",""]${MLDSA_SERVER}
      }
    },
    "sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}
  }],
  "outbounds":[
    {"protocol":"freedom","tag":"direct"},
    {"protocol":"blackhole","settings":{"response":{"type":"http"}},"tag":"block"}${OUTBOUND_WARP}
  ]
}
EOF
info "Server config -> ${XRAY_CONF_DIR}/config.json"

# ============================================================================
#  Step 8: Systemd + BBR + UFW
# ============================================================================
banner "[Step 8/9] Systemd, BBR, UFW..."

cat > /etc/systemd/system/xray.service <<'SVC'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl restart xray
if [[ "$OPT_AUTOSTART" == "y" ]]; then
    systemctl enable xray >/dev/null 2>&1
fi

sleep 1
if systemctl is-active --quiet xray; then
    info "Xray is RUNNING."
else
    warn "Xray failed to start! Debug with: journalctl -u xray -n 30"
fi

# ── BBR (optional, idempotent — check before appending) ────────────────────
if [[ "$OPT_BBR" == "y" ]]; then
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        if ! grep -q 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null; then
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        fi
        sysctl -p >/dev/null 2>&1 || true
        info "BBR enabled."
    else
        info "BBR already active — skipping."
    fi
else
    info "BBR — skipped (user opted out)."
fi

# ── UFW (idempotent) ───────────────────────────────────────────────────────
if [[ "$OPT_UFW" == "y" ]]; then
    command -v ufw &>/dev/null || apt-get install -y -qq ufw >/dev/null 2>&1 || true
    if command -v ufw &>/dev/null; then
        ufw default deny incoming  >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw allow ssh >/dev/null 2>&1
        ufw allow "${XRAY_PORT}/tcp" >/dev/null 2>&1
        if [[ "$OPT_NGINX" == "y" ]]; then
            ufw allow 80/tcp  >/dev/null 2>&1
            ufw allow 443/tcp >/dev/null 2>&1
        fi
        echo "y" | ufw enable >/dev/null 2>&1
        info "UFW enabled (SSH + ${XRAY_PORT}/tcp)."
    fi
fi

# ============================================================================
#  Step 9: Client Configs + Share Link
# ============================================================================
banner "[Step 9/9] Generating client configs..."

MLDSA_CLIENT=""
MLDSA_URL=""
if [[ "$OPT_MLDSA" == "y" && -n "$MLDSA_VERIFY" ]]; then
    MLDSA_CLIENT=',"mldsa65Verify":"'"${MLDSA_VERIFY}"'"'
    MLDSA_URL="&pqv=${MLDSA_VERIFY}"
fi

# ── Generate per-user configs ───────────────────────────────────────────────
for u in "${!UUIDS[@]}"; do
    USER_NUM=$((u+1))
    USER_UUID="${UUIDS[$u]}"
    USER_DIR="${CLIENT_DIR}/user${USER_NUM}"
    mkdir -p "$USER_DIR"

    info "Generating configs for User ${USER_NUM}: ${USER_UUID}"

    # ── Split Tunnel (China Direct) ─────────────────────────────────────────
    cat > "${USER_DIR}/config_split_tunnel.json" <<EOF
{
  "log":{"loglevel":"warning"},
  "dns":{"servers":[
    {"address":"1.1.1.1","domains":["geosite:geolocation-!cn"]},
    {"address":"223.5.5.5","domains":["geosite:cn"],"expectIPs":["geoip:cn"]},
    {"address":"114.114.114.114","domains":["geosite:cn"]},
    "localhost"
  ]},
  "routing":{"domainStrategy":"IPIfNonMatch","rules":[
    {"domain":["geosite:category-ads-all"],"outboundTag":"block"},
    {"domain":["geosite:cn"],"outboundTag":"direct"},
    {"ip":["geoip:cn","geoip:private"],"outboundTag":"direct"},
    {"ip":["223.5.5.5","114.114.114.114"],"outboundTag":"direct"},
    {"domain":["geosite:geolocation-!cn"],"outboundTag":"proxy"},
    {"port":"0-65535","outboundTag":"proxy"}
  ]},
  "inbounds":[
    {"listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"udp":true},"tag":"socks-in"},
    {"listen":"127.0.0.1","port":10809,"protocol":"http","tag":"http-in"}
  ],
  "outbounds":[
    {"protocol":"vless","settings":{"vnext":[{
      "address":"${SERVER_IP}","port":${XRAY_PORT},
      "users":[{"id":"${USER_UUID}","flow":"xtls-rprx-vision","encryption":"none"}]
    }]},"streamSettings":{"network":"raw","security":"reality","realitySettings":{
      "fingerprint":"chrome","serverName":"${REALITY_SNI}",
      "password":"${PUBLIC_KEY}","shortId":"${SHORT_ID}"${MLDSA_CLIENT}
    }},"tag":"proxy"},
    {"protocol":"freedom","tag":"direct"},
    {"protocol":"blackhole","settings":{"response":{"type":"http"}},"tag":"block"}
  ]
}
EOF

    # ── Full Tunnel ─────────────────────────────────────────────────────────
    cat > "${USER_DIR}/config_full_tunnel.json" <<EOF
{
  "log":{"loglevel":"warning"},
  "dns":{"servers":["1.1.1.1","8.8.8.8"]},
  "routing":{"domainStrategy":"AsIs","rules":[
    {"domain":["geosite:category-ads-all"],"outboundTag":"block"},
    {"ip":["geoip:private"],"outboundTag":"direct"},
    {"port":"0-65535","outboundTag":"proxy"}
  ]},
  "inbounds":[
    {"listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"udp":true},"tag":"socks-in"},
    {"listen":"127.0.0.1","port":10809,"protocol":"http","tag":"http-in"}
  ],
  "outbounds":[
    {"protocol":"vless","settings":{"vnext":[{
      "address":"${SERVER_IP}","port":${XRAY_PORT},
      "users":[{"id":"${USER_UUID}","flow":"xtls-rprx-vision","encryption":"none"}]
    }]},"streamSettings":{"network":"raw","security":"reality","realitySettings":{
      "fingerprint":"chrome","serverName":"${REALITY_SNI}",
      "password":"${PUBLIC_KEY}","shortId":"${SHORT_ID}"${MLDSA_CLIENT}
    }},"tag":"proxy"},
    {"protocol":"freedom","tag":"direct"},
    {"protocol":"blackhole","settings":{"response":{"type":"http"}},"tag":"block"}
  ]
}
EOF

    # ── Share link ──────────────────────────────────────────────────────────
    VLESS_URL="vless://${USER_UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none${MLDSA_URL}#VLESS-User${USER_NUM}-${SHORT_ID}"
    echo "$VLESS_URL" > "${USER_DIR}/vless_link.txt"

    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "$VLESS_URL"
        qrencode -o "${USER_DIR}/vless_qr.png" "$VLESS_URL" 2>/dev/null || true
    fi

    info "User ${USER_NUM} configs -> ${USER_DIR}/"
done

# Also write first user's configs to CLIENT_DIR root for backward compatibility
if [[ ${#UUIDS[@]} -gt 0 ]]; then
    cp "${CLIENT_DIR}/user1/config_split_tunnel.json" "${CLIENT_DIR}/config_split_tunnel.json" 2>/dev/null || true
    cp "${CLIENT_DIR}/user1/config_full_tunnel.json"  "${CLIENT_DIR}/config_full_tunnel.json"  2>/dev/null || true
    cp "${CLIENT_DIR}/user1/vless_link.txt"           "${CLIENT_DIR}/vless_link.txt"           2>/dev/null || true
    cp "${CLIENT_DIR}/user1/vless_qr.png"             "${CLIENT_DIR}/vless_qr.png"             2>/dev/null || true
fi

# ============================================================================
#  FINAL VALIDATION
# ============================================================================
banner "Running final validation..."

FAIL=false

if [[ ! -f "${XRAY_CONF_DIR}/config.json" ]]; then
    error "Server config was NOT written!"
fi

# Validate per-user configs
for u in "${!UUIDS[@]}"; do
    USER_NUM=$((u+1))
    USER_DIR="${CLIENT_DIR}/user${USER_NUM}"
    for f in config_split_tunnel.json config_full_tunnel.json vless_link.txt; do
        if [[ ! -f "${USER_DIR}/$f" ]]; then
            warn "MISSING: ${USER_DIR}/$f"
            FAIL=true
        fi
    done
    # Check no empty critical fields
    for field in '"password":""' '"id":""' '"shortId":""' '"address":""'; do
        if grep -q "$field" "${USER_DIR}/config_split_tunnel.json" 2>/dev/null; then
            warn "User${USER_NUM} split config has empty field: $field"
            FAIL=true
        fi
    done
done

# Also validate server config
for field in '"id":""' '"privateKey":""'; do
    if grep -q "$field" "${XRAY_CONF_DIR}/config.json" 2>/dev/null; then
        warn "Server config has empty field: $field"
        FAIL=true
    fi
done

if $FAIL; then
    echo ""
    warn "=== DIAGNOSTIC DUMP ==="
    echo "UUIDS=(${UUIDS[*]})"
    echo "PUBLIC_KEY=$PUBLIC_KEY"
    echo "PRIVATE_KEY=${PRIVATE_KEY:0:20}..."
    echo "SHORT_ID=$SHORT_ID"
    echo "SERVER_IP=$SERVER_IP"
    echo "MLDSA_SEED=${MLDSA_SEED:-(empty)}"
    echo "MLDSA_VERIFY=${MLDSA_VERIFY:-(empty)}"
    echo "OPT_MLDSA=$OPT_MLDSA OPT_JP=$OPT_JP"
    echo "REUSE_KEYS=$REUSE_KEYS NUM_USERS=${#UUIDS[@]}"
    echo ""
    echo "--- Server config ---"
    cat "${XRAY_CONF_DIR}/config.json" 2>/dev/null || true
    echo ""
    echo "--- Client split config ---"
    cat "${CLIENT_DIR}/config_split_tunnel.json" 2>/dev/null || true
    echo ""
    error "Validation failed. See diagnostic dump above."
fi

info "All configs validated — no empty fields."

# ============================================================================
#  Summary
# ============================================================================
echo ""
banner "============================================================"
banner "  Installation Complete!"
banner "============================================================"
echo ""
echo -e "  ${BOLD}Xray      :${NC} $XRAY_VER"
echo -e "  ${BOLD}Server IP :${NC} $SERVER_IP"
echo -e "  ${BOLD}Port      :${NC} $XRAY_PORT"
echo -e "  ${BOLD}Users     :${NC} ${#UUIDS[@]}"
for u in "${!UUIDS[@]}"; do
    echo -e "  ${BOLD}  User $((u+1)) :${NC} ${UUIDS[$u]}"
done
echo -e "  ${BOLD}Public Key:${NC} $PUBLIC_KEY"
echo -e "  ${BOLD}Short ID  :${NC} $SHORT_ID"
echo -e "  ${BOLD}SNI       :${NC} $REALITY_SNI"
[[ "$OPT_MLDSA" == "y" ]] && echo -e "  ${BOLD}ML-DSA-65 :${NC} Enabled (seed=${MLDSA_SEED:0:16}...)"
[[ "$OPT_WARP" == "y" ]]  && echo -e "  ${BOLD}WARP      :${NC} 127.0.0.1:$WARP_SOCKS_PORT"
[[ "$OPT_JP" == "y" ]]    && echo -e "  ${BOLD}JP Media  :${NC} Enabled (Pixiv,Niconico,DLsite,Fanzia,Reddit,TikTok)"
[[ "$OPT_ADBLOCK" == "y" ]] && echo -e "  ${BOLD}AdBlock   :${NC} Enabled"
if [[ -n "$NGINX_FALLBACK_PORT" ]]; then
    echo -e "  ${BOLD}Nginx     :${NC} 127.0.0.1:$NGINX_FALLBACK_PORT"
    echo -e "  ${BOLD}Nginx cfg :${NC} ${NGINX_CONF_PATH:-/etc/nginx/sites-available/xray-fallback}"
    echo -e "  ${BOLD}Nginx test:${NC} curl -s http://127.0.0.1:${NGINX_FALLBACK_PORT}/"
fi
[[ "$OPT_UFW" == "y" ]]   && echo -e "  ${BOLD}UFW       :${NC} Enabled"
[[ "$OPT_BBR" == "y" ]]   && echo -e "  ${BOLD}BBR       :${NC} Enabled"
[[ "$OPT_BBR" == "n" ]]   && echo -e "  ${BOLD}BBR       :${NC} Disabled (CUBIC default)"
$REUSE_KEYS && echo -e "  ${BOLD}Keys      :${NC} Reused from previous install (clients unaffected)"
echo ""
echo -e "  ${BOLD}Files:${NC}"
echo "    Server config : ${XRAY_CONF_DIR}/config.json"
for u in "${!UUIDS[@]}"; do
    echo "    User $((u+1)) configs: ${CLIENT_DIR}/user$((u+1))/"
done
echo "    (User 1 also copied to ${CLIENT_DIR}/ root for backward compat)"
echo ""
echo -e "  ${BOLD}VLESS share links:${NC}"
for u in "${!UUIDS[@]}"; do
    USER_LINK=$(cat "${CLIENT_DIR}/user$((u+1))/vless_link.txt" 2>/dev/null || true)
    echo "    User $((u+1)): $USER_LINK"
done
echo ""
if [[ "$OPT_WARP" == "y" ]]; then
    echo -e "  ${BOLD}Verify WARP IP (run on client while connected):${NC}"
    echo "    curl --proxy socks5h://127.0.0.1:10808 ifconfig.me"
    echo "    curl --proxy socks5h://127.0.0.1:10808 ipinfo.io"
    echo "    (Should show Cloudflare WARP IP, not your server IP)"
    echo ""
fi
echo -e "  ${BOLD}Commands:${NC}"
echo "    systemctl {status|restart|stop} xray"
echo "    journalctl -u xray -f"
echo ""
banner "============================================================"
