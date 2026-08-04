#!/usr/bin/env bash
# Restart the Wyoming satellite when it stops feeding the wake word engine.
#
# The satellite can get stuck after a failed speech-to-text round trip: it keeps
# the TCP connection to the wake service open and keeps logging "Waiting for wake
# word", but stops sending audio. Nothing errors, so it looks healthy while being
# completely deaf — which is indistinguishable, from the sofa, from the wake word
# not working.
#
# The tell is the wake engine sitting at 0% CPU. It burns a few percent whenever
# audio is arriving, so sustained idle means nothing is being sent.
set -u

CONTAINER=wyoming-openwakeword
SERVICE=wyoming-satellite.service
LOG="$HOME/.cache/immich_kiosk_pi/satellite.log"
CHECK_SECONDS=120
# Two consecutive idle checks before acting, so a momentary lull isn't enough.
IDLE_LIMIT=2

idle=0
while true; do
    sleep "$CHECK_SECONDS"

    cpu=$(docker stats --no-stream --format '{{.CPUPerc}}' "$CONTAINER" 2>/dev/null | tr -d '%')
    [ -z "$cpu" ] && continue          # container restarting; try again later

    if awk -v c="$cpu" 'BEGIN { exit !(c < 0.5) }'; then
        idle=$((idle + 1))
    else
        idle=0
    fi

    if [ "$idle" -ge "$IDLE_LIMIT" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') watchdog: wake engine idle at ${cpu}% - restarting satellite" >> "$LOG"
        systemctl --user restart "$SERVICE"
        idle=0
        sleep 30                        # let it settle before judging again
    fi
done
