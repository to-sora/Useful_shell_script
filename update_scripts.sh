#!/bin/bash

# 定義核心邏輯：自動偵測 XAUTH 並測試 DISPLAY 0 與 1
CORE_LOGIC='
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
'

# 更新 maxfan.sh
echo "#!/bin/bash
$CORE_LOGIC
sudo DISPLAY=\$VALID_DISPLAY XAUTHORITY=\$XAUTH nvidia-settings \
  -a \"[gpu:0]/GPUFanControlState=1\" \
  -a \"[fan:0]/GPUTargetFanSpeed=95\"
echo \"已將 Fan 0 設定為 95% (Display: \$VALID_DISPLAY)\"" > maxfan.sh

# 更新 onfan.sh
echo "#!/bin/bash
fanspeed=\${1:-70}
$CORE_LOGIC
sudo DISPLAY=\$VALID_DISPLAY XAUTHORITY=\$XAUTH nvidia-settings \
  -a \"[gpu:0]/GPUFanControlState=1\" \
  -a \"[fan:0]/GPUTargetFanSpeed=\$fanspeed\"
echo \"已將 Fan 0 設定為 \$fanspeed% (Display: \$VALID_DISPLAY)\"" > onfan.sh

# 更新 onfan_30.sh
echo "#!/bin/bash
$CORE_LOGIC
sudo DISPLAY=\$VALID_DISPLAY XAUTHORITY=\$XAUTH nvidia-settings \
  -a \"[gpu:0]/GPUFanControlState=1\" \
  -a \"[fan:0]/GPUTargetFanSpeed=30\"
echo \"已將 Fan 0 設定為 30% (Display: \$VALID_DISPLAY)\"" > onfan_30.sh

# 更新 offfan.sh
echo "#!/bin/bash
$CORE_LOGIC
sudo DISPLAY=\$VALID_DISPLAY XAUTHORITY=\$XAUTH nvidia-settings \
  -a \"[gpu:0]/GPUFanControlState=0\"
echo \"已恢復自動風扇控制 (Display: \$VALID_DISPLAY)\"" > offfan.sh

chmod +x *.sh
echo "所有腳本已更新，並已處理 DISPLAY 0/1 自動切換邏輯。"
