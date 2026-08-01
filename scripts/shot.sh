#!/usr/bin/env bash
# Grab the Pi's display and copy it here. Usage: scripts/shot.sh [outfile]
set -euo pipefail
# Load local overrides (git-ignored) so usernames/hosts stay out of the repo.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/local.env" ] && . "$SCRIPT_DIR/local.env"

PI="${PI_HOST:-pi@tabletpi.local}"
OUT="${1:-/tmp/tabletpi-shot.png}"
ssh "$PI" 'export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0; grim /tmp/shot.png' >/dev/null 2>&1
scp -q "$PI:/tmp/shot.png" "$OUT"
echo "$OUT"
