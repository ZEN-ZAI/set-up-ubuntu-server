#!/bin/bash
set -euo pipefail

echo "🚀 [1] Updating system..."
sudo apt update -y && sudo apt upgrade -y

echo "🐳 [2] Installing Docker + Compose..."
curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh
sudo apt install -y docker-compose-plugin
sudo usermod -aG docker $USER

echo "🛡️ [3] Enable IP forwarding + install netfilter..."
sudo sed -i 's/#\?net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sudo sysctl -p
sudo apt install -y netfilter-persistent iptables-persistent

echo "📡 [4] Installing Pi-hole (Docker)..."
mkdir -p ~/zen-homelab/pihole
cat > ~/zen-homelab/pihole/docker-compose.yml <<EOF
version: "3"

services:
  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    restart: unless-stopped
    environment:
      TZ: "Asia/Bangkok"
      WEBPASSWORD: "admin"
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "80:80"
    volumes:
      - ./etc-pihole:/etc/pihole
      - ./etc-dnsmasq.d:/etc/dnsmasq.d
EOF

docker compose -f ~/zen-homelab/pihole/docker-compose.yml up -d

echo "🌐 [5] Setup NAT & DHCP rules..."
sudo iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
sudo netfilter-persistent save

echo "☁️ [6] Installing cloudflared..."
arch=$(uname -m)
arch=${arch/armv7l/arm} && arch=${arch/aarch64/arm64}
wget -O cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
sudo dpkg -i cloudflared.deb || sudo apt -f install -y

echo "☁️ [7] Cloudflare Tunnel setup..."
if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
  echo "🛠️  Using provided token for tunnel..."
  cloudflared service install "$CLOUDFLARE_TUNNEL_TOKEN"
else
  echo "🔐 Token not found. Please login manually."
  cloudflared tunnel login
fi

echo "✅ All done! Rebooting in 5 seconds..."
sleep 5
sudo reboot
