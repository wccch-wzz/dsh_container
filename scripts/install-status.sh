#!/system/bin/sh
# install-status.sh — single-line JSON consumed by the WebUI (readiness + progress).
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/lib.sh"

_ready=false; module_install_ready && _ready=true
_rootfs=false; [ -f "$ROOTFS/etc/os-release" ] && _rootfs=true
_node=false; [ -x "$ROOTFS/usr/local/bin/node" ] && _node=true
_dsh=false; [ -x "$ROOTFS/usr/local/bin/dsh" ] && _dsh=true
_ver="$(cat "$INSTALL_MARKER" 2>/dev/null || echo none)"
_bytes="$(du -sk "$ROOTFS" 2>/dev/null | awk '{print $1 * 1024}')"
case "$_bytes" in ''|*[!0-9]*) _bytes=0;; esac

# Progress of a background install, when one is running or has finished.
_pstate="idle"; _ppct=0; _pmsg=""; _perr=""
if [ -f "$PROGRESS_FILE.status" ]; then
  _pstate="$(cat "$PROGRESS_FILE.status" 2>/dev/null)"
fi
if [ -f "$PROGRESS_FILE" ]; then
  _ppct="$(sed -n 's/^percent=//p' "$PROGRESS_FILE" 2>/dev/null | head -n 1)"
  _pmsg="$(sed -n 's/^message=//p' "$PROGRESS_FILE" 2>/dev/null | head -n 1)"
fi
# When the install worker died abruptly (for example after the manager view was closed),
# it cannot write an error state. Detect a stale worker using its PID marker so the UI does
# not show a permanently animated "installing" state.
if [ "$_pstate" = "running" ]; then
  _ip="$(cat "$PROGRESS_FILE.pid" 2>/dev/null)"
  case "$_ip" in ''|*[!0-9]*)
    # Give the detach wrapper a short grace period to publish its PID marker.
    _updated="$(sed -n 's/^updated=//p' "$PROGRESS_FILE" 2>/dev/null | head -n 1)"
    case "$_updated" in ''|*[!0-9]*) _updated=0;; esac
    _now="$(date +%s 2>/dev/null)"; case "$_now" in ''|*[!0-9]*) _now=0;; esac
    if [ "$_now" -gt 0 ] && [ $((_now - _updated)) -gt 15 ]; then _pstate=error; _perr="安装进程状态丢失，请重试或查看 install.log"; fi
    ;;
    *)
      # A detached shell's leader may exit while its child keeps installing. Validate
      # liveness against the actual installer command line, not just the recorded PID.
      _alive=false
      if kill -0 "$_ip" 2>/dev/null; then _alive=true; fi
      if [ "$_alive" = false ] && command -v pgrep >/dev/null 2>&1 \
         && pgrep -f "$MODDIR/scripts/install.sh --force" >/dev/null 2>&1; then
        _alive=true
      fi
      if [ "$_alive" = false ]; then _pstate=error; _perr="安装进程已退出，请重试或查看 install.log"; fi
      ;;
  esac
fi
[ -f "$PROGRESS_FILE.error" ] && _perr="$(head -n 1 "$PROGRESS_FILE.error" 2>/dev/null)"
case "$_ppct" in ''|*[!0-9]*) _ppct=0;; esac

# Escape the human-readable strings so the output stays valid JSON.
_json() { printf '%s' "$1" | tr -d '\r' | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/ /g'; }

printf '{"ready":%s,"rootfs":%s,"node":%s,"dsh":%s,"installedVersion":"%s","moduleVersion":"%s","rootfsBytes":%s,"progress":{"state":"%s","percent":%s,"message":"%s","error":"%s"}}\n' \
  "$_ready" "$_rootfs" "$_node" "$_dsh" "$_ver" "$(module_version)" "$_bytes" \
  "$_pstate" "$_ppct" "$(_json "$_pmsg")" "$(_json "$_perr")"
