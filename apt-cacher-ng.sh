sudo tee /usr/local/bin/apt-proxy-detect.sh > /dev/null << 'EOF' && sudo chmod +x /usr/local/bin/apt-proxy-detect.sh && echo 'Acquire::http::Proxy-Auto-Detect "/usr/local/bin/apt-proxy-detect.sh";' | sudo tee /etc/apt/apt.conf.d/00aptproxy > /dev/null
#!/bin/bash
if nc -w1 -z "10.0.0.6" 3142; then
  echo -n "http://10.0.0.6:3142"
else
  echo -n "DIRECT"
fi
EOF

# Remove the script after execution
rm -- "$0"