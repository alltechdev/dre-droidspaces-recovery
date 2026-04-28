# fromrecovery — Linux desktop on OnePlus Nord N200 5G (dre)

Adaptation of [droidspaces-recovery-hack-example](https://github.com/ravindu644/droidspaces-recovery-hack-example) for dre on LineageOS 23.2:
slot A keeps stock LineageOS, slot B boots Ubuntu desktop via Droidspaces container with all hardware (wifi, audio, touch, GPU) brought up by the underlying Android vendor modules.

## Status

- [x] Phase 0 — workspace init
- [x] Phase 1 — repack pipeline (vendor_boot + boot rebuilt, flashable to slot B)
- [x] Phase 2 — SELinux permissive + adb root + Android UI disabled
- [x] Phase 3 — recovery-console rendering on the panel (forked binary
       with on-screen keyboard + `/proc/touchpanel/force_resume` wakeup)
- [x] Phase 4 — Ubuntu 24.04 container autoboots under recovery-console
- [ ] Phase 5 — Wayland desktop (parked: Mesa freedreno can't drive
       KGSL on this kernel; falls back to llvmpipe)
- [x] Phase 6a — USB NCM ethernet alongside adb (10.7.7.x)
- [x] Phase 6b — internal WiFi (WCN3990 → wlan0) auto-up on boot,
       saved-network reconnect via `/linux/wpa.conf`
       — see [docs/WIFI-BRINGUP.md](docs/WIFI-BRINGUP.md)

## Layout (committed)

```
build.sh                   — unpack stock vendor_boot, apply ramdisk overlay, repack
ramdisk-overlay/           — files we add or replace inside the ramdisk
patches/                   — patch files against init.rc and friends
README.md
```

## Inputs (NOT committed; user supplies)

- `~/dre/out/arch/arm64/boot/Image` — Droidspaces kernel built from `~/dre`
- `~/dre/boot.img`, `~/dre/vendor_boot.img` — stock LineageOS images for dre
