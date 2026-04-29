#!/system/bin/sh
# Droidspaces wifi bringup, cnss-daemon edition.
# After modem brings up wlan_pd and icnss connects to WLFW, launch the
# real cnss-daemon to do BDF + cal_report (kernel-side QMI gets err 48
# INVALID_ARG; only userspace libqmiservices serializes a format the
# modem accepts). Modem then fires FW_READY autonomously, wlan.ko probes,
# wlan0 comes up.

R=/linux/wifi-result.txt
P() { echo "DREWIFI: $*" > /dev/pmsg0 2>/dev/null; printf '%s\n' "DREWIFI: $*" >> $R; sync; }
: > $R; sync
P "=== START $(date +%T) ==="

# Hold a kernel wake_lock so the device never auto-sleeps while
# recovery-console is running. Released by the power-button daemon
# (/linux/powerkeyd) on KEY_POWER press to allow manual suspend.
echo droidspaces > /sys/power/wake_lock 2>/dev/null

# Brightness 80% (3276/4095). recovery-console resets brightness on
# launch, so set it here from wifi-bringup (runs after console).
echo 3276 > /sys/class/backlight/panel0-backlight/brightness 2>/dev/null
echo 3276 > /sys/class/backlight/backlight/brightness 2>/dev/null

# Create dirs cnss-daemon needs (unix socket + cal storage).
mkdir -p /data/vendor/wifi/sockets
chmod 755 /data/vendor/wifi /data/vendor/wifi/sockets

mkdir -p /tmp/modem
mount -t vfat -o ro /dev/block/by-name/modem_b /tmp/modem 2>/dev/null
echo /linux/firmware-merged > /sys/module/firmware_class/parameters/path
mkdir -p /vendor/firmware /dev/disk /linux/rmtfs-files
mount --bind /linux/firmware-merged /vendor/firmware 2>/dev/null
ln -sf /dev/block/by-name /dev/disk/by-partlabel
echo 8 4 1 7 > /proc/sys/kernel/printk

pkill rmtfs; pkill pd-mapper; pkill tqftpserv; pkill cnss-daemon
sleep 1

P "starting daemons"
/linux/bin/rmtfs -P -v >/dev/kmsg 2>&1 &
/linux/bin/pd-mapper >/dev/kmsg 2>&1 &
/linux/bin/tqftpserv >/dev/kmsg 2>&1 &
sleep 3
P "rmtfs=$(pidof rmtfs) pd-mapper=$(pidof pd-mapper) tqftpserv=$(pidof tqftpserv)"

for SUB in 0 1 2; do
    P "powerup $SUB"
    echo 1 > /sys/bus/msm_subsys/devices/subsys$SUB/force_powerup
    P "  $SUB=$(cat /sys/bus/msm_subsys/devices/subsys$SUB/state)"
    sleep 4
done

P "wait wlan_pd UP (max 30s)"
for i in $(seq 1 30); do
    sleep 1
    if dmesg 2>/dev/null | grep -q "wlan_pd, state: 0x1fffffff"; then
        P "  WLAN_PD_UP@$i"; break
    fi
done

P "wait icnss WLFW (max 30s)"
for i in $(seq 1 30); do
    sleep 1
    if dmesg 2>/dev/null | grep -q "DREDBG: arrive return success"; then
        P "  ICNSS_ARRIVED@$i"; break
    fi
done

P "insmod wlan.ko"
INSRES=$(insmod /linux/modules/wlan.ko 2>&1)
P "  rc=$? out=$INSRES"

echo 0 > /proc/sys/kernel/printk_ratelimit; echo 1000 > /proc/sys/kernel/printk_ratelimit_burst
mkdir -p /mnt/vendor/persist; mount -t ext4 -o ro /dev/block/by-name/persist /mnt/vendor/persist 2>/dev/null; ls /mnt/vendor/persist/regdb.bin /mnt/vendor/persist/bdwlan.bin >> $R 2>&1
P "starting cnss-daemon"
LD_LIBRARY_PATH=/linux/cnss/lib64:/system/lib64 /linux/cnss/bin/strace -f -ttt -s 200 -o /linux/cnss.strace /linux/cnss/bin/cnss-daemon >/dev/kmsg 2>&1 &
sleep 2
P "  cnss-daemon pid=$(pidof cnss-daemon)"

P "wait FW_READY (max 30s)"
for i in $(seq 1 30); do
    sleep 1
    if dmesg 2>/dev/null | grep -q "WLAN FW is ready"; then
        P "  FW_READY@$i"; break
    fi
done

P "echo ON > /dev/wlan"
echo ON > /dev/wlan 2>&1
P "  rc=$?"
sleep 5

P "ifconfig wlan0 up"
ifconfig wlan0 up 2>&1
P "  rc=$?"

# Replace the broken /etc/resolv.conf symlink (-> /run/resolvconf/...)
# with a real file. /run is tmpfs and resolvconf isn't installed, so
# without this every chroot apt/curl/etc. fails with "Temporary failure
# resolving". Write 1x; survives reboots since /linux/rootfs is on
# data partition.
if [ -L /linux/rootfs/etc/resolv.conf ] || [ ! -s /linux/rootfs/etc/resolv.conf ]; then
    rm -f /linux/rootfs/etc/resolv.conf
    printf 'nameserver 192.168.8.1\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' \
        > /linux/rootfs/etc/resolv.conf
    P "resolv.conf rewritten"
fi

# Auto-reconnect to saved network if /linux/wpa.conf exists. Retry
# once if the first pass didn't get an IPv4 address — the most common
# reason is wpa_supplicant racing with the radio coming up.
if [ -f /linux/wpa.conf ] && [ -x /linux/wifi-connect.sh ]; then
    P "wifi-connect (saved)"
    /linux/wifi-connect.sh >> $R 2>&1
    if ! ifconfig wlan0 2>/dev/null | grep -q "inet addr:"; then
        P "  no IPv4 yet; retry"
        sleep 3
        /linux/wifi-connect.sh >> $R 2>&1
    fi

    # NTP sync: recovery has no RTC backup, clock returns to 1970 every
    # boot. ntpdate is installed in the rootfs; sync once we have wifi
    # so apt cert validity works.
    P "ntpdate"
    chroot /linux/rootfs /usr/sbin/ntpdate -u pool.ntp.org >> $R 2>&1
    P "  date=$(date -u)"
fi

P "ifconfig wlan0:"
ifconfig wlan0 2>&1 | head -3 >> $R; sync
P "lsmod wlan:"
lsmod 2>&1 | grep wlan >> $R; sync
P "--- DREDBG dmesg ---"
dmesg 2>/dev/null | grep -E "DREDBG|cnss-daemon|FW is ready|wlan_pd|cause: FW|err: |wlan0" | tail -50 >> $R; sync
P "=== END ==="
sync; sleep 3; sync
