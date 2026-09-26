#!/usr/bin/env bash
# HomeCanvas installer — one command, and it walks you through the rest.
#
#   curl -fsSL https://raw.githubusercontent.com/vwillcox/HomeCanvas/main/install.sh | bash
#
# or, from a copy of the code:   bash install.sh
#
#   --check   look at this machine and say what is missing; change nothing
#   --yes     accept every default without asking (unattended installs)
#
# Run it on the machine that will show HomeCanvas, as your normal user — it
# asks for your password (sudo) when it needs to install something. Run it
# again at any time to update to the latest version.
set -euo pipefail

REPO_URL="https://github.com/vwillcox/HomeCanvas.git"
# Another branch, for trying out a change before it is released.
BRANCH="${HOMECANVAS_BRANCH:-main}"
APP_DIR="${HOMECANVAS_DIR:-$HOME/homecanvas}"
FLUTTER_DIR="$HOME/flutter"
LOG="$HOME/homecanvas-install.log"
CONFIG="$HOME/.config/homecanvas/config.json"

MODE="install"
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --yes | -y) ASSUME_YES=1 ;;
    -h | --help)
      sed -n '2,15p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

# ---- how it talks ----------------------------------------------------------

if [ -t 1 ]; then
  B=$'\e[1m' DIM=$'\e[2m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' C=$'\e[36m' N=$'\e[0m'
else
  B="" DIM="" G="" Y="" R="" C="" N=""
fi

