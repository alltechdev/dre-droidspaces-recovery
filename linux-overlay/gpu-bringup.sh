#!/system/bin/sh
# gpu-bringup — re-create the /vendor and /system shims that let the
# Adreno user-space stack (libEGL_adreno + libGLESv2_adreno + gralloc
# HAL) load in our slot-B recovery. Vendor blobs themselves live in
# /linux/gpu/ on the data partition; this script just lays down the
# symlinks Android's loader expects.
#
# Idempotent — safe to re-run.
#
# After this runs, a native Android binary linked against bionic can
# call eglGetDisplay/eglInitialize/eglCreateContext on
# libEGL_adreno.so directly with:
#   LD_LIBRARY_PATH=/linux/gpu/lib64:/linux/gpu/lib64/egl:/system/lib64
# and get hardware-accelerated GLES on the Adreno 619.
#
# Quick test (binary at /linux/gpu/bin/egl-smoke):
#   LD_LIBRARY_PATH=/linux/gpu/lib64:/linux/gpu/lib64/egl:/system/lib64 \
#       /linux/gpu/bin/egl-smoke

R=/linux/gpu-result.txt
# Write a marker the moment we start, into multiple locations so we
# can tell whether the script ran from init even if /linux is somehow
# unmounted at that moment.
date > /gpu-bringup-marker 2>/dev/null
date > /tmp/gpu-bringup-marker 2>/dev/null
date > /linux/gpu-bringup-marker 2>/dev/null
P() { printf '%s %s\n' "$(date +%T)" "$*" >> "$R"; }
: > "$R"
P "=== gpu-bringup start ==="

# 1) binderfs — exposes hwbinder + vndbinder contexts that the kernel
#    binder driver registered (CONFIG_ANDROID_BINDER_DEVICES). The
#    plain /dev/binder symlink already exists at boot; the others
#    don't.
mkdir -p /dev/binderfs
mount -t binder binder /dev/binderfs 2>/dev/null
ln -sf /dev/binderfs/hwbinder  /dev/hwbinder
ln -sf /dev/binderfs/vndbinder /dev/vndbinder
P "binderfs $(ls /dev/binderfs 2>/dev/null | tr '\n' ' ')"

# 2) Bootstrap linker. Some vendor binaries (hwservicemanager, etc.)
#    request /system/bin/bootstrap/linker64 as their interpreter; the
#    recovery only ships /system/bin/linker64.
mkdir -p /system/bin/bootstrap
ln -sf /system/bin/linker64 /system/bin/bootstrap/linker64

# 3) /vendor/lib64/{egl,hw} — Adreno's eglSubDriverAndroid.so + the
#    gralloc HALs are looked up on these absolute paths by the Android
#    EGL loader and gralloc dispatcher. Symlink them to point at the
#    persistent stage on /linux/gpu/.
mkdir -p /vendor/lib64/egl /vendor/lib64/hw
# /vendor/lib64/egl/ accepts symlinks — Adreno's eglSubDriverAndroid
# follows them happily.
for f in /linux/gpu/lib64/egl/*.so; do
    [ -f "$f" ] || continue
    ln -sf "$f" /vendor/lib64/egl/"$(basename "$f")"
done
# /vendor/lib64/hw/ does NOT — the HAL loader (libutils.so dlopen
# path) rejects gralloc HAL libs that resolve to a symlink, returning
# EGL_BAD_ACCESS during eglInitialize. Copy the real files instead.
# Idempotent: only copy if dest is missing or older.
for f in /linux/gpu/lib64/hw/*.so; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    if [ ! -f "/vendor/lib64/hw/$name" ] || \
       [ "$f" -nt "/vendor/lib64/hw/$name" ]; then
        cp -f "$f" "/vendor/lib64/hw/$name"
    fi
done
P "vendor/lib64/egl: $(ls /vendor/lib64/egl 2>/dev/null | wc -l) entries"
P "vendor/lib64/hw : $(ls /vendor/lib64/hw 2>/dev/null | wc -l) entries"

# 4) Smoke test — confirms EGL + GLES + gralloc are wired up. Exits
#    with 0 on PASS, non-zero on failure. Result captured to result
#    file so we can read after a reboot.
if [ -x /linux/gpu/bin/egl-smoke ]; then
    P "egl-smoke:"
    LD_LIBRARY_PATH=/linux/gpu/lib64:/linux/gpu/lib64/egl:/system/lib64 \
        /linux/gpu/bin/egl-smoke >> "$R" 2>&1
    P "  rc=$?"
fi

P "=== gpu-bringup end ==="
sync
