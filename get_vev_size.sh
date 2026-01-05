#!/bin/bash

# Set the starting directory
SEARCH_DIR=${1:-$(pwd)} # Default to current directory if no argument provided

# Function to check if a directory is a Python virtual environment
is_venv() {
  [[ -f "$1/bin/activate" && -d "$1/lib" ]]
}

# Recursively find all virtual environments
find "$SEARCH_DIR" -type d -name "bin" | while read -r bin_dir; do
  venv_dir=$(dirname "$bin_dir")
  if is_venv "$venv_dir"; then
    venv_size=$(du -sh "$venv_dir" 2>/dev/null | awk '{print $1}')
    echo "Found virtual environment: $venv_dir (Size: $venv_size)"
  fi
done
