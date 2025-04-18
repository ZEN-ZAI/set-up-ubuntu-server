#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

#----------------------------------------
# 0. Ensure root
#----------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "❌ Please run as root (sudo $0)"
  exit 1
fi

#----------------------------------------
# Variables (override via env if you like)
#----------------------------------------
PIHOLE_PASSWORD="${PIHOLE_PASSWORD:-<PI_HOLE_PASSWORD>}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-<TOKEN>}"
TUNNEL_NAME="home-lab"
DOMAIN_NAME="<example.com>"
HOME_DIR="/home/${SUDO_USER:-root}"
PIHOLE_DIR="$HOME/pihole"

STATIC_IP="192.168.42.1/24"
DHCP_RANGE="192.168.42.10,192.168.42.100,12h"


#----------------------------------------
# 1. Update & install deps
#----------------------------------------
echo "🚀 [1] Updating & installing packages…"
apt update && apt upgrade -y
apt install -y \
  curl wget jq dpkg \
  docker-compose-plugin \
  netfilter-persistent iptables-persistent \
  dnsmasq

#----------------------------------------
# 2. Docker install
#----------------------------------------
curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh
sudo apt install docker-compose-plugin -y
sudo usermod -aG docker $USER

# 2.5 Add your user to the docker group (reminder to log out/in)
usermod -aG docker "${SUDO_USER:-$USER}"
echo "⚠️  Added $SUDO_USER to docker group. Log out and back in to apply."

#----------------------------------------
# 3. Networking: Enable IP forwarding
#----------------------------------------
echo "🛡️ [3] Enabling IP Forwarding..."
sudo sed -i 's|#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf
sudo sysctl -p

echo "📦 Installing iptables-persistent..."
sudo apt install -y netfilter-persistent iptables-persistent

