#!/usr/bin/env bash
# Interactively store Immich email+password into the TabletPi config (for the
# Locked Folder feature) and stage the Locked Folder PIN for a one-time test.
# Run on the Pi:  bash ~/set-immich-login.sh
set -e
CONFIG="$HOME/.config/tabletpi/config.json"
[ -f "$CONFIG" ] || { echo "Config not found at $CONFIG"; exit 1; }

read -rp "Immich email: " EMAIL
[ -n "$EMAIL" ] || { echo "Email is required"; exit 1; }
read -rsp "Immich password: " PW; echo
read -rp "Locked Folder PIN: " PIN

python3 - "$EMAIL" "$PW" "$PIN" "$CONFIG" <<'PY'
import json, sys
email, pw, pin, path = sys.argv[1:5]
d = json.load(open(path))
d["immichEmail"] = email
d["immichPassword"] = pw
json.dump(d, open(path, "w"), indent=2)
open("/tmp/lockpin", "w").write(pin)
print("OK: saved email+password to config; PIN staged at /tmp/lockpin")
PY
chmod 600 "$CONFIG"
