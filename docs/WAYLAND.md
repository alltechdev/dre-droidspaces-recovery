# Continuing the wayland desktop path

The wayland desktop (phoc + phosh) path was implemented end-to-end,
booted to the lockscreen, and was abandoned because rendering was
unusably slow without GPU acceleration. **The path is parked, not
deleted.** This doc records exactly what was set up and how to
revive it.

## What works today (without any new work)

- The Ubuntu rootfs at `/linux/rootfs/` already has `phosh`, `phoc`,
  `phosh-mobile-tweaks`, `phosh-osk-stub`, `weston`, `sway`, and
  `seatd` apt-installed.
- A working `/etc/phosh/phoc.ini` is on the rootfs (was at
  `~/fromrecovery/rootfs-additions/etc/phosh/phoc.ini` in the phase 5
  commit, but that was removed when we reverted; if missing, the
  contents that worked are in the historical commit `22e2001`).
- A working `launch-phosh.sh` and `touchpanel-quirk.py` were also
  pushed into `/linux/rootfs/usr/local/bin/` during phase 5 setup.
  Same caveat — removed from this repo at phase 6a, source preserved
  in commit `22e2001`.
- A `phosh.service` systemd unit exists at
  `/linux/rootfs/etc/systemd/system/phosh.service`; we disabled it
  by removing the `multi-user.target.wants/phosh.service` symlink
  before pivoting back to recovery-console.

## What it took to get phosh working last time

End-to-end, in order. Required to all be true at the same time:

### 1. Kernel: `CONFIG_VT=y`

wlroots' libseat-builtin opens `/dev/tty0` to acquire a seat. Without
`CONFIG_VT` the device node either doesn't exist or returns ENXIO,
and phoc bails before reaching the main loop. Add to
`~/dre/defconfig-fragment.config`:

```
CONFIG_VT=y
CONFIG_HW_CONSOLE=y
CONFIG_VT_CONSOLE=y
CONFIG_UNIX98_PTYS=y
```

Verified kABI-safe — `module_layout` CRC stays at `0x1b8a8bf8` so
stock vendor modules continue to load. (Do verify after a rebuild
just in case the LineageOS kernel git tip moved.)

The historic commit dropping this in is `1fd7d55` on
`dre-droidspaces-kernel` (force-pushed away when we abandoned the
path). `git show 1fd7d55 -- defconfig-fragment.config` from the
reflog if needed.

### 2. Recovery-side: DRM handoff to phosh

phoc inside the container needs DRM master, but recovery-console
already has it. In phase 5 we added a host-side handoff watcher:

- `ramdisk-overlay/system/bin/drm-handoff-watcher` polls
  `/linux/.unlock-drm`; on first appearance, kills recovery-console
  via `pgrep -f recovery-console | head -1 | xargs kill -9`. Use
  `pgrep -f`, not bare `pgrep` — `/proc/PID/comm` truncates to 15
  chars and `recovery-console` is 16, so plain `pgrep
  recovery-console` misses it.
- `init.rc` registers the watcher as `service drm-handoff-watcher`
  with `oneshot` so init doesn't tight-loop after it exits.
- `boot-ubuntu.sh` adds `-B "$LINUX_MNT:/host_linux"` to the
  droidspaces invocation so the container can write
  `/host_linux/.unlock-drm`. It also clears any stale flag at the
  start of the script.

These changes lived in commit `22e2001`. To revive, cherry-pick or
just apply the diff manually.

### 3. Container: phosh.service + launch script

Drop these into `/linux/rootfs/`:

```
/etc/phosh/phoc.ini                            # explicit DSI-1 mode + scale
/etc/systemd/system/phosh.service              # the unit
/etc/systemd/system/multi-user.target.wants/phosh.service  # enable symlink
/usr/local/bin/launch-phosh.sh                 # what the unit ExecStarts
/usr/local/bin/touchpanel-quirk.py             # EVIOCSABS quirk for libinput
```

`launch-phosh.sh` does, in order:

