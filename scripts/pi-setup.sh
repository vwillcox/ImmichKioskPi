#!/usr/bin/env bash
# One-time Raspberry Pi setup for the HomeCanvas Immich app.
# Run this ON THE PI: bash pi-setup.sh
# It installs the Flutter toolchain + native libs needed to build & run the app.
#
# Most people want install.sh instead, which does this and everything after it
# (building, Immich, the network name, starting on boot) with a few questions.
# This is the by-hand step 1 in INSTALL.md.
set -euo pipefail

echo "==> HomeCanvas Pi setup starting"
echo "==> Installing system build dependencies (needs sudo)..."
sudo apt-get update
sudo apt-get install -y \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-14-dev \
  libmpv-dev mpv \
  curl git unzip xz-utils zip \
  wlr-randr

# Flutter SDK (stable channel), installed to ~/flutter
FLUTTER_DIR="$HOME/flutter"
if [ ! -d "$FLUTTER_DIR" ]; then
  echo "==> Cloning Flutter stable (shallow)..."
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
else
  echo "==> Flutter already present at $FLUTTER_DIR, updating..."
  git -C "$FLUTTER_DIR" pull --ff-only || true
fi

# Add to PATH for future shells
if ! grep -q 'flutter/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/flutter/bin:$PATH"' >> "$HOME/.bashrc"
  echo "==> Added Flutter to PATH in ~/.bashrc"
fi

export PATH="$FLUTTER_DIR/bin:$PATH"

echo "==> Enabling Linux desktop support..."
flutter config --enable-linux-desktop --no-analytics

echo "==> Precaching Linux engine artifacts (this downloads a few hundred MB)..."
flutter precache --linux

echo "==> Flutter version:"
flutter --version

echo
echo "==> Setup complete. Verifying doctor (Linux toolchain only):"
flutter doctor -v || true

echo
echo "==> The dashboard editor on port 80, so its address needs no number..."
PORT80="$(dirname "$0")/setup-port-80.sh"
if [ -f "$PORT80" ]; then
  bash "$PORT80" || echo "==> Port 80 not set up — run scripts/setup-port-80.sh later."
fi

echo
echo "============================================================"
echo " Setup finished. Next: set up the touchscreen — INSTALL.md, step 2."
echo "============================================================"