STEP=0
STEPS=9
step() {
  STEP=$((STEP + 1))
  echo
  echo "${B}${C}[$STEP/$STEPS] $*${N}"
}
say() { echo "  $*"; }
ok() { echo "  ${G}✓${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
fail() { echo "  ${R}✗${N} $*"; }
die() {
  echo
  echo "${R}${B}Stopped:${N} $*" >&2
  [ -s "$LOG" ] && echo "${DIM}The full log is in $LOG${N}" >&2
  exit 1
}

# Questions come from the keyboard even when this script arrives through a
# pipe (curl … | bash), when its own input is the script rather than you.
TTY=/dev/tty
have_tty() { [ "$ASSUME_YES" = 0 ] && { : <"$TTY"; } 2>/dev/null; }

# ask "Question?" y|n  → true for yes. The default is what Enter gives, and
# what --yes (or no keyboard to ask at) chooses.
ask() {
  local q="$1" def="${2:-y}" hint reply
  [ "$def" = y ] && hint="[Y/n]" || hint="[y/N]"
  if ! have_tty; then
    [ "$def" = y ]
    return
  fi
  read -r -p "  $q $hint " reply <"$TTY" || reply=""
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

# ask_text "Prompt" "default" [secret] → the answer on stdout.
ask_text() {
  local q="$1" def="${2:-}" secret="${3:-}" reply
  if ! have_tty; then
    echo "$def"
    return
  fi
  if [ -n "$secret" ]; then
    read -r -s -p "  $q: " reply <"$TTY" || reply=""
    echo >&2
  else
    read -r -p "  $q${def:+ [$def]}: " reply <"$TTY" || reply=""
  fi
  echo "${reply:-$def}"
}

# Runs a long command with its output in the log rather than on screen, and
# a line saying what is happening. The log's tail is shown if it fails.
run() {
  local what="$1" start
  shift
  printf '  %s… ' "$what"
  echo "=== $what: $*" >>"$LOG"
  start=$(wc -l <"$LOG")
  if "$@" >>"$LOG" 2>&1; then
    echo "${G}done${N}"
  else
    echo "${R}failed${N}"
    # This step's own last lines, not whatever came before it in the log.
    echo "${DIM}"
    tail -n +"$((start + 1))" "$LOG" | tail -n 12 | sed 's/^/    /'
    echo "${N}"
    return 1
  fi
}

# ---- get the code ------------------------------------------------------------

# Arrived through curl rather than from a copy of the code? Fetch the code,
# then carry on from the copy's own installer, so every helper it uses is the
# version that came with it.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [ -z "$SELF_DIR" ] || [ ! -f "$SELF_DIR/pubspec.yaml" ] ||
  ! grep -q '^name: home_canvas' "$SELF_DIR/pubspec.yaml"; then
  echo "${B}HomeCanvas installer${N}"
  if ! command -v git >/dev/null; then
    echo "  git is needed to fetch HomeCanvas. Installing it (needs your password)…"
    {
      if command -v apt-get >/dev/null; then
        sudo apt-get update && sudo apt-get install -y git
      elif command -v dnf >/dev/null; then
        sudo dnf install -y git
      elif command -v pacman >/dev/null; then
        sudo pacman -S --needed --noconfirm git
      elif command -v zypper >/dev/null; then
        sudo zypper --non-interactive install git
      else
        false
      fi
    } >>"$LOG" 2>&1 || die "Please install git, then run this again."
    command -v git >/dev/null || die "Please install git, then run this again."
  fi
  if [ -d "$APP_DIR/.git" ]; then
    echo "  Updating the copy in $APP_DIR…"
    git -C "$APP_DIR" pull --ff-only -q || die "Couldn't update $APP_DIR — local changes in the way?"
  elif grep -qs '^name: home_canvas' "$APP_DIR/pubspec.yaml" && [ -f "$APP_DIR/install.sh" ]; then
    # Copied here rather than downloaded (scripts/sync.sh does that): it
    # can't fetch updates itself, so carry on with the copy as it is.
    echo "  Using the copy already in $APP_DIR."
  else
    [ -e "$APP_DIR" ] && die "$APP_DIR exists but isn't HomeCanvas. Move it aside, or set HOMECANVAS_DIR."
    echo "  Fetching HomeCanvas into $APP_DIR…"
    git clone -q --depth 1 -b "$BRANCH" "$REPO_URL" "$APP_DIR" || die "Couldn't download HomeCanvas from $REPO_URL"
  fi
  exec bash "$APP_DIR/install.sh" "$@"
fi
APP_DIR="$SELF_DIR"

# ---- about this machine ----------------------------------------------------

[ "$(id -u)" -eq 0 ] && die "Run this as your normal user, not as root or with sudo — it asks for your password when it needs it."

OS_NAME="Linux"
OS_FAMILY=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_NAME="${PRETTY_NAME:-$OS_NAME}"
  for id in ${ID:-} ${ID_LIKE:-}; do
    case "$id" in
      debian | ubuntu | raspbian) OS_FAMILY=apt ;;
      fedora | rhel | centos) OS_FAMILY=dnf ;;
      arch | archarm | manjaro | endeavouros) OS_FAMILY=pacman ;;
      opensuse* | suse | sles) OS_FAMILY=zypper ;;
    esac
    [ -n "$OS_FAMILY" ] && break
  done
fi
# Anything else that still has one of the four package managers.
if [ -z "$OS_FAMILY" ]; then
  for pm in apt-get:apt dnf:dnf pacman:pacman zypper:zypper; do
    command -v "${pm%%:*}" >/dev/null && OS_FAMILY="${pm##*:}" && break
  done
fi

case "$(uname -m)" in
  aarch64 | arm64) ARCH=arm64 ;;
  x86_64 | amd64) ARCH=x64 ;;
  *) ARCH="" ;;
esac

# labwc is the Raspberry Pi desktop; anything else is started the standard way.
DESKTOP=other
if pgrep -x labwc >/dev/null 2>&1 || [[ "${XDG_CURRENT_DESKTOP:-}" == *labwc* ]]; then
  DESKTOP=labwc
fi

# Over SSH there is no desktop in the environment; point at the one running.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; then
  export WAYLAND_DISPLAY=wayland-0
fi

BINARY="$APP_DIR/build/linux/$ARCH/release/bundle/homecanvas"
UNIT="$HOME/.config/systemd/user/homecanvas.service"

# ---- what is needed --------------------------------------------------------

