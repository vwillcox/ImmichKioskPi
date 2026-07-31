#!/usr/bin/env bash
# Sync + run the app on the Pi's DSI display (via the running labwc Wayland session).
# Usage: scripts/run.sh [debug|release]
#   debug   -> flutter run (hot reload, attaches to terminal)
#   release -> build once and launch the release binary detached
set -euo pipefail

MODE="${1:-release}"
PI="${PI_HOST:-vwillcox@tabletpi.local}"
PI_DIR="${PI_DIR:-/home/vwillcox/tabletpi}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$HERE/sync.sh"

# Environment so GUI apps target the Pi's Wayland session on seat0.
# NOTE: kill by exact process name (-x tabletpi); `pkill -f .../tabletpi` also
# matches this launcher's own command line and would kill the shell mid-launch.
WENV='export PATH="$HOME/flutter/bin:$PATH"; export XDG_RUNTIME_DIR=/run/user/1000; export WAYLAND_DISPLAY=wayland-0; export GDK_BACKEND=wayland;'

if [ "$MODE" = "debug" ]; then
  ssh -t "$PI" "$WENV cd '$PI_DIR' && flutter run -d linux"
else
  ssh "$PI" "$WENV cd '$PI_DIR' && flutter build linux --release"
  # Restart via the systemd user service (returns immediately, survives ssh exit).
  ssh "$PI" "export XDG_RUNTIME_DIR=/run/user/1000; systemctl --user restart tabletpi.service && echo restarted"
  echo "Restarted the kiosk on the Pi display. Logs: journalctl --user -u tabletpi -f"
fi
