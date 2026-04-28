# WiFi bringup in slot-B recovery

This recovery now brings the internal WiFi (`wlan0`) up automatically
on boot. No Android WLAN stack is present — the orchestration runs
from `/linux/wifi-v13.sh`, launched by the `wifi-bringup` init service
added to `init.rc`.

## init.rc service

```
service wifi-bringup /system/bin/sh -c "sleep 6; /linux/wifi-v13.sh"
    user root
    group root
    oneshot
    disabled
    seclabel u:r:recovery:s0
```

Started from `on boot` after `recovery-console-bringup`. The 6s sleep
lets adsp/cdsp settle before the script starts force-powering
peripherals.

## What `/linux/wifi-v13.sh` does

1. Force-powers adsp/cdsp/modem via
   `/sys/bus/msm_subsys/devices/subsys*/force_powerup`.
2. Starts `rmtfs`, `pd-mapper`, `tqftpserv` from `/linux/`.
3. Waits up to 30s for `/sys/bus/.../servreg-loc/.../msm/modem/wlan_pd`
   to report `state=0x1fffffff (UP)`.
4. Waits up to 30s for ICNSS_ARRIVED in dmesg
   (icnss connected to WLFW QMI service id 69).
5. `mkdir -p /mnt/vendor/persist; mount -t ext4 -o ro
   /dev/block/by-name/persist /mnt/vendor/persist` — so cnss-daemon
   can find `regdb.bin`.
6. `mkdir -p /data/vendor/wifi/sockets` — cnss-daemon's unix socket
   bind path.
7. Disables `printk_ratelimit` (cnss-daemon writes a lot to kmsg).
8. Launches the real Qualcomm `cnss-daemon` from `/linux/cnss/bin/`
   with the LD_LIBRARY_PATH including a `libperipheral_client.so`
   shim (see the `cnss-stage` repo).
9. Waits up to 30s for `WLAN FW is ready` in dmesg.
10. Triggers `wlan.ko` driver registration: `echo ON > /dev/wlan`.
11. `ifconfig wlan0 up`.
12. If `/linux/wpa.conf` exists, runs `/linux/wifi-connect.sh` to
    auto-reconnect to the saved network.
13. Runs `ntpdate pool.ntp.org` once we have wifi (recovery has no
    persistent RTC; clock returns to 1970 every boot).

## `/linux/wifi-connect.sh`

Wrapper that wraps `wpa_supplicant -D nl80211` + `dhclient` from the
Ubuntu rootfs (`/linux/rootfs`). Two invocation modes:

```sh
/linux/wifi-connect.sh "SSID" "PASSWORD"   # connect, save to /linux/wpa.conf
/linux/wifi-connect.sh                     # reconnect using saved /linux/wpa.conf
```

The wpa_supplicant is launched via `setsid ... &` so it survives the
oneshot init service being reaped.

## Why this design

A more "Android-native" approach would be to ship full vendor WLAN
HAL + cnss-daemon's pm-service stack. That requires Binder +
servicemanager + pm-service, none of which exist in this recovery.

The chain we picked treats `cnss-daemon` as a single closed-source
binary that just needs:

- /persist mounted (it reads regdb.bin)
- /data/vendor/wifi/sockets/ writable
- /dev/subsys_<name> openable (the `libperipheral_client.so` shim
  satisfies this without Binder; see cnss-stage repo)

…and otherwise drives the modem itself. cnss-daemon's BDF +
cal_report wire format is something kernel-side QMI can't reproduce
(modem rejects with `INVALID_ARG (48)` / `ARG_TOO_LONG (19)`),
so running the real daemon is the cleanest path.

## Removed: wifi-watchdog

Earlier iterations had a `wifi-watchdog` init service that
unconditionally rebooted recovery after 200s, in case the bringup
hung (modem grabbing USB and breaking adb). With the bringup chain
now reliable end-to-end, the watchdog is gone — boot stays up.

## Reproducibility

The `init.rc` lives in the overlay; `build.sh` repacks the ramdisk
with the same byte-for-byte content every run. The only persistent
state is `/linux/` on the data partition (the bringup script + the
saved wpa.conf), which survives reboot but isn't part of the boot
image — so re-flashing the boot image alone never affects what wifi
the device reconnects to.
