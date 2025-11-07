#!/bin/bash
# Uninstall script for peppymeterbasic (Bookworm)
# Cleans up systemd service and temporary files safely.

set -euo pipefail

SERVICE_FILE="/etc/systemd/system/peppymeterbasic.service"
DROPIN_DIR="/etc/systemd/system/peppymeterbasic.service.d"
FIFO_PATH="/tmp/basic_peppy_meter_fifo"

echo "Stopping peppymeterbasic service..."
sudo systemctl stop peppymeterbasic.service >/dev/null 2>&1 || true
sudo systemctl disable peppymeterbasic.service >/dev/null 2>&1 || true

echo "Removing systemd unit and drop-ins..."
sudo rm -f "${SERVICE_FILE}" || true
if [ -d "${DROPIN_DIR}" ]; then
  sudo rm -rf "${DROPIN_DIR}" || true
fi

echo "Cleaning temporary FIFO..."
if [ -p "${FIFO_PATH}" ]; then
  sudo rm -f "${FIFO_PATH}"
fi

echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Removing Python cache..."
sudo rm -rf /data/plugins/user_interface/peppymeterbasic/BasicPeppyMeter/__pycache__ || true

echo "Uninstall complete."
echo "pluginuninstallend"
