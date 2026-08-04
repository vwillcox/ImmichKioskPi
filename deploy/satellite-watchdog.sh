#!/usr/bin/env bash
# Restart the Wyoming satellite when it stops feeding the wake word engine.
#
# The satellite can get stuck after a dropped connection or a failed
# speech-to-text round trip: it keeps its sockets open and carries on logging
# "Waiting for wake word", but stops sending audio. Nothing errors, so it looks
# entirely healthy while hearing nothing — which from across the room is
# indistinguishable from the wake word not working.
#
# The tell is the *wake engine's* CPU, not the satellite's. A deaf satellite
# still reads its microphone — it accrues CPU quite happily — it just stops
# forwarding audio. openWakeWord, on the other hand, only burns CPU when audio
# actually arrives. Measured on this machine: 75 ticks per 10s while listening,
# a flat 0 when the satellite has gone deaf.
#
# The engine runs in a container, but containers share the host PID namespace,
# so /proc/<pid>/stat is readable without going near the docker socket.
#
# Deliberately does not use `docker stats`: this runs as a systemd *user*
# service, and the user manager keeps whatever groups it was started with. If
# the docker group was granted after that manager started, the socket is
# unreadable here even though it works fine in a login shell.
set -u

SERVICE=wyoming-satellite.service
# Match the wake engine process on the host, container or not.
WAKE_PATTERN="[w]yoming_openwakeword"
LOG="$HOME/.cache/immich_kiosk_pi/satellite.log"
CHECK_SECONDS=90
# Ticks below which the engine counts as receiving nothing. It accrues roughly
# 675 per 90s while listening, so this is a wide margin.
IDLE_TICKS=30
# Two consecutive idle samples before acting, so a quiet moment isn't enough.
IDLE_LIMIT=2

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') watchdog: $*" >> "$LOG"; }

cpu_ticks() {   # utime + stime for a pid, or empty if it's gone
    local pid=$1 stat
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    # Strip through the comm field, which may itself contain spaces.
    stat=${stat#*") "}
    awk '{print $12 + $13}' <<<"$stat"
}

log "started (pid $$)"
idle=0
prev_pid=""
prev_ticks=""

while true; do
    sleep "$CHECK_SECONDS"

    pid=$(pgrep -f "$WAKE_PATTERN" | head -1)
    if [ -z "$pid" ]; then
        log "wake engine process not found - restarting satellite"
        systemctl --user restart "$SERVICE"
        idle=0; prev_pid=""; prev_ticks=""
        sleep 30
        continue
    fi

    ticks=$(cpu_ticks "$pid") || ticks=""
    if [ -z "$ticks" ]; then
        log "could not read /proc/$pid/stat - skipping this check"
        prev_pid=""; prev_ticks=""
        continue
    fi

    # Only compare against the same process; a restart resets the counters.
    if [ "$pid" = "$prev_pid" ] && [ -n "$prev_ticks" ]; then
        delta=$((ticks - prev_ticks))
        if [ "$delta" -lt "$IDLE_TICKS" ]; then
            idle=$((idle + 1))
            log "idle sample $idle/$IDLE_LIMIT (${delta} ticks in ${CHECK_SECONDS}s)"
        elif [ "$idle" -ne 0 ]; then
            idle=0
        fi
    fi

    prev_pid=$pid
    prev_ticks=$ticks

    if [ "$idle" -ge "$IDLE_LIMIT" ]; then
        log "satellite has gone deaf - restarting"
        systemctl --user restart "$SERVICE"
        idle=0; prev_pid=""; prev_ticks=""
        sleep 30
    fi
done
