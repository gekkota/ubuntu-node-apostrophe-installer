#!/bin/bash
# Script to copy configure.sh to a remote server, set it executable, and run it.
# It prompts for the server IP address, username (default: ubuntu), and a PEM number.
# The PEM number is used to construct the PEM file path.
#
# NOTE: Adjust the default PEM path as needed.

# Prompt for server IP address
read -p "Enter the server IP address: " SERVER_IP

# Prompt for server username with default "ubuntu"
read -p "Enter the server username (default: ubuntu): " SERVER_USER
if [ -z "$SERVER_USER" ]; then
    SERVER_USER="ubuntu"
fi

# Prompt for PEM file number (if empty, use default)
read -p "Enter the PEM number (default PEM: ~/www/threekey/LightsailDefaultKey-eu-west-3.pem): " PEM_NO
# Remove any leading '#' if the user accidentally includes it.
PEM_NO=$(echo "$PEM_NO" | sed 's/^#//')

if [ -z "$PEM_NO" ]; then
    PEM_PATH="~/www/threekey/LightsailDefaultKey-eu-west-3.pem"
else
    PEM_PATH="~/www/threekey/LightsailDefaultKey-eu-west-${PEM_NO}.pem"
fi

# Expand the tilde to the full home directory path
PEM_PATH=$(eval echo "$PEM_PATH")

# Check if configure.sh exists in the current directory
if [ ! -f "configure.sh" ]; then
    echo "Error: configure.sh not found in the current directory."
    exit 1
fi

echo "Copying configure.sh to ${SERVER_USER}@${SERVER_IP}..."
echo "PEM PATH: $PEM_PATH"

# Copy the file using the PEM file for authentication
scp -i "$PEM_PATH" configure.sh "${SERVER_USER}@${SERVER_IP}:~/"

echo "Setting configure.sh executable and running it on ${SERVER_IP}..."
ssh -i "$PEM_PATH" "${SERVER_USER}@${SERVER_IP}" "chmod +x ~/configure.sh && sudo ~/configure.sh"