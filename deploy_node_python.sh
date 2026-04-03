#!/bin/bash
set -e
WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"

if [ ! -f /mnt/data/node.sh ] || [ ! -f /mnt/data/node_monitor.py ]; then
  echo "缺少 /mnt/data/node.sh 或 /mnt/data/node_monitor.py"
  exit 1
fi

if [ -f "$WORK_DIR/node.sh" ]; then
  cp "$WORK_DIR/node.sh" "$WORK_DIR/node.sh.bak.$(date +%Y%m%d%H%M%S)"
fi
if [ -f "$WORK_DIR/node_monitor.py" ]; then
  cp "$WORK_DIR/node_monitor.py" "$WORK_DIR/node_monitor.py.bak.$(date +%Y%m%d%H%M%S)"
fi

if [ -x "$WORK_DIR/node.sh" ]; then
  "$WORK_DIR/node.sh" -stop >/dev/null 2>&1 || true
fi
pkill -f "node_monitor.py run" 2>/dev/null || true
pkill -f "node.sh -cron" 2>/dev/null || true

cp /mnt/data/node.sh "$WORK_DIR/node.sh"
cp /mnt/data/node_monitor.py "$WORK_DIR/node_monitor.py"
chmod +x "$WORK_DIR/node.sh" "$WORK_DIR/node_monitor.py"

echo "已部署到 $WORK_DIR"
echo "接下来运行: /root/TrafficCop/node.sh"
