#!/system/bin/sh
# powerkeyd — sleep on power-button press, restore brightness + touch on resume.
# Started by init.rc (or wifi-bringup); holds /sys/power/wake_lock so the
# device only sleeps when we explicitly write to /sys/power/state.

LOCK=droidspaces
BRIGHT=3276
INPUT=/dev/input/event0

# Helper: log to /linux/powerkeyd.log and pmsg.
LOGF=/linux/powerkeyd.log
log() {
    printf '%s %s\n' "$(date +%T)" "$*" >> "$LOGF"
    echo "POWERKEYD: $*" > /dev/pmsg0 2>/dev/null
}

: > "$LOGF"
log "start"
echo "$LOCK" > /sys/power/wake_lock

# Brightness keeper: recovery-console resets brightness to its default
# (200) on idle, both at startup and on its internal timer. Reassert
# our 80% level every 2s. While we're suspended /sys/class is also
# suspended, so this loop just gets paused and resumes naturally.
(
    while true; do
        cur=$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null)
        if [ -n "$cur" ] && [ "$cur" -lt "$BRIGHT" ]; then
            echo "$BRIGHT" > /sys/class/backlight/panel0-backlight/brightness 2>/dev/null
            echo "$BRIGHT" > /sys/class/backlight/backlight/brightness 2>/dev/null
        fi
        sleep 2
    done
) &

# recovery-console grabs event0 (qpnp_pon) exclusively, so we can't
# read KEY_POWER directly. Instead, poll bl_power: it goes 0->4 on
# blank (sleep) and 4->0 on wake. On the 4->0 edge, fire force_resume
# so the Novatek touch IC comes back up.
BL=/sys/class/backlight/panel0-backlight/bl_power
prev=$(cat "$BL" 2>/dev/null)
log "bl_power watch start (initial=$prev)"
while true; do
    cur=$(cat "$BL" 2>/dev/null)
    if [ "$prev" != "$cur" ]; then
        log "bl_power $prev -> $cur"
        if [ "$prev" != "0" ] && [ "$cur" = "0" ]; then
            # transition off->on: wake
            echo 1 > /proc/touchpanel/force_resume 2>/dev/null
            echo "$BRIGHT" > /sys/class/backlight/panel0-backlight/brightness 2>/dev/null
            log "  fired force_resume + brightness restore"
        fi
        prev="$cur"
    fi
    sleep 1
done
