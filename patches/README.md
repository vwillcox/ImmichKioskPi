# Patches

Local patches to third-party software this kiosk depends on, kept here so a
rebuild doesn't silently lose them.

## `librespot-connect-page-index.patch`

Fixes Spotify Connect transfers **out of** the kiosk resetting the track to
the beginning — move playback from "Kiosk" to a phone or desktop and the
song would restart instead of resuming.

Upstream bug: [librespot#1459](https://github.com/librespot-org/librespot/issues/1459)
(open since January 2025). Applies to librespot `dev` @ `9c7d756` (v0.8.0).

### The cause

Spotify describes a position in a context as a `ContextIndex { page, track }`
pair. librespot flattens every resolved context page into one list and tracks
its position as a single flat index — and the transmitted `page` is never
assigned at all, so it's always `0`.

For a context that fits in one page, `{page: 0, track: N}` is accidentally
correct, which is why small playlists transfer fine. For anything larger — a
long playlist, or Liked Songs — the flat index runs past the end of page 0,
so the pair points at a track that doesn't exist there. The receiving client
can't resolve it and falls back to the start of the context.

That also explains the second symptom reported upstream — that after a
transfer, "next track" jumps to the *first* track of Liked Songs. That's
exactly where `page: 0` lands. And it explains why a maintainer could only
reproduce it with Liked Songs and not a 3-track playlist: the bug needs a
multi-page context, and Liked Songs is simply the context most likely to be
one.

### The fix

Record where each page begins in the flattened list (`page_offsets`), then
translate the flat index back into a `(page, track-within-page)` pair — but
only in `request_to_send()`, at the moment the state goes on the wire. All of
librespot's internal bookkeeping keeps working on flat indices exactly as
before, so the blast radius is one function at the network edge.

Shuffled contexts are deliberately left alone: they aren't played in page
order, so a page/track pair can't describe a position within them.

### Building

Needs an aarch64 Linux build for the Pi. On an Apple Silicon Mac, Docker runs
arm64 containers natively, so this builds at full speed without cross
toolchains:

```bash
git clone --depth 1 --branch dev https://github.com/librespot-org/librespot.git
cd librespot
git apply /path/to/librespot-connect-page-index.patch

docker run --rm --platform linux/arm64 -v "$PWD":/src -w /src rust:1-trixie bash -c '
  export PATH=/usr/local/cargo/bin:$PATH
  apt-get update -qq && apt-get install -y -qq libpulse-dev libasound2-dev pkg-config build-essential libssl-dev
  cargo build --release --no-default-features \
    --features "pulseaudio-backend,alsa-backend,native-tls,with-libmdns"'
```

`with-libmdns` matters — that's what advertises the device over mDNS so it
appears in Spotify's Connect picker at all.

Match the container's Debian release to the Pi's (`trixie` here) so the
binary links against a compatible glibc.

### Installing

The build output (`target/release/librespot`) goes to `~/librespot-patched/`
on the Pi, and `~/.config/systemd/user/librespot.service` points `ExecStart`
at it. The distro-installed `/usr/bin/librespot` is left untouched, so
reverting is just a matter of pointing `ExecStart` back at it.
