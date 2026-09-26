#!/usr/bin/env bash
# Give the Pi a name you can type instead of its IP address.
# Run this ON THE PI: bash scripts/set-hostname.sh [name]   (default: homecanvas)
#
# Sets the hostname and makes sure Avahi is announcing it over mDNS, so every
# machine on the network can reach the kiosk as <name>.local — the dashboard
# editor at http://homecanvas.local:8090, and SSH as pi@homecanvas.local.
set -euo pipefail

NAME="${1:-homecanvas}"

# Hostnames are letters, digits and hyphens, not starting or ending with one.
if ! [[ "$NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
  echo "Not a valid hostname: $NAME" >&2
  exit 1
fi

OLD="$(hostname)"
echo "==> Hostname: $OLD -> $NAME"
sudo hostnamectl set-hostname "$NAME"

# Debian resolves its own name through the 127.0.1.1 line; left pointing at
# the old name, sudo complains "unable to resolve host" on every call.
if grep -qE '^127\.0\.1\.1\b' /etc/hosts; then
  sudo sed -i -E "s/^127\.0\.1\.1\b.*/127.0.1.1\t$NAME/" /etc/hosts
else
  printf '127.0.1.1\t%s\n' "$NAME" | sudo tee -a /etc/hosts >/dev/null
fi

# Raspberry Pi OS ships Avahi, but a Lite image or a trimmed install may not.
# (install.sh installs it on other Linuxes; here only apt is tried.)
if ! command -v avahi-daemon >/dev/null && [ ! -x /usr/sbin/avahi-daemon ]; then
  if command -v apt-get >/dev/null; then
    echo "==> Installing avahi-daemon..."
    sudo apt-get update
    sudo apt-get install -y avahi-daemon
  else
    echo "Avahi isn't installed — install it (avahi, nss-mdns) and run this again." >&2
    exit 1
  fi
fi

# Only announce on real network cards. Left to itself Avahi also announces
# Docker's bridge, and other machines then resolve the name to 172.17.0.1 —
# an address that only exists inside the Pi. Physical interfaces (eth0,
# wlan0) are the ones with a device behind them in sysfs.
IFACES=""
for dev in /sys/class/net/*; do
  [ -e "$dev/device" ] && IFACES="${IFACES:+$IFACES,}$(basename "$dev")"
done
if [ -n "$IFACES" ]; then
  CONF=/etc/avahi/avahi-daemon.conf
  echo "==> Limiting mDNS to: $IFACES"
  if grep -qE '^#?allow-interfaces=' "$CONF"; then
    sudo sed -i -E "s/^#?allow-interfaces=.*/allow-interfaces=$IFACES/" "$CONF"
  else
    sudo sed -i -E "/^\[server\]/a allow-interfaces=$IFACES" "$CONF"
  fi
fi

echo "==> Announcing $NAME.local over mDNS..."
sudo systemctl enable avahi-daemon
# A restart, not a reload: Avahi only picks up the new hostname on start.
sudo systemctl restart avahi-daemon

echo
echo "Done. From another machine on the network:"
echo "  dashboard editor:  http://$NAME.local:8090"
echo "  ssh:               ssh $(id -un)@$NAME.local"
echo
echo "Restart the kiosk (systemctl --user restart homecanvas) so it shows the"
echo "new address on screen, and update PI_HOST in scripts/local.env on the"
echo "machine you build from."
