# onfan.sh

Set GPU fan control to manual and set target fan speed to a provided value.

## Requirements
- `nvidia-settings`
- `sudo` privileges
- X11 session available at `DISPLAY=:0`
- Xauthority at `/var/run/lightdm/root/:0`

## Usage
```bash
./onfan.sh [fan_percent]
```

## Notes
- Default fan speed is 70% when no argument is provided.
