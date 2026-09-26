#!/usr/bin/env bash
# Run for you by scripts/setup-port-80.sh, which also deals with anything
# already on port 80; use that rather than this. See INSTALL.md, "The editor
# on port 80".
#
# Let HomeCanvas serve its editor on port 80, so the address is simply
# http://homecanvas.local. Linux keeps ports below 1024 for root; this lowers
# that line to 80 for everyone on the Pi, now and after every reboot.
# Run on the Pi:  sudo bash deploy/enable-port-80.sh
#
set -e
if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo bash $0"
  exit 1
fi

CONF=/etc/sysctl.d/60-homecanvas-port-80.conf
cat > "$CONF" <<'CONF'
# HomeCanvas: let an ordinary user open port 80 for the dashboard editor.
net.ipv4.ip_unprivileged_port_start = 80
CONF
chmod 644 "$CONF"

# Now, without waiting for a reboot. Written directly because Raspberry Pi
# OS does not always put `sysctl` on the path.
echo 80 > /proc/sys/net/ipv4/ip_unprivileged_port_start
echo "Installed $CONF — ports from 80 up are open to ordinary users."
echo "Restart HomeCanvas to pick it up:  systemctl --user restart homecanvas"
