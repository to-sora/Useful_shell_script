#reset_clone_VM.sh 
#!/usr/bin/env bash
set -Eeuo pipefail
# changed if needed
PROXMOX_HOSTNAME="Proxmox"

usage() {
  echo "Usage: $0 <tailscale-hostname>"
  echo "Example: $0 standard-201"
}

TS_HOSTNAME="${1:-}"
if [[ -z "${TS_HOSTNAME}" ]]; then
  usage
  exit 64
fi

# Basic validation to avoid accidental injection / invalid hostnames
if [[ ! "${TS_HOSTNAME}" =~ ^[A-Za-z0-9-]{1,63}$ ]]; then
  echo "ERROR: Invalid tailscale-hostname: '${TS_HOSTNAME}'"
  echo "Allowed: 1-63 chars of letters, digits, hyphen."
  exit 65
fi

CURRENT_HOST="$(hostnamectl --static 2>/dev/null || hostname || true)"
if [[ "${CURRENT_HOST}" == "${PROXMOX_HOSTNAME}" ]]; then
  echo "WARNING: Detected hostname '${CURRENT_HOST}' (Proxmox host)."
  echo "Refusing to run to prevent damaging the Proxmox host."
  exit 3
fi

cat <<EOF
WARNING: This script will:
  1) Reset machine-id (/etc/machine-id + /var/lib/dbus/machine-id)
  2) Restart network services and attempt DHCP renew on default interface
  3) Stop tailscaled, logout, DELETE /var/lib/tailscale (wipes node state)
  4) Start tailscaled and run: tailscale up --hostname='${TS_HOSTNAME}'

Current system hostname: ${CURRENT_HOST}
Target Tailscale hostname: ${TS_HOSTNAME}
EOF

read -r -p "Type 'I UNDERSTAND' to continue: " CONFIRM
if [[ "${CONFIRM}" != "I UNDERSTAND" ]]; then
  echo "Aborted."
  exit 1
fi

# Reset machine-id + renew DHCP/network (original logic preserved)
sudo bash -Eeuo pipefail -c 'trap "echo FAIL: line $LINENO; exit 1" ERR; dev="$(ip -4 route show default | sed -n '\''s/.* dev \([^ ]*\).*/\1/p'\'' | head -n1)"; [ -n "$dev" ]; [ -x /usr/bin/systemd-machine-id-setup ] || { echo "systemd-machine-id-setup missing"; exit 2; }; rm -f /etc/machine-id /var/lib/dbus/machine-id; systemd-machine-id-setup >/dev/null; ln -sf /etc/machine-id /var/lib/dbus/machine-id; systemctl is-active --quiet systemd-networkd && systemctl restart systemd-networkd || true; systemctl is-active --quiet NetworkManager && systemctl restart NetworkManager || true; command -v networkctl >/dev/null 2>&1 && networkctl renew "$dev" >/dev/null 2>&1 || true; command -v nmcli >/dev/null 2>&1 && nmcli dev disconnect "$dev" >/dev/null 2>&1 || true; command -v nmcli >/dev/null 2>&1 && nmcli dev connect "$dev" >/dev/null 2>&1 || true; sleep 1; ip4="$(ip -4 -o addr show dev "$dev" | sed -n '\''s/.* inet \([^ ]*\).*/\1/p'\'' | head -n1)"; echo "OK: machine-id reset, DHCP renewed, $dev=$ip4"'

# Reset Tailscale state + bring up with required hostname arg
sudo systemctl stop tailscaled
sudo tailscale logout || true
sudo rm -rf /var/lib/tailscale
sudo systemctl start tailscaled
sudo tailscale up --hostname="${TS_HOSTNAME}"

