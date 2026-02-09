# onfan_max.sh

Set GPU fan control to manual and set target fan speed to 90%.

## Requirements
- `nvidia-settings`
- `sudo` privileges
- X11 session available at `DISPLAY=:0`
- Xauthority at `/var/run/lightdm/root/:0`

## Usage
```bash
./onfan_max.sh
```
