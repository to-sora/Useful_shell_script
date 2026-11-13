#!/usr/bin/env bash
set -euo pipefail
(( EUID == 0 )) || { printf 'Run as root.\n' >&2; exit 1; }
listing=$(systemctl list-unit-files --no-legend --no-pager ssh.service sshd.service ssh.socket sshd.socket); targets=(); while read -r unit state _; do [[ $state == alias ]] && continue; case $unit in ssh.service|sshd.service|ssh.socket|sshd.socket) targets+=("$unit");; esac; done <<< "$listing"
(( ${#targets[@]} )) || { printf 'OpenSSH systemd units required.\n' >&2; exit 1; }; systemctl disable "${targets[@]}"; systemctl stop "${targets[@]}"
