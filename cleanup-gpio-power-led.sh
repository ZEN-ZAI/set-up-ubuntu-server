#!/bin/bash

set -e

echo "[🧹] Disabling systemd services..."
sudo systemctl disable --now led-blink.service || true
sudo systemctl disable --now led-on.service || true
sudo systemctl disable --now led-off.service || true
sudo systemctl disable --now gpio3-shutdown.service || true

echo "[🗑️] Removing scripts from /usr/local/bin..."
sudo rm -f /usr/local/bin/led-blink.sh
sudo rm -f /usr/local/bin/led-on.sh
sudo rm -f /usr/local/bin/led-off.sh
sudo rm -f /usr/local/bin/gpio3-shutdown.sh

echo "[🗑️] Removing systemd unit files..."
sudo rm -f /etc/systemd/system/led-blink.service
sudo rm -f /etc/systemd/system/led-on.service
sudo rm -f /etc/systemd/system/led-off.service
sudo rm -f /etc/systemd/system/gpio3-shutdown.service

echo "[🔄] Reloading systemd..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

echo "[✅] Cleanup complete!"

# Optional: self delete
# rm -- "$0"
