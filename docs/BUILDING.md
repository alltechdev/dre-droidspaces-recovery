# Building boot.img + vendor_boot.img

## Inputs (consumed, not produced here)

| file | source | role |
|---|---|---|
| `~/dre/vendor_boot.img` | stock LineageOS dre OTA | template for our vendor_boot (we replace the ramdisk) |
| `~/dre/boot.img` | stock LineageOS dre OTA | template for our boot (we replace the kernel) |
| `~/dre/out/arch/arm64/boot/Image` | built by `dre-droidspaces-kernel`'s `build.sh` | the kernel binary |
| `tools/magiskboot` | committed in this repo | unpack/repack helper |

## What `build.sh` does

In `~/fromrecovery/build.sh`:

1. Sanity checks all input files exist; exits 1 if any are missing.
2. `mkdir -p work/{vendor-boot-build,boot-build} out/`; `rm -rf` the
   per-image work dirs so each run starts clean.
3. **vendor_boot pipeline:**
   - `magiskboot unpack` the stock vendor_boot.img into
     `work/vendor-boot-build/{ramdisk.cpio,dtb,header,…}`.
   - `cpio -idmv` extracts ramdisk.cpio into
     `work/vendor-boot-build/ramdisk/` (which becomes a writable
     tree).
   - **Overlay**: `cp -av ramdisk-overlay/. work/vendor-boot-build/ramdisk/`
     — copies our edited init.rc + scripts + recovery-console binary
     on top of the stock tree.
   - **Patches**: any `*.patch` in `patches/` is applied with
     `patch -p1` from inside `work/vendor-boot-build/ramdisk/`.
     (Currently just `02-disable-adb-auth.patch`, which sets
     `ro.secure=0`/`ro.adb.secure=0`/`ro.debuggable=1` in
     prop.default so adb is rootless.)
   - **chmod normalise** (CRITICAL — see KNOWN-ISSUES.md #1):
     ```
     find work/.../ramdisk/system/etc -type f -exec chmod 0644 {} +
     find work/.../ramdisk/system/bin -type f -exec chmod 0755 {} +
     ```
     Skipping this caused a six-attempt boot-hang debugging session.
   - `find . | cpio -o -H newc -R 0:0 --reproducible` re-packs the
     ramdisk with root:root ownership and deterministic timestamps.
     `--reproducible` is necessary; without it the cpio archive
     contains the per-file mtimes of the work tree which makes the
     output non-deterministic.
   - `magiskboot repack` writes `out/vendor_boot-slot-b.img`.
4. **boot pipeline (much smaller):**
   - `magiskboot unpack` stock `boot.img`.
   - Replace the kernel: `cp ~/dre/out/arch/arm64/boot/Image
     work/boot-build/kernel`.
   - `magiskboot repack` writes `out/boot-slot-b.img`.
5. Print the final SHA256 of both images.

magiskboot exits with code 3 on VBMETA-signed images (informational,
not an error). The script's `unpack` calls are wrapped in `… || true`
to tolerate this.

## Flashing

```
adb reboot bootloader        # if the device is up
fastboot devices             # confirm "fastboot" mode
fastboot flash vendor_boot_b out/vendor_boot-slot-b.img
fastboot flash boot_b out/boot-slot-b.img
fastboot reboot recovery
```

The slot B is what we own; slot A still flashes/boots stock LineageOS.

## Releases

`v20260426` on
https://github.com/alltechdev/dre-droidspaces-recovery/releases
attaches both `boot-slot-b.img` and `vendor_boot-slot-b.img` for
people who don't want to build locally. The kernel inside is from
the matching `dre-droidspaces-kernel` `v20260426` release.
