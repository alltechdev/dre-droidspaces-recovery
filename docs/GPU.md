# GPU acceleration in slot-B recovery

End state: hardware-accelerated EGL/GLES on the Adreno 619 inside the
slot-B Droidspaces recovery, with no Android framework running. Same
GL stack `lineage Camera` uses on stock; same kernel ABI; same blobs.

```
GL_VENDOR:   Qualcomm
GL_RENDERER: Adreno (TM) 619
GL_VERSION:  OpenGL ES 3.2 V@0530.48 (...)
PASS — GPU acceleration works
```

## Pieces

- **`linux-overlay/gpu-bringup.sh`** — boot-time orchestrator. Mounts
  binderfs, lays down `/vendor/lib64/{egl,hw}` and
  `/system/bin/bootstrap/linker64`, runs the smoke test, writes
  `/linux/gpu-result.txt`.
- **`ramdisk-overlay/system/etc/init/hw/init.rc`** — defines the
  `gpu-bringup` init service and triggers it from
  `on property:init.svc.powerkeyd=running`.
- The actual EGL/GLES blobs + smoke-test source live in the sibling
  [adreno-stage](https://github.com/alltechdev/adreno-stage) repo
  and get pushed to `/linux/gpu/` on the data partition.

## Why the property trigger and not `on boot`

`start gpu-bringup` directly under `on boot` was silently dropped —
init never logged "starting service 'gpu-bringup'", marker files
weren't created, the script never executed, even though the same
service was perfectly start-able via `setprop ctl.start gpu-bringup`
or by hand. wifi-bringup and powerkeyd in the same `on boot` block
fired fine; gpu-bringup specifically didn't. Best guess: a
combination of printk ratelimit suppressing init's log lines plus a
silent action-queue limit.

Hooking off `on property:init.svc.powerkeyd=running` fires reliably:
powerkeyd transitions to `running` at t≈8s, the property action
fires, and gpu-bringup starts immediately. Total end-to-end ~12s
including the smoke-test verification.

## Geometry of the staged blobs

```
/linux/gpu/lib64/                        — bulk of system libs (~445 MB)
/linux/gpu/lib64/egl/                    — the Adreno EGL drivers
/linux/gpu/lib64/hw/                     — gralloc + mapper HALs
/linux/gpu/bin/egl-smoke                 — the smoke test
```

`gpu-bringup.sh` then materializes the paths Android's loader expects:

```
/vendor/lib64/egl/<driver>.so            — symlinks (loader follows them)
/vendor/lib64/hw/<hal>.so                — REAL FILES (loader rejects symlinks)
/system/bin/bootstrap/linker64           — symlink to /system/bin/linker64
/dev/hwbinder, /dev/vndbinder            — symlinks into /dev/binderfs
```

The HAL-loader-rejects-symlinks gotcha is the trap: if you symlink
the gralloc HAL libs, `eglInitialize` returns `EGL_BAD_ACCESS`
(0x3003) and you'll spend an hour wondering why. Real-file copy is
required.

## Verifying

After the device boots, the recipe is fully working when:

```
$ adb shell cat /linux/gpu-result.txt
=== gpu-bringup start ===
binderfs binder binder-control features hwbinder vndbinder
vendor/lib64/egl: 4 entries
vendor/lib64/hw : 38 entries
egl-smoke:
[+] EGL 1.5  vendor: Qualcomm Inc.
GL_VENDOR:   Qualcomm
GL_RENDERER: Adreno (TM) 619
GL_VERSION:  OpenGL ES 3.2 V@0530.48 (...)
PASS — GPU acceleration works
=== gpu-bringup end ===
```

Or run the test directly:

```
adb shell 'LD_LIBRARY_PATH=/linux/gpu/lib64:/linux/gpu/lib64/egl:/system/lib64 \
    /linux/gpu/bin/egl-smoke'
```

## Not yet wired

GLES is up; a Wayland compositor that can use this stack and present
to `/dev/dri/card0` is the next piece. Two paths:

- **Native bionic compositor** — build (or repackage) a Wayland
  compositor as a bionic binary so it can dlopen the same blobs.
  Highest perf, most work.
- **libhybris bridge** — run the compositor inside the Ubuntu
  chroot (glibc), let libhybris's bionic-loader-in-glibc shim
  dispatch EGL calls into the Adreno blobs. Easier, slight overhead.

Either way, GPU rendering itself is no longer a blocker — it's
done.
