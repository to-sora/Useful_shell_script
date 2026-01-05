# lim_power.sh

Set a GPU power limit with a default of 350W, then apply clock limits.

## Requirements
- `nvidia-smi`
- `sudo` privileges

## Usage
```bash
./lim_power.sh [power_watts]
```

## Notes
- Valid range: 150 to 400 watts.
- Sets persistence mode on and applies graphics clock limits.
