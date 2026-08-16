# ImmichKioskPi — the long version

Everything that doesn't belong on the [README](README.md): each optional
feature, the technical detail behind the awkward parts, and the notes that
explain why something is the way it is rather than the obvious way.

- [What's new on this branch](#whats-new-on-this-branch)
- [Known issues](#known-issues)
- [Optional setup](#optional-setup)
  - [Power-off button](#power-off-button)
  - [Now playing from your phone](#now-playing-from-your-phone)
  - [Spotify](#spotify)
  - [The widget dashboard](#the-widget-dashboard)
  - [Share Inbox](#share-inbox)
  - [A phone as a wireless camera](#a-phone-as-a-wireless-camera)
  - [Indoor temperature sensor](#indoor-temperature-sensor)
  - [Turning the screen off with Alexa](#turning-the-screen-off-with-alexa)
  - [Turning the screen off by itself](#turning-the-screen-off-by-itself)
  - [TV Remote](#tv-remote)
  - [Locked Folder](#locked-folder)
- [Gestures](#gestures)
- [Settings](#settings)
- [Development](#development)
- [Troubleshooting](#troubleshooting)
- [Third-party libraries](#third-party-libraries)
- [Credits and sources](#credits-and-sources)

---

## What's new on this branch

Work in progress on `pullMessages`, not yet merged to `main`.

**A widget dashboard**
- Clock, weather, calendar, RSS news, Spotify and a TV remote on a 12×8 grid,
  arranged from a browser on the local network with a live preview that renders
  real content rather than placeholders.
- Five built-in themes plus a JSON template for your own, twenty OFL-licensed
  fonts, per-widget font and size, optional shadows and square corners.
- The widget registry is open: a new type declares its options and its preview,
  and the editor builds its own UI from that.

**End-to-end encrypted shares**
- Shares are sealed with a fresh X25519 key pair per message (HKDF-SHA256 +
  ChaCha20-Poly1305), so a reverse proxy that terminates TLS sees only bytes.
- The panel's identity key rotates weekly, keeping the previous one for a
  further period so a phone that cached the old key mid-rotation still works.
- Both ends show it: the phone displays the panel's key fingerprint and a
  padlock per message; the panel logs which of the two kinds it received.

**Senders managed from a web page**
- Add and revoke per-device tokens from a page the panel serves on the local
  network only, instead of typing them on the touchscreen.

**Firefox as the kiosk's browser**
- Stronger tracker blocking by default, and cookie-banner rejection — which
  matters more on a wall panel than a desktop, since there is often nobody
  standing there to answer a consent dialog.
- Touch works because Firefox is launched as a **native Wayland client**. The
  usual advice, `MOZ_USE_XINPUT2=1`, is X11-only and does nothing; under
  XWayland the events never arrive at all.

**A phone as a wireless camera**
- An old Android phone running IP Webcam becomes a camera; a corner window
  opens full screen on a tap, where pinching drives the phone's sensor zoom.

**Spotify**
- Device switcher, queue view, and browse panels for playlists, recently played
  and top tracks.
- A local librespot patch fixing transfers *off* the kiosk landing on the wrong
  track — see [`patches/`](patches/).
- Rate limiting honours Spotify's `Retry-After` per endpoint instead of
  hammering through 429s.

**Screen and overlays**
- Turns itself off when nothing is playing, no slideshow is running and nobody
  has touched it; a touch, music, or an incoming share brings it back.
- Weather, now playing and the camera window each pick a corner, and two can
  never end up in the same one — moving onto an occupied corner swaps the pair.

---

## Known issues

**Camera**
- The Pi 5 has no hardware H.264 decoder, so the stream is decoded in software
  — roughly half a core at 1080p25. Dropping the phone to 720p in Settings →
  Camera roughly halves that.
- **IP Webcam has no login by default** — set one, or the stream is open to
  anything on your network.
- **Enable "start server on boot" in IP Webcam**, or nothing serves after the
  phone reboots and the kiosk simply waits.
- Zoom is a sensor crop, not optical. On phones with a periscope lens that lens
  is not reachable by any third-party app, so zooming gains framing, not detail.
- If the phone's app is force-stopped abruptly enough times it leaks its client
  slots and then accepts connections while sending nothing. Force-stopping and
  reopening it clears that.

**Browser**
- Firefox's built-in cookie-banner blocking is patchy; banners on sites it has
  no rule for still appear on a first visit. `sudo apt install
  webext-ublock-origin-firefox` catches far more.
- Firefox's real `--kiosk` flag is deliberately **not** used: it takes the whole
  screen and ignores any geometry asked of it, which would bury the kiosk's own
  close button. The chrome is hidden with `userChrome.css` instead.

**Spotify**
- A Development Mode app can't use the batch endpoints, browse/categories or
  artist top-tracks, and search is capped at 10 results. Extended Quota Mode
  lifts these.
- Spotify Connect can't carry lossless, so the kiosk device is capped at
  320 kbps — a Spotify-side limit, not a librespot one.
- The librespot fix in [`patches/`](patches/) is applied to a local build; it
  isn't upstream.

**Deployment**
- `deploy/labwc-autostart` doesn't start `vidaa_remote.service`, which a live
  install may rely on. Merge rather than overwrite if you use the TV remote.
- Nothing on the Pi keeps a journal for user units, so the app's output is
  discarded unless a `StandardOutput=` drop-in is added — see
  [Development](#development).

---

## Optional setup

### Power-off button

To let the in-app **Restart** and **Power off** buttons work without a password
prompt, run once on the Pi:

```bash
sudo bash deploy/enable-poweroff.sh
```

### Now playing from your phone

The now-playing panel reads Bluetooth **AVRCP**, so it works with whatever app
your phone is using — no accounts or API keys.

Pair the phone with the Pi once:

```bash
bluetoothctl
# then, at the prompt:
#   power on
#   agent NoInputNoOutput
#   default-agent
#   pairable on
#   discoverable on
# accept the passkey on both the phone and here, then:
#   trust <PHONE_MAC>
```

Play something on the phone with **media audio** routed to the Pi. The panel
appears in the slideshow; tap it to expand, tap again to shrink.

> **Trade-off worth knowing:** AVRCP metadata rides along with the Bluetooth
> audio stream, so the phone's audio plays through the **Pi**, not the phone.
> That's inherent to this approach, not a choice of implementation.

#### Using headphones on the phone

If you'd rather the music kept playing on the phone — Bluetooth headphones, its
own speaker — turn **Settings → Now playing → "Play the audio on this device"**
off. The Pi stops acting as an audio sink, but the panel keeps showing the track
and the controls still work: this display becomes a pure remote.

That works because AVRCP's control channel is independent of the A2DP audio
stream, so `org.bluez.MediaPlayer1` survives with the audio profile switched
off. The setting is re-applied whenever the phone reconnects, since PipeWire
turns the audio profile back on by itself.

With the setting on, PipeWire routes the incoming stream to whatever output is
active. Check the link with:

```bash
pw-link -l | grep bluez
```

(`pactl` may not be installed on Raspberry Pi OS; `pw-link` and `wpctl` are the
PipeWire tools that are.)

Two things that look like faults but aren't: those links only exist while audio
is **actively streaming**, so a paused track shows none; and `wpctl inspect` can
report a stale `bluez5.profile`. Neither is a reliable way to tell whether audio
routing is enabled — the setting itself is the source of truth.

The volume slider sets **AVRCP absolute volume**, i.e. the level the phone is
sending — the same control as the phone's own volume buttons. It is not a local
mixer level for the Pi's output.

Album artwork isn't part of AVRCP, so it's looked up from the free
[iTunes Search API](https://performance-partners.apple.com/search-api) using the
artist and track name. Searching by track is markedly more reliable than by
album, because AVRCP album strings often carry suffixes like
`(Deluxe Version) [Explicit]`.

### Spotify

Two independent features — set up either or both.

#### Web API control (like, playlists, controlling whatever's already playing)

With Spotify Premium the now-playing panel can control Spotify directly over the
**Web API** instead of the generic AVRCP path — proper seek, shuffle, repeat,
volume, **like/unlike**, and **add to a playlist**, on whichever Connect device
is actually active. It's shown in preference to AVRCP whenever Spotify has
something active, and falls back the rest of the time.

This is a control layer only — audio comes from wherever Spotify is already
playing, unless that's also the Pi.

**Setup**, in Settings → Spotify:

1. Create a free app at the
   [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Add `http://127.0.0.1:8909/callback` as a Redirect URI.
3. Paste the **Client ID** and tap **Connect**. A browser window opens on the
   Pi's own screen for the one-time login; a small local server catches the
   redirect and finishes automatically.

No client secret is needed or stored — the login uses OAuth Authorization Code
with PKCE. If you connected before liking/playlists existed, tap **Reconnect**
once: an existing refresh token doesn't gain scopes it wasn't granted.

> Spotify replaced several library/playlist endpoints in February 2026 (the old
> per-type `/me/tracks` and `/playlists/{id}/tracks` now 403 silently); this
> integration uses the current `/me/library` and `/playlists/{id}/items`.

#### Spotify Connect device (play audio directly on the Pi)

The Pi can appear as its own device — **"Kiosk"** — in Spotify's Connect picker.
Picking it streams audio straight to the Pi; no Bluetooth pairing, no OAuth.

Powered by [librespot](https://github.com/librespot-org/librespot). The easiest
way to get the binary is the [raspotify](https://github.com/dtcooper/raspotify)
package, but its own systemd service runs as root against ALSA directly, which
fights with PipeWire. Use it only for the binary, then run librespot yourself as
a **user** service:

```bash
sudo apt-get -y install curl
curl -sL https://dtcooper.github.io/raspotify/install.sh | sudo sh
sudo systemctl disable --now raspotify

mkdir -p ~/.config/systemd/user ~/.cache/librespot
cp ~/immich_kiosk_pi/deploy/librespot.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now librespot.service
```

Requires Spotify Premium, as librespot itself does.

**On transferring playback away from the kiosk:** stock librespot restarts the
track from the beginning when you move playback from "Kiosk" to another device,
if you're playing from a large context like Liked Songs — an
[upstream bug](https://github.com/librespot-org/librespot/issues/1459) open
since January 2025. [`patches/`](patches/) carries a fix, with the cause and how
to build it.

**On audio quality:** the unit passes `--bitrate 320`, the highest Ogg Vorbis
quality Connect carries (the default is 160 without it). True lossless isn't
reachable on any Connect device — Spotify's Lossless tier only streams inside
its own apps, over a different pipeline entirely.

### The widget dashboard

An alternate screen mode: clock, weather, calendar, RSS news, Spotify and a TV
remote on a 12×8 grid. Reach it from the home screen's toolbar; the back arrow
in the corner returns you.

Arrange it from a browser on the same network — by default `http://<pi>:8090`.
The editor shows a live preview that renders real content rather than
placeholders, so what you lay out is what appears on the panel.

- **Themes** — five built in (midnight, paper, ember, forest, nightstand). Drop
  your own JSON in `~/.config/immich_kiosk_pi/themes/`; see
  [`deploy/theme-template.json`](deploy/theme-template.json).
- **Fonts** — twenty OFL-licensed faces in four groups, twelve sizes, set per
  widget.
- **Weather** — current conditions on their own, a 5/7/14-day forecast, or both.
- **Calendar** — month or schedule view, several ICS URLs, a colour per source.
- **News** — several feeds blended by a recency-and-fairness score so one busy
  feed can't crowd out the rest; tap an item to read it.
- **Spotify** — artwork that repositions with the tile's shape, a fade like the
  full player's, and transport controls sized for a quick tap.
- **Speed test** — see below.

#### Pages

A dashboard can have several pages. Use **+ Page** in the editor, then move a
widget across with the **Page** dropdown in its settings — dragging does not
cross a page break.

Two ways to turn them, and they combine:

- **Flip every _n_ seconds** turns the page on a timer. 0 leaves it manual, and
  anything under 3 is floored, since a config typo would otherwise make the
  panel strobe.
- **Tap to flip** turns the page when you tap the background. Off by default:
  a dashboard full of tappable widgets would otherwise change page every time
  you pressed one. The tap only counts when it lands on empty grid — the
  widget under your finger gets it first.

Swiping sideways always works regardless of either setting, and the dots along
the bottom show where you are and jump straight to a page. A manual turn
restarts the timer, so a page you just chose is not whipped away.

Pages are inferred from the widgets rather than stored as a count, so a page
cannot claim to exist after its last widget has been deleted or moved off it.

#### Speed test

Runs [Ookla's speedtest CLI](https://www.speedtest.net/apps/cli) and shows it
happening: ping first, then download on the outer ring of the dial, upload on
the inner one, with the live figure in the middle. Tap to start, tap again to
cancel.

Both speeds share **one dial**, because the pair is the interesting thing — a
line is "200 down, 20 up", and reading that off two gauges makes you do the
comparison yourself.

The scale is **logarithmic**, one power of ten per equal sweep. A linear dial
calibrated for a gigabit line squashes everything under about 50 Mbps into the
first few degrees, so 20 Mbps and 2 Mbps look identical — which is exactly when
you are looking at it.

Install the CLI first. It needs no root:

```bash
curl -fsSL -o /tmp/st.tgz \
  https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz
mkdir -p ~/.local/bin && tar xzf /tmp/st.tgz -C /tmp speedtest
install -m755 /tmp/speedtest ~/.local/bin/speedtest
```

> Use Ookla's own binary, not Debian's `speedtest-cli` package. That is a
> different program with different output entirely, and this widget reads
> Ookla's `--format=jsonl` stream — one JSON object per line as the test runs,
> which is what makes a live display possible. Ookla's `--format=json` prints
> nothing at all until the test has finished.

Bandwidth arrives as **bytes per second** and is converted to megabits here.
Getting that wrong is the classic way to report a line as an eighth of its real
speed.

Set **Run automatically every (hours)** to have it test on its own; 0 leaves it
manual. Each run moves a few hundred megabytes, so keep it well spaced on a
metered connection.

### Share Inbox

Anyone with the companion Android app (`companion_app/`) can share a photo, GIF,
video, web link or note to the kiosk from any app's share sheet.

There's no relay: the kiosk runs its own small HTTP listener. Getting that
listener reachable from wherever the app is — same Wi-Fi, or the whole internet
— is your own networking concern: a port forward, a reverse proxy, whatever you
already run. The kiosk only needs to know which local port to bind.

**Setup**, in Settings → Share Inbox:

1. Set the listen port (defaults to 8081) and point your router or reverse proxy
   at it.
2. Add a name for each person — this generates a token. Hand it over as you
   would a Wi-Fi password, to enter in their copy of the app alongside the
   kiosk's address. There's also a web page for this, on the local network only,
   at `http://<pi>:8090/senders`.
3. Shares show up attributed, with a chime and a corner notification. Photos and
   GIFs open in the pinch-zoom viewer, videos in the player, notes full-screen
   in large type, and links in a browser window.

The chime plays through its own player, so its volume is independent of whatever
else is playing. A **Do Not Disturb** switch in the top bar mutes it.

#### Reading notes aloud

**Settings → Share Inbox → Read notes aloud** speaks incoming text notes, with
"Message from <name>" first unless you turn that off.

Text only. A photo has nothing to read, and a link spoken aloud is a stream of
letters nobody can follow — the chime already says something arrived and the
screen says what it was. A URL inside a note becomes "a link", and anything
past 600 characters is cut short with "and there is more on screen" rather
than trapping you in a recital.

Speech has its own volume, defaulting to **45%** — deliberately below the
chime and the music. A voice at the same level as music is startling in a
quiet room: it arrives unannounced rather than being something you chose to
play. Do Not Disturb silences it along with the chime.

It uses [piper](https://github.com/rhasspy/piper), a neural text-to-speech
engine that runs locally — measured on this Pi 5 at a real-time factor of
about 0.16, so a sentence is synthesised in roughly a sixth of the time it
takes to say. Local rather than a cloud voice for the same reason as
everything else here: a note somebody shares to this panel is private, and
reading it out should not mean sending it anywhere.

Install it and a voice; neither needs root:

```bash
mkdir -p ~/.local/share/piper ~/.local/bin && cd ~/.local/share/piper
curl -fsSL -o piper.tgz \
  https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_aarch64.tar.gz
tar xzf piper.tgz && rm piper.tgz
ln -sf ~/.local/share/piper/piper/piper ~/.local/bin/piper

V=https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/jenny_dioco/medium
curl -fsSL -o voice.onnx      $V/en_GB-jenny_dioco-medium.onnx
curl -fsSL -o voice.onnx.json $V/en_GB-jenny_dioco-medium.onnx.json
```

That is a British female voice. Any piper voice works — swap the two files,
keeping the names `voice.onnx` and `voice.onnx.json`. Without them the setting
does nothing and the panel carries on as before; speech is a nicety, not a
dependency.

> Do **not** `apt install piper`. Debian's package of that name is a GTK
> configurator for gaming mice, which shares the name and does nothing useful
> here. Debian does package `espeak-ng`, which is a real synthesiser but plainly
> robotic — acceptable in a headset, less so read aloud in a room.

#### End-to-end encryption

Shares reaching the kiosk from outside pass through whatever proxy you put in
front of it, which terminates TLS and can therefore read every message. TLS
protects the wire and nothing else, so the payload is sealed as well.

The panel holds a long-lived X25519 identity key and publishes the public half
at `GET /pubkey`. To send, the phone generates a **fresh key pair for that one
message**, does X25519 against the panel's key, and derives a one-message key
with HKDF-SHA256. The body is ChaCha20-Poly1305 in 64 KiB chunks, each binding
its index and a final-flag into the AAD, so chunks can't be reordered, dropped,
repeated, or the message truncated.

A new key per message is a stronger reading of "rotate often" than any schedule:
there's no long-lived message key to capture, and taking the panel's identity key
later decrypts nothing sent before it. The identity key rotates weekly on top of
that, keeping the previous one for a further period so a phone that cached the
old key mid-rotation isn't rejected.

**What it deliberately does not do.** It doesn't prove *who* sent a message —
anyone with the public key can seal one, and authorship still rests on the bearer
token. Nor does it protect content from anyone with a shell on the Pi, since the
identity key is a file there. The threat addressed is the path in between, not
the endpoints.

Set `requireEncryption` in `config.json` to reject anything unsealed with a 412,
once every phone is on a version that encrypts.

### A phone as a wireless camera

An old Android phone running
[IP Webcam](https://play.google.com/store/apps/details?id=com.pas.webcam) becomes
a camera. A button in the top bar opens a small corner window; tapping that opens
it full screen, where pinching zooms the phone's sensor rather than enlarging the
picture here. Settings → Camera holds the address, credentials, stream size and
position.

The picture comes over **RTSP (H.264)**, not MJPEG, which costs an absurd
180 Mbit/s by comparison. RTSP also carries the sensor's rotation, so the image
arrives the right way up whichever way the phone is lying — this is why the
earlier android-ip-camera approach could not be made to work.

Worth knowing if you change this code:

- The Pi 5 has **no hardware H.264 decoder**, so this is software decode.
  `hwdec=no` is set explicitly, because
  `VideoControllerConfiguration(enableHardwareAcceleration: false)` does not
  reach libmpv.
- **libmpv tolerates exactly one `Player`.** A second never opens, and
  dispose-then-recreate hangs. Full screen borrows the overlay's player rather
  than making its own.
- `VideoController.platform.future` must be awaited before `player.open()`.
- Retry only on a real player error or completion event. Judging liveness by
  `player.stream.width` looks reasonable and is wrong — the width never arrives
  for a stream that is working fine, so the retry loop tears down a good stream.

### Indoor temperature sensor

The indoor reading comes from a Govee H510x (H5101/H5102/H5104/H5177), which
broadcasts temperature and humidity in its Bluetooth LE advertisements.

**The kiosk doesn't scan for it.** Home Assistant already watches the same sensor
full-time via `govee_ble`, so the kiosk reads the value from its REST API
instead. Two things scanning the same air gained nothing, and BLE scanning on the
Pi's built-in radio makes Bluetooth audio stutter, because that radio shares one
antenna with A2DP.

Configure it under **Settings → Home Assistant**. Without a token the indoor
reading is simply hidden. Tokens are awkward to type on a touchscreen, so:

```bash
bash ~/immich_kiosk_pi/scripts/set-ha-token.sh
```

Create the token under your user name → Security → Long-lived access tokens.

The 24-hour chart comes from Home Assistant's history API, thinned to roughly one
point per ten minutes so the chart doesn't try to draw thousands of segments.

**If you want Bluetooth audio and BLE sensing at once, use two radios.** A USB
BLE dongle removes the contention entirely: leave the built-in `hci0` for audio
and give Home Assistant the dongle. Disable the Bluetooth config entry for the
built-in adapter, or it will scan on both. BlueZ only powers extra controllers at
boot when `AutoEnable=true` is set in `/etc/bluetooth/main.conf`.

### Turning the screen off with Alexa

No cloud account, no Amazon developer account, nothing exposed to the internet.
Three pieces:

1. **`deploy/screen_control.py`** — a small HTTP service on the host. Home
   Assistant runs in a container and can't reach the host's Wayland session, so
   it can't call `wlopm` itself. This runs as the user who owns that session and
   binds to localhost only:

   ```
   /screen                 state as JSON
   /screen/on              /screen/off      /screen/toggle
   /screen/brightness?value=0-100
   ```

   ```bash
   cp deploy/screen-control.service ~/.config/systemd/user/
   systemctl --user enable --now screen-control.service
   ```

2. **A `command_line` switch in Home Assistant** that curls it. Home Assistant
   uses host networking, so `127.0.0.1:8765` reaches the host service.

3. **`emulated_hue`**, presenting that switch to Alexa as a Philips Hue V1
   bridge. Alexa has native Hue support, so nothing else is needed.

Both YAML blocks are in `deploy/homeassistant.yaml`.

Name the device carefully: if the name collides with an Echo, a speaker or a
group, Alexa matches that instead and the light is never reached — the app button
keeps working, so it looks like a voice problem when it isn't. "Kiosk" alone
collided here; "Kiosk screen" was fine.

Two constraints, both from Alexa rather than this project:

- **It must listen on port 80.** Amazon stopped talking to other ports in the
  August 2019 Echo firmware.
- **The Pi needs a fixed address.** Alexa caches the bridge by IP, so a DHCP
  lease change silently breaks it; `emulated_hue`'s `host_ip` must match.

### Turning the screen off by itself

**Settings → Screen → "Turn the screen off when idle"** does the same on a timer.
A touch brings it straight back. Optionally it also wakes when music starts or a
share arrives — that only ever undoes a switch-off this setting made, so if you
turned the screen off by voice it stays off rather than the two fighting.

**Touch wakes it, which is why "off" dims rather than powers down.** Cutting the
DSI output also cuts power to the touch controller, so the panel stops reporting
touches and nothing in software can wake it. Measured on this display: 13 touch
events with the output on, none at all with it off.

So `/screen/off` sets the backlight to zero and leaves the output powered, and
`screen_control.py` watches the touchscreen to turn it back up.
`/screen/off?deep=1` still powers the output right down, for when the saving
matters more than waking it by hand.

Devices to watch come from `/proc/bus/input/devices` — anything with a `mouse`
handler. Keyboard-style devices are deliberately excluded: the paired phone's
AVRCP media keys appear as one, and a track change shouldn't wake the screen.
Reading the touchscreen needs membership of the `input` group.

Power changes and wakes are recorded in
`~/.cache/immich_kiosk_pi/screen_control.log`, which is the quickest way to tell
whether a touch was seen at all.

### TV Remote

Two separate things share this name.

**The dashboard widget** drives a Hisense VIDAA television directly over its
local MQTT interface — power, volume, arrows, OK, back, home, and the current
source. Add it from the dashboard editor and give it the TV's address.

It needs a client certificate and matching private key at
`assets/certs/vidaa_client.pem` and `assets/certs/vidaa_client.key`. The
television will only accept **the manufacturer's own** client certificate, so
this is not a credential you can generate or rotate — it is the same key on
every VIDAA set, extracted from Hisense's own app.

**The key is not in this repository.** `assets/certs/*.key` is git-ignored:
even a key that isn't secret in any real sense shouldn't be published from
here, and keeping it out means the repo doesn't have to be rewritten again if
that judgement changes. Put your own copy at that path before building.
Without it the widget reports "TV client certificate not set up" rather than
failing later with a TLS handshake error that names the wrong thing.

> Because it can't be rotated, treat it as what it is: a shared manufacturer
> key that grants control of a television on your own network, and nothing
> more. It is not a secret of yours, and losing it costs you nothing that
> keeping it would have protected.

**The toolbar button** switches to a companion remote-control app running on the
same Pi, if you have one. It shells out to
[`wlrctl`](https://git.sr.ht/~brocellous/wlrctl):

```bash
sudo apt-get install -y wlrctl
```

The app is matched by Wayland `app_id`, set by `_remoteAppId` in
`lib/screens/home_screen.dart`. Without `wlrctl`, or without that app running,
the button simply never appears.

### Locked Folder

Immich's Locked Folder is protected by a login **session**, which an API key
can't unlock, so the app needs your account login:

```bash
bash deploy/set-immich-login.sh
```

It prompts for your email and password (hidden) and stores them in
`~/.config/immich_kiosk_pi/config.json`. A padlock icon then appears in the home
screen's toolbar; tap it and enter your PIN.

> Your password is stored in plain text in that file, readable only by your user.
> If you'd rather not, skip this step — everything else works without it.

---

## Gestures

| Where | Gesture | Action |
|---|---|---|
| Albums | long-press | start multi-select |
| Albums | tap (while selecting) | add / remove album |
| Photo | pinch or double-tap | zoom in and out |
| Photo | drag (zoomed) | pan |
| Photo | swipe left / right | previous / next |
| Photo | swipe down | close |
| Photo | tap | hide / show controls |
| Slideshow | swipe left / right | previous / next (pauses) |
| Slideshow | swipe down | exit |
| Slideshow | tap | hide / show controls |
| Video | double-tap left / right | skip back / forward 10s |
| Video | double-tap centre | play / pause |
| Video | drag horizontally | scrub |
| Video | drag vertically | volume |
| Video | swipe down | close |
| Camera | pinch (full screen) | zoom the phone's sensor |
| Weather panel | tap | expand / collapse the forecast |
| Now playing panel | tap | expand / collapse the player |

On-screen +/− zoom buttons are also provided as a fallback.

---

## Settings

Tap the gear icon on the home screen:

- **Connection** — Immich server URL and API key
- **Locked Folder** — whether the account login is configured
- **Weather** — on/off, location, screen corner, °C/°F
- **Now playing** — what the paired phone is playing, and which corner
- **Spotify** — Client ID, connect/reconnect, the Connect device
- **Camera** — address, credentials, stream size, corner
- **Share Inbox** — listen port, senders and their tokens, chime volume
- **Home Assistant** — server, token and entity IDs for the indoor sensor
- **Screen** — idle timeout and what wakes it
- **Slideshow** — seconds per photo, transition style, shuffle
- **Storage** — how much the photo cache is using, with a Clear button
- **Device** — Restart and Power off
- **About** — version, every open-source library with its licence, and credits

---

## Development

Built on the Pi (it's an arm64 Linux target), but the source can live elsewhere
and sync over:

```bash
scripts/sync.sh        # copy source to the Pi
scripts/run.sh         # sync, build release, restart the kiosk
scripts/run.sh debug   # sync, then flutter run with hot reload
scripts/shot.sh        # screenshot the Pi's display to a PNG
```

Everything is configured through `scripts/local.env`, or by overriding `PI_HOST`
/ `PI_DIR` as environment variables.

**Getting logs.** A Pi OS install typically keeps no journal for *user* units —
`journalctl --user` reports "No journal files were found" — so everything the app
prints goes nowhere. Redirect it to a file:

```bash
mkdir -p ~/.config/systemd/user/immich_kiosk_pi.service.d
printf '[Service]\nStandardOutput=append:/tmp/kiosk.log\nStandardError=append:/tmp/kiosk.log\n' \
  > ~/.config/systemd/user/immich_kiosk_pi.service.d/log.conf
systemctl --user daemon-reload && systemctl --user restart immich_kiosk_pi
tail -f /tmp/kiosk.log
```

That catches `debugPrint`, unhandled async errors, and libmpv's own log — the
last of which is the only way to see why a camera stream opens without complaint
and then shows nothing.

The window is fullscreen and borderless by default. Set
`IMMICH_KIOSK_WINDOWED=1` to run it in a normal window while debugging.

**Applying labwc changes.** `killall -HUP labwc` reloads the config. `labwc
--reconfigure` looks like it should do this and does nothing to the running
compositor, which makes a change appear not to have worked.

### Debug launch hooks

Environment variables that boot straight into one screen — handy for capturing
screenshots or testing a screen in isolation. Inert unless set.

| Variable | Opens |
|---|---|
| `IMMICH_KIOSK_TEST_ALBUMGRID=<albumId>` | an album's asset grid (`IMMICH_KIOSK_TEST_ALBUMNAME` sets its title) |
| `IMMICH_KIOSK_TEST_GALLERY=<albumId>` | the photo viewer (`IMMICH_KIOSK_TEST_GALLERY_INDEX` picks the photo) |
| `IMMICH_KIOSK_TEST_SLIDESHOW=<albumId>` | the slideshow |
| `IMMICH_KIOSK_TEST_VIDEO=<assetId>` | the video player |
| `IMMICH_KIOSK_TEST_LOCKED=<pin>` | the Locked Folder, unlocked |
| `IMMICH_KIOSK_TEST_LOCKED_VIDEO=<pin>` | the first locked video |
| `IMMICH_KIOSK_TEST_ABOUT=1` | the About screen |
| `IMMICH_KIOSK_TEST_NOWPLAYING=1` | the now-playing panel on a blank background |

### Screen burn-in

The weather and now-playing panels are the only things that stay put on an
always-on display, so they drift continuously within a 24px radius, tracing a
slow Lissajous path (17- and 23-minute periods on the two axes, recomputed every
20 seconds — about two pixels a step, below the threshold of notice).

The panels' margin is deliberately larger than the drift amplitude: a panel
clamped against a screen edge would sit still there, which is the problem this is
meant to solve. See `lib/widgets/burn_in_drift.dart`.

### Project layout

```
lib/
  main.dart                    # app entry, providers, root routing
  theme.dart                   # dark, touch-first theme
  config/app_config.dart       # settings model
  models/immich_models.dart    # Album, Asset
  dashboard/                   # widget grid, themes, registry, live preview
    widgets/                   # clock, weather, spotify, calendar, news, tv
  services/
    config_service.dart        # reads/writes config.json
    immich_service.dart        # Immich REST client + response caching
    locked_folder_service.dart # session login, PIN unlock, re-lock
    media_cache.dart           # on-disk image cache + memory tuning
    weather_service.dart       # Open-Meteo forecast and geocoding
    now_playing_service.dart   # BlueZ AVRCP over D-Bus + artwork lookup
    spotify_service.dart       # Web API control, OAuth PKCE
    camera_service.dart        # IP Webcam control endpoints
    share_inbox_service.dart   # the HTTP listener for shares
    sealed_share.dart          # X25519 + ChaCha20-Poly1305, key rotation
    sealed_stream.dart         # chunked sealed reader/writer
    dashboard_service.dart     # the editor's web server
    kiosk_browser.dart         # launches Firefox/Chromium windows
    tv_service.dart            # Hisense VIDAA over MQTT
  screens/                     # home, album, gallery, video, slideshow,
                               # locked folder, settings, about, viewers
  widgets/                     # overlays, cached image, back button
companion_app/                 # the Android share app
```

### How it talks to Immich

Immich v3 REST API, authenticated with the `x-api-key` header:

| Purpose | Endpoint |
|---|---|
| Album list | `GET /api/albums` |
| Album contents | `POST /api/search/metadata` with `albumIds` |
| Thumbnail / preview | `GET /api/assets/{id}/thumbnail?size=thumbnail\|preview` |
| Full image | `GET /api/assets/{id}/original` |
| Video stream | `GET /api/assets/{id}/video/playback` |

The Locked Folder additionally uses `POST /api/auth/login`,
`POST /api/auth/session/unlock`, then `POST /api/search/metadata` with
`visibility: locked`, and `POST /api/auth/session/lock` on exit — these need a
session token rather than an API key.

### Caching

Images and API responses are cached under `~/.cache/immich_kiosk_pi` —
deliberately **not** in `/tmp`, which on Raspberry Pi OS is a RAM-backed tmpfs.
The cache holds up to 20,000 files for a year, so restarts are near-instant.
Clear it any time from **Settings → Storage**.

---

## Troubleshooting

**Nothing appears on screen**
Check the service: `systemctl --user status immich_kiosk_pi`. It needs the labwc
Wayland session to already be up — that's why it's started from
`~/.config/labwc/autostart`.

**A feature worked, then stopped after a reboot**
Almost certainly a unit bound to `graphical-session.target`, which labwc never
activates. Start it from `~/.config/labwc/autostart` instead. This caused three
separate faults here — Spotify Connect missing, screen-off dead, shares not
arriving.

**Touch does nothing in a browser window**
Firefox must be a native Wayland client. `MOZ_USE_XINPUT2=1` is the usual advice
and is X11-only. Check `mouseEmulation="no"` is set on the `<touch>` rule in
`rc.xml`, and that no `Xwayland` process appears when the browser starts.

**Some thumbnails don't load**
The app retries with backoff and falls back to the full-size image. If it
persists, the asset may not have a thumbnail generated in Immich yet.

**Videos play as a blank blue frame**
Hardware video decoding can produce an unsampleable surface on this GL path, so
the player forces software decoding. If you've changed that, change it back in
`lib/screens/video_player_screen.dart`.

**The camera says "waiting for camera" forever**
Check IP Webcam is actually serving (its "start server on boot" setting), and
that the phone's app hasn't leaked its client slots — force-stop and reopen it.

**Text fields are hard to fill in**
There's no on-screen keyboard, so the server URL, API key and login are easiest
to set by editing `~/.config/immich_kiosk_pi/config.json` over SSH. Sender tokens
have a web page instead. The numeric PIN pad is custom-built and works fine by
touch.

**Harmless log noise**
`Failed to create AudioController: Unable to find mixer control: Master` is an
ALSA probe from media_kit; audio still works.

---

## Third-party libraries

The same list is on the device under **Settings → About**, so attribution travels
with the app rather than living only here.

Built with [Flutter](https://flutter.dev) (BSD-3-Clause,
[source](https://github.com/flutter/flutter)).

### Dart packages

| Package | Used for | Licence |
|---|---|---|
| [provider](https://pub.dev/packages/provider) · [src](https://github.com/rrousselGit/provider) | State management / dependency injection | MIT |
| [dio](https://pub.dev/packages/dio) · [src](https://github.com/cfug/dio) | HTTP client for the Immich and weather APIs | MIT |
| [cached_network_image](https://pub.dev/packages/cached_network_image) · [src](https://github.com/Baseflow/flutter_cached_network_image) | Images with auth headers and caching | MIT |
| [flutter_cache_manager](https://pub.dev/packages/flutter_cache_manager) · [src](https://github.com/Baseflow/flutter_cache_manager) | On-disk cache, relocated to the NVMe | MIT |
| [file](https://pub.dev/packages/file) · [src](https://github.com/google/file.dart) | Filesystem abstraction for the custom cache | MIT |
| [media_kit](https://pub.dev/packages/media_kit) · [src](https://github.com/media-kit/media-kit) | Video playback and speed control | MIT |
| [media_kit_video](https://pub.dev/packages/media_kit_video) | Video render surface | MIT |
| [media_kit_libs_video](https://pub.dev/packages/media_kit_libs_video) | Native video dependencies | MIT |
| [dbus](https://pub.dev/packages/dbus) · [src](https://github.com/canonical/dbus.dart) | Talks to BlueZ for phone media metadata | MPL-2.0 |
| [cryptography](https://pub.dev/packages/cryptography) | X25519, HKDF and ChaCha20-Poly1305 for encrypted shares | Apache-2.0 |
| [crypto](https://pub.dev/packages/crypto) · [src](https://github.com/dart-lang/tools) | SHA-256 for the Spotify OAuth PKCE code challenge and key ids | BSD-3-Clause |
| [path](https://pub.dev/packages/path) · [src](https://github.com/dart-lang/path) | Path joining for cache locations | BSD-3-Clause |
| [flutter_lints](https://pub.dev/packages/flutter_lints) (dev) | Lint rules | BSD-3-Clause |

### System libraries

| Library | Used for | Licence |
|---|---|---|
| [mpv / libmpv](https://mpv.io) · [source](https://github.com/mpv-player/mpv) | Video decoding behind media_kit | LGPL-2.1+ ([details](https://github.com/mpv-player/mpv/blob/master/Copyright)) |
| [BlueZ](http://www.bluez.org) · [source](https://github.com/bluez/bluez) | Bluetooth stack — AVRCP metadata and control | GPL-2.0+ / LGPL-2.1+ |
| [librespot](https://github.com/librespot-org/librespot) | Spotify Connect device ("Kiosk") | MIT |
| [Firefox](https://www.mozilla.org/firefox/) | Shared links and articles, and the Spotify login | MPL-2.0 |
| [labwc](https://labwc.github.io) | The Wayland compositor the kiosk runs under | GPL-2.0 |
| [wlrctl](https://git.sr.ht/~brocellous/wlrctl) | Focusing windows for the TV Remote button | MIT |
| [GTK 3](https://www.gtk.org) | Flutter's Linux embedder window | LGPL-2.1+ |

### Fonts

The dashboard's twenty fonts are all under the
[SIL Open Font Licence 1.1](https://scripts.sil.org/OFL), listed with their
designers on the About screen.

### Services

| Service | Used for | Terms |
|---|---|---|
| [Immich](https://immich.app) · [src](https://github.com/immich-app/immich) | Your own photo server (the whole point) | AGPL-3.0 |
| [Open-Meteo](https://open-meteo.com) | Weather forecast — no API key required | Free for non-commercial use, [CC BY 4.0](https://open-meteo.com/en/license) |
| [iTunes Search API](https://performance-partners.apple.com/search-api) | Album artwork lookup | Free, no key · Apple terms |
| [Spotify Web API](https://developer.spotify.com/documentation/web-api) | Playback control, liked songs and playlists | Requires your own free Developer app + Premium |
| [postcodes.io](https://postcodes.io) · [src](https://github.com/ideal-postcodes/postcodes.io) | UK postcode → coordinates | MIT, data under [OGL](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/) |
| [IP Webcam](https://play.google.com/store/apps/details?id=com.pas.webcam) | The phone-as-camera stream and its control API | Free / paid app, third-party |

---

## Credits and sources

Almost all of the code here was written for this project, but these parts come
from, or are adapted from, elsewhere:

- **Flutter project scaffolding** — `linux/runner/*`, `.metadata`,
  `analysis_options.yaml` and the initial `main.dart` were generated by
  `flutter create` and then modified (notably `my_application.cc`, changed to
  start fullscreen and borderless). Flutter SDK, BSD-3-Clause.
- **`_NvmeFileSystem`** in `lib/services/media_cache.dart` is modelled on
  [`IOFileSystem`](https://github.com/Baseflow/flutter_cache_manager/blob/develop/lib/src/storage/file_system/file_system_io.dart)
  from flutter_cache_manager (MIT), changed to store files under a fixed
  directory instead of the system temp directory.
- **Weather code descriptions and icon mapping** in
  `lib/services/weather_service.dart` and `lib/widgets/weather_overlay.dart`
  follow the WMO weather-code table as published in the
  [Open-Meteo API docs](https://open-meteo.com/en/docs).
- **Immich API usage** was derived from the
  [Immich API documentation](https://immich.app/docs/api) together with probing a
  live v3 server — in particular that album contents come from
  `POST /api/search/metadata`, and that the Locked Folder needs a session token
  rather than an API key.
- **Bluetooth now-playing** uses BlueZ's AVRCP support over D-Bus
  ([`org.bluez.MediaPlayer1`](https://github.com/bluez/bluez/blob/master/doc/org.bluez.MediaPlayer.rst))
  for metadata and transport control. Album art is not part of AVRCP, so it is
  resolved separately from the iTunes Search API by artist + track title.
- **The sealed-share format** follows the standard sealed-box construction
  (ephemeral X25519 → HKDF → AEAD) as described in the
  [libsodium documentation](https://doc.libsodium.org/public-key_cryptography/sealed_boxes),
  implemented here over the `cryptography` package rather than copied.
- **Material Design icons** ship with Flutter (Apache-2.0).

No code was copied from Stack Overflow, blog posts or other projects.

---

## Licence

[MIT](LICENSE) — do what you like with it, no warranty.
