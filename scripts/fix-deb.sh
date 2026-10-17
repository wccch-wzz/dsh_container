#!/system/bin/sh
# fix-deb.sh — unpack a Debian package on the host side, converting hardlinks to copies.
#
# Why this exists: inside PRoot the link2symlink extension rewrites hardlink() into a
# symlink plus a shadow file. When that shadow path cannot be created (permissions, SELinux,
# a read-only bind) dpkg's unpack step fails with
#   dpkg-deb: error: paste subprocess was killed by signal (Broken pipe)
# and leaves an unreadable placeholder in place of the real binary, so the tool then reports
# "No such file or directory" even though the file exists.
#
# Extracting on the host with tar -h turns every hardlink and symlink into a real file, so the
# guest receives usable binaries. Used to repair packages when the in-guest unpack failed.
#
# Usage: fix-deb.sh <package.deb> <rootfs> [launcher-bin-dir]
set -u
DEB="$1"; ROOTFS="$2"; LBIN="${3:-}"
[ -f "$DEB" ] || { echo "fix-deb: package not found: $DEB" >&2; exit 1; }
[ -d "$ROOTFS" ] || { echo "fix-deb: rootfs not found: $ROOTFS" >&2; exit 1; }

WORK="${ROOTFS%/}/../.deb-fix-work"
rm -rf "$WORK"; mkdir -p "$WORK" || exit 1

# An archive header is 60 bytes and members are padded to an even offset.
off=8
total="$(wc -c < "$DEB" | tr -d ' ')"
member=""
while [ "$off" -lt "$total" ]; do
  hdr="$(dd if="$DEB" bs=1 skip="$off" count=60 2>/dev/null)"
  name="$(printf '%s' "$hdr" | cut -c1-16 | tr -d ' ')"
  size="$(printf '%s' "$hdr" | cut -c49-58 | tr -d ' ')"
  case "$size" in ''|*[!0-9]*) break ;; esac
  case "$name" in
    data.tar*)
      dd if="$DEB" bs=1 skip=$((off + 60)) count="$size" of="$WORK/$name" 2>/dev/null
      member="$WORK/$name"
      ;;
  esac
  off=$((off + 60 + size + (size % 2)))
done

if [ -z "$member" ]; then
  rm -rf "$WORK"
  echo "fix-deb: no data member in $(basename "$DEB")" >&2
  exit 1
fi

# tar shells out for xz/zstd; prefer the launcher's own copies when they are available.
if [ -n "$LBIN" ] && [ -d "$LBIN" ]; then
  PATH="$LBIN:/system/bin:/system/xbin"
  LD_LIBRARY_PATH="$(dirname "$LBIN")/lib:/system/lib64"
  export PATH LD_LIBRARY_PATH
fi

# -h follows links so hardlinks become independent copies.
if tar -xhf "$member" -C "$ROOTFS" 2>/dev/null; then
  rc=0
elif tar -xf "$member" -C "$ROOTFS" 2>/dev/null; then
  rc=0
else
  rc=1
fi

rm -rf "$WORK"
[ "$rc" -eq 0 ] && echo "fix-deb: unpacked $(basename "$DEB")"
exit "$rc"
