#!/system/bin/sh
# wifi-connect.sh SSID PASSWORD     -> connect, persist to /linux/wpa.conf
# wifi-connect.sh                   -> reconnect using saved /linux/wpa.conf
export TMPDIR=/tmp
SSID="$1"; PSK="$2"
SAVE=/linux/wpa.conf

if [ -z "$SSID" ]; then
    [ ! -f "$SAVE" ] && { echo "usage: $0 SSID [PASSWORD]   (or save first then no args)"; exit 2; }
    CONF="$SAVE"
else
    CONF=/linux/rootfs/tmp/wpa.conf
    mkdir -p /linux/rootfs/tmp /tmp
    {
        echo "ctrl_interface=/run/wpa_supplicant"
        echo "update_config=1"
        echo "network={"
        echo "    ssid=\"$SSID\""
        if [ -n "$PSK" ]; then
            echo "    psk=\"$PSK\""
            echo "    key_mgmt=WPA-PSK"
        else
            echo "    key_mgmt=NONE"
        fi
        echo "}"
    } > "$CONF"
    chmod 600 "$CONF"
    cp "$CONF" "$SAVE"; chmod 600 "$SAVE"
fi

mkdir -p /linux/rootfs/run
mount --bind /sys  /linux/rootfs/sys  2>/dev/null
mount --bind /proc /linux/rootfs/proc 2>/dev/null
mount --bind /dev  /linux/rootfs/dev  2>/dev/null
mount --bind /run  /linux/rootfs/run  2>/dev/null

chroot /linux/rootfs /usr/bin/killall -q wpa_supplicant 2>/dev/null
chroot /linux/rootfs /usr/bin/killall -q dhclient 2>/dev/null
sleep 1
ifconfig wlan0 up

# Stage the conf inside the chroot for wpa_supplicant.
cp "$CONF" /linux/rootfs/tmp/wpa.conf 2>/dev/null
chmod 600 /linux/rootfs/tmp/wpa.conf

echo "[*] wpa_supplicant"
# setsid + & + redirect: detach so we survive when called from a oneshot
# init service. Plain `-B` was being SIGKILL'd along with wifi-bringup.
setsid chroot /linux/rootfs /usr/sbin/wpa_supplicant -i wlan0 -c /tmp/wpa.conf -f /tmp/wpa.log -D nl80211 </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
sleep 2

ASSOC=""
i=0
while [ $i -lt 15 ]; do
    sleep 2
    if chroot /linux/rootfs /usr/sbin/iw dev wlan0 link 2>/dev/null | grep -q "Connected to"; then
        ASSOC=1; break
    fi
    i=$((i+1))
done

if [ -z "$ASSOC" ]; then
    echo "[!] not associated"
    tail -20 /linux/rootfs/tmp/wpa.log
    exit 1
fi

echo "[+] associated, dhcp"
# dhclient -1 exits after binding; safe to run inline.
setsid chroot /linux/rootfs /usr/sbin/dhclient -1 wlan0 </dev/null >/dev/null 2>&1
echo "---wlan0---"
ifconfig wlan0 | head -3
