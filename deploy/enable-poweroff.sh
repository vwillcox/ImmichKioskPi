#!/usr/bin/env bash
# Allow the kiosk user to power off / reboot without a password prompt, so the
# in-app Power button works. Run on the Pi:  sudo bash deploy/enable-poweroff.sh
set -e
if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo bash $0"
  exit 1
fi

USER_NAME="${SUDO_USER:-$(logname 2>/dev/null || true)}"
if [ -z "$USER_NAME" ]; then
  echo "Could not determine the desktop user. Re-run with: sudo bash $0"
  exit 1
fi
RULE=/etc/polkit-1/rules.d/50-immich_kiosk_pi-power.rules

cat > "$RULE" <<EOF
// Allow $USER_NAME to power off / reboot the kiosk without authentication.
polkit.addRule(function(action, subject) {
  if (subject.user == "$USER_NAME" &&
      (action.id == "org.freedesktop.login1.power-off" ||
       action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
       action.id == "org.freedesktop.login1.reboot" ||
       action.id == "org.freedesktop.login1.reboot-multiple-sessions")) {
    return polkit.Result.YES;
  }
});
EOF

chmod 644 "$RULE"
echo "Installed $RULE for user '$USER_NAME'."
echo "Verifying..."
sudo -u "$USER_NAME" dbus-send --system --print-reply \
  --dest=org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager.CanPowerOff 2>/dev/null | tail -1
echo "If that says \"yes\", the in-app Power button will work."
