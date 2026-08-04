#!/usr/bin/env python3
"""A small HTTP control surface for the kiosk display.

Home Assistant runs in a container and has no way to reach the host's Wayland
session, so it can't call `wlopm` itself. This runs on the host as the user who
owns that session and exposes the display over localhost instead. Keeping it
separate from the Flutter app means the screen can still be turned on when the
kiosk isn't running, and it survives Home Assistant image updates.

Endpoints (all GET, so Home Assistant's command_line can just curl them):

    /screen              current state as JSON
    /screen/on           power the panel back up
    /screen/off          power the panel down
    /screen/toggle
    /screen/brightness?value=0-100
    /media                  what the paired phone is playing
    /media/play             /media/pause     /media/playpause
    /media/next             /media/previous  /media/stop
    /media/volume?value=0-100
    /lva/restart             restart the voice satellite container

Binds to localhost only. Home Assistant uses host networking, so it can reach
this, but nothing off the machine can.
"""

import glob
import json
import os
import re
import selectors
import signal
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

LISTEN = ("127.0.0.1", 8765)

# Power changes and wakes are rare and worth a record — without one, working out
# why the screen did or didn't come back means catching it live. Routine state
# polling is not logged; Home Assistant does that every 30 seconds.
LOG = os.path.expanduser("~/.cache/immich_kiosk_pi/screen_control.log")
_log_lock = threading.Lock()


def log(message):
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + message + "\n"
    try:
        with _log_lock:
            os.makedirs(os.path.dirname(LOG), exist_ok=True)
            # Keep it small; this runs for months on a kiosk.
            if os.path.exists(LOG) and os.path.getsize(LOG) > 64_000:
                with open(LOG) as f:
                    tail = f.readlines()[-200:]
                with open(LOG, "w") as f:
                    f.writelines(tail)
            with open(LOG, "a") as f:
                f.write(line)
    except OSError:
        pass

# wlopm needs to talk to the compositor the kiosk user is logged into.
os.environ.setdefault("WAYLAND_DISPLAY", "wayland-0")
os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")


def _wlopm(args=()):
    return subprocess.run(
        ["wlopm", *args], capture_output=True, text=True, timeout=10
    ).stdout


def outputs():
    """Map of output name -> True when powered on, parsed from `wlopm`."""
    found = {}
    for line in _wlopm().splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] in ("on", "off"):
            found[parts[0]] = parts[1] == "on"
    return found


def set_output(on):
    """Power every output up or down."""
    flag = "--on" if on else "--off"
    for name in outputs():
        _wlopm([flag, name])
    return outputs()


# Brightness to come back to. Seeded from whatever the panel is showing now.
_restore_to = 100


def set_power(on, deep=False):
    """Turn the display off or on.

    "Off" means backlight to zero, leaving the output powered. That matters:
    cutting the DSI output also cuts power to the touch controller, so the panel
    stops reporting touches entirely and nothing short of another command can
    bring it back. Measured on this display — 13 touch events with the output
    on, none at all with it off.

    `deep` restores the old behaviour and genuinely powers the output down. It
    saves a little more, but the screen can then only be woken by Alexa or by
    /screen/on.
    """
    global _restore_to
    if on:
        set_output(True)
        set_brightness(_restore_to)
        log(f"on (brightness {_restore_to})")
    else:
        current = brightness()
        if current:
            _restore_to = current
        set_brightness(0)
        if deep:
            set_output(False)
        log("off deep - touch cannot wake this" if deep else "off (backlight 0)")
    return state()


def _backlight():
    paths = glob.glob("/sys/class/backlight/*/")
    return paths[0] if paths else None


def brightness():
    """Backlight as a percentage, or None when there's no backlight device."""
    path = _backlight()
    if not path:
        return None
    try:
        with open(path + "brightness") as f:
            current = int(f.read().strip())
        with open(path + "max_brightness") as f:
            maximum = int(f.read().strip())
        return round(current * 100 / maximum) if maximum else None
    except OSError:
        return None


def set_brightness(percent):
    path = _backlight()
    if not path:
        return None
    percent = max(0, min(100, percent))
    with open(path + "max_brightness") as f:
        maximum = int(f.read().strip())
    # Anything above zero should stay visible, so never round down to off.
    value = max(1, round(percent * maximum / 100)) if percent else 0
    with open(path + "brightness", "w") as f:
        f.write(str(value))
    return brightness()


def state():
    powered = outputs()
    level = brightness()
    return {
        # Visibly on: a powered output showing a lit backlight.
        "on": any(powered.values()) and (level is None or level > 0),
        "outputs": powered,
        "brightness": level,
        "restoreTo": _restore_to,
    }


