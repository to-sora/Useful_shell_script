# reset_power.sh

Reset GPU power and clock settings to a predefined profile.

## Requirements
- `nvidia-smi`
- `sudo` privileges

## Usage
```bash
./reset_power.sh
```

## Notes
- Sets power limit to 400W.
- Disables persistence mode.
- Sets graphics clock range to 300-2400 MHz.