1. Start `systemd-udevd` by hand if not running (`systemctl start
   systemd-udevd` — container default target doesn't pull it).
2. Run `touchpanel-quirk.py` so libinput accepts the touchpanel
   (driver reports `min == max` on `ABS_MT_WIDTH_MAJOR`, libinput
   rejects as kernel bug). The script overrides absinfo via
   `EVIOCSABS` — sets new max = 255 for affected codes (or 65535
   for `ABS_MT_TRACKING_ID`).
3. Touch `/host_linux/.unlock-drm` so the host watcher kills
   recovery-console and frees DRM master.
4. `dbus-run-session phoc -S -C /etc/phosh/phoc.ini -E
   /usr/libexec/phosh`.

`phoc.ini` (working content for dre):

```
[output:DSI-1]
mode = 1080x2400
scale = 2
```

Without an explicit DSI-1 stanza, phoc doesn't advertise any output
to phosh and phosh dies with `Wayland compositor lacks needed
globals: outputs: 0`.

Renderer env in `launch-phosh.sh`:

```
export WLR_RENDERER=pixman
export WLR_NO_HARDWARE_CURSORS=1
```

`WLR_DRM_NO_ATOMIC=1` and `WLR_DRM_NO_MODIFIERS=1` were experimented
with — they BROKE the panel (DRM modeset never landed). Don't set
them. Default atomic mode worked once the DSI-1 output was set.

### 4. Get a real DBus session (not logind seat)

phosh's PolKit / battery / a11y components want a session bus.
`dbus-run-session` provides one. logind would also work but the
container doesn't have an active logind session and creating one
inside a container is more trouble than `dbus-run-session`.

`systemd-run --uid=0 --gid=0 --quiet /usr/local/bin/launch-phosh.sh`
proved the most reliable way to invoke the script. Plain
`nohup setsid` from `droidspaces run` would die when the run command
returned; `systemd-run --scope` couldn't combine with `--pty`. The
`systemd-run` form leaves the launch script running in a transient
unit that survives the dispatcher exiting.

### 5. The nasty caveat: backlight reads 0

When phoc was driving the panel, the WLED `actual_brightness` sysfs
node read `0` even though the panel was clearly lit and phosh was
visible. This is misleading but not actually broken — the WLED
control loop on this driver just doesn't update the readback in
this configuration. Don't bother polling actual_brightness as a
"is it on?" signal.

## Why we abandoned it

Once everything was set up, phoc + phosh booted, the lockscreen
appeared, root-with-PIN-`1234` worked. Two problems made the path
unusable:

1. **Slow as molasses**: ~50 s for the first lockscreen paint and
   visibly stuttering interactions. Cause: Mesa freedreno can't
   accelerate on dre's split SDE/KGSL kernel architecture, so
   wlroots is rendering 1080×2400×32bpp at every frame on the SoC's
   CPU via pixman. This is not a tunable; it's structural. See
   KNOWN-ISSUES.md #5.
2. **Power button blanks the panel**: tapping power put DPMS off,
   and panel didn't always recover even with phoc/phosh still alive.
   Restarting `phosh.service` brought it back, which isn't OK for
   a phone.

The path is reasonable when (1) is solved. The path is NOT
reasonable while running pixman-on-CPU.

## Reviving — short version

If GPU acceleration becomes possible (see
`dre-droidspaces-kernel/docs/HANDOFF.md` "GPU acceleration
(blocked)"):

1. Reapply the four `CONFIG_VT*` lines in
   `~/dre/defconfig-fragment.config`, rebuild kernel, verify CRC
   `0x1b8a8bf8`, copy `Image` to
   `~/fromrecovery/kernel-Image-droidspaces`.
2. From git, recover the phase-5 ramdisk overlay (commit
   `22e2001` on `dre-droidspaces-recovery`):
   - `git show 22e2001 -- ramdisk-overlay/system/bin/drm-handoff-watcher`
     → save as that file.
   - `git show 22e2001 -- ramdisk-overlay/system/etc/init/hw/init.rc`
     → take the `service drm-handoff-watcher` block and the
     `boot-ubuntu.sh` `-B` argument, fold into current init.rc /
     boot-ubuntu.sh.
3. Push the rootfs additions back into `/linux/rootfs/` from commit
   `22e2001`'s `rootfs-additions/`. The files in
   `install-rootfs-additions.sh` walk the tree and adb-push.
4. `systemctl enable phosh.service` (or recreate the
   multi-user.target.wants symlink) inside the container.
5. Rebuild boot images, flash, test.

The historic phosh-autoboot working commit is `22e2001 phase 5: phosh
wayland desktop autoboots over the panel` on
`dre-droidspaces-recovery`. It's not on `main` anymore but is
fetchable via the GitHub commit URL.

## Reviving — questions to answer first

Before reviving, the GPU/desktop blockers are the real fight.

- Does Mesa freedreno work on this kernel now? Test:
  ```
  apt install -y mesa-utils  # if not already
  /linux/bin/droidspaces --name=ubuntu run \
    bash -c "EGL_LOG_LEVEL=debug eglinfo -B 2>&1 | grep -E 'driver|llvmpipe|kgsl|msm'"
  ```
  If `EGL driver name: kms_swrast` or `OpenGL renderer: llvmpipe` —
  not yet. Solve GPU first.
- Does Xorg work now? Less relevant since we'd use Wayland, but
  test reveals whether Qualcomm SDE atomic-property handling has
  been fixed. Probably no — this would need a kernel fix or a Mesa
  fork.

If both still fail, reviving the wayland desktop is moot — it'll
look the same as before. Use the time on GPU acceleration instead.
