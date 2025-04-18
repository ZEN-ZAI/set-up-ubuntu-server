#!/bin/bash

set -e

echo "[🛠️] Installing gpiod..."
sudo apt update
sudo apt install -y gpiod

LED_LINE=17
BUTTON_LINE=3
BIN_DIR=/usr/local/bin
UNIT_DIR=/etc/systemd/system

echo "[⚙️] Writing scripts..."

# 1. LED Blink Script
cat <<'EOF' | sudo tee $BIN_DIR/led-blink.sh >/dev/null
#!/bin/bash
LED_LINE=17
chip=$(gpiodetect | head -n1 | awk '{print $1}')
while true; do
  gpioset "$chip" "$LED_LINE"=1
  sleep 0.1
  gpioset "$chip" "$LED_LINE"=0
  sleep 0.1
done
EOF

# 2. LED ON Script
cat <<'EOF' | sudo tee $BIN_DIR/led-on.sh >/dev/null
#!/bin/bash
LED_LINE=17
chip=$(gpiodetect | head -n1 | awk '{print $1}')
pkill -f led-blink.sh || true
gpioset "$chip" "$LED_LINE"=1
EOF

# 3. LED OFF Script
cat <<'EOF' | sudo tee $BIN_DIR/led-off.sh >/dev/null
#!/bin/bash
LED_LINE=17
chip=$(gpiodetect | head -n1 | awk '{print $1}')
gpioset "$chip" "$LED_LINE"=0
EOF

# 4. GPIO3 Shutdown Script (3-second hold version)
cat <<'EOF' | sudo tee $BIN_DIR/gpio3-shutdown.sh >/dev/null
#!/bin/bash

BUTTON_LINE=3
LED_LINE=17
CHIP=$(gpiodetect | head -n1 | awk '{print $1}')

echo "Waiting for button press and hold (3 seconds) on GPIO $BUTTON_LINE..."

while true; do
  hold_counter=0

  # รอจนปุ่มถูกกด
  while [ "$(gpioget "$CHIP" "$BUTTON_LINE" 2>/dev/null || echo "error")" = "0" ]; do
    hold_counter=$((hold_counter + 1))
    sleep 0.1

    if [ "$hold_counter" -ge 30 ]; then
      echo "Button held for 3 seconds, shutting down..."

      for i in {1..10}; do
        gpioset "$CHIP" "$LED_LINE"=1
        sleep 0.5
        gpioset "$CHIP" "$LED_LINE"=0
        sleep 0.5
      done

      shutdown -h now
      exit 0
    fi
  done

  # ปล่อยก่อนครบ 3 วิ → รีเซ็ต
  sleep 0.1
done
EOF

echo "[🔐] Making scripts executable..."
sudo chmod +x $BIN_DIR/led-blink.sh
sudo chmod +x $BIN_DIR/led-on.sh
sudo chmod +x $BIN_DIR/led-off.sh
sudo chmod +x $BIN_DIR/gpio3-shutdown.sh

echo "[📄] Writing systemd services..."

# Service: LED Blink
cat <<EOF | sudo tee $UNIT_DIR/led-blink.service >/dev/null
[Unit]
Description=Blink LED fast on boot
DefaultDependencies=no
Before=basic.target
After=local-fs.target

[Service]
ExecStart=$BIN_DIR/led-blink.sh
Type=simple
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Service: LED ON
cat <<EOF | sudo tee $UNIT_DIR/led-on.service >/dev/null
[Unit]
Description=Set LED solid ON after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN_DIR/led-on.sh

[Install]
WantedBy=multi-user.target
EOF

# Service: LED OFF
cat <<EOF | sudo tee $UNIT_DIR/led-off.service >/dev/null
[Unit]
Description=Turn OFF LED on shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=$BIN_DIR/led-off.sh

[Install]
WantedBy=halt.target reboot.target shutdown.target
EOF

# Service: GPIO3 Shutdown
cat <<EOF | sudo tee $UNIT_DIR/gpio3-shutdown.service >/dev/null
[Unit]
Description=Shutdown when GPIO3 is pressed and held
After=multi-user.target

[Service]
ExecStart=$BIN_DIR/gpio3-shutdown.sh
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "[✅] Enabling services..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable led-blink.service led-on.service led-off.service gpio3-shutdown.service

echo "[🚀] Setup complete. Reboot to activate!"