# Commands, then libraries by their pkg-config name.
NEED_CMDS="git curl unzip python3 clang cmake ninja pkg-config"
NEED_LIBS="gtk+-3.0 mpv liblzma"

# Package names for each family: needed, then nice to have (the network name,
# finding the touchscreen and its output).
packages() {
  case "$OS_FAMILY" in
    apt)
      local stdcxx
      # The C++ library the compiler builds against. Its version is in the
      # package name, and differs by release: take the newest there is.
      stdcxx=$(apt-cache search --names-only '^libstdc\+\+-[0-9]+-dev$' 2>/dev/null |
        awk '{print $1}' | sort -V | tail -1)
      echo "clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev ${stdcxx:-libstdc++-dev} libmpv-dev mpv curl git unzip xz-utils zip python3"
      echo "avahi-daemon wlr-randr libinput-tools"
      ;;
    dnf)
      echo "clang cmake ninja-build pkgconf-pkg-config gtk3-devel xz-devel libstdc++-devel mpv-devel curl git unzip xz zip python3"
      echo "avahi nss-mdns wlr-randr libinput-utils"
      ;;
    pacman)
      echo "clang cmake ninja pkgconf gtk3 xz mpv curl git unzip zip python"
      echo "avahi nss-mdns wlr-randr libinput"
      ;;
    zypper)
      echo "clang cmake ninja pkgconf-pkg-config gtk3-devel xz-devel mpv-devel curl git unzip xz zip python3"
      echo "avahi nss-mdns wlr-randr libinput-tools"
      ;;
  esac
}

pkg_install() {
  case "$OS_FAMILY" in
    apt) sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) sudo dnf install -y "$@" ;;
    pacman) sudo pacman -S --needed --noconfirm "$@" ;;
    zypper) sudo zypper --non-interactive install "$@" ;;
  esac
}

pkg_refresh() {
  case "$OS_FAMILY" in
    apt) sudo apt-get update ;;
    dnf) sudo dnf makecache ;;
    # Not -Sy: refreshing without upgrading is the partial upgrade Arch
    # warns against. An out-of-date system is left to its owner.
    pacman) true ;;
    zypper) sudo zypper --non-interactive refresh ;;
  esac
}

flutter_cmd() {
  if [ -x "$FLUTTER_DIR/bin/flutter" ]; then
    echo "$FLUTTER_DIR/bin/flutter"
  else
    command -v flutter || true
  fi
}

MISSING=()
check_system() {
  MISSING=()
  local c l
  for c in $NEED_CMDS; do
    if command -v "$c" >/dev/null; then ok "$c"; else fail "$c"; MISSING+=("$c"); fi
  done
  if command -v pkg-config >/dev/null; then
    for l in $NEED_LIBS; do
      if pkg-config --exists "$l"; then ok "$l (library)"; else fail "$l (library)"; MISSING+=("$l"); fi
    done
  else
    for l in $NEED_LIBS; do fail "$l (library — can't check without pkg-config)"; MISSING+=("$l"); done
  fi
  local fl
  fl=$(flutter_cmd)
  if [ -n "$fl" ]; then
    ok "Flutter ($("$fl" --version 2>/dev/null | head -1 | awk '{print $2}'))"
  else
    fail "Flutter"
    MISSING+=("flutter")
  fi
}

# ---- the steps ---------------------------------------------------------------

echo
echo "${B}Welcome to HomeCanvas${N}"
echo "${DIM}Photos from Immich and a dashboard for your wall.${N}"
echo
say "This machine:  ${B}$OS_NAME${N}, $(uname -m), desktop: $DESKTOP"
say "HomeCanvas:    $APP_DIR"
[ -n "$ARCH" ] || die "HomeCanvas runs on 64-bit ARM (Raspberry Pi 4/5) or 64-bit Intel/AMD. This is $(uname -m)."

