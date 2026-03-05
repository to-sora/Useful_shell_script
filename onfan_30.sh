#!/bin/bash

# 1. 自動獲取正確的 Xauthority
XAUTH=$(ps aux | grep -m 1 "Xorg" | grep -oP "(?<=-auth )\S+")
[ -z "$XAUTH" ] && XAUTH=$(ps aux | grep -m 1 "Xwayland" | grep -oP "(?<=-auth )\S+")

# 2. 測試並尋找有效的 DISPLAY (0 或 1)
VALID_DISPLAY=""
for d in :0 :1; do
    if sudo DISPLAY=$d XAUTHORITY=$XAUTH nvidia-settings -q Screens &>/dev/null; then
        VALID_DISPLAY=$d
        break
    fi
done

if [ -z "$VALID_DISPLAY" ]; then
    echo "錯誤: 無法在 :0 或 :1 找到有效的 X Server"
    exit 1
fi

sudo DISPLAY=$VALID_DISPLAY XAUTHORITY=$XAUTH nvidia-settings   -a "[gpu:0]/GPUFanControlState=1"   -a "[fan:0]/GPUTargetFanSpeed=30"
echo "已將 Fan 0 設定為 30% (Display: $VALID_DISPLAY)"
