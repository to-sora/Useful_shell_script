#!/usr/bin/env bash
set -euo pipefail

# Debian/Ubuntu administration tools; package names remain visible for review.
packages=(
    ca-certificates curl wget openssh-client rsync
    git jq vim-tiny nano less tmux htop tree file
    zip unzip tar xz-utils lsof procps psmisc
    iproute2 iputils-ping dnsutils mtr-tiny traceroute tcpdump netcat-openbsd socat
    gnupg python3 python3-pip python3-venv build-essential shellcheck
)

(( $# <= 1 )) || { printf 'Expected at most one argument.\n' >&2; exit 2; }
case ${1:-install} in
    --list) printf '%s\n' "${packages[@]}"; exit 0 ;;
    --dry-run) mode=preview ;;
    install) mode=install ;;
    *) printf 'Usage: %s [--list|--dry-run]\n' "$0" >&2; exit 2 ;;
esac
command -v apt-get >/dev/null || { printf 'apt-get is required (Debian/Ubuntu).\n' >&2; exit 1; }
if [[ $mode == preview ]]; then
    exec apt-get --simulate install --no-install-recommends "${packages[@]}"
fi
(( EUID == 0 )) || { printf 'Run as root.\n' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get -o APT::Update::Error-Mode=any update
apt-get install -y --no-install-recommends "${packages[@]}"
printf 'Tool installation completed.\n'
