# Userdata + container rootfs setup

The phone's `/dev/block/by-name/userdata` partition (~50 GB) is
reformatted to ext4 and dedicated to Linux. Everything below lives
on it.

## One-time setup (from a recovery shell)

```
mke2fs -t ext4 -L linux -F /dev/block/by-name/userdata
mount -t ext4 /dev/block/by-name/userdata /linux
mkdir -p /linux/bin /linux/rootfs
```

Tradeoff: this destroys all Android user data on slot A. Slot A still
boots and re-flashes, just with no user data. We deemed this
acceptable since the device is dedicated to Linux.

## droidspaces binary

```
adb push droidspaces-v6.0.0/aarch64/droidspaces /linux/bin/
adb shell chmod +x /linux/bin/droidspaces
```

Source: https://github.com/ravindu644/Droidspaces-OSS releases,
`droidspaces-v6.0.0-2026-04-24.tar.gz`. 324K static aarch64 ELF.

## Ubuntu rootfs

We use the **base** Ubuntu-24.04-XFCE rootfs from
`ravindu644/Droidspaces-rootfs-builder` v20260419, NOT the
"experimental" one. The experimental rootfs ships with a corrupt
dpkg database (empty ubuntu-archive-keyring.gpg, "9 files installed"
state, broken Debconf/Db.pm) and `apt install` fails on libc6.

```
xz -dc Ubuntu-24.04-XFCE-Droidspaces-rootfs-aarch64-*.tar.xz \
  | adb exec-in 'tar -x -C /linux/rootfs/'
```

Streaming via `adb exec-in` is necessary because the recovery's
toybox tar lacks xz support; we decompress on the host and feed the
plain-tar stream over USB.

## What lives in the rootfs from past wayland experiments

The active UI is **recovery-console** drawing the term grid + OSK
straight to the framebuffer. We are NOT running phoc/phosh/sway/
weston — those packages are on disk only as historical residue from
the wayland path that got abandoned (see KNOWN-ISSUES.md #4–#6).

What's apt-installed but unused:

```
phosh phoc phosh-mobile-tweaks phosh-osk-stub
sway weston
seatd libinput-tools evtest
python3-evdev libwayland-server0
```

`phosh.service` was symlinked into `multi-user.target.wants/` for
auto-start; we removed that symlink and ran `systemctl disable
phosh.service` to keep it dormant. systemd inside the container
boots to multi-user.target with a getty on tty1, which is what
recovery-console renders.

If you ever want to revive the wayland path, the binaries are
already there. But fixing the underlying blockers (#4–#6) is the
real work.

## Network setup (USB tether)

apt requires internet. We don't have wifi (cnss-daemon port not
done), so we tether over USB-NCM. The phone exposes `usb0` (192.168.42.2);
the host configures `enxda7ed5ffff01` (192.168.42.1) and NATs through
its uplink:

Host (one-shot per session):

```
sudo ip addr add 192.168.42.1/24 dev enxda7ed5ffff01
sudo ip link set enxda7ed5ffff01 up
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s 192.168.42.0/24 -o <uplink> -j MASQUERADE
sudo iptables -A FORWARD -s 192.168.42.0/24 -j ACCEPT
sudo iptables -A FORWARD -d 192.168.42.0/24 -j ACCEPT
```

Device (from a recovery shell after boot):

```
ifconfig usb0 192.168.42.2 netmask 255.255.255.0 up
```

Inside the container (apt invocation):

```
/linux/bin/droidspaces --name=ubuntu run bash -c '
  ip route add default via 192.168.42.1 dev usb0
  echo nameserver 1.1.1.1 > /etc/resolv.conf
  apt-get -o Acquire::ForceIPv4=true update
'
```

Two gotchas:

1. **Device clock at 1970** breaks TLS (certs aren't valid yet).
   Set it manually on each boot:
   ```
   adb shell "date $(date -u +%m%d%H%M%Y).$(date -u +%S)"
   ```
2. The Ubuntu sources file has `Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg`.
   In the experimental rootfs that file was zero bytes. If you see
   `NO_PUBKEY 871920D1991BC93C` / "is not signed" errors, copy a
   working keyring from the base rootfs.

## Long-term wifi

Not done. The port path:

1. Kernel: load `wlan.ko` (lives at `/linux/modules/wlan.ko`,
   extracted from vendor_dlkm via `payload_dumper` of
   `lineage-23.2-…dre-signed.zip`'s payload.bin).
2. Provide firmware: `wlanmdsp.mbn`, `bdwlan.*`, `WCNSS_qcom_cfg.ini`,
   `wlan_mac.bin`. We have these collected at `/linux/firmware-vendor/`
   on the device.
3. Bring up modem subsystem: dre's WCN3990 wifi+BT firmware loading
   is gated on the modem subsystem being ONLINE. Currently slot B
   has it OFFLINING because nothing pokes it. Lifting it requires
   either a kernel patch (force `subsys_powerup`) or a port of
   cnss-daemon. Multi-day undertaking.

For now: USB-NCM tether for one-shot apt installs, USB-OTG wifi
dongle for daily use.
