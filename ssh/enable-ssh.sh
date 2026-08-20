#!/bin/bash
# Script to enable SSH access

echo "Enabling SSH access..."

# Enable SSH service
systemctl enable ssh
systemctl start ssh

# Open SSH port in firewall
ufw allow 22/tcp

echo "SSH enabled successfully!"
echo "SSH service status:"
systemctl status ssh --no-pager -l
echo ""
echo "Firewall status:"
ufw status | grep 22