if [ "$MODE" = check ]; then
  echo
  echo "${B}What's here${N}"
  check_system
  echo
  if [ ${#MISSING[@]} -eq 0 ]; then
    say "${G}Everything needed to build HomeCanvas is installed.${N}"
  else
    say "Missing: ${MISSING[*]}"
    if [ -n "$OS_FAMILY" ]; then
      say "Run ${B}bash install.sh${N} to install them."
    else
      say "Your Linux isn't one this installer knows how to install for — see INSTALL.md."
    fi
  fi
  exit 0
fi

: >"$LOG"

# Already installed? Most people running this again want the new version.
if [ -x "$BINARY" ] && [ -f "$UNIT" ]; then
  echo
  say "HomeCanvas is already installed here."
  if ask "Update it to the latest version? (No goes through the whole setup again)" y; then
    step() { echo; echo "${B}${C}$*${N}"; }
    step "Updating"
    if [ -d "$APP_DIR/.git" ]; then
      run "Fetching the latest version" git -C "$APP_DIR" pull --ff-only || die "Couldn't update — local changes in $APP_DIR?"
    else
      warn "This copy was put here from another computer, not downloaded, so it"
      warn "can't fetch updates itself — send the new version the same way."
      warn "Rebuilding what's here."
    fi
    FL=$(flutter_cmd)
    run "Building (this takes a few minutes)" bash -c "cd '$APP_DIR' && '$FL' pub get && '$FL' build linux --release" || die "The build failed."
    systemctl --user restart homecanvas.service 2>/dev/null || true
    echo
    say "${G}${B}Updated and restarted.${N}"
    exit 0
  fi
fi

echo
say "It will:"
say "  1. check what's installed          6. give it a name on your network"
say "  2. install anything missing        7. start it automatically"
say "  3. install Flutter                 8. set up the touchscreen"
say "  4. build HomeCanvas                9. put the editor on a simple address"
say "  5. connect it to your Immich"
say "${DIM}Nothing is changed without saying what first. It asks for your password"
say "to install things.${N}"
echo
ask "Ready to start?" y || exit 0

# Ask for the password once now, and keep it fresh through the long build.
sudo -v || die "This needs your password (sudo) to install packages."
( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null || true' EXIT

# 1 -------------------------------------------------------------------------
step "Checking what's installed"
check_system

# 2 -------------------------------------------------------------------------
step "Installing what's missing"
if [ -z "$OS_FAMILY" ]; then
  warn "Your Linux isn't Debian/Raspberry Pi OS/Ubuntu, Fedora, Arch or openSUSE,"
  warn "so this can't install for you. INSTALL.md lists what's needed."
  [ ${#MISSING[@]} -eq 0 ] || die "Missing: ${MISSING[*]}"
else
  {
    read -r NEEDED
    read -r EXTRA
  } < <(packages)
  if [ ${#MISSING[@]} -eq 0 ] || [ "${MISSING[*]}" = flutter ]; then
    ok "Nothing missing"
  fi
  run "Refreshing the package list" pkg_refresh || die "Couldn't reach the package servers — is the network up?"
  # shellcheck disable=SC2086
  run "Installing build tools and libraries" pkg_install $NEEDED || {
    [ "$OS_FAMILY" = dnf ] && warn "On Fedora, mpv-devel comes from RPM Fusion: https://rpmfusion.org/Configuration"
    [ "$OS_FAMILY" = pacman ] && warn "If packages weren't found, bring the system up to date first: sudo pacman -Syu"
    die "Couldn't install the packages above."
  }
  # One at a time: some aren't packaged everywhere, and none is essential.
  for p in $EXTRA; do
    run "Installing $p" pkg_install "$p" || warn "$p isn't available here — skipped"
  done
fi

# 3 -------------------------------------------------------------------------
step "Flutter"
FL=$(flutter_cmd)
if [ -z "$FL" ]; then
  say "Flutter builds HomeCanvas. It goes in $FLUTTER_DIR (about 2 GB)."
  run "Downloading Flutter" git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR" ||
    die "Couldn't download Flutter."
  FL="$FLUTTER_DIR/bin/flutter"
  if ! grep -q 'flutter/bin' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/flutter/bin:$PATH"' >>"$HOME/.bashrc"
  fi
else
  ok "Already installed: $FL"
fi
run "Setting Flutter up for Linux" "$FL" config --enable-linux-desktop --no-analytics || die "Flutter wouldn't configure."
run "Downloading Flutter's Linux engine (a few hundred MB)" "$FL" precache --linux || die "Couldn't download Flutter's engine."
# HomeCanvas needs a recent Dart; an old Flutter install gets updated.
if ! (cd "$APP_DIR" && "$FL" pub get >>"$LOG" 2>&1); then
  warn "This Flutter is too old for HomeCanvas — updating it."
  run "Updating Flutter" "$FL" upgrade --force || die "Couldn't update Flutter."
  run "Fetching HomeCanvas's packages" bash -c "cd '$APP_DIR' && '$FL' pub get" || die "Couldn't fetch packages."
else
  ok "Flutter is recent enough"
fi

# 4 -------------------------------------------------------------------------
step "Building HomeCanvas"
say "${DIM}This takes a few minutes on a Raspberry Pi.${N}"
run "Building" bash -c "cd '$APP_DIR' && '$FL' build linux --release" || die "The build failed."
[ -x "$BINARY" ] || die "The build finished, but $BINARY isn't there."
ok "Built"

# 5 -------------------------------------------------------------------------
step "Connecting to Immich"
current_url=""
if [ -f "$CONFIG" ]; then
  current_url=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("immichUrl",""))' "$CONFIG" 2>/dev/null || true)
fi
if [ -n "$current_url" ] && [[ "$current_url" != *example.com* ]]; then
  ok "Already connected to $current_url"
  change=n
  ask "Connect to a different Immich server?" n && change=y
else
  change=y
fi
if [ "$change" = y ]; then
  say "HomeCanvas shows the photos on your Immich server. You'll need its"
  say "address, and an API key from Immich: ${B}Account Settings → API Keys${N}."
  say "${DIM}(Leave the address empty to skip — you can do this on the screen later.)${N}"
  while true; do
    url=$(ask_text "Immich address, e.g. https://photos.example.com" "")
    url="${url%/}"
    [ -z "$url" ] && { warn "Skipped"; break; }
    [[ "$url" =~ ^https?:// ]] || url="https://$url"
    if ! curl -fsS -m 10 "$url/api/server/ping" 2>/dev/null | grep -q pong; then
      fail "No Immich server answered at $url"
      ask "Try another address?" y && continue
      break
    fi
    ok "Found Immich at $url"
    key=$(ask_text "API key (it won't show as you type or paste)" "" secret)
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "x-api-key: $key" "$url/api/users/me" || true)
    if [ "$code" != 200 ]; then
      fail "Immich didn't accept that key (HTTP $code)"
      ask "Try again?" y && continue
      break
    fi
    ok "The key works"
    mkdir -p "$(dirname "$CONFIG")"
    URL="$url" KEY="$key" python3 - "$CONFIG" <<'PY'
import json, os, sys
p = sys.argv[1]
try:
    c = json.load(open(p))
except Exception:
    c = {}
c["immichUrl"] = os.environ["URL"]
c["apiKey"] = os.environ["KEY"]
json.dump(c, open(p, "w"), indent=2)
PY
    chmod 600 "$CONFIG"
    ok "Saved to $CONFIG"
    break
  done
fi

# 6 -------------------------------------------------------------------------
step "A name on your network"
current=$(hostname)
say "So you can reach it as ${B}<name>.local${N} instead of by its IP address."
if [ "$current" = homecanvas ]; then
  NAME=homecanvas
  ok "Already called homecanvas"
  ask "Keep that name?" y || NAME=$(ask_text "New name (letters, digits, hyphens)" "homecanvas")
else
  NAME=$(ask_text "Name (letters, digits, hyphens)" "homecanvas")
fi
if [ "$NAME" != "$current" ] || ! systemctl is-active --quiet avahi-daemon 2>/dev/null; then
  run "Naming it $NAME and announcing $NAME.local" bash "$APP_DIR/scripts/set-hostname.sh" "$NAME" ||
    warn "Couldn't set the name — see $LOG. Everything else still works by IP address."
fi
# Whatever it is called now — the summary shouldn't promise a name that failed.
NAME=$(hostname)

# 7 -------------------------------------------------------------------------
step "Starting it automatically"
mkdir -p "$(dirname "$UNIT")"
# The service from the repo, pointed at this copy's build. The Pi's labwc
# desktop is always wayland-0; elsewhere the desktop hands its own display
# over when it starts the service (below).
sed -e "s#^ExecStart=.*#ExecStart=$BINARY#" \
  "$APP_DIR/deploy/homecanvas.service" >"$UNIT.new"
if [ "$DESKTOP" != labwc ]; then
  sed -i -e '/^Environment=WAYLAND_DISPLAY=/d' -e '/^Environment=GDK_BACKEND=/d' "$UNIT.new"
fi
mv "$UNIT.new" "$UNIT"
# Its output to a file, since user services often keep no log of their own.
mkdir -p "$UNIT.d"
printf '[Service]\nStandardOutput=append:/tmp/kiosk.log\nStandardError=append:/tmp/kiosk.log\n' >"$UNIT.d/log.conf"
USER_SERVICES=1
if systemctl --user daemon-reload 2>>"$LOG" &&
  systemctl --user enable homecanvas.service >>"$LOG" 2>&1; then
  ok "Service installed"
else
  USER_SERVICES=0
  warn "This system has no user services (systemd --user), so HomeCanvas won't"
  warn "start by itself. Run it with: $BINARY"
fi

if [ "$USER_SERVICES" = 0 ]; then
  :
elif [ "$DESKTOP" = labwc ]; then
  # labwc never starts graphical-session.target, so its autostart has to.
  AUTO="$HOME/.config/labwc/autostart"
  mkdir -p "$(dirname "$AUTO")"
  [ -f "$AUTO" ] || printf '#!/bin/sh\n' >"$AUTO"
  if ! grep -q 'homecanvas.service' "$AUTO"; then
    cat >>"$AUTO" <<'EOF'

# HomeCanvas (added by install.sh)
systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR GDK_BACKEND 2>/dev/null
systemctl --user restart homecanvas.service
EOF
  fi
  chmod +x "$AUTO"
  ok "Starts with the desktop (labwc autostart)"
else
  DESK="$HOME/.config/autostart/homecanvas.desktop"
  mkdir -p "$(dirname "$DESK")"
  cat >"$DESK" <<'EOF'
[Desktop Entry]
Type=Application
Name=HomeCanvas
Comment=Starts the HomeCanvas kiosk
Exec=sh -c "systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR GDK_BACKEND; systemctl --user restart homecanvas.service"
X-GNOME-Autostart-enabled=true
EOF
  ok "Starts when you log in to the desktop"
fi

if [ "$USER_SERVICES" = 0 ]; then
  :
elif [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
  systemctl --user import-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY XDG_RUNTIME_DIR 2>/dev/null || true
  if systemctl --user restart homecanvas.service 2>>"$LOG"; then
    ok "Started — look at the screen"
  else
    warn "Couldn't start it now — it starts the next time the desktop does."
  fi
else
  say "It starts the next time the desktop does."
fi

# 8 -------------------------------------------------------------------------
step "The touchscreen"
if [ "$DESKTOP" != labwc ]; then
  ok "Nothing to do on this desktop"
else
  RC="$HOME/.config/labwc/rc.xml"
  if [ -f "$RC" ] && grep -q '<touch ' "$RC"; then
    ok "Already set up in $RC"
  else
    # The touch device: libinput needs root to read the input devices.
    touch_dev=""
    if command -v libinput >/dev/null; then
      touch_dev=$(sudo libinput list-devices 2>/dev/null | awk '
        /^Device:/ { sub(/^Device:[ \t]+/, ""); dev = $0 }
        /^Capabilities:/ && /touch/ { print dev; exit }')
    fi
    # The panel it belongs to, preferring the Pi's own display connector.
    outputs=$(wlr-randr 2>/dev/null | awk '/^[^ ]/ {print $1}')
    out=$(echo "$outputs" | grep -m1 '^DSI' || echo "$outputs" | head -1)
    if [ -z "$touch_dev" ]; then
      ok "No touchscreen found — nothing to do"
    elif [ -z "$out" ]; then
      warn "Found the touchscreen ($touch_dev) but couldn't see the display."
      warn "Run this again from the desktop, or see INSTALL.md, step 2."
    else
      say "Touchscreen: ${B}$touch_dev${N} on display ${B}$out${N}"
      say "${DIM}Real touch events rather than a pretend mouse: needed for swiping.${N}"
      if ask "Set it up?" y; then
        esc() { sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e 's/</\&lt;/g'; }
        line="  <touch deviceName=\"$(echo "$touch_dev" | esc)\" mapToOutput=\"$(echo "$out" | esc)\" mouseEmulation=\"no\"/>"
        if [ -f "$RC" ]; then
          cp "$RC" "$RC.before-homecanvas"
          # After the opening tag, however it is written.
          LINE="$line" python3 - "$RC" <<'PY'
import os, re, sys
p = sys.argv[1]
s = open(p).read()
m = re.search(r"<openbox_config[^>]*>", s)
if m:
    s = s[: m.end()] + "\n" + os.environ["LINE"] + s[m.end():]
else:
    s = s.rstrip() + "\n" + os.environ["LINE"] + "\n"
open(p, "w").write(s)
PY
          ok "Added to $RC (the old one is $RC.before-homecanvas)"
        else
          mkdir -p "$(dirname "$RC")"
          sed -e "s#^  <touch .*#$(echo "$line" | sed 's/[#&\\]/\\&/g')#" \
            "$APP_DIR/deploy/labwc-rc.xml" >"$RC"
          ok "Created $RC"
        fi
        pkill -HUP -x labwc 2>/dev/null && ok "The desktop has picked it up"
      fi
    fi
  fi
fi

# 9 -------------------------------------------------------------------------
step "A simple address for the editor"
say "The dashboard is arranged from a web page on your phone or computer."
if [ "$ASSUME_YES" = 1 ]; then
  bash "$APP_DIR/scripts/setup-port-80.sh" --no </dev/null || warn "Port 80 not set up — the editor is on :8090"
else
  bash "$APP_DIR/scripts/setup-port-80.sh" <"$TTY" || warn "Port 80 not set up — the editor is on :8090"
fi

# ---- extras and the end ------------------------------------------------------

echo
# Only where polkit is what decides who may power off, as on Raspberry Pi OS.
if [ -d /etc/polkit-1/rules.d ] && ! [ -f /etc/polkit-1/rules.d/50-homecanvas-power.rules ]; then
  say "One more: HomeCanvas has Restart and Power off buttons in its Settings."
  if ask "Let them work without a password?" y; then
    run "Allowing restart and power off" sudo bash "$APP_DIR/deploy/enable-poweroff.sh" ||
      warn "Couldn't — see $LOG"
  fi
fi

# The editor's address: plain if port 80 is set up, with :8090 otherwise.
editor="http://$NAME.local:8090"
if [ "$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 1024)" -le 80 ] &&
  ! ss -ltnH '( sport = :80 )' 2>/dev/null | grep -qv '0.0.0.0:80'; then
  editor="http://$NAME.local"
fi

echo
echo "${G}${B}HomeCanvas is installed.${N}"
echo
say "Arrange the dashboard:  ${B}$editor${N}  (from any phone or computer at home)"
say "Update later:           ${B}bash $APP_DIR/install.sh${N}"
say "Its log:                /tmp/kiosk.log"
say "More to set up — Spotify, the weather, Home Assistant, sharing from your"
say "phone: ${B}$APP_DIR/INSTALL.md${N}, \"Optional setup\"."
echo
