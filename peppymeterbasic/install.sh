#!/bin/bash
# Install script for peppymeterbasic (Bookworm-safe)
# - Installs PeppyMeter app and deps (PEP 668 compliant)
# - Sets up systemd service peppymeterbasic.service (User=volumio on all arch)
# - Creates arch-specific symlinks for peppyalsa library
set -euo pipefail

peppymeterpath="/data/plugins/user_interface/peppymeterbasic/BasicPeppyMeter"
spath="/data/plugins/user_interface/peppymeterbasic"
customfolder="/data/INTERNAL/PeppyMeterBasic/Templates"
PLUGIN_PATH="/data/plugins/user_interface/peppymeterbasic"
ALSA_BASE_PATH="${PLUGIN_PATH}/alsa-lib"

# Ensure writable template dir
mkdir -p "${customfolder}"
chmod 777 -R "${customfolder}"

echo "Installing dependencies (Bookworm / PEP 668 compliant)..."
sudo apt-get update
sudo apt-get -y --no-install-recommends install \
  python3-pygame python3-dev libjpeg-dev zlib1g-dev libfftw3-dev python3-pil

echo "Cloning PeppyMeter (shallow, anonymous, tolerant)..."
# Prevent any interactive GitHub auth prompts on headless devices
export GIT_TERMINAL_PROMPT=0
if [ ! -d "${peppymeterpath}" ] || [ -z "$(ls -A "${peppymeterpath}" 2>/dev/null)" ]; then
  git clone --depth 1 https://github.com/project-owner/peppy_meter "${peppymeterpath}" || true
fi

# Ownership for plugin paths
chmod 777 -R "${peppymeterpath}" || true
sudo chown -R volumio:volumio "${spath}" "${customfolder}"

# Detect architecture (portable)
ARCH="$(uname -m)"
if [[ -z "${ARCH}" ]]; then
  echo "Warning: could not detect architecture; continuing with generic setup"
fi
echo "Detected architecture: ${ARCH}"

# Write service (least privilege everywhere)
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
  *)             echo "Warning: unknown arch '${ARCH}', skipping peppyalsa symlinks"; PEPPY_ALSA_PATH="";;
esac

sudo systemctl daemon-reload

# Create peppyalsa soname symlinks if the source exists
if [[ -n "${PEPPY_ALSA_PATH}" ]] && [[ -f "${PEPPY_ALSA_PATH}/libpeppyalsa.so.0.0.0" ]]; then
  mkdir -p "${ALSA_BASE_PATH}"
  ln -sfn "${PEPPY_ALSA_PATH}/libpeppyalsa.so.0.0.0" "${ALSA_BASE_PATH}/libpeppyalsa.so"
  ln -sfn "${PEPPY_ALSA_PATH}/libpeppyalsa.so.0.0.0" "${ALSA_BASE_PATH}/libpeppyalsa.so.0"
  echo "Linked ${PEPPY_ALSA_PATH}/libpeppyalsa.so.0.0.0 -> ${ALSA_BASE_PATH}/libpeppyalsa.so{,.0}"
else
  echo "Note: peppyalsa library for '${ARCH}' not found; continuing without symlinks."
fi

# Ensure launcher is executable
sudo chmod +x /data/plugins/user_interface/peppymeterbasic/startpeppymeterbasic.sh

# Required by Volumio plugin installer
echo "plugininstallend"
