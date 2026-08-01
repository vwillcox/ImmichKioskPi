#!/usr/bin/env bash
# Sync + run the app on the Pi's DSI display (via the running labwc Wayland session).
# Usage: scripts/run.sh [debug|release]
#   debug   -> flutter run (hot reload, attaches to terminal)
#   release -> build once and launch the release binary detached
set -euo pipefail

MODE="${1:-release}"
# Load local overrides (git-ignored) so usernames/hosts stay out of the repo.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/local.env" ] && . "$SCRIPT_DIR/local.env"

PI="${PI_HOST:-pi@raspberrypi.local}"
PI_DIR="${PI_DIR:-/home/pi/immich_kiosk_pi}"
HERE="$SCRIPT_DIR"

"$HERE/sync.sh"

# Environment so GUI apps target the Pi's Wayland session on seat0.
# NOTE: kill by exact process name (-x immich_kiosk_pi); `pkill -f .../immich_kiosk_pi` also
# matches this launcher's own command line and would kill the shell mid-launch.
WENV='export PATH="$HOME/flutter/bin:$PATH"; export XDG_RUNTIME_DIR=/run/user/1000; export WAYLAND_DISPLAY=wayland-0; export GDK_BACKEND=wayland;'

if [ "$MODE" = "debug" ]; then
  ssh -t "$PI" "$WENV cd '$PI_DIR' && flutter run -d linux"
else
  ssh "$PI" "$WENV cd '$PI_DIR' && flutter build linux --release"
  # Restart via the systemd user service (returns immediately, survives ssh exit).
  ssh "$PI" "export XDG_RUNTIME_DIR=/run/user/1000; systemctl --user restart immich_kiosk_pi.service && echo restarted"
  echo "Restarted the kiosk on the Pi display. Logs: journalctl --user -u immich_kiosk_pi -f"
fi
