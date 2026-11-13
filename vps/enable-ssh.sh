#!/usr/bin/env bash
set -euo pipefail
(( EUID == 0 )) || { printf 'Run as root.\n' >&2; exit 1; }
listing=$(systemctl list-unit-files --no-legend --no-pager ssh.service sshd.service ssh.socket sshd.socket); services=(); sockets=(); while read -r unit state _; do [[ $state == alias ]] && continue; case $unit in ssh.service|sshd.service) services+=("$unit");; ssh.socket|sshd.socket) sockets+=("$unit");; esac; done <<< "$listing"
(( ${#services[@]} == 1 && ${#sockets[@]} <= 1 )) || { printf 'Expected one OpenSSH service and up to one socket.\n' >&2; exit 1; }; target=${services[0]}; if (( ${#sockets[@]} )) && { systemctl is-active --quiet "${sockets[0]}" || ! systemctl is-active --quiet "$target"; }; then target=${sockets[0]}; fi; systemctl enable --now "$target"
