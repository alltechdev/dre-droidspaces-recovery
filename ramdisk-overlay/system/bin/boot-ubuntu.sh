#!/system/bin/sh
# Boot the Ubuntu container under recovery-console. Recovery-console
# launches us via --exec; we self-mount /linux and exec droidspaces in
# foreground so the container's stdio takes over the PTY.
set -e

LINUX_DEV=/dev/block/by-name/userdata
LINUX_MNT=/linux

if ! mountpoint -q "$LINUX_MNT"; then
  mkdir -p "$LINUX_MNT"
  mount -t ext4 "$LINUX_DEV" "$LINUX_MNT"
fi

exec /linux/bin/droidspaces \
    -r /linux/rootfs \
    -n ubuntu \
    -h ubuntu \
    --hw-access \
    --privileged=full \
    --foreground \
    start
