#!/usr/bin/env bash
# Store a Home Assistant long-lived access token in the ImmichKioskPi config,
# so the kiosk can read the indoor temperature from Home Assistant.
#
# Create the token in Home Assistant: click your user name (bottom left) ->
# Security -> Long-lived access tokens -> Create token.
#
# Run on the Pi:  bash ~/immich_kiosk_pi/scripts/set-ha-token.sh
set -e
CONFIG="$HOME/.config/immich_kiosk_pi/config.json"
[ -f "$CONFIG" ] || { echo "Config not found at $CONFIG"; exit 1; }

# Read silently: the token is a credential and shouldn't land in scrollback.
read -rsp "Home Assistant long-lived access token: " TOKEN; echo
[ -n "$TOKEN" ] || { echo "Token is required"; exit 1; }

read -rp "Home Assistant URL [http://localhost:8123]: " URL
URL="${URL:-http://localhost:8123}"

python3 - "$TOKEN" "$URL" "$CONFIG" <<'PY'
import json, sys, urllib.request, urllib.error

token, url, path = sys.argv[1:4]
url = url.rstrip("/")

d = json.load(open(path))
ha = d.setdefault("homeAssistant", {})
ha["baseUrl"] = url
ha["token"] = token
ha.setdefault("temperatureEntity", "")
ha.setdefault("humidityEntity", "")
ha.setdefault("batteryEntity", "")

# Check the token works before saving it, so a typo is caught here rather than
# showing up later as a silently missing temperature.
req = urllib.request.Request(
    f"{url}/api/", headers={"Authorization": f"Bearer {token}"}
)
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        json.load(r)
except urllib.error.HTTPError as e:
    sys.exit(f"Home Assistant rejected the token (HTTP {e.code}). Not saved.")
except Exception as e:
    sys.exit(f"Could not reach Home Assistant at {url}: {e}. Not saved.")

entity = ha.get("temperatureEntity")
if entity:
    req = urllib.request.Request(
        f"{url}/api/states/{entity}", headers={"Authorization": f"Bearer {token}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            print(f"OK: {entity} currently reads {json.load(r)['state']}")
    except Exception as e:
        print(f"Warning: token works, but {entity} could not be read: {e}")
else:
    print("Note: no temperature entity set yet (Settings -> Home Assistant).")

json.dump(d, open(path, "w"), indent=2)
print("Token saved.")
PY

chmod 600 "$CONFIG"
systemctl --user restart immich_kiosk_pi.service 2>/dev/null && echo "Kiosk restarted."
