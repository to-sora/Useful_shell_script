export DISPLAY=:0
export XAUTHORITY=/var/run/lightdm/root/:0
sudo nvidia-settings -a "[gpu:0]/GPUFanControlState=1" -a "[fan:0]/GPUTargetFanSpeed=30"
