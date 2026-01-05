# offfan.sh

Disable manual GPU fan control (return control to driver/automatic).

## Requirements
- `nvidia-settings`
- `sudo` privileges
- X11 session available at `DISPLAY=:0`
- Xauthority at `/var/run/lightdm/root/:0`

## Usage
```bash
./offfan.sh
```
