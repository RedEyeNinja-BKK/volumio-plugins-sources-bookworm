#!/bin/bash
# Install script for peppymeterbasic (Bookworm-safe, GitHub-agnostic)
# Strategy:
#   1) If BasicPeppyMeter is bundled in the plugin src, copy it (fastest, no network).
#   2) Else try anonymous tarball downloads from known public URLs (no auth prompts).
#   3) If still not available, finish install and log a clear hint for manual placement.
set -euo pipefail

peppymeterpath="/data/plugins/user_interface/peppymeterbasic/BasicPeppyMeter"
spath="/data/plugins/user_interface/peppymeterbasic"
customfolder="/data/INTERNAL/PeppyMeterBasic/Templates"
PLUGIN_PATH="$spath"
ALSA_BASE_PATH="${PLUGIN_PATH}/alsa-lib"

# Where we might have shipped PeppyMeter source inside the plugin package
# (commit this folder to your repo to avoid network during install)
BUNDLED_SRC_REL="BasicPeppyMeter_src"           # <- you can add this folder to your repo
BUNDLED_SRC_ABS="${spath}/${BUNDLED_SRC_REL}"

# Anonymous tarball candidates (must be public repos; order = preference)
# Adjust these if you fork PeppyMeter to your own public repo.
TARBALL_CANDIDATES=(
  "https://codeload.github.com/project-owner/peppy_meter/tar.gz/refs/heads/master"
  "https://codeload.github.com/project-owner/PeppyMeter/tar.gz/refs/heads/master"
)

log() { echo "[peppymeterbasic] $*"; }

# -----------------------------------------------------------------------------
# 0) Baseline folders / permissions
# -----------------------------------------------------------------------------
mkdir -p "${customfolder}"
chmod 777 -R "${customfolder}" || true
sudo mkdir -p "${spath}"
sudo chown -R volumio:volumio "${spath}" "${customfolder}" || true

# -----------------------------------------------------------------------------
# 1) Dependencies (PEP 668-safe; no system pip)
# -----------------------------------------------------------------------------
log "Installing dependencies (Bookworm / PEP 668 compliant)..."
sudo apt-get update
sudo apt-get -y --no-install-recommends install \
  python3-pygame python3-dev libjpeg-dev zlib1g-dev libfftw3-dev python3-pil ca-certificates curl tar

# -----------------------------------------------------------------------------
# 2) Obtain PeppyMeter app
#    Prefer bundled src (if present in the packaged plugin). Otherwise try tarballs.
# -----------------------------------------------------------------------------
ensure_peppymeter() {
  if [[ -d "${peppymeterpath}" && -n "$(ls -A "${peppymeterpath}" 2>/dev/null)" ]]; then
    log "PeppyMeter already present at ${peppymeterpath}"
    return 0
  fi

  if [[ -d "${BUNDLED_SRC_ABS}" && -n "$(ls -A "${BUNDLED_SRC_ABS}" 2>/dev/null)" ]]; then
    log "Using bundled PeppyMeter source from ${BUNDLED_SRC_ABS}"
    mkdir -p "${peppymeterpath}"
    cp -a "${BUNDLED_SRC_ABS}/." "${peppymeterpath}/"
    return 0
  fi

  log "No bundled PeppyMeter found; trying anonymous tarball download..."
  mkdir -p "${peppymeterpath}"
  tmpdir="$(mktemp -d)"
  for url in "${TARBALL_CANDIDATES[@]}"; do
    log "Downloading ${url}"
    if curl -fL --connect-timeout 10 --retry 2 "$url" -o "${tmpdir}/peppymeter.tar.gz"; then
      tar -xzf "${tmpdir}/peppymeter.tar.gz" -C "${tmpdir}"
      # Extracted folder is <repo>-<hash>; copy its contents
      srcdir="$(find "${tmpdir}" -maxdepth 1 -type d -name 'peppy_*' -o -name 'PeppyMeter-*' | head -n1 || true)"
      if [[ -n "${srcdir}" && -d "${srcdir}" ]]; then
        cp -a "${srcdir}/." "${peppymeterpath}/"
        rm -rf "${tmpdir}"
        log "PeppyMeter downloaded and placed at ${peppymeterpath}"
        return 0
      fi
    fi
  done

  rm -rf "${tmpdir}" || true
  log "WARNING: Unable to fetch PeppyMeter sources automatically."
  log "         You can place the app manually into: ${peppymeterpath}"
  return 0  # do not fail the whole plugin install; the service will log a hint at runtime
}

ensure_peppymeter
sudo chown -R volumio:volumio "${peppymeterpath}" || true
chmod 755 -R "${peppymeterpath}" || true

# -----------------------------------------------------------------------------
# 3) Systemd service (least privilege on all architectures)
# -----------------------------------------------------------------------------
sudo tee /etc/systemd/system/peppymeterbasic.service >/dev/null <<'EOC'
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
sudo systemctl daemon-reload

# -----------------------------------------------------------------------------
# 4) Architecture-specific peppyalsa soname links (armhf/arm64/amd64)
# -----------------------------------------------------------------------------
ARCH="$(uname -m || true)"
log "Detected architecture: ${ARCH:-unknown}"

case "${ARCH}" in
  armv6l|armv7l) PEPPY_ALSA_PATH="${ALSA_BASE_PATH}/armhf" ;;
  aarch64)       PEPPY_ALSA_PATH="${ALSA_BASE_PATH}/arm64" ;;
  x86_64)        PEPPY_ALSA_PATH="${ALSA_BASE_PATH}/x86_64" ;;
  *)             log "Warning: unknown arch '${ARCH}', skipping peppyalsa symlinks"; PEPPY_ALSA_PATH="";;
esac

if [[ -n "${PEPPY_ALSA_PATH}" ]]; then
  SRC_LIB=""
  if [[ -f "${PEPPY_ALSA_PATH}/libpeppyalsa.so.0.0.0" ]]; then
    SRC_LIB="${PEPPY_ALSA_PATH}/libpeppyalsa.so.0.0.0"
  elif [[ -f "${PEPPY_ALSA_PATH}/libpeppyalsa.so" ]]; then
    SRC_LIB="${PEPPY_ALSA_PATH}/libpeppyalsa.so"
  fi

  if [[ -n "${SRC_LIB}" ]]; then
    mkdir -p "${ALSA_BASE_PATH}"
    ln -sfn "${SRC_LIB}" "${ALSA_BASE_PATH}/libpeppyalsa.so"
    ln -sfn "${SRC_LIB}" "${ALSA_BASE_PATH}/libpeppyalsa.so.0"
    log "Linked ${SRC_LIB} -> ${ALSA_BASE_PATH}/libpeppyalsa.so{,.0}"
  else
    log "Note: peppyalsa library not found for '${ARCH}' in '${PEPPY_ALSA_PATH}'."
  fi
fi

# -----------------------------------------------------------------------------
# 5) Ensure launcher is executable
# -----------------------------------------------------------------------------
sudo chmod +x "${spath}/startpeppymeterbasic.sh" || true

# -----------------------------------------------------------------------------
# 6) REQUIRED by Volumio installer
# -----------------------------------------------------------------------------
echo "plugininstallend"
