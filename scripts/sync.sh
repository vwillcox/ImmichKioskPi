#!/usr/bin/env bash
# Sync source from the Mac (source of truth) to the Pi for building.
# Usage: scripts/sync.sh
set -euo pipefail

# Load local overrides (git-ignored) so usernames/hosts stay out of the repo.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/local.env" ] && . "$SCRIPT_DIR/local.env"

PI="${PI_HOST:-pi@tabletpi.local}"
PI_DIR="${PI_DIR:-/home/pi/tabletpi}"
HERE="$(cd "$SCRIPT_DIR/.." && pwd)"

ssh "$PI" "mkdir -p '$PI_DIR'"

rsync -az --delete \
  --exclude '.git/' \
  --exclude 'build/' \
  --exclude '.dart_tool/' \
  --exclude 'linux/flutter/ephemeral/' \
  --exclude '**/.DS_Store' \
  "$HERE"/ "$PI:$PI_DIR"/

echo "Synced $HERE -> $PI:$PI_DIR"
