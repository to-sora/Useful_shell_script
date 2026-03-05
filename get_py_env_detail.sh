#!/bin/bash

# Find all 'activate' scripts in potential venv directories
find ~/program_self_guest/ -type f -name "activate" | while read activate_script; do
    echo "_________________________________________________________________________________"
    echo "Found venv: $(dirname $activate_script)"
    # Source the activate script to activate the venv
    source "$activate_script"
    du -sh "$(dirname $activate_script)/../"
    # Check pip version
    echo "Checking pip version..."
    pip --version

    # List installed packages
    echo "Listing installed packages..."
#    pip list

    # Save installed packages to a requirements.txt in the venv directory
    pip freeze > "$(dirname $activate_script)/../../../past/requirements.txt"

    echo "Saved requirements to $(dirname $activate_script)/../requirements.txt"

    # Deactivate the virtual environment
    deactivate
done
