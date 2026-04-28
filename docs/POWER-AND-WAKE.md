# Power button + wake handling

## Problem

In the slot-B recovery, when the user presses the power button:

1. `recovery-console` (which has `EVIOCGRAB`'d `/dev/input/event0`)
   sees the `KEY_POWER` press and blanks the panel via DRM —
   `bl_power` goes `0 → 4`.
2. A second power press un-blanks — `bl_power` goes `4 → 0`.

The display comes back, but **touch is dead** because the Novatek IC
needs an explicit `/proc/touchpanel/force_resume` write to come out
of suspend (recovery-console drives DRM via legacy `SETCRTC`, not
through `mdss_panel_notifier` — same reason we already needed the
force_resume hook to get touch working at boot).

There's also a separate issue: `recovery-console` lowers brightness
on its idle timer.

## Solution: `/linux/powerkeyd.sh`

A small init service that runs alongside the wifi-bringup. It does
two things:

### 1. Brightness keeper

```sh
while true; do
    cur=$(cat /sys/class/backlight/panel0-backlight/brightness)
    if [ "$cur" -lt 3276 ]; then
        echo 3276 > /sys/class/backlight/panel0-backlight/brightness
    fi
    sleep 2
done
```

Reasserts 80% brightness whenever recovery-console drops it. Runs
in a backgrounded subshell.

### 2. bl_power transition watcher

`getevent` on `/dev/input/event0` was the natural choice, but
`recovery-console` calls `EVIOCGRAB` on it, so anyone else listening
sees nothing. Instead, poll `bl_power`:

```sh
while true; do
    cur=$(cat /sys/class/backlight/panel0-backlight/bl_power)
    if [ "$prev" != "0" ] && [ "$cur" = "0" ]; then
        # transition off->on: wake
        echo 1 > /proc/touchpanel/force_resume
        echo 3276 > /sys/class/backlight/panel0-backlight/brightness
    fi
    prev="$cur"
    sleep 1
done
```

Detects the `4 → 0` transition (wake) and fires `force_resume` plus
re-asserts brightness.

## init.rc service

```
service powerkeyd /system/bin/sh -c "/linux/powerkeyd.sh"
    user root
    group root
    disabled
    seclabel u:r:recovery:s0
```

Started from `on boot` alongside `wifi-bringup`. The
`/system/bin/sh -c "..."` wrapper is required because init validates
the service binary path at parse time, and `/linux/` isn't mounted
when init.rc is parsed. Same trick `wifi-bringup` uses.

## Wake_lock

`powerkeyd` writes `droidspaces` to `/sys/power/wake_lock` at start.
That blocks kernel autosuspend, so the device only ever sleeps via
`recovery-console`'s own panel blank — never via an idle kernel
timeout. (The original "device sleeps without me touching it" report
was recovery-console's idle blank, not kernel autosuspend; the
wake_lock keeps kernel-level state stable while recovery-console
manages display state.)

## Why not just patch recovery-console?

`recovery-console` is a third-party binary we already maintain a
fork of (for OSK + force_resume at startup). Adding power-key /
brightness behavior there means another patch to carry. A separate
daemon also works regardless of which UI is on the panel — Ubuntu
console, plain shell, or recovery-console — without re-patching.

## Log

`/linux/powerkeyd.log` — short transcript:

```
19:55:54 start
19:55:54 bl_power watch start (initial=0)
19:56:00 bl_power 0 -> 4         # power pressed, sleep
19:56:02 bl_power 4 -> 0         # power pressed, wake
19:56:02   fired force_resume + brightness restore
```

Useful for debugging if touch ever doesn't recover.
