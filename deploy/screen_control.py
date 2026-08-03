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

Binds to localhost only. Home Assistant uses host networking, so it can reach
this, but nothing off the machine can.
"""

import glob
import json
import os
import re
import selectors
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

LISTEN = ("127.0.0.1", 8765)

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


def set_power(on):
    """Switch every output. Returns the state actually observed afterwards."""
    flag = "--on" if on else "--off"
    for name in outputs():
        _wlopm([flag, name])
    return outputs()


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
    return {
        "on": any(powered.values()),
        "outputs": powered,
        "brightness": brightness(),
    }


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
                set_power(False)
                waker.note_power(False)
                return self._reply(state())
            if path == "/screen/toggle":
                target = not state()["on"]
                set_power(target)
                waker.note_power(target)
                return self._reply(state())
            if path == "/screen/brightness":
                raw = parse_qs(url.query).get("value", [None])[0]
                if raw is None or not re.fullmatch(r"\d{1,3}", raw):
                    return self._reply({"error": "value must be 0-100"}, 400)
                set_brightness(int(raw))
                return self._reply(state())
            self._reply({"error": "not found"}, 404)
        except Exception as exc:  # noqa: BLE001 - report, don't take the server down
            self._reply({"error": str(exc)}, 500)


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
        powered = any(outputs().values())
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
                    set_power(True)
                    self.note_power(True)


waker = Waker()


if __name__ == "__main__":
    threading.Thread(target=waker.run, daemon=True).start()
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
