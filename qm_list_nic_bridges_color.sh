qm_list_nic_bridges_color() {
  # --- colour control ---
  local use_color=1
  if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
    use_color=0
  fi

  local RST BOLD DIM
  local CYAN GREEN RED YELLOW BLUE MAGENTA WHITE
  if [ "$use_color" -eq 1 ]; then
    RST=$'\e[0m'
    BOLD=$'\e[1m'
    DIM=$'\e[2m'
    WHITE=$'\e[37m'
    CYAN=$'\e[36m'
    GREEN=$'\e[32m'
    RED=$'\e[31m'
    YELLOW=$'\e[33m'
    BLUE=$'\e[34m'
    MAGENTA=$'\e[35m'
  else
    RST=""; BOLD=""; DIM=""
    WHITE=""; CYAN=""; GREEN=""; RED=""; YELLOW=""; BLUE=""; MAGENTA=""
  fi

  # --- helpers ---
  _trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"   # ltrim
    s="${s%"${s##*[![:space:]]}"}"   # rtrim
    printf "%s" "$s"
  }

  # Header
  printf "%s%s%-6s %-24s %-10s%s\n" "$BOLD" "$WHITE" "VMID" "NAME" "STATUS" "$RST"

  qm list | awk 'NR>1{print $1, $2, $3}' | while read -r vmid name status; do
    local stc="$WHITE"
    case "$status" in
      running) stc="$GREEN" ;;
      stopped) stc="$RED" ;;
      *)       stc="$YELLOW" ;;
    esac

    printf "%s%-6s%s %-24s %s%-10s%s\n" \
      "$CYAN" "$vmid" "$RST" \
      "$name" \
      "$stc" "$status" "$RST"

    # Parse NICs from qm config (pure bash)
    qm config "$vmid" 2>/dev/null | while IFS= read -r line; do
      [[ "$line" =~ ^net[0-9]+: ]] || continue

      local net rest model br vlan
      net="${line%%:*}"
      rest="$(_trim "${line#*:}")"

      # split by comma
      local IFS=,
      local -a parts
      read -r -a parts <<< "$rest"
      unset IFS

      model="-"; br="-"; vlan="-"

      # model is first key before '=' (e.g. virtio=MAC -> virtio)
      if [ "${#parts[@]}" -ge 1 ]; then
        local first="$(_trim "${parts[0]}")"
        model="${first%%=*}"
      fi

      # read key=value items
      local p key val
      for p in "${parts[@]}"; do
        p="$(_trim "$p")"
        key="${p%%=*}"
        val="${p#*=}"
        case "$key" in
          bridge) br="$val" ;;
          tag)    vlan="$val" ;;   # Proxmox VLAN tag
          vid)    vlan="$val" ;;   # (some configs use vid)
        esac
      done

      printf "  %s%-6s%s %-8s %sbridge=%s%-12s%s %svlan=%s%-6s%s\n" \
        "$MAGENTA" "$net" "$RST" \
        "$model" \
        "$DIM" "$WHITE" "$br" "$RST" \
        "$DIM" "$YELLOW" "$vlan" "$RST"
    done

    echo
  done
}
qm_list_nic_bridges_color
