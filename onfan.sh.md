# onfan.sh

```bash
export DISPLAY=:0
export XAUTHORITY=/var/run/lightdm/root/:0
export fanspeed=${1:-70}
sudo nvidia-settings -a "[gpu:0]/GPUFanControlState=1" -a "[fan:0]/GPUTargetFanSpeed=$fanspeed"
```