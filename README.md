# HomeCanvas

A touchscreen photo frame, media browser and wall dashboard for your own
[Immich](https://immich.app) server, built for a Raspberry Pi with a DSI touch
display.

It boots straight into a fullscreen kiosk — no desktop, no mouse, no keyboard.
Browse your albums, pinch to zoom photos, play videos, run a slideshow, and see
the local weather. It doubles as a speaker (Bluetooth or Spotify Connect), takes
photos and notes shared from a phone, and switches to a dashboard of nearly
forty widgets — clock, weather, calendar, news, trains, bins, chores, your
network and your servers — that you arrange from a browser.

Built with Flutter as a native Linux app, so it stays smooth on a Pi.

| | |
|---|---|
| **[INSTALL.md](INSTALL.md)** | Setting it up: the hardware, the install, and every optional feature — Spotify, Bluetooth, the camera, the share inbox, the dashboard's widgets, turning the screen off with Alexa. Troubleshooting too. |
| **[THEMES.md](THEMES.md)** | The sixteen themes, each shown on the real panel, and how to make your own. |
| **[TECHNICAL.md](TECHNICAL.md)** | How it works: the dashboard's widget registry and editor, the encryption, the visualiser, the APIs it talks to, the project layout, debug hooks and the libraries it is built on. |

---

## Screenshots

### Photos

| The home screen | An album |
|---|---|
| ![The home screen: a greeting, a mini player and the albums](docs/screenshots/home.jpg) | ![An album's photo wall](docs/screenshots/album.jpg) |
| A greeting and the library in numbers, a mini player while music plays, and the albums. | A photo wall with headings that follow the photos rather than the calendar. |

| Photo viewer | Slideshow |
|---|---|
| ![The photo viewer](docs/screenshots/photo-viewer.jpg) | ![The slideshow with the weather and now playing](docs/screenshots/slideshow.jpg) |
| Pinch, double-tap or the +/− buttons to zoom; swipe for the next. | Photo-frame mode: the weather and what's playing in the corners, drifting slowly so nothing burns in. |

![The weather panel expanded over the slideshow](docs/screenshots/weather.jpg)

Tap the weather in the corner for a fortnight's forecast.

![Slideshow animation](docs/screenshots/05-slideshow-animation.gif)

Ken Burns pan with a cross-fade between slides *(also as
[MP4](docs/screenshots/05-slideshow-animation.mp4))*.

### Now playing

![The full-screen player](docs/screenshots/now-playing.jpg)

When music is playing the player takes over the screen, with the album art
blurred behind, a visualiser of what is actually coming out of the speaker, and
controls sized for a thumb — like, shuffle, repeat and add-to-playlist included.
Shrink it and it tucks into the mini player on the home screen, or into the Now
playing tile on the dashboard.

### The dashboard

![The dashboard: clock, weather, TV remote, now playing and the news](docs/screenshots/dashboard.jpg)

A 12×8 grid of widgets in pages that turn themselves — or hold, with the pause
beside the page dots. Play and pause are in the top bar on every page whenever
something is playing. Pages can have hours of their own: a morning page from
six till nine, a night page after ten.

| Home lab | Network |
|---|---|
| ![Servers, services, notes, sun and moon, certificates, updates and a memory](docs/screenshots/dashboard-homelab.jpg) | ![UniFi network health, clients, devices, throughput and speed tests](docs/screenshots/dashboard-network.jpg) |
| This Pi and the NAS with disk health from SMART, services, certificates, updates, notes and a memory from this day. | UniFi health, who's on the network, the router and switches, and two speed tests: to the internet, and across your own wiring. |

| Around the house | Calendar and photos |
|---|---|
| ![Grid carbon, on this day in history, train departures and chores](docs/screenshots/dashboard-around-the-house.jpg) | ![A month calendar beside a photo](docs/screenshots/dashboard-calendar.jpg) |
| How clean the electricity is, the next trains, a chores chart with stars, and something from history. | Your calendars and a photo from Immich. |

| The full forecast | Switching TV inputs |
|---|---|
| ![The full forecast](docs/screenshots/forecast.jpg) | ![The TV inputs](docs/screenshots/tv-inputs.jpg) |
| Tap the weather: now, the next 24 hours as a curve, and the week on one scale. | The TV remote's Input button: every input, and what is plugged into each. |

![The Omarchy hotkeys cheat sheet](docs/screenshots/dashboard-omarchy.jpg)

A page of its own for the Omarchy keyboard shortcuts.

### Themes

[![Sixteen themes](docs/screenshots/themes/all.jpg)](THEMES.md)

Sixteen themes, dark and light, glassy, glossy and flat, and each one dresses
the whole kiosk: the photo browser, the music player and Settings as well as
the dashboard. **[THEMES.md](THEMES.md)** shows each one full size.

### Arranged from a browser

![The dashboard editor in a browser](docs/screenshots/editor.jpg)

The editor runs on the panel and opens in any browser on your network. The
previews are the panel's own drawing of each widget, so what you lay out is
what you get. Widgets come in folding groups; drag to place and resize,
reorder pages by dragging their tabs.

### Settings and more

| Settings | About |
|---|---|
| ![Settings, in tabs](docs/screenshots/settings.jpg) | ![The About screen](docs/screenshots/about.jpg) |
| In six tabs: Photos, Music, Home, Display, Sharing and System. | Every library the app is built on, with its licence. |

![A shared link open in Firefox](docs/screenshots/10-firefox-article.jpg)

A link shared from a phone opens in Firefox with the browser's furniture hidden
and a close button the kiosk draws itself.

> Personal details in these screenshots — the server's address, device names,
> the household's notes and the album covers on the home screen — are blurred or
> pixelated. Album artwork shown is © its respective rights holder, fetched live
> to demonstrate the UI; this project claims no ownership of it.

---

## Features

**Photos & video** — every Immich album, sortable and with empty ones hidden;
a full-screen viewer with pinch-zoom, double-tap zoom and swipe; video via
libmpv with speed, scrub, zoom and volume; portrait and landscape uncropped.

**Slideshow** — fade, slide, Ken Burns or page-turn transitions, shuffle, a
blurred backdrop behind letterboxed shots, and several albums played as one.

**Music** — pair a phone over Bluetooth and the Pi becomes its speaker, or play
Spotify on it directly as a Connect device named "Kiosk". With Premium the panel
controls the account: seek, like, add to a playlist, pick the device, see the
queue.

**The dashboard** — nearly forty widgets in groups, arranged from a browser:

| Group | Widgets |
|---|---|
| Time & day | Clock, Calendar, Timers, Sun & moon, Countdowns (with bank holidays) |
| Weather & air | Weather with a full forecast, Air & pollen, Rain soon |
| Photos, music & TV | Now playing, TV remote, Photo, On this day, Immich library, Birthdays |
| Around the house | Bin day, Notes, Shopping list, Grid carbon, Lights (Govee), Home Assistant, Meal plan, Chores & rewards |
| Getting out | Train departures |
| News & reference | News feeds (with adverts filtered out), On this day in history, Omarchy hotkeys |
| Network | UniFi health, Who's home, UniFi devices, Network clients, WAN throughput, ISP speed test, Speed test, LAN speed test |
| Home lab | Servers (with SMART disk health), Services, Certificates, Updates |

Sixteen [themes](THEMES.md) — dark and light, glassy, glossy and flat, dressing the whole kiosk — plus a JSON template for your own, twenty fonts, per-widget sizing,
pages and widgets that show only at certain hours, and an optional background
of your own photos behind the tiles.

**Share Inbox** — a companion Android app (in this repo) shares photos, GIFs,
videos, links and notes to the kiosk from any app's share sheet, from anywhere,
**end-to-end encrypted** with a fresh key per message. Notes can be read aloud
by a voice that runs on the Pi.

**A phone as a camera** — an old Android phone running IP Webcam becomes a
camera in a corner window; pinch to drive the phone's own zoom.

**Private content** — opens Immich's Locked Folder with your PIN, and re-locks
when you leave.

**Built for a wall** — panels drift slowly against burn-in; the screen turns
itself off when idle and wakes on touch (or by voice, through Alexa); starts on
boot and restarts if it crashes; caches aggressively on disk.

---

## Getting started

You need a **Raspberry Pi 5** (or 4) with a touch display, running **Raspberry
Pi OS** (trixie), and an **Immich server**. On the Pi, open a terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/vwillcox/HomeCanvas/main/install.sh | bash
```

The installer walks you through everything, asking before it changes anything:
it installs what's needed, builds HomeCanvas, connects it to Immich, names it
on your network and starts it on boot. Run the same command again later to
update. It also works on Debian, Ubuntu, Fedora, Arch and openSUSE, on 64-bit
ARM or Intel/AMD.

**[INSTALL.md](INSTALL.md)** has the steps done by hand, and the optional
extras: Spotify, the weather, Home Assistant, sharing from your phone.

---

## Privacy

HomeCanvas talks to your own Immich server, and to a public service only when
you add a widget that needs one — Open-Meteo for the weather, National Grid ESO
for grid carbon, Realtime Trains for departures — sending no more than that
widget needs: a place, a postcode district, a station. No analytics, no
accounts of ours. Your credentials live in `~/.config/homecanvas/config.json` on
the device and are never committed. Shares from the companion app are
end-to-end encrypted, so even a reverse proxy in the path cannot read them.

---

## Licence

[MIT](LICENSE) — do what you like with it, no warranty.

Third-party libraries, their licences and credits for adapted code are in
[TECHNICAL.md](TECHNICAL.md#third-party-libraries) and on the device under
**Settings → System → About**, so attribution travels with the app.