# The Linux Voice Assistant container has a known, unresolved upstream bug
# (OHF-Voice/linux-voice-assistant issue #355): it silently stops hearing its
# wake word after playing a response, and the only known recovery is a
# restart. Home Assistant runs in its own container and has no way to run
# `docker compose` on the host, so — same pattern as the screen — an
# automation calls this endpoint instead.
#
# Signals the container's own process rather than going through `docker
# compose restart`: that needs the docker group, and a systemd --user service
# only has the groups its manager started with, not ones granted afterwards —
# the same trap the old wyoming-satellite watchdog hit trying to call `docker
# stats`. The container runs as this same uid (1000), so a plain SIGTERM needs
# no special permission at all, and its `restart: unless-stopped` policy
# brings it straight back up. Verified: killing the pid this way produces a
# genuinely fresh boot in the container's own log within ~7 seconds.
def restart_lva():
    pid = subprocess.run(
        ["pgrep", "-f", "linux_voice_assistant"],
        capture_output=True, text=True, timeout=10,
    ).stdout.split()
    if not pid:
        raise RuntimeError("linux_voice_assistant process not found")
    os.kill(int(pid[0]), signal.SIGTERM)
    log("restarted linux-voice-assistant (worked around known upstream deafness bug)")


class Handler(BaseHTTPRequestHandler):
    # The default handler logs every request to stderr, which would fill the
    # journal given Home Assistant polls this on a timer.
    def log_message(self, *args):
        pass

    def _reply(self, body, code=200):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path.rstrip("/") or "/"
        try:
            if path == "/screen":
                return self._reply(state())
            if path == "/screen/on":
                set_power(True)
                waker.note_power(True)
                return self._reply(state())
            if path == "/screen/off":
                deep = parse_qs(url.query).get("deep", ["0"])[0] not in ("0", "")
                set_power(False, deep=deep)
                waker.note_power(False)
                return self._reply(state())
            if path == "/screen/toggle":
                target = not state()["on"]
                set_power(target)
                waker.note_power(target)
                return self._reply(state())
            if path == "/media":
                return self._reply(media_state())
            if path.startswith("/media/"):
                action = path.rsplit("/", 1)[1]
                commands = {
                    "play": "Play", "pause": "Pause", "stop": "Stop",
                    "next": "Next", "previous": "Previous",
                    "playpause": "playpause",
                }
                if action == "volume":
                    raw = parse_qs(url.query).get("value", [None])[0]
                    if raw is None or not re.fullmatch(r"\d{1,3}", raw):
                        return self._reply({"error": "value must be 0-100"}, 400)
                    if set_volume(int(raw)) is None:
                        return self._reply(
                            {"error": "no active stream to set volume on"}, 409)
                    log(f"media volume {raw}")
                    return self._reply(media_state())
                if action not in commands:
                    return self._reply({"error": "unknown media command"}, 404)
                log(f"media {action}")
                return self._reply(media_command(commands[action]))
            if path == "/lva/restart":
                try:
                    restart_lva()
                except Exception as exc:  # noqa: BLE001
                    return self._reply({"error": str(exc)}, 500)
                return self._reply({"restarted": True})
            if path == "/screen/brightness":
                raw = parse_qs(url.query).get("value", [None])[0]
                if raw is None or not re.fullmatch(r"\d{1,3}", raw):
                    return self._reply({"error": "value must be 0-100"}, 400)
                global _restore_to
                value = int(raw)
                set_brightness(value)
                if value:
                    _restore_to = value
                return self._reply(state())
            self._reply({"error": "not found"}, 404)
        except Exception as exc:  # noqa: BLE001 - report, don't take the server down
            self._reply({"error": str(exc)}, 500)


# --- Media control -------------------------------------------------------
#
# The paired phone is controlled over Bluetooth AVRCP, which BlueZ exposes as
# org.bluez.MediaPlayer1. The kiosk app already does this for its now-playing
# widget, but that lives inside the Flutter app where Home Assistant can't reach
# it — so the same controls are offered here too. `busctl --json` avoids taking
# on a D-Bus library for six method calls.

MEDIA_IFACE = "org.bluez.MediaPlayer1"
TRANSPORT_IFACE = "org.bluez.MediaTransport1"

# AVRCP absolute volume is 0-127.
AVRCP_MAX_VOLUME = 127


def _busctl(args, parse=True):
    r = subprocess.run(
        ["busctl", "--system", "--json=short", *args],
        capture_output=True, text=True, timeout=10,
    )
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "busctl failed")
    if not parse or not r.stdout.strip():
        return None
    return json.loads(r.stdout)


def media_player():
    """D-Bus path of the connected phone's AVRCP player, or None.

    Found rather than configured: the path carries the phone's MAC, and which
    controller it connected on can change.
    """
    r = subprocess.run(
        ["busctl", "--system", "tree", "org.bluez"],
        capture_output=True, text=True, timeout=10,
    )
    found = re.findall(r"/org/bluez/hci\d+/dev_[A-F0-9_]+/player\d+", r.stdout)
    return found[0] if found else None


def media_transport():
    """Path of the active A2DP transport, or None.

    BlueZ only creates this while audio is actually streaming, so volume is
    unavailable when playback is paused — there is nothing to set it on.
    """
    r = subprocess.run(
        ["busctl", "--system", "tree", "org.bluez"],
        capture_output=True, text=True, timeout=10,
    )
    found = re.findall(r"/org/bluez/hci\d+/dev_[A-F0-9_]+/fd\d+", r.stdout)
    return found[0] if found else None


