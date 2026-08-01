# TabletPi

A touchscreen **Immich** photo/video browser for a Raspberry Pi with a 10" DSI
touch display. Built with Flutter (native Linux), running fullscreen in kiosk
mode on labwc/Wayland.

## Features

- Browse Immich albums (auto-fetched cover thumbnails, non-empty first)
- Full-screen photo viewer with pinch-zoom, double-tap zoom and swipe between
  assets
- **Video playback** (libmpv via `media_kit`) with a **playback-speed** selector
  (0.25×–2×), seek bar, and zoom
- **Slideshow** with configurable interval and **transitions** (fade / slide / Ken Burns),
  shuffle, and neighbour preloading
- **Locked Folder**: opens Immich's server-side Locked Folder via a session
  login + your PIN (see below); re-locks on exit
- **Weather overlay** in the slideshow: a corner panel (temperature, conditions,
  location, today's high/low) that **expands to a full-screen 7-day forecast**
  on tap and animates back on a second tap. Uses Open-Meteo + postcodes.io —
  **no API key required**. Location defaults to `CO1 1ZY`; corner, location and
  °C/°F are configurable in Settings.
- **Multi-select albums**: long-press albums on the home grid and play them all
  as one combined slideshow
- Aggressive **caching** on the NVMe (images, album lists) for instant restarts
- Touch-friendly **settings / control panel**: connection, Locked Folder status,
  weather, slideshow, cache size, and **Restart / Power off**

### Gestures

Multi-touch is enabled on the DSI panel (`ili_v3`), so the full gesture set is
available:

| Where | Gesture | Action |
|---|---|---|
| Albums grid | long-press | start multi-select |
| Albums grid | tap (in selection) | add/remove album |
| Photo viewer | pinch / double-tap | zoom in & out |
| Photo viewer | drag (zoomed) | pan |
| Photo viewer | swipe left/right | previous / next |
| Photo viewer | swipe down | close |
| Photo viewer | tap | hide/show chrome |
| Slideshow | swipe left/right | previous / next (pauses) |
| Slideshow | swipe down | exit |
| Slideshow | tap | hide/show controls |
| Video | double-tap left/right | skip ∓10s |
| Video | double-tap centre | play / pause |
| Video | drag horizontally | scrub |
| Video | drag vertically | volume |
| Video | swipe down | close |
| Video | pinch | zoom |

Drag-scrolling is enabled for every pointer kind via a custom `ScrollBehavior`.
Gestures that would fight `InteractiveViewer` are disabled while zoomed, and
panning is only enabled once zoomed in, so each gesture reaches the right
handler. On-screen +/- zoom buttons remain as a fallback.

Note there is **no on-screen keyboard**, so text fields (server URL, API key,
email, password) are set from `config.json` / SSH. The numeric PIN pad is
custom and works by touch.

## Hardware / target

- Raspberry Pi 5 (8 GB), Debian 13 (trixie), aarch64
- Compositor: **labwc** (Wayland). Display in landscape (1920×1200).
- Immich server reachable over the network; API-key auth.

## Architecture

```
lib/
  main.dart                    # providers + root gate (setup vs home)
  theme.dart                   # dark, touch-first theme
  config/app_config.dart       # config model (connection, weather, slideshow)
  models/immich_models.dart    # Album, Asset
  services/
    config_service.dart        # loads/saves ~/.config/tabletpi/config.json
    immich_service.dart        # Immich REST client (dio) + response caching
    locked_folder_service.dart # session login, PIN unlock, re-lock
    media_source.dart          # api-key vs Bearer media URLs/headers
    media_cache.dart           # NVMe-pinned image cache + image-cache tuning
    api_cache.dart             # JSON-on-disk cache for API responses
    weather_service.dart       # Open-Meteo forecast + geocoding
  screens/
    home_screen.dart           # albums grid, multi-select, Locked Folder tile
    album_screen.dart          # asset grid + Slideshow button
    gallery_screen.dart        # pinch-zoom swipe gallery
    video_player_screen.dart   # media_kit player, speed + gesture controls
    slideshow_screen.dart      # auto-advancing transitions
    locked_folder_screen.dart  # locked assets grid
    settings_screen.dart       # control panel
    setup_screen.dart          # first-run / edit connection
    pin_screen.dart            # numeric PIN pad
  widgets/
    remote_image.dart          # cached image w/ auth headers + retry/fallback
    big_back_button.dart       # 64px touch-friendly back target
    weather_overlay.dart       # corner panel -> full-screen 7-day forecast
```

**Immich endpoints used** (server v3.x): `GET /api/albums`,
`POST /api/search/metadata` (album assets), `GET /api/assets/{id}/thumbnail?size=thumbnail|preview`,
`GET /api/assets/{id}/original`, `GET /api/assets/{id}/video/playback`. All send
the `x-api-key` header.

## Configuration

Runtime config lives on the Pi at `~/.config/tabletpi/config.json` (see
[`config.example.json`](config.example.json)); it is **not** committed. Fields:
`immichUrl`, `apiKey` (normal browsing), `immichEmail` + `immichPassword`
(Locked Folder session login), and `slideshow`.

### Locked Folder

Immich's Locked Folder is gated behind a real login **session** — the API key
cannot unlock it. So the app logs in with your email + password to get a session
token, then `POST /api/auth/session/unlock {pinCode}` elevates it, lists
`visibility: locked` assets, and `POST /api/auth/session/lock` re-locks on exit.

Store the login on the Pi (hidden prompts) with:

```bash
bash deploy/set-immich-login.sh   # writes immichEmail/immichPassword into config.json
```

Then tap the **Locked Folder** tile on the home screen and enter your PIN.

## Dev workflow

The Mac holds the source; Flutter builds run on the Pi (arm64). Helper scripts:

```bash
scripts/pi-setup.sh   # one-time, run ON THE PI (sudo): installs Flutter + libmpv
scripts/sync.sh       # rsync Mac source -> Pi (~/tabletpi)
scripts/run.sh        # sync + build --release + restart the kiosk service
scripts/run.sh debug  # sync + flutter run (hot reload) on the Pi display
scripts/shot.sh       # grab the Pi's screen (grim) to a PNG for verification
```

Environment overrides: `PI_HOST` (default `vwillcox@tabletpi.local`),
`PI_DIR` (default `/home/vwillcox/tabletpi`).

## Kiosk / autostart

- systemd **user** service: [`deploy/tabletpi.service`](deploy/tabletpi.service)
  → `~/.config/systemd/user/tabletpi.service`
- labwc autostart: [`deploy/labwc-autostart`](deploy/labwc-autostart)
  → `~/.config/labwc/autostart` (starts the service once the compositor is up)

Operate it:

```bash
systemctl --user restart tabletpi     # relaunch
systemctl --user stop tabletpi        # stop
journalctl --user -u tabletpi -f      # logs
```

The GTK window starts fullscreen/borderless. Set `TABLETPI_WINDOWED=1` to run in
a normal decorated window for debugging.

## Known notes

- `Failed to create AudioController: Unable to find mixer control: Master` in the
  log is a harmless `media_kit` ALSA volume probe; audio still plays via the
  default sink.
- Screen blanking: if the panel sleeps, disable the session idle timeout (labwc
  has no blanking of its own; the Pi desktop's idle handling can be adjusted).
