#!/bin/bash

# Get the list of running models from `ollama ps` command
models=$(ollama ps)

# Loop through each model and extract the ID
for model in $models; do
    # Extract the ID from the line
    id=$(echo "$model" | awk '{print $2}')

    # Stop the model using `ollama stop` command
    ollama stop $id
done