def get_volume():
    """Volume as 0-100, or None when nothing is streaming."""
    path = media_transport()
    if not path:
        return None
    try:
        raw = _busctl(["get-property", "org.bluez", path, TRANSPORT_IFACE,
                       "Volume"])["data"]
        return round(raw * 100 / AVRCP_MAX_VOLUME)
    except Exception:
        return None


def set_volume(percent):
    path = media_transport()
    if not path:
        return None
    percent = max(0, min(100, percent))
    raw = round(percent * AVRCP_MAX_VOLUME / 100)
    _busctl(["set-property", "org.bluez", path, TRANSPORT_IFACE, "Volume",
             "q", str(raw)], parse=False)
    return percent


def _prop(path, name):
    try:
        return _busctl(["get-property", "org.bluez", path, MEDIA_IFACE, name])["data"]
    except Exception:
        return None


def media_state():
    path = media_player()
    if not path:
        return {"connected": False}
    track = _prop(path, "Track") or {}
    def field(key):
        v = track.get(key)
        return v.get("data") if isinstance(v, dict) else None
    status = _prop(path, "Status")
    return {
        "connected": True,
        # AVRCP reports "playing", "paused", "stopped", "forward-seek"...
        "status": status,
        "playing": status == "playing",
        "title": field("Title"),
        "artist": field("Artist"),
        "album": field("Album"),
        "duration": field("Duration"),
        "position": _prop(path, "Position"),
        # None while paused: AVRCP volume lives on the streaming transport.
        "volume": get_volume(),
    }


def media_command(name):
    """Send one AVRCP command. Returns the state afterwards."""
    path = media_player()
    if not path:
        return {"connected": False}
    if name == "playpause":
        name = "Pause" if _prop(path, "Status") == "playing" else "Play"
    _busctl(["call", "org.bluez", path, MEDIA_IFACE, name], parse=False)
    # AVRCP takes a moment to report the new state back.
    time.sleep(0.4)
    return media_state()


def pointer_devices():
    """Event devices for the touchscreen (and any mouse).

    /proc/bus/input/devices lists a `Handlers=` line per device; pointer devices
    get a `mouse` handler, which on this Pi picks out the touch panel and
    nothing else. Deliberately excludes keyboard-style devices — the paired
    phone's AVRCP media keys appear as one, and a track change shouldn't wake
    the screen.
    """
    found = []
    try:
        with open("/proc/bus/input/devices") as f:
            blocks = f.read().split("\n\n")
    except OSError:
        return found
    for block in blocks:
        handlers = ""
        for line in block.splitlines():
            if line.startswith("H: Handlers="):
                handlers = line.split("=", 1)[1]
        if "mouse" not in handlers:
            continue
        for token in handlers.split():
            if token.startswith("event"):
                found.append("/dev/input/" + token)
    return found


class Waker:
    """Turns the screen back on when the panel is touched.

    Powering the output down stops the compositor drawing, and nothing brings it
    back on its own — without this the only way back is the HTTP endpoint or
    asking Alexa.
    """

    # Trust our own view of the power state between checks: while the screen is
    # on, touches stream in constantly and shelling out to wlopm per event would
    # be absurd. Re-read occasionally in case something else changed it.
    RECHECK = 30.0

    # Ignore input for a moment after powering down: a finger still resting on
    # the panel would otherwise wake it straight back up.
    SETTLE = 1.5

    def __init__(self):
        self._on = True
        self._checked = 0.0
        self._off_at = 0.0
        self._lock = threading.Lock()

    def note_power(self, on):
        """Record a state we set ourselves, so the watcher stays in step."""
        with self._lock:
            self._on = on
            self._checked = time.monotonic()
            if not on:
                self._off_at = time.monotonic()

    def _settling(self):
        with self._lock:
            return time.monotonic() - self._off_at < self.SETTLE

    def _is_on(self):
        with self._lock:
            fresh = time.monotonic() - self._checked < self.RECHECK
            if fresh:
                return self._on
        powered = state()["on"]
        self.note_power(powered)
        return powered

    def run(self):
        devices = pointer_devices()
        if not devices:
            return
        sel = selectors.DefaultSelector()
        opened = []
        for path in devices:
            try:
                fd = open(path, "rb", buffering=0)
            except OSError:
                continue  # Needs membership of the `input` group.
            opened.append(fd)
            sel.register(fd, selectors.EVENT_READ)
        if not opened:
            return
        while True:
            for key, _ in sel.select():
                # The content doesn't matter, only that input happened. Reading
                # also drains the buffer, which has to happen regardless.
                try:
                    key.fileobj.read(1024)
                except OSError:
                    continue
                if self._settling():
                    continue
                if not self._is_on():
                    log("touch detected while off - waking")
                    set_power(True)
                    self.note_power(True)


waker = Waker()


if __name__ == "__main__":
    # Come back to whatever the panel is set to now, not an arbitrary default.
    _restore_to = brightness() or 100
    devices = pointer_devices()
    log(f"started; watching {devices or 'NO POINTER DEVICES'} for touch")
    threading.Thread(target=waker.run, daemon=True).start()
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
