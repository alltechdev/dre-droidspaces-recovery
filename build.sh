#!/usr/bin/env bash
# Build slot B's vendor_boot.img: dre's stock vendor_boot ramdisk with our
# overlay applied + patches applied, repacked. Phase 1 just exercises the
# pipeline (overlay/patches are empty); later phases add real edits.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$ROOT/work"
OUT="$ROOT/out"
TOOLS="$ROOT/tools"

# Inputs (user supplies)
DRE_REPO="${DRE_REPO:-$HOME/dre}"
STOCK_VENDOR_BOOT="$DRE_REPO/vendor_boot.img"
STOCK_BOOT="$DRE_REPO/boot.img"
DROIDSPACES_KERNEL="$DRE_REPO/out/arch/arm64/boot/Image"

# Tools
MAGISKBOOT="$TOOLS/magiskboot"

for f in "$STOCK_VENDOR_BOOT" "$STOCK_BOOT" "$DROIDSPACES_KERNEL" "$MAGISKBOOT"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

mkdir -p "$WORK" "$OUT"
rm -rf "$WORK"/vendor-boot-build "$WORK"/boot-build
mkdir -p "$WORK/vendor-boot-build" "$WORK/boot-build"

# ---------- vendor_boot: ramdisk surgery ----------
# magiskboot exits with 3 for VBMETA-signed images (informational, not a real
# error) — we tolerate any non-zero exit from unpack/repack.
echo "==> Unpacking stock vendor_boot.img"
( cd "$WORK/vendor-boot-build" && "$MAGISKBOOT" unpack "$STOCK_VENDOR_BOOT" >/dev/null ) || true

echo "==> Extracting ramdisk to a writeable tree"
mkdir -p "$WORK/vendor-boot-build/ramdisk"
( cd "$WORK/vendor-boot-build/ramdisk" && cpio -idmv < ../ramdisk.cpio >/dev/null 2>&1 )

# Overlay: any file under ramdisk-overlay/ replaces the same path in the ramdisk.
if [ -d "$ROOT/ramdisk-overlay" ] && [ -n "$(find "$ROOT/ramdisk-overlay" -type f)" ]; then
  echo "==> Applying ramdisk overlay"
  cp -av "$ROOT/ramdisk-overlay/." "$WORK/vendor-boot-build/ramdisk/"
fi

# Patches: any *.patch under patches/ applied with patch -p1 inside ramdisk tree.
if [ -d "$ROOT/patches" ]; then
  for p in "$ROOT/patches"/*.patch; do
    [ -e "$p" ] || continue
    echo "==> Applying patch $(basename "$p")"
    ( cd "$WORK/vendor-boot-build/ramdisk" && patch -p1 < "$p" )
  done
fi

echo "==> Re-packing ramdisk (force root:root, since extract loses uid)"
( cd "$WORK/vendor-boot-build/ramdisk" && \
  find . | cpio -o -H newc -R 0:0 --reproducible 2>/dev/null > ../ramdisk.cpio.new )
mv "$WORK/vendor-boot-build/ramdisk.cpio.new" "$WORK/vendor-boot-build/ramdisk.cpio"

echo "==> Repacking vendor_boot.img"
( cd "$WORK/vendor-boot-build" && \
  "$MAGISKBOOT" repack "$STOCK_VENDOR_BOOT" "$OUT/vendor_boot-slot-b.img" 2>&1 \
    | grep -E "_SZ|HEADER|CMDLINE" )

# ---------- boot.img: just swap kernel ----------
echo
echo "==> Unpacking stock boot.img"
( cd "$WORK/boot-build" && "$MAGISKBOOT" unpack "$STOCK_BOOT" >/dev/null ) || true

echo "==> Swapping kernel for our Droidspaces build"
cp "$DROIDSPACES_KERNEL" "$WORK/boot-build/kernel"

echo "==> Repacking boot.img"
( cd "$WORK/boot-build" && \
  "$MAGISKBOOT" repack "$STOCK_BOOT" "$OUT/boot-slot-b.img" 2>&1 \
    | grep -E "_SZ|HEADER" )

echo
echo "==> Done."
ls -la "$OUT"
sha256sum "$OUT"/*.img
