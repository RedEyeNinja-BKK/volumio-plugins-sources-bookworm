#!/bin/bash
# Minimal, resilient launcher
# - Sets LD_LIBRARY_PATH so bundled peppyalsa is found
# - Tries common PeppyMeter entry points
# - Leaves detailed parameter handling to index.js/config if present
set -euo pipefail

PLUGIN_DIR="/data/plugins/user_interface/peppymeterbasic"
ALSA_BASE_PATH="$PLUGIN_DIR/alsa-lib"
export LD_LIBRARY_PATH="$ALSA_BASE_PATH:${LD_LIBRARY_PATH:-}"

# Optional: read FIFO path from config.json if index.js writes it there.
# Fall back to a sane default if jq not present or key missing.
CFG="/data/configuration/user_interface/peppymeterbasic/config.json"
if command -v jq >/dev/null 2>&1 && [[ -f "$CFG" ]]; then
  FIFO_PATH="$(jq -r '.fifoPath // "/tmp/basic_peppy_meter_fifo"' "$CFG" 2>/dev/null || echo "/tmp/basic_peppy_meter_fifo")"
else
  FIFO_PATH="/tmp/basic_peppy_meter_fifo"
fi

# If FIFO is expected (Camilla backend), don't hard fail—PeppyMeter can still show animations.
if [[ ! -p "$FIFO_PATH" ]]; then
  echo "PeppyMeter: FIFO '$FIFO_PATH' not found (this is OK for Loopback backend)."
fi

# Common PeppyMeter entry points
if [[ -x "$PLUGIN_DIR/BasicPeppyMeter/run-peppymeter.sh" ]]; then
  exec "$PLUGIN_DIR/BasicPeppyMeter/run-peppymeter.sh"
elif [[ -f "$PLUGIN_DIR/BasicPeppyMeter/peppymeter.py" ]]; then
  exec python3 -u "$PLUGIN_DIR/BasicPeppyMeter/peppymeter.py"
else
  echo "PeppyMeter: no known entrypoint found under $PLUGIN_DIR/BasicPeppyMeter"
  exit 1
fi
