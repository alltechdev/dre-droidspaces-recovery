# Init flow walk-through

The slot-B boot path is a sequence of small init.rc edits + scripts.
This file documents what each piece does and why, in the order init
fires them.

## Files involved

```
ramdisk-overlay/
├── system/etc/init/hw/init.rc            # full replacement of stock init.rc
├── system/bin/recovery-console           # the panel UI (binary, see recovery-console repo)
├── system/bin/boot-ubuntu.sh             # the wrapper recovery-console exec's
└── system/bin/selinux-permissive         # echo 0 > /sys/fs/selinux/enforce
```

## init.rc edits over stock LineageOS recovery's init.rc

The init.rc in the overlay is a **full replacement** (not a patch
applied by `build.sh`'s patches/ — that has just `02-disable-adb-
auth.patch` for prop.default). The differences from stock:

### `on init`

Adds:

```
start selinux-permissive
```

Disables SELinux enforcement at the very start of init so that
nothing else needs SELinux policy edits. Combined with prop.default's
`ro.secure=0 / ro.adb.secure=0 / ro.debuggable=1` (patch 02), adb is
root with no auth handshake.

### `on boot`

Adds:

```
start recovery-console-bringup
```

after `class_start hal`. The bringup shim sleeps 2 seconds (so
lineage recovery has fully powered the DSI panel + WLED) then starts
recovery-console.

### `on fs && property:sys.usb.configfs=1`

Adds an `ncm.usb0` USB function alongside `ffs.adb` and `ffs.fastboot`:

```
mkdir /config/usb_gadget/g1/functions/ncm.usb0
write /config/usb_gadget/g1/functions/ncm.usb0/host_addr DA:7E:D5:FF:FF:01
write /config/usb_gadget/g1/functions/ncm.usb0/dev_addr  DA:7E:D5:FF:FF:02
```

### `on property:sys.usb.config=adb && property:sys.usb.ffs.ready=1 && property:sys.usb.configfs=1`

Adds:

```
symlink /config/usb_gadget/g1/functions/ncm.usb0 /config/usb_gadget/g1/configs/b.1/f2
```

So when adb mode is selected, the gadget exposes BOTH `ffs.adb`
(`f1`) AND `ncm.usb0` (`f2`). Host sees a single USB cable carrying
adb + a CDC-NCM ethernet endpoint. We use it for installing packages
(apt) without bringing up wifi — wifi requires a much deeper port of
cnss-daemon.

**Important caveat about init.rc symlinks**: configfs only accepts
symlinks created by init's privileged `symlink` keyword. A userspace
`ln -s` from a shell — even as root — gets EPERM. So this line has
to live in init.rc.

### Service definitions (appended)

```
service selinux-permissive /system/bin/selinux-permissive
    disabled
    oneshot
    user root
    group root
    seclabel u:r:recovery:s0

service recovery-console-bringup /system/bin/sh -c "sleep 2; start recovery-console"
    user root
    group root
    oneshot
    disabled
    seclabel u:r:recovery:s0

service recovery-console /system/bin/recovery-console --exec /system/bin/boot-ubuntu.sh
    user root
    group root
    oneshot
    disabled
    seclabel u:r:recovery:s0
```

All three are `disabled` so they don't auto-start with class_default;
they're explicitly fired via `start` from `on init` (selinux) or
`on boot` (bringup → console).

## boot-ubuntu.sh

```
#!/system/bin/sh
set -e

LINUX_DEV=/dev/block/by-name/userdata
LINUX_MNT=/linux

if ! mountpoint -q "$LINUX_MNT"; then
  mkdir -p "$LINUX_MNT"
  mount -t ext4 "$LINUX_DEV" "$LINUX_MNT"
fi

exec /linux/bin/droidspaces \
    -r /linux/rootfs \
    -n ubuntu \
    -h ubuntu \
    --hw-access \
    --privileged=full \
    --foreground \
    start
```

Recovery-console launches this as `--exec` in its PTY. droidspaces
runs in foreground so its container init's stdio is the PTY, and
recovery-console paints the resulting bytes onto the panel.

`--hw-access` exposes `/dev/dri`, `/dev/input/*`, etc. so the
container's userspace can talk to the GPU/touchpanel/etc. directly
when needed (e.g. wayland experiments — currently unused).

`--privileged=full` lifts seccomp + capability restrictions; needed
for systemd inside the container.

## What recovery-console does once exec'd

Order is verifiable in `recovery-console/main.c` (line numbers as of
commit `f958b6a`):

1. `input_init(&in)` (line 194) — opens `/dev/input/event*`,
   filters by `EV_KEY` capability so the touchpanel (BTN_TOUCH) and
   any USB OTG keyboards are picked up.
2. `(void)system(CMD_STOP)` (line 206 in foreground or 211 in
   `--background`) where `CMD_STOP = "stop recovery"`. Asks init to
   stop the lineage recovery binary so we can take DRM master.
3. `display_init(&disp)` (line 227) — opens `/dev/dri/card0`, sets
   `DRM_CLIENT_CAP_UNIVERSAL_PLANES`. `atomic_modeset()` looks up
   `ACTIVE` / `MODE_ID` property IDs and gets 0 for both because we
   intentionally do NOT set `DRM_CLIENT_CAP_ATOMIC` (we tried it in
   this session — the panel went black, reverted; see
   `recovery-console/docs/OSK.md` "Touch wake" for the longer note).
   So the code falls back to legacy `DRM_IOCTL_MODE_SETCRTC`,
   allocates a dumb buffer via `DRM_IOCTL_MODE_CREATE_DUMB`,
   modesets the panel, bumps the WLED to `BACKLIGHT_VAL`.
4. Write "1" to `/proc/touchpanel/force_resume` (line 237) — wakes
   the Novatek IC out of mdss-panel-notifier-driven suspend. Logs
   `touchpanel force_resume sent` on success or
   `touchpanel force_resume node missing — touch will be dead` if
   the kernel doesn't have the 003 patch applied.
5. Initialize the OSK with `osk_init(&osk, disp.width, disp.height)`,
   shrink the term grid by `osk_height_for(disp.width, disp.height)`
   pixels so the cells don't overlap the keyboard region.
6. `spawn_shell(&pty_fd, term.cols, term.rows, exec_cmd)` — forks
   `/bin/sh -c <argv>` (here: `boot-ubuntu.sh`) in a PTY at the
   right cell dimensions.
7. Enter the main loop:
   - PTY output → `term_write` → mark dirty rows → `display_render`
     → `osk_render` → `display_kick`
   - Keyboard `EV_KEY` events → `input_ev_to_pty()` → PTY
   - Touch `EV_ABS` + `BTN_TOUCH` events → `osk_touch_press` /
     `osk_touch_release` hit-test → synthesized `KEY_*` events →
     `input_ev_to_pty()` (with synthetic `KEY_LEFTSHIFT` /
     `KEY_LEFTCTRL` / `KEY_LEFTALT` press+release wrapping when
     sticky modifiers or autoshift caps are set) → PTY

## handoff diagram (slot B vs slot A)

```
device's GPT
├── boot_a / vendor_boot_a       # stock LineageOS Android (untouched)
├── boot_b / vendor_boot_b       # OUR images (kernel + recovery ramdisk)
├── userdata                     # ext4 we own; mounted at /linux
├── super (system/vendor/...)    # shared, read-only — both slots see this
├── modem_a / modem_b            # cellular firmware
└── persist, modemst, etc.       # shared
```

`fastboot set_active a` + `fastboot reboot` boots stock LineageOS
recovery (no user data → factory-reset prompt, but functional).
`fastboot set_active b` + `fastboot reboot recovery` boots us.