# Step 4: Set static IP via netplan
echo "🖧 [4] Checking netplan config..."
NETPLAN_FILE=$(ls /etc/netplan/*.yaml | head -n 1 || true)

if [ -z "$NETPLAN_FILE" ]; then
  echo "❌ No netplan config found in /etc/netplan/"
  exit 1
fi

echo "📄 Using netplan file: $NETPLAN_FILE"
echo "💡 Please update your netplan manually to include:"
echo
echo "  ethernets:"
echo "    eth0:"
echo "      dhcp4: no"
echo "      addresses:"
echo "        - $STATIC_IP"
echo
echo "📎 After editing, apply with: sudo netplan apply"
read -rp "⏸️ Press [Enter] to continue after you've updated netplan..."

# Step 5: Disable OS dnsmasq (Pi-hole will do DHCP)
echo "🛑 [5] Disabling system dnsmasq (conflict with Pi-hole)..."
sudo systemctl disable --now dnsmasq || true

# Step 6: Deploy Pi-hole with host networking
echo "📂 [6] Deploying Pi-hole…"
mkdir -p "${HOME_DIR}/pihole"
cat > "${HOME_DIR}/pihole/docker-compose.yml" <<EOF
services:
  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    network_mode: host
    environment:
      TZ: Asia/Bangkok
    volumes:
      - ${HOME_DIR}/pihole/etc-pihole:/etc/pihole
      - ${HOME_DIR}/pihole/etc-dnsmasq.d:/etc/dnsmasq.d
    cap_add:
      - NET_ADMIN
    restart: unless-stopped
EOF
docker compose -f "${HOME_DIR}/pihole/docker-compose.yml" up -d
docker exec pihole pihole setpassword "${PIHOLE_PASSWORD}"

echo "✅ Pi-hole deployed!"
echo "📎 Access: http://192.168.42.1/admin"
echo "👉 Go to: Settings > DHCP > Enable DHCP Server"
echo "   - Range: 192.168.42.10 – 192.168.42.100"
echo "   - Gateway: 192.168.42.1"
echo "   - DNS: 192.168.42.1"
# read -rp "⏸️ Press [Enter] when you have configured DHCP in Pi-hole UI..."

# Step 7: Create smart-gateway.sh
echo "📜 [7] Creating smart-gateway.sh script..."
sudo tee /usr/local/bin/smart-gateway.sh > /dev/null <<'EOSCRIPT'
#!/bin/bash
set -euo pipefail

check_internet() {
  local iface=$1
  local success=0
  for i in {1..3}; do
    echo "[🔍] Ping test $i on $iface..."
    if ping -I "$iface" -c 1 8.8.8.8 &>/dev/null; then
      success=$((success+1))
    fi
    sleep 1
  done
  if [ "$success" -ge 2 ]; then
    echo "[✅] Internet OK via $iface ($success/3)"
    return 0
  else
    echo "[❌] No internet via $iface ($success/3)"
    return 1
  fi
}

setup_nat() {
  echo "[🔁] NAT: $1 → $2"
  iptables -t nat -F
  iptables -t nat -A POSTROUTING -o "$1" -j MASQUERADE
  sysctl -w net.ipv4.ip_forward=1
  netfilter-persistent save
}

if check_internet wlan0; then
  echo "[🚀] Using wlan0 as Internet source"
  setup_nat wlan0 eth0
elif check_internet eth0; then
  echo "[🚀] Using eth0 as Internet source"
  setup_nat eth0 wlan0
else
  echo "[🛑] No internet on wlan0 or eth0. Exiting."
  exit 1
fi

echo "[♻️] Restarting Pi-hole if needed..."
docker start pihole || docker compose -f "$HOME/pihole/docker-compose.yml" up -d pihole
EOSCRIPT

sudo chmod +x /usr/local/bin/smart-gateway.sh

# Step 8: Enable systemd service
echo "🧬 [8] Creating smart-gateway.service..."
sudo tee /etc/systemd/system/smart-gateway.service > /dev/null <<EOF
[Unit]
Description=Zen Smart Gateway Switching
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/smart-gateway.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

echo "🔁 Enabling and starting smart-gateway.service..."
sudo systemctl daemon-reexec
sudo systemctl enable --now smart-gateway.service

echo "✅ Smart Gateway Setup Complete!"

#----------------------------------------
# 9. cloudflared tunnel
#----------------------------------------
echo "☁️ [9] Installing cloudflared…"
arch=$(dpkg --print-architecture)
case "$arch" in
  arm64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb";;
  amd64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb";;
  *) echo "Unsupported arch $arch"; exit 1;;
esac
wget -qO /tmp/cloudflared.deb "$url"
dpkg -i /tmp/cloudflared.deb

if [[ -z "$TUNNEL_TOKEN" ]]; then
  echo "❓ Export TUNNEL_TOKEN and re‑run for Cloudflare Tunnel."
else
  cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
Environment="TUNNEL_TOKEN=${TUNNEL_TOKEN}"
ExecStart=/usr/bin/cloudflared tunnel run --token \$TUNNEL_TOKEN
Restart=always
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cloudflared.service
  echo "☁️ Cloudflare Tunnel started"
fi

#----------------------------------------
# 10. Homepage container
#----------------------------------------
echo "🏠 [10] Deploying homepage…"
mkdir -p "${HOME_DIR}/homepage"
cat > "${HOME_DIR}/homepage/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1.0"/><title>Zen's Homelab</title>
<style>body{font-family:sans-serif;background:#111;color:#fff;text-align:center;padding:5em;}a{color:#4FC3F7;text-decoration:none;display:block;margin:.5em 0;}.title{font-size:2em;margin-bottom:1em;}</style>
</head>
<body>
  <div class="title">🌐 Zen's Home‑lab Dashboard</div>
</body>
</html>
EOF

cat > "${HOME_DIR}/homepage/docker-compose.yml" <<EOF
services:
  homepage:
    image: halverneus/static-file-server
    container_name: homepage
    ports:
      - "8080:8080"
    volumes:
      - ./:/web
    restart: unless-stopped
EOF
docker compose -f "${HOME_DIR}/homepage/docker-compose.yml" up -d

echo "✅ All done!
• Pi‑hole: http://192.168.42.1/admin  (pass: $PIHOLE_PASSWORD)
• Homepage: http://localhost:8080 → https://$DOMAIN_NAME"