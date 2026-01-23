ls /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf 2>/dev/null | \
while read f; do
  id=$(basename "$f" .conf)
  onboot=$(awk -F': ' '/^onboot:/{print $2}' "$f")
  order=$(awk -F'[=, ]+' '/^startup:/{for(i=1;i<=NF;i++)if($i=="order"){print $(i+1)}}' "$f")
  [ "$onboot" = "1" ] && echo "${order:-9999} $id"
done | sort -n | awk '{print $2}'
