# lim_power_low.sh

Set a lower GPU power limit with a default of 200W, then apply clock limits.

## Requirements
- `nvidia-smi`
- `sudo` privileges

## Usage
```bash
./lim_power_low.sh [power_watts]
```

## Notes
- Intended valid range: 150 to 400 watts.
- Sets persistence mode on and applies graphics clock limits.
