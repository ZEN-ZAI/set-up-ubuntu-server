#!/bin/bash

chip=$(gpiodetect | head -n1 | awk '{print $1}')
echo "📟 Using GPIO chip: $chip"
echo "⚠️  Skipping GPIO 0–3 (I2C/shutdown), 14–15 (UART console)"

# GPIOs to skip
SKIP_LIST=(0 1 2 3 14 15)

for gpio in {0..27}; do
  if [[ " ${SKIP_LIST[@]} " =~ " $gpio " ]]; then
    echo "⏭️  Skipping GPIO $gpio"
    continue
  fi

  echo "🔌 Testing GPIO $gpio → OFF"
  gpioset "$chip" "$gpio"=0
  sleep 1

  echo "💡 Testing GPIO $gpio → ON"
  gpioset "$chip" "$gpio"=1
  sleep 1
done

echo "✅ Done testing safe GPIOs 4–13, 16–27"