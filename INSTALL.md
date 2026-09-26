# Installing HomeCanvas

How to get the kiosk running on a Pi, and how to set up each optional part.
For how things work underneath, see [TECHNICAL.md](TECHNICAL.md).

- [What you need](#what-you-need)
- [Install](#install)
- [Optional setup](#optional-setup)
  - [Power-off button](#power-off-button)
  - [Emoji](#emoji)
  - [Now playing from your phone](#now-playing-from-your-phone)
  - [Spotify](#spotify)
  - [The widget dashboard](#the-widget-dashboard)
  - [Setting up the widgets](#setting-up-the-widgets)
  - [Share Inbox](#share-inbox)
  - [A phone as a wireless camera](#a-phone-as-a-wireless-camera)
  - [Indoor temperature sensor](#indoor-temperature-sensor)
  - [Turning the screen off with Alexa](#turning-the-screen-off-with-alexa)
  - [Turning the screen off by itself](#turning-the-screen-off-by-itself)
  - [TV Remote](#tv-remote)
  - [Locked Folder](#locked-folder)
- [Using it](#using-it)
- [Troubleshooting](#troubleshooting)
- [Known issues](#known-issues)

---

## What you need

- **Raspberry Pi 5** (or Pi 4) with a DSI touch display — developed against a
  10" 1200×1920 panel used in landscape
- **Raspberry Pi OS (Debian 13 "trixie")** or similar, running the **labwc**
  Wayland session
- An **Immich server** (v3.x) reachable on your network
- A computer to build from, or build directly on the Pi

---

## Install

### The easy way

On the Pi, in a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/vwillcox/HomeCanvas/main/install.sh | bash
```

That's it — the installer asks a few questions and does the rest:

1. checks what's installed on your Linux and installs what's missing
   (Raspberry Pi OS, Debian, Ubuntu, Fedora, Arch or openSUSE);
2. installs Flutter and builds HomeCanvas;
3. connects it to Immich — have your server's address and an API key
   (**Account Settings → API Keys**) ready, or skip it and do it later;
4. gives it a name on your network, so it's `homecanvas.local`;
5. starts it with the desktop, finds the touchscreen and sets it up;
6. puts the dashboard editor at `http://homecanvas.local`
   ([details](#the-editor-on-port-80)).

It says what it's about to do before each step, keeps a full log in
`~/homecanvas-install.log`, and can be run again safely: on an installed Pi
it offers to **update** instead. If you already have a copy of the code,
`bash install.sh` in it does the same.

```bash
bash install.sh --check   # only look: what's installed, what's missing
bash install.sh --yes     # no questions — take every default
```

### By hand

The same steps, for doing it yourself — or building on another computer and
sending it to the Pi, which is quicker while developing.

**1. Install the toolchain on the Pi**

```bash
bash scripts/pi-setup.sh
```

Installs Flutter, the Linux build dependencies and libmpv. Needs `sudo` and
downloads a few hundred MB.

**2. Set up the touchscreen** — merge [`deploy/labwc-rc.xml`](deploy/labwc-rc.xml)
into `~/.config/labwc/rc.xml`, changing `deviceName` to yours (find it with
`libinput list-devices`) and `mapToOutput` to your panel. `mouseEmulation="no"`
is the important part — it delivers real touch events rather than synthetic
mouse ones.

Reload labwc with `killall -HUP labwc`. (`labwc --reconfigure` looks like it
should do this and does nothing to the running compositor.)

**3. Give it a name** — so you can reach it as `homecanvas.local` from any
machine on the network instead of remembering its IP address:

```bash
bash scripts/set-hostname.sh            # or: bash scripts/set-hostname.sh kitchen
```

Sets the hostname and makes sure Avahi is announcing it over mDNS — on the Pi's
real network cards only, since with Docker installed Avahi otherwise hands out
the container bridge's `172.17.0.1`, which nothing else can reach. The dashboard
editor is then at `http://homecanvas.local:8090` and SSH at
`pi@homecanvas.local`. The kiosk shows the `.local` address on screen once
restarted, with the IP beside it for the odd browser (some Android versions)
that can't resolve `.local` names.

**4. Point the helper scripts at your Pi**

```bash
cp scripts/local.env.example scripts/local.env
```

Edit it with your Pi's SSH details. It's git-ignored, so your hostname stays out
of the repo.

**5. Add your Immich details** — create `~/.config/homecanvas/config.json`
on the Pi (see [`config.example.json`](config.example.json)) with your server URL
and an API key from **Account Settings → API Keys**, then `chmod 600` it.

There is no on-screen keyboard, so this file is the easiest place for anything
long: addresses, keys and tokens.

**6. Build and run**

```bash
scripts/run.sh
```

Syncs the source to the Pi, builds a release binary there, and launches it.

**7. Start it on boot**

```bash
mkdir -p ~/.config/systemd/user ~/.config/labwc
cp deploy/homecanvas.service ~/.config/systemd/user/
cp deploy/labwc-autostart ~/.config/labwc/autostart
chmod +x ~/.config/labwc/autostart
systemctl --user daemon-reload
systemctl --user enable --now homecanvas
```

> Start units from labwc's `autostart`, not from `graphical-session.target` —
> labwc never activates it, so anything bound to it silently never runs. This
> caused three separate "worked until I rebooted" faults.

**8. Keep its output** (recommended). A Pi OS install typically keeps no journal
for *user* units, so everything the app prints goes nowhere. Send it to a file:

```bash
mkdir -p ~/.config/systemd/user/homecanvas.service.d
printf '[Service]\nStandardOutput=append:/tmp/kiosk.log\nStandardError=append:/tmp/kiosk.log\n' \
  > ~/.config/systemd/user/homecanvas.service.d/log.conf
systemctl --user daemon-reload && systemctl --user restart homecanvas
tail -f /tmp/kiosk.log
```

**9. A plain address for the editor** (recommended) — once HomeCanvas has
started, run this on the Pi so the dashboard editor is at
`http://homecanvas.local` with no `:8090`:

```bash
bash scripts/setup-port-80.sh
```

It asks for `sudo` once. If Home Assistant's Alexa bridge already has port
80, it asks before sharing it. Add `--yes` or `--no` to answer that question
up front (for an unattended install), and use `--undo` to reverse it. The
details are in [The editor on port 80](#the-editor-on-port-80).

**Upgrading from ImmichKioskPi.** The project was called ImmichKioskPi
until September 2026. Your settings and cache move to their new folders
(`~/.config/homecanvas`, `~/.cache/homecanvas`) by themselves on the first
start, and a link is left at each old path. The service has a new name, so
swap it once:

```bash
cp ~/.config/immich_kiosk_pi/config.json ~/config-backup.json   # to be safe
sed -i 's#^PI_DIR=.*#PI_DIR=/home/<you>/homecanvas#' scripts/local.env  # on your computer
scripts/sync.sh && ssh <pi> 'cd ~/homecanvas && flutter build linux --release'
# then on the Pi:
cd ~/.config/systemd/user
cp ~/homecanvas/deploy/homecanvas.service .
mkdir -p homecanvas.service.d && cp immich_kiosk_pi.service.d/*.conf homecanvas.service.d/ 2>/dev/null
sed -i 's#%h/immich_kiosk_pi/#%h/homecanvas/#' screen-control.service
sed -i 's#immich_kiosk_pi.service#homecanvas.service#' ~/.config/labwc/autostart *.service
systemctl --user daemon-reload
systemctl --user disable --now immich_kiosk_pi.service
systemctl --user enable --now homecanvas.service
systemctl --user restart screen-control.service
```

The debug switches are now `HOMECANVAS_…` rather than `IMMICH_KIOSK_…`, and
the window's app id is `info.talktech.homecanvas`. Phones running the
companion app keep working without an update.

---

## Optional setup

Everything below is optional. Each part is off, or hides itself, until it is set
up.

### Power-off button

To let the in-app **Restart** and **Power off** buttons work without a password
prompt, run once on the Pi:

```bash
sudo bash deploy/enable-poweroff.sh
```

### Emoji

Emoji in notes, chores and the shopping list need a colour emoji font on the
Pi. Raspberry Pi OS does not include one:

```bash
sudo apt install fonts-noto-color-emoji
systemctl --user restart homecanvas
```

Without it, emoji show as blank space. Everything the app draws itself — stars,
ticks, icons — works either way.

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

Play something on the phone with **media audio** routed to the Pi. The player
appears; tap it to expand, tap again to shrink.

> AVRCP metadata rides along with the Bluetooth audio stream, so the phone's
> audio plays through the **Pi**, not the phone.

**Keeping the sound on the phone.** To keep the music playing on the phone —
headphones, its own speaker — turn off **Settings → Music → "Play the audio on
this device"**. The panel keeps showing the track and the controls still work;
it becomes a remote.

The volume slider sets the level the phone is sending — the same as the phone's
own volume buttons. Album artwork is looked up from the free iTunes Search API
by artist and track.

**The visualiser.** The expanded player draws bars or a waveform of what is
coming out of the Pi's speaker. Tap it to change style — bars, waveform, off —
or set it in **Settings → Music → Visualiser**. It is still when the audio is
not playing on this device, since there is then nothing here to draw.

### Spotify

Two independent features — set up either or both. Both need Spotify Premium.

#### Controlling Spotify (like, playlists, seek, pick the device)

The now-playing panel can control Spotify directly: seek, shuffle, repeat,
volume, **like**, **add to a playlist**, the queue and which device plays. It
is used in preference to Bluetooth whenever Spotify has something playing.

In **Settings → Music → Spotify**:

1. Create a free app at the
   [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Add `http://127.0.0.1:8909/callback` as a Redirect URI.
3. Paste the **Client ID** and tap **Connect**. A browser window opens on the
   Pi's own screen for the one-time login and closes itself when it is done.

No client secret is needed. If you connected before liking and playlists
existed, tap **Reconnect** once.

**Or over SSH**, which saves typing the Client ID on the panel with no
keyboard:

```bash
bash ~/homecanvas/scripts/set-spotify-token.sh <client_id>
```

It still opens the login on the Pi's own screen, since that step needs your
Spotify password, which nothing here sees. Only the Client ID and a refresh
token are saved to `~/.config/homecanvas/config.json`, and the kiosk restarts
to pick them up.

#### Playing Spotify on the Pi ("Kiosk" in the Connect picker)

The Pi can appear as its own device, **Kiosk**, in Spotify's device picker.
This uses [librespot](https://github.com/librespot-org/librespot). The easiest
way to get the binary is the [raspotify](https://github.com/dtcooper/raspotify)
package — but use it only for the binary, and run librespot as a **user**
service so it plays through PipeWire:

```bash
sudo apt-get -y install curl
curl -sL https://dtcooper.github.io/raspotify/install.sh | sudo sh
sudo systemctl disable --now raspotify

mkdir -p ~/.config/systemd/user ~/.cache/librespot
cp ~/homecanvas/deploy/librespot.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now librespot.service
```

It streams at 320 kbps, the most Connect carries. Moving playback *off* the
kiosk restarts the track with stock librespot; [`patches/`](patches/) has a fix
and how to build it.

### The widget dashboard

Reach it from the dashboard button in the toolbar at the top right. Arrange it
from a browser on the same network at **`http://homecanvas.local:8090`**.

- **Add a widget** from the groups on the right, then drag it into place and
  pull its corner to resize. Tap one to change its settings.
- **Pages** — **+** adds one; drag a page's tab, or use **Move ‹ ›**, to reorder
  them. Each page can have a name and **hours**: a morning page shown from 6 to
  9 on weekdays, a night page from 22:00 to 06:30. The panel goes to a page when
  its time comes, and leaves pages out of the rotation outside their hours.
- **Turning pages** — **Flip every _n_ seconds** turns them on a timer; the
  pause button beside the page dots on the panel holds the page you are on.
  **Tap to flip** turns the page when you tap empty space. Swiping always works.
- **Widgets that come and go** — each widget's settings end with **Only show it
  between**, for a trains board on weekday mornings or the bins the evening
  before.
- **The theme** — sixteen, dark (Glass, Aurora, Abyss, Obsidian, Synthwave,
  Midnight, Ember, Forest, Espresso, Terminal, Terminal Night, Nightstand) and
  light (Frost, Paper, Sorbet, Swiss); see [THEMES.md](THEMES.md). The theme
  dresses the whole kiosk, not just the dashboard. To make your own, drop a
  JSON file in `~/.config/homecanvas/themes/`, starting from
  [`deploy/theme-template.json`](deploy/theme-template.json).
- **The look of each widget** — twenty fonts and twelve sizes, square corners
  or shadows off, and the top bar on or off.
- **Photo background** — your Immich photos behind the tiles, darkened and
  cross-fading slowly: from the whole library or one album, how dark, how often
  they change.

Nothing reaches the panel until you press **Save to panel**; **Revert** throws
away what you have changed.

### Setting up the widgets

Most widgets work as soon as they are added. These need something first.

#### Weather, Sun & moon, Air & pollen, Rain soon, Grid carbon

All use the place set in **Settings → Home → Weather** — a town or a UK
postcode. Grid carbon sends only the first half of a postcode, and can be given
its own.

#### Calendar

Each calendar is its **secret iCal address**: in Google Calendar, the calendar's
settings → *Secret address in iCal format*; in Apple's, *Public Calendar*; in
Outlook, *Publish a calendar*. `webcal://` addresses work. Anyone with one of
these links can read that calendar, so treat them as passwords.

#### Bin day

One row per bin: its name, a colour, **any one collection date** from the
council's calendar, and how many weeks apart they are. It works out the rest,
reminds you from the evening before, and can say so out loud at a time you set
(which needs the voice — see [Reading notes aloud](#reading-notes-aloud)).

#### Notes and the shopping list

Nothing to set up. Anyone on the home network can add to them from a phone at
**`http://homecanvas.local:8090/notes`** and **`http://homecanvas.local:8090/list`** — add those to a
phone's home screen. Text shared from the companion app lands on the Notes
widget too. Port 8090 is meant for the home network: don't forward it.

#### Train departures

Uses [Realtime Trains](https://www.realtimetrains.co.uk). Sign in at
[api-portal.rtt.io](https://api-portal.rtt.io), request a token and paste it
into the widget's **Realtime Trains token**. Either kind of token the portal
issues works. Stations are the three-letter codes on a ticket — COL, MDE, LST.

#### Lights

For Govee lights and plugs. Either turn on **LAN Control** for each device in
the Govee Home app — the panel then finds them on the network by itself — or
get an API key in the Govee Home app under **Profile → Settings → Apply for API
Key** and paste it into the widget.

#### Home Assistant

Uses the connection in **Settings → Home → Home Assistant** (an address and a
long-lived access token — see [Indoor temperature sensor](#indoor-temperature-sensor)).
The widget's entity list is then picked from what your Home Assistant has.
Lights and switches change with a tap; locks and doors are only ever shown.

#### The UniFi widgets

Network health, Who's home, UniFi devices, Network clients, WAN throughput and
ISP speed test all read a UniFi console. Create an API key in the UniFi Network
app under **Settings → Control Plane → Integrations** (a read-only admin's key
is enough), then add to `config.json`:

```json
"unifi": {
  "enabled": true,
  "host": "192.168.1.1",
  "apiKey": "your-key"
}
```

The console's own certificate is accepted even though it is self-signed; set
`"allowSelfSignedCert": false` if you have given it a real one.

#### Servers

Shows this Pi on its own. For other machines, install
[Glances](https://github.com/nicolargo/glances) on each and give the widget its
address (`nas.local` — the port can be left off). On Debian or Raspberry Pi OS:

```bash
sudo apt install glances python3-fastapi python3-uvicorn python3-jinja2
```

Debian's service runs Glances in a mode the widget can't read, so point it at
the web API instead:

```bash
sudo mkdir -p /etc/systemd/system/glances.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/bin/glances -w --disable-webui --enable-plugin smart\n' \
  | sudo tee /etc/systemd/system/glances.service.d/web.conf
sudo systemctl daemon-reload && sudo systemctl enable --now glances
sudo systemctl restart glances
curl -s http://localhost:61208/api/4/quicklook   # should print numbers
```

On CasaOS, Glances is one click in its app store.

**Disk health (SMART).** For a health dot beside each disk, Glances needs
`smartctl` and pySMART:

```bash
sudo apt install smartmontools
sudo pip3 install --break-system-packages pySMART
sudo systemctl restart glances
curl -s http://localhost:61208/api/4/smart     # should list your disks
```

If that lists nothing and the disk is in a **USB enclosure**, `smartctl` may
not know the enclosure's bridge chip. Find its USB id with `lsusb`, check
`sudo smartctl -d sat -H /dev/sda` works, then teach smartctl the bridge — for
example, for a `174e:1155` bridge:

```bash
printf '{ "USB: 174e:1155 SATA bridge; ",\n  "0x174e:0x1155",\n  "",\n  "",\n  "-d sat"\n},\n' \
  | sudo tee -a /etc/smart_drivedb.h
sudo systemctl restart glances
```

#### Services

A light for each thing that should be up. The address says how it is checked:
`https://…` asks for a page, `host:port` connects, and a bare name or address is
pinged. Give a computer's MAC address and tapping it while it sleeps sends a
wake-on-LAN.

#### Certificates, Updates

Certificates: the sites to watch, like `example.com`, or `host:port`. Updates
checks Immich against its latest release, Home Assistant's own update entities
(through the connection in Settings) and UniFi firmware (through the UniFi
key), each switchable.

#### Birthdays

Uses the people Immich recognises. Open a person in Immich, set their **date of
birth**, and they appear.

#### Chores & rewards

Add the people, then the chores: who does each (or nobody, for "anyone"), which
days, how many stars. A picture is an emoji (see [Emoji](#emoji)). Set a weekly
star goal and name the reward. It resets each Monday and remembers the week
through restarts.

#### News: reading an article aloud

Tap a headline, then **Read aloud**. The kiosk fetches the article, leaves
out the menus, adverts and "related stories", and reads it in the same voice
as shared notes. It needs piper installed (see
[Reading notes aloud](#reading-notes-aloud)), at its own volume (**Settings → Volumes → News reader**).
Anything playing pauses while it reads and carries on afterwards. A bar along
the bottom of the screen shows what is being read, on any screen, with pause,
next paragraph and stop. If the page can't be read (a paywall, a video
page), it reads the feed's summary instead and says so.

**A voice per writer.** Put more piper voices in
`~/.local/share/piper/voices/` (each a `.onnx` with its `.onnx.json`) and each
article's author gets one of them or the main voice: the same one every
time for the same writer, so you come to know who wrote what by ear. It says
"By …" after the headline. The choice comes from the name as spelt, not from
anything it might suggest about the person. To add a British male voice:

```bash
mkdir -p ~/.local/share/piper/voices && cd ~/.local/share/piper/voices
V=https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alan/medium
curl -fsSL -O $V/en_GB-alan-medium.onnx
curl -fsSL -O $V/en_GB-alan-medium.onnx.json
```

Restart the kiosk after adding voices. Shared notes and reminders keep the
main voice.

#### Speed test

Runs [Ookla's speedtest CLI](https://www.speedtest.net/apps/cli). Install it —
no root needed:

```bash
curl -fsSL -o /tmp/st.tgz \
  https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz
mkdir -p ~/.local/bin && tar xzf /tmp/st.tgz -C /tmp speedtest
install -m755 /tmp/speedtest ~/.local/bin/speedtest
```

> Use Ookla's own binary, not Debian's `speedtest-cli` package — a different
> program with different output.

Each test moves a few hundred megabytes, so keep **Run automatically every**
well spaced on a metered connection.

#### LAN speed test

Measures your own network rather than the internet, against a self-hosted
[OpenSpeedTest](https://openspeedtest.com/selfhosted-speedtest) server. Run it
on the machine to test against:

```bash
docker run -d --restart=unless-stopped --name openspeedtest \
  -p 3000:3000 -p 3001:3001 openspeedtest/latest
```

and put `http://<that machine>:3000` in the widget.

#### TV remote

See [TV Remote](#tv-remote).

### Share Inbox

Anyone with the companion Android app (`companion_app/`) can share a photo, GIF,
video, web link or note to the kiosk from any app's share sheet.

There's no relay: the kiosk runs its own small listener. Making that reachable
from wherever the phones are — same Wi-Fi, or the whole internet — is up to
you: a port forward, a reverse proxy, whatever you already run.

In **Settings → Sharing**:

1. Set the listen port (8081 by default) and point your router or proxy at it.
2. Add a name for each person — this makes a token for their copy of the app.
   There's also a page for this, on the local network only, at
   `http://homecanvas.local:8090/senders`.
3. Shares arrive with a chime and the sender's name. Photos open in the viewer,
   videos in the player, notes in large type, links in a browser window.

A **Do Not Disturb** switch in the top bar mutes the chime. Shares are
end-to-end encrypted by the app; set `requireEncryption` in `config.json` to
refuse anything that isn't, once every phone is up to date.

#### Reading notes aloud

**Settings → Sharing → Read notes aloud** speaks incoming notes, and the same
voice announces finished timers and bin reminders. It uses
[piper](https://github.com/rhasspy/piper), which runs on the Pi — nothing is
sent anywhere. Install it and a voice; neither needs root:

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

That is a British female voice; any piper voice works if you keep the names
`voice.onnx` and `voice.onnx.json`.

> Do **not** `apt install piper` — Debian's package of that name configures
> gaming mice.

### A phone as a wireless camera

An old Android phone running
[IP Webcam](https://play.google.com/store/apps/details?id=com.pas.webcam) becomes
a camera. Set its address, login, stream size and corner in **Settings → Home →
Camera**. The camera button in the top bar opens a corner window; tap it for
full screen, and pinch there to zoom the phone's sensor.

In IP Webcam, **set a login** (it has none by default) and turn on **start
server on boot**. A 720p stream uses half the Pi's effort of a 1080p one.

### Indoor temperature sensor

The indoor reading comes from a Govee H510x (H5101/H5102/H5104/H5177)
thermometer, through **Home Assistant**, which already watches it with the
`govee_ble` integration.

Set Home Assistant's address and entities in **Settings → Home → Home
Assistant**. Create a token under your user name → Security → Long-lived access
tokens, then, rather than typing it on the touchscreen:

```bash
bash ~/homecanvas/scripts/set-ha-token.sh
```

> Bluetooth audio and Bluetooth sensing share one radio on the Pi and make each
> other stutter. If Home Assistant runs on the same Pi, give it a USB Bluetooth
> dongle for the sensors and leave the built-in radio for audio.

### Turning the screen off with Alexa

No cloud account, nothing exposed to the internet. Three pieces:

1. **`deploy/screen_control.py`**, a small service on the Pi that switches the
   screen:

   ```bash
   cp deploy/screen-control.service ~/.config/systemd/user/
   systemctl --user enable --now screen-control.service
   ```

2. **A `command_line` switch in Home Assistant** that calls it.
3. **`emulated_hue`**, which shows that switch to Alexa as a Philips Hue light.

Both Home Assistant blocks are in [`deploy/homeassistant.yaml`](deploy/homeassistant.yaml).

- **Name it carefully.** If the name matches an Echo, speaker or group, Alexa
  picks that instead. "Kiosk" collided here; "Kiosk screen" was fine.
- **It must be on port 80** — Echoes stopped using other ports in 2019.
- **Give the Pi a fixed address.** Alexa remembers the bridge by IP.

### The editor on port 80

The editor is always at `http://homecanvas.local:8090`. Set the Pi up once
and it's at plain **`http://homecanvas.local`** as well:

```bash
bash scripts/setup-port-80.sh          # asks before changing Home Assistant
bash scripts/setup-port-80.sh --yes    # unattended: share without asking
bash scripts/setup-port-80.sh --no     # unattended: never touch Home Assistant
bash scripts/setup-port-80.sh --undo   # reverse the sharing
```

`pi-setup.sh` runs it too. Home Assistant's bridge can only be shared once
HomeCanvas has started, so on a new install it tells you to run it again
then (install step 9).

It asks for `sudo` once, to let an ordinary user open port 80, then looks at
what already has the port:

- **Nothing:** HomeCanvas takes port 80 the next time it starts.
- **Home Assistant's Alexa bridge** (`emulated_hue`, as in the section above):
  it **offers** to share the port. Alexa only talks to port 80, so the bridge
  can't simply move. If you say yes, it:
  1. backs up Home Assistant's `configuration.yaml` to
     `~/configuration.yaml.before-port-80`;
  2. changes `emulated_hue` to `listen_port: 8300` with `advertise_port: 80`,
     so Alexa is still told port 80, and restarts Home Assistant;
  3. sets HomeCanvas's `dashboard.hueRelay` to the bridge. HomeCanvas then
     passes Alexa's requests (`/description.xml`, and `/api/...` paths other
     than the editor's own) through to it.

  Say no, and nothing changes: the editor stays on `:8090`.
- **Anything else:** it's left alone and the editor stays on `:8090`.

Settings → Display → Dashboard shows the editor's address. When it isn't on
port 80, Settings says why, and suggests the script when Alexa's bridge is
the reason.

**Check the Alexa part:** `curl http://homecanvas.local/description.xml`
should return the Hue bridge's description, and "Alexa, turn off the kiosk
screen" should still work. If Home Assistant is down, Alexa's requests get a
502, not the editor.

**To undo the sharing:** `bash scripts/setup-port-80.sh --undo` puts Home
Assistant's config back from the backup, restarts it, and turns port 80 off
in HomeCanvas.

### Turning the screen off by itself

**Settings → Display → "Turn the screen off when idle"**. A touch brings it
back; optionally, music starting or a share arriving does too. The touch that
wakes it is swallowed, so it doesn't also press whatever is underneath. This
uses `screen_control.py` above, which needs the user in the `input` group.

### TV Remote

Two things share this name.

**The dashboard widget** drives a Hisense VIDAA television over your network:
power, volume, arrows, OK, back, home and inputs. Set the TV's address in
**Settings → Home → Television**.

It needs the television's client certificate and key at
`assets/certs/vidaa_client.pem` and `assets/certs/vidaa_client.key` before
building. The set only accepts the manufacturer's own certificate — the same on
every VIDAA television, taken from Hisense's app — so it is not in this
repository; put your own copy there. Without it the widget says so.

If you also run the standalone TV remote app, give each its **own device
UUID**, or they keep disconnecting each other.

**The toolbar's remote button** switches to a separate remote-control app on
the same Pi, if you have one. It needs `wlrctl`:

```bash
sudo apt-get install -y wlrctl
```

### Locked Folder

Immich's Locked Folder needs your account login, not just the API key:

```bash
bash deploy/set-immich-login.sh
```

It asks for your email and password and stores them in `config.json`, readable
only by your user. A padlock then appears in the toolbar; tap it and enter your
PIN. Skip this if you would rather not store the password — nothing else needs
it.

---

## Using it

### Gestures

| Where | Gesture | Action |
|---|---|---|
| Albums | long-press | start picking several for a slideshow |
| Photo | pinch or double-tap | zoom |
| Photo | swipe left / right | previous / next |
| Photo | swipe down | close |
| Slideshow | swipe left / right | previous / next |
| Slideshow | swipe down | exit |
| Video | double-tap left / right | back / forward 10s |
| Video | drag across / up and down | scrub / volume |
| Camera | pinch (full screen) | zoom the phone's sensor |
| Weather | tap | the full forecast |
| Now playing | tap | open or shrink the full player |
| Dashboard | swipe | change page |
| Dashboard | tap the current page's dot | hold or carry on turning pages |

### Settings

The gear at the top right. Seven tabs:

| Tab | What's there |
|---|---|
| **Photos** | the Immich connection, Locked Folder, slideshow, photo cache |
| **Music** | now playing, the visualiser, Spotify |
| **Home** | weather, Home Assistant, the television, the camera |
| **Display** | the screen turning off, brightness, the dashboard |
| **Volumes** | Do Not Disturb, and separate volumes for notifications, speech, the news reader and timers |
| **Sharing** | the share inbox, senders, reading notes aloud |
| **System** | restart, power off, and About — every library and its licence |

---

## Troubleshooting

**Nothing appears on screen** — check `systemctl --user status homecanvas`.
It needs the labwc session up first, which is why it starts from
`~/.config/labwc/autostart`.

**Something worked, then stopped after a reboot** — almost certainly a unit
bound to `graphical-session.target`, which labwc never starts. Start it from
labwc's `autostart` instead.

**Touch does nothing in a browser window** — Firefox must run as a native
Wayland client, and `rc.xml` needs `mouseEmulation="no"` on its `<touch>` rule.

**Emoji show as blank space** — install the emoji font; see [Emoji](#emoji).

**A Servers machine says "not answering"** — check
`curl http://<machine>:61208/api/4/quicklook` from the Pi. If that fails, Glances
isn't running in web mode; see [Servers](#servers).

**Some thumbnails don't load** — the app retries and falls back to the full
image. If it persists, Immich may not have made that thumbnail yet.

**Videos play as a blank blue frame** — the player forces software decoding for
this reason; if you have changed that in
`lib/screens/video_player_screen.dart`, change it back.

**The camera waits for ever** — check IP Webcam is serving ("start server on
boot"). If it was force-stopped repeatedly, force-stop and reopen it once more.

**Text fields are hard to fill in** — there's no on-screen keyboard. Edit
`~/.config/homecanvas/config.json` over SSH, or use the web pages
(`http://homecanvas.local:8090` for the dashboard, `/senders` for share tokens).

**`homecanvas.local` doesn't open** — on the Pi, `systemctl status avahi-daemon`
should be running and `hostname` should say `homecanvas`; re-run
`scripts/set-hostname.sh` if not. Windows and macOS resolve `.local` out of the
box; a Linux desktop needs `nss-mdns` (Arch: `sudo pacman -S nss-mdns`, then add
`mdns_minimal [NOTFOUND=return]` before `resolve` on the `hosts:` line of
`/etc/nsswitch.conf`). If another device already has the name, Avahi announces
`homecanvas-2.local` instead — `journalctl -u avahi-daemon` says which. The IP
address shown under it on the kiosk always works.

**Harmless log noise** — `Unable to find mixer control: Master` is an ALSA probe
from media_kit; audio still works.

---

## Known issues

- **Camera** — the Pi 5 decodes the stream in software, about half a core at
  1080p. IP Webcam's zoom is a sensor crop; a periscope lens can't be reached
  by any third-party app.
- **Browser** — Firefox's cookie-banner blocking misses sites it has no rule
  for; `sudo apt install webext-ublock-origin-firefox` catches far more. News
  articles avoid banners altogether by opening in reader view.
- **Spotify** — a Development Mode app can't use some endpoints, and search is
  capped at 10 results. Lossless can't go over Connect. The librespot fix in
  `patches/` isn't upstream.
