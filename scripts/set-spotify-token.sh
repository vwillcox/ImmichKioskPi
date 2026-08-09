#!/usr/bin/env bash
# Connect a Spotify account to the ImmichKioskPi config, so the now-playing
# panel can control it directly over the Web API.
#
# Create a free app at https://developer.spotify.com/dashboard, add
# http://127.0.0.1:8909/callback as a Redirect URI on it, then run this with
# that app's Client ID.
#
# This opens a real browser window ON THE KIOSK'S OWN SCREEN for the one-time
# Spotify login — there's no way around that step, since it needs your
# Spotify password, which nothing here ever sees or stores. Only the Client ID
# (not confidential) and a refresh token end up in the config.
#
# Run on the Pi:  bash ~/immich_kiosk_pi/scripts/set-spotify-token.sh <client_id>
set -e
CONFIG="$HOME/.config/immich_kiosk_pi/config.json"
[ -f "$CONFIG" ] || { echo "Config not found at $CONFIG"; exit 1; }

CLIENT_ID="${1:-}"
if [ -z "$CLIENT_ID" ]; then
  read -rp "Spotify Client ID: " CLIENT_ID
fi
[ -n "$CLIENT_ID" ] || { echo "Client ID is required"; exit 1; }

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

python3 - "$CLIENT_ID" "$CONFIG" <<'PY'
import base64
import hashlib
import http.server
import json
import pathlib
import secrets
import shutil
import string
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

CLIENT_ID, CONFIG_PATH = sys.argv[1], pathlib.Path(sys.argv[2])
REDIRECT_PORT = 8909
REDIRECT_URI = f"http://127.0.0.1:{REDIRECT_PORT}/callback"
SCOPES = ("user-read-playback-state user-modify-playback-state "
          "user-read-currently-playing")

alphabet = string.ascii_letters + string.digits


def random_string(n):
    return "".join(secrets.choice(alphabet) for _ in range(n))


# PKCE per RFC 7636: base64url(SHA-256(verifier)), no padding. Matches the
# same computation (and the same RFC worked example) the kiosk app itself
# uses and tests against.
verifier = random_string(64)
challenge = base64.urlsafe_b64encode(
    hashlib.sha256(verifier.encode("ascii")).digest()
).decode().rstrip("=")
state = random_string(16)

auth_url = "https://accounts.spotify.com/authorize?" + urllib.parse.urlencode({
    "client_id": CLIENT_ID,
    "response_type": "code",
    "redirect_uri": REDIRECT_URI,
    "code_challenge_method": "S256",
    "code_challenge": challenge,
    "scope": SCOPES,
    "state": state,
})

result = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        result["code"] = qs.get("code", [None])[0]
        result["state"] = qs.get("state", [None])[0]
        result["error"] = qs.get("error", [None])[0]
        ok = result["error"] is None and result["state"] == state
        body = (
            "<html><body style='background:#111;color:#eee;"
            "font-family:sans-serif;display:flex;align-items:center;"
            "justify-content:center;height:100vh;margin:0'>"
            f"<div style='text-align:center'><h2>{'Spotify connected' if ok else 'Something went wrong'}</h2>"
            f"<p>{'You can close this window.' if ok else 'Go back and try again.'}</p></div>"
            "</body></html>"
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", REDIRECT_PORT), Handler)
# Handles exactly one request then returns — there's only one redirect to
# catch, so no need for serve_forever()/an explicit shutdown.
thread = threading.Thread(target=server.handle_request, daemon=True)
thread.start()

print("Opening a browser on this screen for the Spotify login...")
# Not xdg-open: on this bare labwc session (no full desktop environment)
# Chromium's default ozone platform detection picks X11 and fails outright
# with "Missing X server or $DISPLAY", and even once told to use Wayland it
# blocks on a GNOME-Keyring "choose a password" prompt that has nothing to
# do with Spotify. Both are suppressed by these flags. Falls back to
# xdg-open on a machine where chromium isn't the browser.
if shutil.which("chromium"):
    browser_cmd = ["chromium", "--ozone-platform=wayland",
                   "--password-store=basic", "--new-window", auth_url]
else:
    browser_cmd = ["xdg-open", auth_url]
try:
    subprocess.Popen(browser_cmd)
except OSError as e:
    sys.exit(f"Could not open a browser: {e}")

print("Log in and approve access. Waiting up to 3 minutes...")
deadline = time.time() + 180
while "code" not in result and time.time() < deadline:
    time.sleep(0.5)
server.server_close()

if "code" not in result:
    sys.exit("Timed out waiting for the Spotify login.")
if result.get("error"):
    sys.exit(f"Spotify said: {result['error']}")
if result.get("state") != state:
    sys.exit("Redirect did not match — try again.")
code = result.get("code")
if not code:
    sys.exit("Spotify did not return an authorization code.")

try:
    req = urllib.request.Request(
        "https://accounts.spotify.com/api/token",
        data=urllib.parse.urlencode({
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": REDIRECT_URI,
            "client_id": CLIENT_ID,
            "code_verifier": verifier,
        }).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        tokens = json.load(r)
except urllib.error.HTTPError as e:
    sys.exit(f"Spotify rejected the exchange: {e.read().decode()[:300]}")

refresh_token = tokens.get("refresh_token")
if not refresh_token:
    sys.exit("Spotify did not return a refresh token.")

data = json.loads(CONFIG_PATH.read_text())
spotify = data.setdefault("spotify", {})
spotify["clientId"] = CLIENT_ID
spotify["refreshToken"] = refresh_token
CONFIG_PATH.write_text(json.dumps(data, indent=2))
print("Spotify connected and saved.")
PY

chmod 600 "$CONFIG"
systemctl --user restart immich_kiosk_pi.service 2>/dev/null && echo "Kiosk restarted."
