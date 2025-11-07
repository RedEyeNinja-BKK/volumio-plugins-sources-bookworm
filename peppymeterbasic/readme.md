# PeppyMeter Basic (Bookworm) – with optional Camilla FIFO / Monitor backend

This is a Volumio 4 (Bookworm) plugin that displays PeppyMeter VU meters.  
By default it uses an ALSA Loopback “tap” for universal compatibility.  
Optionally, you can switch to a **Camilla FIFO / Monitor** backend for tighter sync and fewer dropouts on DSD→PCM systems.

> Requires the **Touch Display** and **Now Playing** plugins for best visual experience.

## Features
- Default **ALSA Loopback** backend (portable, safe)
- Optional **Camilla FIFO / Monitor** backend (no snd_aloop hop; lower latency)
- Works on **Pi 4 (armhf)**, **Pi 5 (arm64)**, and **x86_64**
- UI controls to select backend and set FIFO path / rate / format

## Why the Camilla FIFO backend?
When FusionDSP (CamillaDSP) is active, DSD content is converted to PCM.  
Feeding Peppy directly from Camilla (via a FIFO “monitor” branch) keeps Peppy in the **same clock domain** as the DAC output, avoiding extra buffering and rate drift that sometimes cause dropouts with large `.dsf` files. Loopback remains the default for users who don’t run DSP or prefer the simplest path.

## Settings
- **Screens / Meters**: choose template, size, and meter pack
- **Backend**:
  - **ALSA Loopback (default)** – requires `snd_aloop`
  - **Camilla FIFO / Monitor** – reads from FIFO (e.g., `/tmp/basic_peppy_meter_fifo`)
    - Set **Samplerate** (e.g., `176400`) to match your Camilla fixed rate
    - Set **Format** (`S16_LE` / `S24_LE` / `S32_LE`)
    - Set **Channels** (usually `2`)

> Tip: If you use FusionDSP with DSD content, set Volumio *DSD Playback Mode = Convert to PCM* and fix Camilla’s samplerate (e.g., 176.4 kHz) to stabilize the pipeline.

## Service / Permissions
- Installs a systemd service: `peppymeterbasic.service`
- Runs as user **volumio** on all architectures
- In **Camilla FIFO** mode, a systemd drop-in is added to start **after** `camilladsp.service`

## Install
This plugin is built via the standard Volumio Bookworm plugin workflow and can be installed from a zip created from the `peppymeterbasic/` folder.

volumio plugin install /home/volumio/peppymeterbasic.zip

## Uninstall
Disable the plugin from the UI, then remove it from the Plugins page.  
The service drop-in (if created) and FIFO are cleaned on stop/disable.

---

Credits:
- PeppyMeter and peppyalsa by the project owners.
- Original PeppyMeter Basic plugin authors [@balbuze] and the Volumio community.

GPL-3.0
