#!/system/bin/sh
# proot-rootfs.sh — run the bundled Android PRoot against a rootfs, with no Termux dependency.
# Usage: proot-rootfs.sh <rootfs> [command ...]
set -eu
SELF="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOTFS="$1"; shift 2>/dev/null || true
[ -d "$ROOTFS" ] || { echo "rootfs not found: $ROOTFS" >&2; exit 2; }
exec /system/bin/env -i \
  HOME=/root USER=root PATH=/system/bin:/system/xbin \
  LD_LIBRARY_PATH="$SELF/lib:/system/lib64" \
  PROOT_TMP_DIR="$SELF/tmp" PROOT_L2S_DIR="$SELF/l2s" \
  "$SELF/bin/proot" --kill-on-exit --link2symlink --sysvipc -0 \
  --rootfs="$ROOTFS" --cwd=/root --bind=/dev --bind=/proc --bind=/sys \
  /usr/bin/env -i HOME=/root USER=root \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  TERM=xterm-256color /bin/bash -lc "${*:-exec /bin/bash -l}"
