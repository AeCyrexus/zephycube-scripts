# Ensure script is run as root if modifying system services
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root to restart the SSH service."
  exit 1
fi

mkdir -p ~/.ssh

echo "ssh-rsa AAAAB3NzaC1yc2EAAAABJQAAAQEAu0Wlm6peGYWk+YBAMsKQ/nPMVLe8Q/DLck8r7jORT0ouYlXv1hR2j5uzgYwzdSr1zFvCnImfgL2z0GqZvDiX3wlAjtn+mq0qnv8nCR1wZH7uEti44xTsBNiGph66Kgdora3BBe9L9GdpKwGb9F2+HXP03EkvvNfqu4IP6BOuUBkLJJH4tL9t5Pc1e92iNttrNkjMxLGc+9IRpYmFGp7TD/QeNmamLrishZ3ASHUuxwNpBdXwc5eUNuAiehzl+01sypgJ2AzkGjBt1r3qJ3nRCx56dUgICv3BILr17CCwqb6MWPLWETj9PxJpXtDIzd4ueW51O9kC5WtfBYZ7VpwlYQ== zephycube" >> ~/.ssh/authorized_keys

chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys

wget -q -O /etc/ssh/sshd_config "https://github.com/AeCyrexus/zephycube-scripts/raw/refs/heads/main/sshd_config"

echo "Restarting SSH service..."
if systemctl restart sshd; then
  echo "SSH service restarted successfully."
else
  echo "Failed to restart SSH service. Check your configuration."
  exit 1
fi

echo "SSH setup completed successfully."