#!/bin/bash

# Ensure script is run as root if modifying system services
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root to restart the SSH service."
  exit 1
fi

# Update and upgrade system packages
apt update && apt upgrade -y

# Set the system timezone
timedatectl set-timezone Asia/Manila

# Install required packages
apt install -y sudo unattended-upgrades curl net-tools

mkdir -p ~/.ssh

# Define the key to add
SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAABJQAAAQEAu0Wlm6peGYWk+YBAMsKQ/nPMVLe8Q/DLck8r7jORT0ouYlXv1hR2j5uzgYwzdSr1zFvCnImfgL2z0GqZvDiX3wlAjtn+mq0qnv8nCR1wZH7uEti44xTsBNiGph66Kgdora3BBe9L9GdpKwGb9F2+HXP03EkvvNfqu4IP6BOuUBkLJJH4tL9t5Pc1e92iNttrNkjMxLGc+9IRpYmFGp7TD/QeNmamLrishZ3ASHUuxwNpBdXwc5eUNuAiehzl+01sypgJ2AzkGjBt1r3qJ3nRCx56dUgICv3BILr17CCwqb6MWPLWETj9PxJpXtDIzd4ueW51O9kC5WtfBYZ7VpwlYQ== zephycube"

# Check for the key in authorized_keys
if ! grep -qF "$SSH_KEY" ~/.ssh/authorized_keys 2>/dev/null; then
  echo "$SSH_KEY" >> ~/.ssh/authorized_keys
  echo "SSH key added."
else
  echo "SSH key already exists."
fi

# Set permissions
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys

# Download and replace sshd_config
wget -q -O /etc/ssh/sshd_config "https://raw.githubusercontent.com/AeCyrexus/zephycube-scripts/refs/heads/main/sshd_config"

# Restart the SSH service
systemctl restart sshd

# Remove the script after execution
rm -- "$0"