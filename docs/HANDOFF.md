# HANDOFF

Read this file first when picking the project up cold.

## Active state (commit `d4eef41` on `main`)

**The UI is recovery-console**, drawing the term grid + on-screen
keyboard directly to `/dev/dri/card0` from the host (Android-recovery)
side. **No wayland compositor, no Xorg, no display manager runs.**
Inside the container is just Ubuntu's systemd → getty on tty1 → sh,
which recovery-console paints onto the panel.

Working:

- Slot-B `boot.img` + `vendor_boot.img` build cleanly via
  `./build.sh`. CRC-stable, perm-normalized cpio.
- Lineage recovery hands DRM master to recovery-console after a
  2-second sleep (`recovery-console-bringup` shim in init.rc).
- recovery-console wakes the Novatek touchscreen via the kernel's
  `/proc/touchpanel/force_resume` (provided by
  `dre-droidspaces-kernel` patch 003) and reads `EV_ABS` /
  `BTN_TOUCH` directly.
- On-screen keyboard renders 5 rows: a Termux-style extras row on
  top (ESC TAB CTRL ALT arrows HOME END), 4 rows of qwerty / symbols
  underneath. `?123` swaps to a numbers + symbols page; sticky
  CTRL/ALT latch on tap; auto-shift caps for `{` `|` `:` `$` `%`
  etc. Press visual tracks the finger live (no stale-cell flash).
- USB tether works: gadget configfs in init.rc adds an `ncm.usb0`
  function alongside `ffs.adb`, so the same USB cable carries adb
  AND a CDC-NCM ethernet endpoint. Use it to apt-install in the
  container.
- adb-as-root, no auth handshake (prop.default flipped via
  `patches/02-disable-adb-auth.patch`).
- `root` / `linux` is the current Ubuntu container login (we set it
  during the session via `echo root:linux | chpasswd`).

Pushed:

- https://github.com/alltechdev/dre-droidspaces-recovery — `main`
  at `d4eef41`.
- Release `v20260426` attaches `boot-slot-b.img` and
  `vendor_boot-slot-b.img`.

## Repo layout

```
build.sh                        # rebuild boot.img + vendor_boot.img
patches/02-disable-adb-auth.patch # ramdisk patch applied during build
ramdisk-overlay/                # files that overlay onto stock vendor_boot ramdisk
├── system/etc/init/hw/init.rc  # full replacement init.rc
├── system/bin/recovery-console # built binary (from recovery-console fork)
├── system/bin/boot-ubuntu.sh   # wrapper exec'd by recovery-console
└── system/bin/selinux-permissive
tools/                          # magiskboot + lpunpack/lpmake
work/                           # build scratch (gitignored)
out/                            # final boot images (gitignored)
docs/                           # this directory
```

`kernel-Image-droidspaces` is gitignored; it's a copy of
`~/dre/out/arch/arm64/boot/Image` that build.sh consumes.

## Direct dependencies

- `~/dre` — kernel build. `build.sh` reads
  `~/dre/out/arch/arm64/boot/Image` (or the local copy at
  `kernel-Image-droidspaces`). Touch input on the panel ALSO
  requires `~/dre`'s patch 003 — without it
  `/proc/touchpanel/force_resume` doesn't exist and recovery-console
  prints `touchpanel force_resume node missing — touch will be dead`.
- `~/recovery-console` — the panel UI binary. Built locally; the
  output `output/recovery-console-aarch64` is copied into
  `ramdisk-overlay/system/bin/recovery-console` before each
  `./build.sh` here.

## Common edit cycle

```
# 1. Edit recovery-console source
cd ~/recovery-console && vim osk.c
make aarch64

# 2. Stage the binary into the recovery overlay
cp output/recovery-console-aarch64 ~/fromrecovery/ramdisk-overlay/system/bin/recovery-console

# 3. Rebuild boot images
cd ~/fromrecovery && ./build.sh

# 4. Flash + test
adb reboot bootloader
fastboot flash vendor_boot_b out/vendor_boot-slot-b.img
fastboot flash boot_b out/boot-slot-b.img
fastboot reboot recovery
```

If you change anything in `ramdisk-overlay/`, only step 3 + 4 are
needed. If you change anything in `~/dre`, also rebuild the kernel
there and re-copy the Image.

## What's NOT done

### Numbers / symbols layout polish

Current OSK layout works but the symbols page is opinionated.
Specifically:

- No way to type a backtick, tilde, double-quote, or pipe directly —
  several of these need shift+autoshift on the symbols page. Some
  are present (e.g. `~` is autoshift on `KEY_GRAVE`); others aren't
  reachable.
- No HOME/END on the alpha page — they're on the extras bar but
  feel cramped at 8 keys.

A second tap-and-hold layer could expose the missing punctuation
without adding rows. Not implemented.

### Wifi (long-term)

The device has no working wifi. WCN3990 firmware load is gated on
the modem subsystem being ONLINE, which on slot B sits in OFFLINING
because nothing pokes it. cnss-daemon would do this in stock Android.
Either port cnss-daemon or write a kernel-side `force_subsys_powerup`
hook (analog to our touch `force_resume`). Multi-day work. We have
the firmware already collected at `/linux/firmware-vendor/` on the
device for when this gets picked up. See ROOTFS.md "Long-term wifi".

For daily use the planned escape hatch is a USB-OTG wifi dongle
(RTL8188 / MT7601) — kernel already has the drivers via vendor_dlkm.

### GPU acceleration

Mesa freedreno can't accelerate on dre's split SDE/KGSL kernel
architecture. See
`dre-droidspaces-kernel/docs/HANDOFF.md` "GPU acceleration (blocked)"
for the three potential paths and why none is short.

### Recovery-console refinements

See `recovery-console/docs/HANDOFF.md`.

## Memory of past mistakes

Saved as long-term feedback so future-me doesn't repeat:

- `feedback_recovery_reboot.md` — `fastboot reboot recovery`, NOT
  bare `fastboot reboot`. Slot B has no Android, normal-mode boot
  hangs.
- `feedback_no_destructive_git.md` — never `git reset --hard` etc.
  on `~/dre/kernel` or any user repo without explicit confirmation;
  destroyed the user's KernelSU work once and had to recover from
  reflog.
- `feedback_ramdisk_perms.md` — repacked init.rc must be 0644 not
  0664; group-writable mode silently bricks boot. Fix is in
  `build.sh`'s chmod step — don't remove it.
