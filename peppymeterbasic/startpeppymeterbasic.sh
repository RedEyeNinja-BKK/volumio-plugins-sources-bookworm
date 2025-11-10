#!/usr/bin/env bash
set -euo pipefail

PLUGIN_DIR="/data/plugins/user_interface/peppymeterbasic"
ALSA_BASE_PATH="$PLUGIN_DIR/alsa-lib"

# 1) Ensure our private ALSA libs (if any) are visible first
export LD_LIBRARY_PATH="$ALSA_BASE_PATH:${LD_LIBRARY_PATH:-}"

# 2) Where our persistent plugin config lives
CFG="/data/configuration/user_interface/peppymeterbasic/config.json"

# 3) Optional FIFO path for CamillaDSP monitor mode
FIFO_PATH="/tmp/basic_peppy_meter_fifo"
if [[ ! -p "$FIFO_PATH" ]]; then
  echo "PeppyMeter: FIFO '$FIFO_PATH' not found (this is OK for Loopback backend)."
fi

# 4) Always run PeppyMeter from its own folder so it finds config.txt
cd "$PLUGIN_DIR/BasicPeppyMeter"

# 5) Exec PeppyMeter
exec python3 -u peppymeter.py
