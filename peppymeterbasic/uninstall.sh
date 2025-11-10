#!/bin/bash
set -euo pipefail

SERVICE="peppymeterbasic.service"

sudo systemctl stop "$SERVICE" 2>/dev/null || true
sudo systemctl disable "$SERVICE" 2>/dev/null || true
sudo rm -f "/etc/systemd/system/$SERVICE"
sudo systemctl daemon-reload

sudo rm -rf /data/plugins/user_interface/peppymeterbasic
sudo rm -rf /data/configuration/user_interface/peppymeterbasic
