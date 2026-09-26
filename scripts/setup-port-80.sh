#!/usr/bin/env bash
# Puts the HomeCanvas editor on port 80, so its address is simply
# http://homecanvas.local — and, when Home Assistant's Alexa bridge
# (emulated_hue) already has port 80, offers to share it.
#
# Run ON THE PI, as your normal user (it asks for sudo once):
#   bash scripts/setup-port-80.sh          set up, or check it is set up
#   bash scripts/setup-port-80.sh --yes    the same, sharing with Alexa's
#                                          bridge without asking (unattended)
#   bash scripts/setup-port-80.sh --no     the same, never sharing
#   bash scripts/setup-port-80.sh --undo   give port 80 back to Home Assistant
#
# pi-setup.sh runs this at the end. Safe to run again at any time.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_CONFIG="$HOME/.config/homecanvas/config.json"
BACKUP="$HOME/configuration.yaml.before-port-80"
HUE_PORT=8300
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

MODE="${1:-}"
case "$MODE" in
  "" | --yes | --no | --undo) ;;
  *)
    echo "Usage: bash $0 [--yes | --no | --undo]"
    exit 2
    ;;
esac

say() { echo "==> $*"; }
ask() {
  # --yes and --no answer for you. Otherwise yes only on a y or yes;
  # anything else, or no terminal to ask at, is no.
  local reply=""
  [ "$MODE" = --yes ] && return 0
  [ "$MODE" = --no ] && return 1
  [ -t 0 ] || return 1
  read -r -p "$1 [y/N] " reply || return 1
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---- what is where --------------------------------------------------------

# The address:port of whatever is listening on port 80, or nothing.
port80_listener() {
  ss -ltnH '( sport = :80 )' 2>/dev/null | awk '{print $4}' | head -1
}

# Whether a Hue bridge — emulated_hue, or a real one — answers at $1.
is_hue_bridge() {
  curl -s -m 4 "http://$1/description.xml" 2>/dev/null |
    grep -qiE 'philips|hue bridge|Home Assistant Bridge'
}

# Home Assistant's configuration.yaml, found through its container's /config
# mount when it runs in Docker, else the usual places.
ha_config() {
  local c src
  for c in $(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null |
    awk '/home-assistant|homeassistant/ {print $1}'); do
    src=$(docker inspect "$c" --format \
      '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
    if [ -n "$src" ] && [ -f "$src/configuration.yaml" ]; then
      echo "$src/configuration.yaml"
      return
    fi
  done
  for c in /config "$HOME/.homeassistant" /home/homeassistant/.homeassistant; do
    if [ -f "$c/configuration.yaml" ]; then
      echo "$c/configuration.yaml"
      return
    fi
  done
}

ha_container() {
  docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null |
    awk '/home-assistant|homeassistant/ {print $1; exit}'
}

restart_ha() {
  local c
  c=$(ha_container)
  if [ -n "$c" ]; then
    say "Restarting Home Assistant ($c)…"
    docker restart "$c" >/dev/null
  else
    say "Restart Home Assistant yourself now — it isn't a container I can find."
  fi
}

# Writes over a file in place — its folder may be root's even when the file
# is not — with sudo only if it must.
overwrite() {
  if [ -w "$1" ]; then cat >"$1"; else sudo tee "$1" >/dev/null; fi
}

# Sets dashboard.webPort and dashboard.hueRelay in HomeCanvas's settings,
# with HomeCanvas stopped so it cannot save over them.
set_app() {
  local relay="$1"
  if [ ! -f "$APP_CONFIG" ]; then
    say "HomeCanvas has no settings yet — start it once, then run this again."
    return 1
  fi
  systemctl --user stop homecanvas.service 2>/dev/null || true
  RELAY="$relay" python3 - "$APP_CONFIG" <<'PY'
import json, os, sys
p = sys.argv[1]
c = json.load(open(p))
d = c.setdefault("dashboard", {})
d["webPort"] = 80
d["hueRelay"] = os.environ["RELAY"]
json.dump(c, open(p, "w"), indent=2)
PY
  systemctl --user start homecanvas.service 2>/dev/null || true
}

# ---- port 80 for an ordinary user -----------------------------------------

allow_port_80() {
  if [ "$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start)" -le 80 ]; then
    return
  fi
  say "Letting HomeCanvas use port 80 (needs sudo, once)…"
  sudo bash "$HERE/deploy/enable-port-80.sh" >/dev/null
}

# ---- undo -----------------------------------------------------------------

if [ "$MODE" = "--undo" ]; then
  config=$(ha_config || true)
  if [ -f "$BACKUP" ] && [ -n "$config" ]; then
    say "Putting Home Assistant's config back from $BACKUP"
    overwrite "$config" <"$BACKUP"
    restart_ha
  fi
  if [ -f "$APP_CONFIG" ]; then
    systemctl --user stop homecanvas.service 2>/dev/null || true
    python3 - "$APP_CONFIG" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
d = c.setdefault("dashboard", {})
d["webPort"] = 0
d["hueRelay"] = ""
json.dump(c, open(p, "w"), indent=2)
PY
    systemctl --user start homecanvas.service 2>/dev/null || true
  fi
  say "Done: the editor is back on :8090 only."
  exit 0
fi

# ---- set up ---------------------------------------------------------------

allow_port_80
listener=$(port80_listener)

if [ -z "$listener" ]; then
  say "Port 80 is free — HomeCanvas takes it when it starts."
  say "The editor will be at http://$(hostname).local"
  exit 0
fi

# Something is there. Look at it by its own address; 0.0.0.0 or * means any.
probe="${listener%:80}"
case "$probe" in 0.0.0.0 | '*' | '[::]' | '::') probe=127.0.0.1 ;; esac

if ! is_hue_bridge "$probe"; then
  say "Something other than a Hue bridge is on port 80 ($listener)."
  say "Leaving it alone — the editor stays at http://$(hostname).local:8090"
  exit 0
fi

# Already shared? Then HomeCanvas is what answers, and relays the bridge.
# /api/volume is quick, and only HomeCanvas answers it.
if grep -q '"hueRelay": "http' "$APP_CONFIG" 2>/dev/null &&
  curl -s -m 4 "http://$probe/api/volume" | grep -q '"dnd"'; then
  say "Already set up: HomeCanvas has port 80 and relays Alexa's Hue bridge."
  exit 0
fi

# Moving the bridge before HomeCanvas can relay it would leave Alexa with
# nothing on port 80, so HomeCanvas must have run once first.
if [ ! -f "$APP_CONFIG" ]; then
  say "Port 80 is Home Assistant's Alexa bridge. HomeCanvas can share it,"
  say "but only once it has started for the first time — run this again then:"
  say "  bash scripts/setup-port-80.sh"
  exit 0
fi

echo
echo "Port 80 belongs to a Hue bridge — Home Assistant's emulated_hue, which"
echo "Alexa uses to find its devices. Alexa only talks to port 80, so it can't"
echo "just move."
echo
echo "HomeCanvas can share it: emulated_hue moves to port $HUE_PORT but still"
echo "tells Alexa to use 80, and HomeCanvas passes Alexa's requests on to it."
echo "Your Alexa devices keep working; Home Assistant restarts once."
echo
if ! ask "Share port 80 with Home Assistant's Alexa bridge?"; then
  say "Left as it is — the editor stays at http://$(hostname).local:8090"
  exit 0
fi

config=$(ha_config || true)
if [ -z "$config" ]; then
  say "Couldn't find Home Assistant's configuration.yaml — see INSTALL.md,"
  say "\"The editor on port 80\", to make the change by hand."
  exit 1
fi

# The one line that changes: `listen_port: 80` inside emulated_hue.
edited=$(mktemp)
trap 'rm -f "$edited"' EXIT
host=$(python3 - "$config" "$HUE_PORT" "$edited" <<'PY'
import re, sys
path, port, dest = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().split("\n")
out, inside, done, host = [], False, False, ""
for line in lines:
    if re.match(r"^emulated_hue:\s*$", line):
        inside = True
    elif inside and line and not line[0].isspace():
        inside = False
    m = re.match(r"^(\s+)listen_port:\s*80\s*$", line) if inside else None
    h = re.match(r"^\s+host_ip:\s*(\S+)", line) if inside else None
    if h:
        host = h.group(1)
    if m and not done:
        out.append(f"{m.group(1)}# HomeCanvas has port 80 and relays Alexa here.")
        out.append(f"{m.group(1)}listen_port: {port}")
        out.append(f"{m.group(1)}advertise_port: 80")
        done = True
    else:
        out.append(line)
if not done:
    sys.exit(3)
open(dest, "w").write("\n".join(out))
print(host)
PY
) || {
  say "emulated_hue in $config has no 'listen_port: 80' to move — see"
  say "INSTALL.md, \"The editor on port 80\", to make the change by hand."
  exit 1
}
cp "$config" "$BACKUP"
say "Backed up Home Assistant's config to $BACKUP"
overwrite "$config" <"$edited"
say "emulated_hue now listens on $HUE_PORT and tells Alexa 80."
restart_ha

relay="http://${host:-127.0.0.1}:$HUE_PORT"
say "Switching HomeCanvas on for port 80, relaying Alexa to $relay…"
set_app "$relay"

# Home Assistant takes a little while to come back.
for _ in $(seq 1 45); do
  curl -s -m 2 "http://$probe/description.xml" | grep -qi 'hue\|philips' && break
  sleep 2
done
if is_hue_bridge "$probe"; then
  say "Done. The editor is at http://$(hostname).local, and Alexa's bridge"
  say "answers through it. Try \"Alexa, turn off the kiosk screen\"."
else
  say "HomeCanvas has port 80, but the bridge isn't answering through it yet —"
  say "give Home Assistant a minute. To undo: bash scripts/setup-port-80.sh --undo"
fi
