#!/usr/bin/env bash
# Sync source from the Mac (source of truth) to the Pi for building.
# Usage: scripts/sync.sh
set -euo pipefail

PI="${PI_HOST:-vwillcox@tabletpi.local}"
PI_DIR="${PI_DIR:-/home/vwillcox/tabletpi}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ssh "$PI" "mkdir -p '$PI_DIR'"

rsync -az --delete \
  --exclude '.git/' \
  --exclude 'build/' \
  --exclude '.dart_tool/' \
  --exclude 'linux/flutter/ephemeral/' \
  --exclude '**/.DS_Store' \
  "$HERE"/ "$PI:$PI_DIR"/

echo "Synced $HERE -> $PI:$PI_DIR"
