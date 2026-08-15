# Kiosk Share

The companion Android app for [ImmichKioskPi](../README.md)'s Share Inbox.
Registers as a share target — pick "Kiosk Share" from any app's share sheet
(Photos, Chrome, a video, anything) to send a photo, GIF, video, link or
note to the kiosk directly.

There's no separate relay or server for this app to talk to: the kiosk
itself listens for these (see `../lib/services/share_inbox_service.dart`).
This app just needs the kiosk's address and a token, both handed to you by
whoever owns the kiosk (from its Settings → Share Inbox screen).

## Setup

1. Install the app and open it once.
2. Tap the gear icon, enter the kiosk's address (e.g.
   `https://mine.example.com`) and the token you were given.
3. Save. Nothing else to do — the app runs quietly as a share target from
   here on.

## Sharing something

From any other app, use its normal Share button and pick **Kiosk Share**.
That's it — it shows up on the kiosk within a couple of seconds, with a
chime (unless Do Not Disturb is on there).

## Development

```bash
flutter pub get
flutter run          # needs a connected device/emulator
flutter build apk     # release: flutter build apk --release
```

Multiple people can each have their own copy of this app pointed at the same
kiosk — every person gets their own name + token from the kiosk's Settings,
so shares show up attributed ("From: Mum's phone").
