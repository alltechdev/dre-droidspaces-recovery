# Continuing the work

A runbook for picking the project up cold. Read in order.

## 0. What you should already know

This is a multi-repo project. Skim these first:

- `docs/README.md` — what this repo does and the three-repo layout.
- `docs/INIT-FLOW.md` — boot sequence walk-through.
- `docs/ROOTFS.md` — what's on the userdata partition and why.
- `docs/HANDOFF.md` — current state, what's left.
- `docs/KNOWN-ISSUES.md` — failure modes we've already hit.

The two sibling repos (`~/dre`, `~/recovery-console`) have their
own `docs/CONTINUING.md` you should also skim before touching their
code.

## 1. Confirm the device is healthy

Plug the phone in. From the host:

```
adb devices                   # expect: 484a5d19   recovery
adb shell cat /sys/class/drm/card0-DSI-1/dpms     # expect: On
adb shell pgrep -af recovery-console              # expect 1 process
adb shell cat /proc/touchpanel/debug_info/main_register
# expect anything that's NOT "Not in resume over state"
```

Sanity-check the container:

```
adb shell '/linux/bin/droidspaces show'           # expect: ubuntu (running)
adb shell '/linux/bin/droidspaces --name=ubuntu run uname -srm'
# expect: Linux 5.4.302-qgki-g49fee6c683d9 aarch64
```

If the device is in fastboot instead, or stuck on the OEM splash:

- `fastboot devices` to confirm fastboot mode.
- `fastboot getvar slot-successful:b` — `no` is normal, init never
  marks itself successful.
- Re-flash the latest committed `out/boot-slot-b.img` and
  `out/vendor_boot-slot-b.img` (see step 3) and `fastboot reboot
  recovery`.

## 2. Reproduce a build from scratch

```
# Kernel (~/dre): produces ~/dre/out/arch/arm64/boot/Image
cd ~/dre && ./build.sh
# Expect: "module_layout CRC: 0x1b8a8bf8  ✓"

# Recovery boot images (~/fromrecovery):
cd ~/fromrecovery && ./build.sh
# Produces: out/boot-slot-b.img, out/vendor_boot-slot-b.img

# OSK source (~/recovery-console): produces aarch64 binary
cd ~/recovery-console && make aarch64
# Output: output/recovery-console-aarch64
```

If any step fails, the matching repo's `docs/KNOWN-ISSUES.md` (or
the build-failure ladder in `docs/BUILDING.md`) lists the usual
suspects.

## 3. Flash + boot

```
adb reboot bootloader && sleep 5
fastboot flash vendor_boot_b out/vendor_boot-slot-b.img
fastboot flash boot_b out/boot-slot-b.img
fastboot reboot recovery       # NOT bare "fastboot reboot"
```

Watch the panel: lineage recovery splash for ~2 s, then black for a
moment as recovery-console takes DRM, then the term grid + OSK.
Tap a key — should type into the shell.

## 4. Get internet (one-shot, when you need apt)

The phone has no wifi yet (see HANDOFF.md "What's NOT done"). Use
USB-NCM tether:

Host (one-shot per session, replace `enp87s0` with your uplink):

```
sudo ip addr add 192.168.42.1/24 dev enxda7ed5ffff01
sudo ip link set enxda7ed5ffff01 up
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s 192.168.42.0/24 -o enp87s0 -j MASQUERADE
sudo iptables -A FORWARD -s 192.168.42.0/24 -j ACCEPT
sudo iptables -A FORWARD -d 192.168.42.0/24 -j ACCEPT
```

Device (each boot — recovery has no init for this):

```
adb shell ifconfig usb0 192.168.42.2 netmask 255.255.255.0 up
adb shell "date $(date -u +%m%d%H%M%Y).$(date -u +%S)"   # else TLS fails
```

Container (each boot too — `/etc/resolv.conf` is a tmpfs):

```
adb shell '/linux/bin/droidspaces --name=ubuntu run bash -c "
  ip route add default via 192.168.42.1 dev usb0
  echo nameserver 1.1.1.1 > /etc/resolv.conf
  apt-get -o Acquire::ForceIPv4=true update
"'
```

## 5. Pick a next task

The likely next moves, in roughly increasing scope:

### a. Polish the OSK

`~/recovery-console/docs/OSK.md` lists open layout issues. Pick one,
edit `osk.c` / `include/osk.h`, rebuild + reflash via the cycle in
HANDOFF.md "Common edit cycle".

### b. Add USB-OTG wifi support

Plug an RTL8188 / MT7601 dongle. The kernel has the drivers but
they're modular in `vendor_dlkm`. You'll need to:

1. Extract the `.ko` from the LineageOS OTA payload (tools at
   `~/fromrecovery/work/venv/` already set up — `payload_dumper`).
2. `insmod` it from a recovery shell (after `firmware_class.path`
   is pointed at where the firmware files live, similar to what
   recovery-console does for ipa_fws — see
   `~/fromrecovery/work/ota/vendor_dlkm_mnt/lib/modules/` for
   reference).
3. Run `wpa_supplicant` from inside the container; the host shares
   the WLAN interface via `--hw-access`.

Look at how `wlan.ko` was almost-loaded earlier in the session
(`/linux/modules/wlan.ko`, the dre WCN3990 driver) — same pattern,
different chip.

### c. Bring the WCN3990 wifi online

The "real" wifi path. Hard. The chip wakes only when the modem
subsystem is `ONLINE`; that happens in Android via cnss-daemon
talking QMI. Two ways:

1. **Port cnss-daemon to systemd-friendly Linux**. Source: AOSP
   `vendor/qcom/proprietary/cnss-daemon` (Lineage doesn't ship it,
   but it's available in some OEM dumps). Need to plumb QMI sockets
   to the modem RPMSG channels.
2. **Add a kernel `force_subsys_powerup` hook**, analog to our
   `force_resume` for touch (see `dre-droidspaces-kernel` patch
   003). Find where `mss` subsystem registration lives in
   `drivers/soc/qcom/` and add a sysfs write that calls the
   internal `subsys_powerup`.

Both need a working wifi-firmware path: `/vendor/firmware_mnt/`
must hold `wlanmdsp.mbn` + `bdwlan.*`. We have those staged at
`/linux/firmware-vendor/` on the device — symlink or bind-mount as
needed.

### d. GPU acceleration

Pure research. Mesa freedreno can't talk to dre's split SDE/KGSL.
See `~/dre/docs/HANDOFF.md` "GPU acceleration (blocked)" for the
three theoretical paths.

## 6. Common gotchas

These all bit during the session:

- **Don't `git reset --hard` on `~/dre/kernel`** — it has the
  user's local KernelSU + sched.h experimental commit and reflog
  recovery is the only way back. Save it as a patch first if you
  need a clean tree. [memory: feedback_no_destructive_git.md]
- **Don't ship init.rc with mode 0664** — Android init silently
  refuses to load it and the device hangs at the OEM splash with
  no error. The chmod step in `build.sh` prevents this; don't
  remove it. [memory: feedback_ramdisk_perms.md]
- **Always `fastboot reboot recovery`**, never bare `fastboot
  reboot`. Slot B has no Android. [memory:
  feedback_recovery_reboot.md]
- **`fastboot getvar partition-size:vendor_boot_b` returns 0**?
  Long-press power to fully cut, then back into bootloader. The
  bootloader's GPT cache went stale.
- **Touch goes silent after a kernel patch**? Confirm the patch
  applied (`cat /proc/touchpanel/force_resume` should exist as a
  proc file) and that recovery-console wrote to it
  (`grep force_resume` recovery-console's source — should be in
  `main.c` under `display_init`).
- **Random `+` or `-dirty` suffix in vermagic**? Stock vendor
  modules will reject the kernel. Re-export `LOCALVERSION=""` and
  rebuild; or check `~/dre/kernel` for uncommitted changes.

## 7. When things go really wrong

Slot A is a clean LineageOS escape hatch. From fastboot:

```
fastboot --set-active=a
fastboot reboot
```

This boots stock LineageOS. Userdata is wiped (we reformatted it
for Linux), so it'll go to the factory-reset prompt. From there you
can re-flash a stock OTA over slot A if you've actually corrupted
something fundamental, then reboot back into slot B with
`fastboot --set-active=b` + `fastboot reboot recovery`.
