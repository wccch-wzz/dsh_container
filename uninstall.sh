#!/system/bin/sh
# uninstall.sh — stop everything the module started; keep user data unless asked.
MODDIR="${MODDIR:-$(dirname "$0")}"
STATE_DIR=/data/adb/dsh_container
for s in dsh module-bridge ssh-term sshd; do
  pf="$STATE_DIR/rootfs/root/.dsh-container/$s.pid"
  [ -f "$pf" ] && kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null
  rm -f "$pf"
done
if [ -f "$STATE_DIR/run/hostd.pid" ]; then
  kill "$(cat "$STATE_DIR/run/hostd.pid" 2>/dev/null)" 2>/dev/null
  rm -f "$STATE_DIR/run/hostd.pid"
fi
if [ -f "$STATE_DIR/run/container.pid" ]; then
  kill "$(cat "$STATE_DIR/run/container.pid" 2>/dev/null)" 2>/dev/null
  rm -f "$STATE_DIR/run/container.pid"
fi
# Rootfs and cache are large; remove them unless the user kept a marker file.
if [ ! -f "$STATE_DIR/keep-rootfs" ]; then
  rm -rf "$STATE_DIR/rootfs" "$STATE_DIR/cache"
fi
exit 0
