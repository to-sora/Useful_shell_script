# download_hf.sh

```bash
#!/bin/bash

RETRY_LIMIT=20
WAIT_TIME=60  # 60 seconds = 1 minute
COMMAND="huggingface-cli download litagin/moe-speech --repo-type dataset --local-dir /mnt/DATA7/UNCLEAN_DATASET_clone/MOE/ --max-workers 12"

for ((i=1; i<=RETRY_LIMIT; i++)); do
    echo "Attempt $i/$RETRY_LIMIT"
    
    # Execute the command
    $COMMAND
    
    echo "Waiting $WAIT_TIME seconds before the next attempt..."
    sleep $WAIT_TIME
done

echo "Completed $RETRY_LIMIT attempts."
```