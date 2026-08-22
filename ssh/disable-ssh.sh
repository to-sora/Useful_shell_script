#!/usr/bin/env bash

# Script to disable SSH access

echo "WARNING: This will disable SSH and close port 22!"
echo "You will need console access to re-enable SSH."
echo ""
read -p "Are you sure? (type 'yes' to continue): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

echo "Disabling SSH access..."

# Close SSH port in firewall
ufw delete allow 22/tcp

# Disable and stop SSH service
systemctl disable ssh
systemctl stop ssh

echo "SSH disabled successfully!"
echo "Port 22 is now closed in firewall."
echo "SSH service is stopped and disabled from boot."
