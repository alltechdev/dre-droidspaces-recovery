# fromrecovery — Linux desktop on OnePlus Nord N200 5G (dre)

Adaptation of [droidspaces-recovery-hack-example](https://github.com/ravindu644/droidspaces-recovery-hack-example) for dre on LineageOS 23.2:
slot A keeps stock LineageOS, slot B boots Ubuntu desktop via Droidspaces container with all hardware (wifi, audio, touch, GPU) brought up by the underlying Android vendor modules.

## Status

- [x] Phase 0 — workspace init
- [ ] Phase 1 — repack pipeline (no-op vendor_boot edit; flash + verify boot)
- [ ] Phase 2 — selinux permissive + adb root + Android UI disabled
- [ ] Phase 3 — recovery-console TTY rendering on screen
- [ ] Phase 4 — Ubuntu container console-only
- [ ] Phase 5 — Wayland desktop
- [ ] Phase 6 — hardware (wifi/audio/touch into desktop)

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
