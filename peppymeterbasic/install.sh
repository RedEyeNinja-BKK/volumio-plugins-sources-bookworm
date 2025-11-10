#!/usr/bin/env bash
set -euo pipefail

# ---- Paths ----
peppymeterpath="/data/plugins/user_interface/peppymeterbasic/BasicPeppyMeter"
spath="/data/plugins/user_interface/peppymeterbasic"
customfolder="/data/INTERNAL/PeppyMeterBasic"
PLUGIN_PATH="$spath"
ALSA_BASE_PATH="$spath/alsa-lib"

# A copy of upstream source optionally included in the plugin tree
BUNDLED_SRC_REL="BasicPeppyMeter_src"
BUNDLED_SRC_ABS="$spath/$BUNDLED_SRC_REL"

# Zero-prompt upstream tarballs (public)
TARBALL_CANDIDATES=(
  "https://codeload.github.com/project-owner/PeppyMeter/tar.gz/refs/heads/master"
  "https://codeload.github.com/project-owner/peppy_meter/tar.gz/refs/heads/master"
)

log(){ echo "[peppymeterbasic] $*"; }

log "Installing dependencies (Bookworm / PEP 668 compliant)..."
sudo apt-get update
sudo apt-get -y --no-install-recommends install \
  python3-pygame python3-dev libjpeg-dev zlib1g-dev libfftw3-dev python3-pil \
  ca-certificates curl tar

sudo mkdir -p "$PLUGIN_PATH" "$customfolder/Templates"
sudo chown -r volumio:volumio "$PLUGIN_PATH" "$customfolder" 2>/dev/null || true
chmod 755 -R "$PLUGIN_PATH"
chmod 777 -R "$customfolder/Templates"

ensure_peppymeter() {
  # If destination already exists, keep it (user may have edited templates there)
  if [[ -d "$peppymeterpath" ]] ; then
    log "PeppyMeter already present at $peppymeterpath"
    return 0
  fi

  # 1) Try anonymous tarball (no interactive auth)
  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' EXIT
  for url in "${TARBALL_CANDIDATES[@]}"; do
    log "Fetching upstream PeppyMeter via tarball: $url"
    if curl -fsSL "$url" -o "$tmpd/peppymeter.tar.gz"; then
      mkdir -p "$tmpd/src"
      tar -xzf "$tmpd/peppymeter.tar.gz" -C "$tmpd/src" --strip-components=1 || true
      if [[ -f "$tmpd/src/peppymeter.py" ]]; then
        mkdir -p "$peppymeterpath"
        cp -a "$tmpd/src/." "$peppymeterpath/"
        log "Installed upstream PeppyMeter into $peppymeterpath"
        return 0
      fi
    fi
  done

  # 2) Fallback: bundled copy (kept in repo at BasicPeppyMeter_src)
  if [[ -d "$BUNDLED_SRC_ABS" ]] && [[ -f "$BUNDLED_SRC_ABS/peppymeter.py" ]]; then
    log "Using bundled PeppyMeter source from $BUNDLED_SRC_ABS"
    mkdir -p "$peppymeterpath"
    cp -a "$BUNDLED_SRC_ABS/." "$peppymeterpath/"
    return 0
  fi

  log "ERROR: Unable to obtain PeppyMeter source (network blocked and no bundled copy)."
  exit 1
}

ensure_default_config() {
  # Provide a persistent config PeppyMeter can read.
  # PeppyMeter expects a config.txt with a [current] section among others.
  local confdir="$customfolder"
  local conf="$confdir/config.txt"

  mkdir -p "$confdir" "$confdir/Templates"

  if [[ ! -f "$conf" ]]; then
    log "Writing default $conf"
    cat > "$conf" <<'CFG'
[current]
base_folder = /data/plugins/user_interface/peppymeterbasic/BasicPeppyMeter

[screen]
# Use one of the folders present under BasicPeppyMeter/ (e.g. 1280x400, 800x480, 480x320, 320x240)
width = 800
height = 480
rotation = 0
fullscreen = True

[meter]
# meter_folder is relative to base_folder, e.g. "800x480"
meter_folder = 800x480

[alsa]
# These are not used in Loopback mode, but kept for completeness
device = peppyalsa
format = S16_LE
channels = 2
rate = 44100

[fifo]
path = /tmp/basic_peppy_meter_fifo
enabled = False
CFG
    chmod 664 "$conf"
  fi

  # Ensure Templates contains at least the meters from the source tree so users can pick/duplicate
  if [[ -d "$peppymeterpath" ]]; then
    # copy only known meter directories if they exist
    for d in 1280x400 800x480 480x320 320x240; do
      [[ -d "$peppymeterpath/$d" ]] && rsync -a --delete "$peppymeterpath/$d" "$confdir/Templates/" || true
    done
  fi
}

setup_systemd() {
  local svc="/etc/systemd/system/peppymeterbasic.service"
  log "Creating systemd unit: $svc"
  sudo tee "$svc" >/dev/null <<'UNIT'
[Unit]
Description=peppymeterbasic Daemon
After=syslog.target

[Service]
Type=simple
WorkingDirectory=/data/plugins/user_interface/peppymeterbasic
ExecStart=/data/plugins/user_interface/peppymeterbasic/startpeppymeterbasic.sh
Restart=on-failure
SyslogIdentifier=volumio
User=volumio
Group=volumio
TimeoutSec=5

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
}

link_alsa_libs() {
  # Make a neutral libpeppyalsa.so{,.0} in alsa-lib/ pointing at arch-specific builds if present.
  local arch="$(uname -m)"
  local src=""
  case "$arch" in
    x86_64)  PEPPY_ALSA_PATH="$ALSA_BASE_PATH/x86_64" ;;
    aarch64) PEPPY_ALSA_PATH="$ALSA_BASE_PATH/arm64" ;;
    armv7*|armv6*) PEPPY_ALSA_PATH="$ALSA_BASE_PATH/armhf" ;;
    *) PEPPY_ALSA_PATH="$ALSA_BASE_PATH";;
  esac

  if [[ -f "$PEPPY_ALSA_PATH/libpeppyalsa.so.0.0.0" ]]; then
    src="$PEPPY_ALSA_PATH/libpeppyalsa.so.0.0.0"
  elif [[ -f "$PEPPY_ALSA_PATH/libpeppyalsa.so" ]]; then
    src="$PEPPY_ALSA_PATH/libpeppyalsa.so"
  fi

  if [[ -n "$src" ]]; then
    mkdir -p "$ALSA_BASE_PATH"
    ln -sfn "$src" "$ALSA_BASE_PATH/libpeppyalsa.so"
    [[ -e "$src" ]] && ln -sfn "$src" "$ALSA_BASE_PATH/libpeppyalsa.so.0" || true
    log "Linked $src -> $ALSA_BASE_PATH/libpeppyalsa.so{,.0}"
  else
    log "No arch-specific peppyalsa library found for $(uname -m); continuing without."
  fi
}

# ---- Run steps ----
ensure_peppymeter
ensure_default_config
setup_systemd
link_alsa_libs

# Finish for Volumio plugin manager
echo plugininstallend
