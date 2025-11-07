#!/bin/bash
# Install script for peppymeterbasic (Bookworm)
# - Installs PeppyMeter app and deps
# - Sets up systemd service peppymeterbasic.service
# - Creates arch-specific symlinks for peppyalsa library
set -euo pipefail

peppymeterpath="/data/plugins/user_interface/peppymeterbasic/BasicPeppyMeter"
spath="/data/plugins/user_interface/peppymeterbasic"
customfolder="/data/INTERNAL/PeppyMeterBasic/Templates"
PLUGIN_PATH="/data/plugins/user_interface/peppymeterbasic"
ALSA_BASE_PATH="${PLUGIN_PATH}/alsa-lib"

mkdir -p "${customfolder}"
chmod 777 -R "${customfolder}"

echo "Installing dependencies..."
sudo apt-get update
sudo apt-get -y --no-install-recommends install \
  python3-pygame python3-pip python3-dev libjpeg-dev zlib1g-dev libfftw3-dev
pip3 install --no-input Pillow

echo "Cloning PeppyMeter..."
git clone --depth 1 https://github.com/project-owner/PeppyMeter "${peppymeterpath}" || true
chmod 777 -R "${peppymeterpath}"
sudo chown -R volumio "${spath}" "${customfolder}"
sudo chgrp -R volumio "${spath}" "${customfolder}"

# Determine architecture
ARCH="$(arch)"
if [[ -z "${ARCH}" ]]; then
  echo "ARCH variable not set"; exit 1
fi

# Write service (use volumio user on all arch for least privilege)
cat > /etc/systemd/system/peppymeterbasic.service <<'EOC'
[Unit]
Description=peppymeterbasic Daemon
After=syslog.target
[Service]
Type=simple
WorkingDirectory=/data/plugins/user_interface/peppymeterbasic
ExecStart=/data/plugins/user_interface/peppymeterbasic/startpeppymeterbasic.sh
Restart=no
SyslogIdentifier=volumio
User=volumio
Group=volumio
TimeoutSec=5
[Install]
WantedBy=multi-user.target
EOC

# Select lib path for peppyalsa by arch
case "${ARCH}" in
  armv6l|armv7l) PEPPY_ALSA_PATH="${ALSA_BASE_PATH}/armhf" ;;
  aarch64)       PEPPY_ALSA_PATH="${ALSA_BASE_PATH}/arm64" ;;
  x86_64)        PEPPY_ALSA_PATH="${ALSA_BASE_PATH}/x86_64" ;;
  *) echo "Unknown arch: ${ARCH}"; exit 1 ;;
esac

sudo systemctl daemon-reload

# Create peppyalsa symlinks
mkdir -p "${ALSA_BASE_PATH}"
ln -sfn "${PEPPY_ALSA_PATH}/libpeppyalsa.so.0.0.0" "${ALSA_BASE_PATH}/libpeppyalsa.so"
ln -sfn "${PEPPY_ALSA_PATH}/libpeppyalsa.so.0.0.0" "${ALSA_BASE_PATH}/libpeppyalsa.so.0"
echo "Linked ${PEPPY_ALSA_PATH}/libpeppyalsa.so.0.0.0 to ${ALSA_BASE_PATH}/libpeppyalsa.so[.0]"

# Make launcher executable
sudo chmod +x /data/plugins/user_interface/peppymeterbasic/startpeppymeterbasic.sh

# Required by Volumio plugin installer
echo "plugininstallend"
