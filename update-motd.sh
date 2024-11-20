#!/bin/bash

# Remove the LXC details script
sudo rm -f /etc/profile.d/00_lxc-details.sh

# ASCII art for MOTD
MOTD_CONTENT=$(cat <<'EOF'
  _____          _            ____      _       
 |__  /___ _ __ | |__  _   _ / ___|   _| |__   ___
   / // _ \ '_ \| '_ \| | | | |  | | | | '_ \ / _ \
  / /|  __/ |_) | | | | |_| | |__| |_| | |_) |  __/
 /____\___| .__/|_| |_|\__, |\____\__,_|_.__/ \___|
          |_|          |___/                        

The programs included with the Debian GNU/Linux system are free software;
the exact distribution terms for each program are described in the
individual files in /usr/share/doc/*/copyright.

Debian GNU/Linux comes with ABSOLUTELY NO WARRANTY, to the extent
permitted by applicable law.
EOF
)

# Write the ASCII art to /etc/motd
echo "$MOTD_CONTENT" | sudo tee /etc/motd > /dev/null

# Disable dynamic MOTD to make it persistent
sudo chmod -x /etc/update-motd.d/*

# Remove this script after execution
rm -- "$0"