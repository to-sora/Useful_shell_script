DEFAULT_POWER=350
MAX_POWER=400
# Check if the first argument is provided and is a valid number
if [[ $1 =~ ^[0-9]+$ ]] && [ $1 -le $MAX_POWER ] && [ $1 -ge 150 ]; then
    POWER_LIMIT=$1
else
    POWER_LIMIT=$DEFAULT_POWER
fi
echo $POWER_LIMIT
# Set the power limit to either the provided argument or the default
sudo nvidia-smi -pm 1

sudo nvidia-smi -pl $POWER_LIMIT
sudo nvidia-smi -lgc 100,2000
