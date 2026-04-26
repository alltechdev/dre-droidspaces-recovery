# Known issues + decisions

A reference list of the failure modes we hit, what they look like,
and what we settled on. If the device starts misbehaving in one of
these specific ways, this is the file to check first.

## 1. OEM splash hang on boot, no console output

**Symptom**: Flashed boot+vendor_boot, `fastboot reboot recovery`,
device sits on the OnePlus logo forever. ADB and serial both silent.
`slot-successful:b` stays `no`. `slot-retry-count:b` stays at 7
(boot tries are not being marked successful but also not counting
down — bootloader is handing off to kernel; the kernel is running
init, init is silently bailing).

**Cause**: A regular file in the ramdisk (typically `init.rc` or one
of the scripts under `/system/bin/`) is group-writable (mode 0664 /
0775). Files edited under the host's default umask 0002 land at this
mode; cpio carries it into the archive verbatim; Android init refuses
to load init.rc when it's group-writable.

**Fix**: Already in `build.sh` — we chmod 0644 on regular files under
`system/etc` and 0755 on `system/bin` before `cpio -o`. **Don't
remove that step.** Failure signature for next time:

```
cpio -tv on the rebuilt ramdisk:
-rw-rw-r--   1 root root  ...  system/etc/init/hw/init.rc

cpio -tv on stock vendor_boot.img ramdisk:
-rw-r--r--   1 root root  ...  system/etc/init/hw/init.rc
```

`cpio -R 0:0` only normalizes uid/gid; there's no equivalent for
mode bits, so the chmod has to happen on disk before pack.

[memory: feedback_ramdisk_perms.md]

## 2. fastboot "partition size: 0"

After many flash cycles or USB drops, the bootloader's GPT cache can
go stale and report:

```
Warning: skip copying boot_b image avb footer (boot_b partition size: 0, …)
```

Long-press the power button to fully cut power, hold power+vol-down
back into bootloader. The GPT is re-read on the next boot.

## 3. Touch dead but device boots

**Symptom**: Recovery-console renders the term grid + OSK on the
panel, but tapping does nothing. `getevent /dev/input/event1` is
silent during taps.

**Cause**: dre's Novatek nt36672c touchpanel driver registers with
SDE via `mdss_panel_notifier` and only resumes the IC on a real
panel-on event from atomic modeset. Our recovery-console can't run
atomic init (see #4) and falls back to legacy SETCRTC, which doesn't
fire the notifier. `/proc/touchpanel/debug_info/main_register` reads
`Not in resume over state`.

**Fix**: kernel patch in dre-droidspaces-kernel
`patches/droidspaces/003-touch-force-resume.patch` adds
`/proc/touchpanel/force_resume`. recovery-console writes "1" once at
startup. Touchpanel wakes within a few hundred ms.

If this stops working: check that the kernel actually has the patch
applied (`cat /proc/touchpanel/force_resume` should exist; if not,
`./build.sh` in the kernel repo and reflash).

## 4. Xorg crashes on dre (historical, path abandoned)

**Symptom**: `startx` segfaults a few hundred ms after probing the
DSI panel. `Xorg.0.log` ends with:

```
(II) modeset(0): Backing store enabled
(II) modeset(0): Silken mouse enabled
(EE) Segmentation fault at address 0x0
```

strace shows the crash happens after a `DRM_IOCTL_MODE_SETPROPERTY`
returns `EINVAL` and Xorg's modesetting driver dereferences NULL.

**Cause**: Qualcomm SDE's atomic property handling is incomplete /
non-standard in dre's downstream kernel. Xorg's `xf86-video-modesetting`
21.1.12 (Ubuntu 24.04) doesn't handle the EINVAL gracefully.

**Status**: not fixed. Same bug reproduces with the author's
`Ubuntu-24.04-XFCE-experimental` rootfs (which uses stock Xorg with
the same modesetting driver). We **abandoned** the X11 path. The
active UI is recovery-console drawing directly to the framebuffer.

## 5. Mesa freedreno can't accelerate

**Symptom**: weston / phoc / sway / xorg all fall back to llvmpipe.
`MESA_LOADER_DEBUG=1` shows `using driver msm_drm for 3 ; failed to
create dri2 screen`.

**Cause**: dre's downstream kernel splits Qualcomm SDE (display) from
KGSL (Adreno GPU) into separate drivers. `/dev/dri/card0` and
`renderD128` are both `qcom,sde-kms` (display only). The actual GPU
is at `/dev/kgsl-3d0` with Qualcomm's KGSL ABI. Mesa freedreno
expects mainline `msm` where display + GPU share one device.

**Status**: blocked. Three potential fixes (Mesa KGSL backend
revival, kernel msm-gpu port, switch to mainline msm) all multi-day
to multi-week. Document the architecture in
`dre-droidspaces-kernel/docs/HANDOFF.md` for future work.

## 6. Phosh too slow to be usable (historical, path abandoned)

When we briefly had phoc + phosh autobooting, the lockscreen took
~50 s for first paint and interactions stuttered: CPU was rendering
1080×2400×32bpp at every frame because of #5. We **abandoned** the
wayland desktop path and use recovery-console + OSK as the UI
instead. The phosh / phoc / sway packages are still apt-installed
in `/linux/rootfs/` but `phosh.service` is disabled and nothing
launches them. Until #5 is solved, that's the right call.

## 7. Wifi dead

`wlan.ko` loads (vermagic matches), and ipa_fws subsystem comes
ONLINE when we drop firmware in `/vendor/firmware/`, but the modem
subsystem stays in `OFFLINING` state. WCN3990 firmware is loaded by
the modem subsystem on this SoC, so until we bring modem online (or
port cnss-daemon) wifi can't initialize. See ROOTFS.md "Long-term
wifi".

Workaround in use: USB-NCM tether for installs, planned: USB-OTG
wifi dongle (RTL8188 etc.) for daily.

## 8. Time always 1970

Recovery doesn't run NTP and userdata-encrypted-time is gone. After
every boot the clock is 1970, which breaks TLS (certs not valid
yet). Set manually:

```
adb shell "date $(date -u +%m%d%H%M%Y).$(date -u +%S)"
```

## 9. recovery-console on power button

If you tap the power button while recovery-console owns the panel,
DPMS goes off and the panel blanks. recovery-console's input loop
treats KEY_POWER as a blank toggle — tap again to wake. (When phosh
was running we observed phoc/phosh staying alive but the panel
freezing; restarting phosh.service brought it back.)
