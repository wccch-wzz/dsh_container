#!/system/bin/sh
# lib.sh — standalone dsh_container configuration and self-healing bootstrap.
#
# Design notes:
#   * No Termux dependency: every path is module-relative or under /data/adb.
#   * Every entry script sources this file, so the corrective work below runs on every
#     invocation. That matters because the module ships prebuilt binaries whose
#     executable bit can be lost during install, and because the WebUI entry page can be
#     missing when a build forgets to ship webroot/index.html.

STATE_DIR="${STATE_DIR:-/data/adb/dsh_container}"
LAUNCHER_DIR_OVERRIDE="${LAUNCHER_DIR:-}"
ROOTFS_OVERRIDE="${ROOTFS:-}"
ROOTFS_CACHE_OVERRIDE="${ROOTFS_CACHE:-}"

# ---- module root resolution -------------------------------------------------
# "customize.sh" is *sourced* by the installer, so "$0" there points at the manager
# process rather than the script. The official install-time variable is MODPATH; MODDIR
# is honored too; "$0" is only used when it actually looks like a module root.
# A wrong-but-nonempty result would silently disable every check below, so each candidate
# must prove itself by containing module.prop.
resolve_moddir() {
  # Only accept a candidate whose realpath contains module.prop. "$0" is rejected when it
  # is not a path (e.g. "sh" under `sh -c`), because that would poison every later check.
  _try() {
    _c="$1"
    [ -n "$_c" ] || return 1
    case "$_c" in
      */*) ;;
      *) return 1 ;;          # bare command name, not a directory
    esac
    [ -d "$_c" ] || return 1
    [ -f "$_c/module.prop" ] || return 1
    if [ "${RESOLVE_MODDIR_SKIP_REALPATH:-0}" != "1" ] && command -v realpath >/dev/null 2>&1; then
      _r="$(realpath "$_c" 2>/dev/null)"
      [ -n "$_r" ] && { printf '%s' "$_r"; return 0; }
    fi
    printf '%s' "$_c"; return 0
  }

  # 1) official install-time variable
  _try "${MODPATH:-}" && return 0
  # 2) legacy variable, but only when it really is a module root
  _try "${MODDIR:-}" && return 0
  # 3) the sourcing script's directory. Two shapes occur in practice:
  #      <mod>/something.sh      -> parent is the module root
  #      <mod>/scripts/entry.sh  -> grandparent is the module root
  _try "${0%/*}" && return 0
  _try "${0%/*}/.." && return 0
  # 4) walk up from the working directory
  _try "$PWD" && return 0
  _try "$PWD/.." && return 0
  _try "$PWD/../.." && return 0

  # Nothing proved out. Return an empty string so callers can distinguish
  # "not resolved" from "resolved to a wrong directory".
  printf '%s' ""
}
MODDIR="$(resolve_moddir)"
BIN_DIR="${BIN_DIR:-/system/bin:/system/xbin}"
DEFAULT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [ -n "$MODDIR" ]; then
  LAUNCHER_DIR="${LAUNCHER_DIR_OVERRIDE:-$MODDIR/libexec/launcher}"
else
  LAUNCHER_DIR="${LAUNCHER_DIR_OVERRIDE:-}"
fi
PROOT_BIN="$LAUNCHER_DIR/bin/proot"
ROOTFS="${ROOTFS_OVERRIDE:-$STATE_DIR/rootfs}"
ROOTFS_CACHE="${ROOTFS_CACHE_OVERRIDE:-$STATE_DIR/cache}"
RUN_DIR="$STATE_DIR/run"
LOG_DIR="$STATE_DIR/logs"
PID_FILE="$RUN_DIR/container.pid"
INSTALL_MARKER="$STATE_DIR/.installed-version"
GUEST_DIR="$ROOTFS/root/.dsh-container"
# The shared workspace stays on /sdcard so the user can reach their files, but TMPDIR must
# NOT live there: /sdcard is a FUSE mount and refuses executable mmap, so any native addon
# cached under it fails to load with "failed to map segment from shared object"
# (DSH caches require_builtin.node that way). Put TMPDIR on the ext4 data partition.
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/sdcard/DSH-work}"
WORKSPACE_TMP="${WORKSPACE_TMP:-$STATE_DIR/tmp}"
DSH_PORT="${DSH_PORT:-23099}"
BRIDGE_PORT="${BRIDGE_PORT:-23991}"
WS_PORT="${WS_PORT:-23992}"
# ssh-term.js 启动时把「真实端口 + token」写到这里：端口被占会自动后移，
# 页面靠这个文件拿到正确端点。硬编码端口在宿主冲突时会让终端永久连不上。
WS_ENDPOINT_FILE="$GUEST_DIR/ws.endpoint"
SSH_PORT="${SSH_PORT:-23022}"
ROOTFS_URL="${ROOTFS_URL:-https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64-root.tar.xz}"
ROOTFS_SHA256="${ROOTFS_SHA256:-5997dcb8b484f6d28c99d367d20669010ef926fba2e6de72babba630d94e313b}"
NODE_URL="${NODE_URL:-https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-arm64.tar.xz}"
NODE_SHA256="${NODE_SHA256:-${NODE_SHA256:-58c9520501f6ae2b52d5b210444e24b9d0c029a58c5011b797bc1fe7105886f6}}"
TS="$(date +%Y%m%d-%H%M%S)"

[ -f "$STATE_DIR/env.sh" ] && . "$STATE_DIR/env.sh"

log() { echo "[dsh_container] $*"; }
die() {
  # Record the failure so a background run's outcome is visible to the WebUI.
  printf '%s\n' "error" > "$PROGRESS_FILE.status" 2>/dev/null
  printf '%s\n' "$*" > "$PROGRESS_FILE.error" 2>/dev/null
  rm -f "$PROGRESS_FILE.pid" 2>/dev/null
  echo "[dsh_container] ERROR: $*" >&2
  exit 1
}

# ---- progress reporting -----------------------------------------------------
# A full install (download + unpack + apt + node + dsh) takes far longer than the WebUI's
# per-command timeout, so it runs detached and reports through this file instead.
PROGRESS_FILE="$RUN_DIR/install-progress"

# progress <percent> <message>
progress() {
  _pct="$1"; shift
  mkdir -p "$RUN_DIR" 2>/dev/null
  _tmp="$PROGRESS_FILE.new.$$"
  {
    printf 'percent=%s\n' "$_pct"
    printf 'message=%s\n' "$*"
    printf 'updated=%s\n' "$(date +%s 2>/dev/null)"
  } > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$PROGRESS_FILE" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  log "$*"
}

_write_progress_state() {
  _state="$1"; _tmp="$PROGRESS_FILE.status.new.$$"
  printf '%s\n' "$_state" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$PROGRESS_FILE.status" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
}
progress_running() { _write_progress_state running; }
progress_done() { _write_progress_state done; }
progress_failed() { _write_progress_state error; }

# Bounded heartbeat. A plain `while [ ! -f stop ]` loop outlives its parent when the
# parent dies before creating the stop file, and then keeps republishing a stale stage
# forever — which made a later install look like it was stuck in an earlier stage.
# The loop therefore also stops once the owning PID (if any) is gone, and has a hard cap.
progress_heartbeat() {
  _pct="$1"; _label="$2"; _stop="$3"; _owner="${4:-}"
  _elapsed=0
  while [ ! -f "$_stop" ]; do
    if [ -n "$_owner" ] && ! kill -0 "$_owner" 2>/dev/null; then
      break
    fi
    [ "$_elapsed" -lt 3600 ] || break
    progress "$_pct" "$_label（已用时 ${_elapsed}s）"
    sleep 4
    _elapsed=$((_elapsed + 4))
  done
  rm -f "$_stop" 2>/dev/null
}

# ---- self-healing helpers ---------------------------------------------------

# Restore the executable bit when a shipped binary lost it. Only a genuinely absent or
# empty file is an error; "present but not executable" used to be misreported as missing.
ensure_exec() {
  _f="$1"
  [ -f "$_f" ] || return 1
  [ -s "$_f" ] || return 1
  [ -x "$_f" ] && return 0
  chmod 755 "$_f" 2>/dev/null
  [ -x "$_f" ]
}

# A usable WebUI entry page: real markup for this module, with no unreplaced placeholder.
page_ok() {
  _f="$1"
  [ -s "$_f" ] || return 1
  grep -qi '<html' "$_f" || return 1
  grep -q 'id="btnInstall"' "$_f" || return 1
  grep -q 'xterm' "$_f" || return 1
  grep -q '__[A-Z][A-Z_]*__' "$_f" && return 1
  return 0
}

# KernelSU requires webroot/index.html. If a build shipped only the template, render it
# here; never overwrite the shipped page with something that fails validation.
ensure_webui() {
  _wb="$MODDIR/webroot"
  _idx="$_wb/index.html"
  _tpl="$_wb/index.html.in"
  page_ok "$_idx" && return 0
  [ -f "$_tpl" ] || return 1
  _tmp="$_wb/.index.html.new"
  rm -f "$_tmp"
  if sed -e "s|__BRIDGE_PORT__|$BRIDGE_PORT|g" \
         -e "s|__WS_PORT__|$WS_PORT|g" \
         "$_tpl" > "$_tmp" 2>/dev/null && page_ok "$_tmp"; then
    mv -f "$_tmp" "$_idx" 2>/dev/null || rm -f "$_tmp"
  else
    rm -f "$_tmp"
  fi
  page_ok "$_idx"
}

# Corrective work that must hold for every entry point.
module_bootstrap() {
  [ "${DISABLE_BOOTSTRAP:-0}" = "1" ] && return 0

  # Accept an already resolved module directory even when this library is sourced from a
  # tiny `sh -c` helper (where $0 is the word "sh"). The module root must still prove
  # itself with module.prop and scripts/install.sh so unrelated directories aren't used.
  if [ -n "$MODDIR" ] && [ -f "$MODDIR/module.prop" ] && [ -f "$MODDIR/scripts/install.sh" ]; then
    :
  else
    echo "[dsh_container] ERROR: 无法定位模块目录（缺少 module.prop / scripts/install.sh）" >&2
    return 1
  fi

  if [ -z "$MODDIR" ]; then
    echo "[dsh_container] ERROR: 无法定位模块目录（缺少 module.prop 的父目录）" >&2
    return 1
  fi

  mkdir -p "$RUN_DIR" "$LOG_DIR" "$ROOTFS_CACHE" 2>/dev/null
  # Keep PRoot temp files and unbundled loader in writable data state, not the module
  # directory (which may be mounted read-only by KernelSU after install).
  PROOT_TMP_DIR="${PROOT_TMP_DIR:-$RUN_DIR/proot-tmp}"
  PROOT_L2S_DIR="${PROOT_L2S_DIR:-$RUN_DIR/proot-l2s}"
  export PROOT_TMP_DIR PROOT_L2S_DIR
  mkdir -p "$PROOT_TMP_DIR" "$PROOT_L2S_DIR" 2>/dev/null

  # Binaries and control scripts must stay executable across reinstalls.
  ensure_exec "$LAUNCHER_DIR/bin/proot" >/dev/null 2>&1
  ensure_exec "$LAUNCHER_DIR/bin/curl" >/dev/null 2>&1
  ensure_exec "$LAUNCHER_DIR/bin/zstd" >/dev/null 2>&1
  ensure_exec "$LAUNCHER_DIR/bin/xz" >/dev/null 2>&1
  ensure_exec "$LAUNCHER_DIR/proot-rootfs.sh" >/dev/null 2>&1
  for _s in "$MODDIR"/scripts/*.sh; do
    [ -e "$_s" ] || continue
    ensure_exec "$_s" >/dev/null 2>&1
  done
  for _s in "$MODDIR/customize.sh" "$MODDIR/action.sh" "$MODDIR/uninstall.sh"; do
    [ -e "$_s" ] && ensure_exec "$_s" >/dev/null 2>&1
  done

  ensure_webui >/dev/null 2>&1
  return 0
}

module_version() {
  _mp="$MODDIR/module.prop"
  [ -f "$_mp" ] && sed -n 's/^version=//p' "$_mp" | head -n 1 || echo unknown
}

# ---- archive handling -------------------------------------------------------

# Android's toybox tar does not implement xz or zstd itself: it shells out to whichever
# "xz"/"zstd" it finds on PATH, and reports "exec xz: No such file or directory" when the
# module runs with the minimal system PATH. The launcher therefore ships its own xz and
# zstd; run_extract_archive() puts those first on PATH and exports the matching library
# directory so the child processes resolve their dependencies.
# POSIX sh has no local variables: every assignment inside a function overwrites the
# caller's variable of the same name. This helper used generic names (_archive/_dest) and
# silently clobbered unpack_rootfs()'s _dest, so a later "$_dest.tmp" check resolved to
# ".../rootfs.tmp.tmp" and always failed. All helper variables are now doubly prefixed.
run_extract_archive() {
  _rx_archive="$1"; _rx_dest="$2"; shift 2
  mkdir -p "$_rx_dest" 2>/dev/null
  /system/bin/env -i \
    HOME=/root PATH="$LAUNCHER_DIR/bin:$BIN_DIR" \
    LD_LIBRARY_PATH="$LAUNCHER_DIR/lib:/system/lib64" \
    TMPDIR="$LAUNCHER_DIR/tmp" \
    /system/bin/tar -x -f "$_rx_archive" -C "$_rx_dest" "$@"
}

# ---- hardlink capability ----------------------------------------------------

# PRoot's --link2symlink emulates hardlinks with symlinks, which is required only where
# link(2) is denied (an unprivileged Termux app). Under KernelSU root on a normal ext4
# data partition hardlinks work natively, and forcing the emulation is actively harmful:
# it leaves entries that list correctly but fail to open, which is what broke dpkg
# unpacking (openssh-client, perl) with "paste subprocess was killed by broken pipe".
# Detect support once and only fall back to the emulation when link(2) really fails.
_proot_hardlink_mode=""
hardlink_mode() {
  if [ -z "$_proot_hardlink_mode" ]; then
    _t="$PROOT_TMP_DIR/.hl-test.$$"
    rm -f "$_t" "$_t.link" 2>/dev/null
    if : > "$_t" 2>/dev/null && ln "$_t" "$_t.link" 2>/dev/null; then
      # Native hardlinks work: omit the flag entirely. proot has no --no-link2symlink
      # switch (that spelling belongs to proot-distro), so "off" means "do not pass it".
      _proot_hardlink_mode=""
    else
      _proot_hardlink_mode="--link2symlink"
    fi
    rm -f "$_t" "$_t.link" 2>/dev/null
  fi
  printf '%s' "$_proot_hardlink_mode"
}

# ---- container execution ----------------------------------------------------

# Run inside the rootfs with a sanitized environment: no inherited host variables, no
# Termux bind mounts, bundle-relative temp and link2symlink directories.
proot_prefix() {
  printf '%s' "/system/bin/env -i \
    HOME=/root USER=root PATH=$BIN_DIR \
    LD_LIBRARY_PATH=$LAUNCHER_DIR/lib:/system/lib64 \
    PROOT_TMP_DIR=$PROOT_TMP_DIR PROOT_L2S_DIR=$PROOT_L2S_DIR \
    $PROOT_BIN --kill-on-exit $(hardlink_mode) --sysvipc $1 \
    -0 --rootfs=$ROOTFS --cwd=/root \
    --bind=/dev --bind=/proc --bind=/sys \
    --bind=/dev/urandom:/dev/random \
    --bind=/sdcard --bind=/storage/emulated/0"
}

in_container() {
  _cmd="$1"
  mkdir -p "$PROOT_TMP_DIR" "$PROOT_L2S_DIR" 2>/dev/null
  # shellcheck disable=SC2046
  $(proot_prefix "") /usr/bin/env -i HOME=/root USER=root TMPDIR=/tmp \
    PATH="$DEFAULT_PATH" TERM=xterm-256color /bin/bash -lc "$_cmd"
}

# Start a long-running guest service from the host side.
# The command queue (agent.sh) is the primary path, but a child backgrounded inside the
# queue subshell can be reaped before it detaches; that produced "SSH 终端已启动" while no
# process existed and port 23992 stayed closed. Here the service runs under its own PRoot
# instance, which stays alive as its parent, so it cannot be orphaned or reaped.
spawn_guest() { # spawn_guest <pid-name> <guest-command> [log-name]
  _sg_name="$1"; _sg_cmd="$2"; _sg_log="${3:-$1.log}"
  mkdir -p "$PROOT_TMP_DIR" "$PROOT_L2S_DIR" "$GUEST_DIR" 2>/dev/null
  # shellcheck disable=SC2046
  nohup $(proot_prefix "") /usr/bin/env -i HOME=/root USER=root TMPDIR=/tmp \
    PATH="$DEFAULT_PATH" TERM=xterm-256color /bin/bash -lc "exec $_sg_cmd" \
    >> "$GUEST_DIR/$_sg_log" 2>&1 &
  echo $! > "$GUEST_DIR/$_sg_name.pid"
  return 0
}

guest_exec() {
  _cmd="$1"; _tmo="${2:-60}"
  _Q="$GUEST_DIR/queue"
  if [ ! -f "$GUEST_DIR/agent.pid" ]; then echo "容器执行器未就绪（请先启动容器）"; return 125; fi
  _apid="$(cat "$GUEST_DIR/agent.pid" 2>/dev/null)"
  if [ -z "$_apid" ] || ! kill -0 "$_apid" 2>/dev/null; then
    echo "容器执行器未就绪（请先启动容器）"; return 125
  fi
  rm -f "$_Q/exit.txt"
  printf '%s' "$_cmd" > "$_Q/cmd.txt.new" 2>/dev/null || { echo "无法写入命令队列"; return 125; }
  mv -f "$_Q/cmd.txt.new" "$_Q/cmd.txt"
  _i=0; _max=$((_tmo * 4))
  while [ "$_i" -lt "$_max" ]; do
    if [ -f "$_Q/exit.txt" ]; then
      sleep 0.3
      cat "$_Q/out.txt" 2>/dev/null
      _rc="$(cat "$_Q/exit.txt" 2>/dev/null)"
      rm -f "$_Q/exit.txt"
      return "${_rc:-0}"
    fi
    sleep 0.25; _i=$((_i + 1))
  done
  echo "命令执行超时（${_tmo}s）"; return 124
}

container_pid() { [ -f "$PID_FILE" ] && cat "$PID_FILE" 2>/dev/null; }
container_running() {
  _p="$(container_pid)"
  [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null
}

# A live PID is not proof of a working container. PRoot can lose syscall emulation for the
# whole tree (the agent then logs "fork: Function not implemented" forever) while the
# top-level process still exists; every later start then looks successful while nothing
# runs. Only a round-trip through the command queue proves the container can do work.
container_healthy() {
  container_running || return 1
  guest_exec "true" 4 >/dev/null 2>&1
}

# Port check. /proc/net/tcp is the primary source; it is unreadable outside the root
# context (for example when a diagnostic is run from a normal app shell), so fall back to
# ss/netstat before concluding the port is closed.
port_open() {
  _port="$1"
  _hex="$(printf '%04X' "$_port")"
  if [ -r /proc/net/tcp ]; then
    awk -v h="$_hex" '$2 ~ (":" h "$") && $4 == "0A" { f=1 } END { exit !f }' /proc/net/tcp 2>/dev/null && return 0
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v p=":$_port" '$4 ~ p"$" { f=1 } END { exit !f }' && return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk -v p=":$_port" '$4 ~ p"$" { f=1 } END { exit !f }' && return 0
  fi
  return 1
}
dsh_port_open() { port_open "$DSH_PORT"; }
bridge_port_open() { port_open "$BRIDGE_PORT"; }
ssh_port_open() { port_open "$SSH_PORT"; }

ws_endpoint_port() {
  _wp=""
  [ -f "$WS_ENDPOINT_FILE" ] && _wp="$(sed -n 's/^port=//p' "$WS_ENDPOINT_FILE" 2>/dev/null | head -n 1)"
  case "$_wp" in ''|*[!0-9]*) _wp="$WS_PORT" ;; esac
  printf '%s' "$_wp"
}
ws_endpoint_token() {
  [ -f "$WS_ENDPOINT_FILE" ] && sed -n 's/^token=//p' "$WS_ENDPOINT_FILE" 2>/dev/null | head -n 1
}
ws_clear_endpoint() { rm -f "$WS_ENDPOINT_FILE" 2>/dev/null; }

# Kill every ssh-term.js instance: the guest node process *and* the host PRoot wrapper that
# carries the same arguments. `ws_healthy` only proves "some ssh-term is serving", so after
# a code deploy the previous build would happily keep answering on the old port with the old
# (unauthenticated) protocol. A restart must therefore be a kill-all, not a port check.
ws_kill_all() {
  ps -A -o PID,ARGS 2>/dev/null | grep 'ssh-term\.js' | grep -v grep | while read -r _pid _rest; do
    case "$_pid" in ''|*[!0-9]*) continue ;; esac
    kill -9 "$_pid" 2>/dev/null
  done
  ws_clear_endpoint
  rm -f "$GUEST_DIR/ssh-term.pid" 2>/dev/null
  return 0
}

ws_port_open() { port_open "$(ws_endpoint_port)"; }

# A listening port is not proof that the terminal works. The queue backgrounds ssh-term
# with nohup, that child gets reaped moments after binding, and a watchdog restart can make
# the port flicker open while the process is already gone. `ensure_ssh` used to trust the
# port alone and then skip the start entirely, leaving a dead terminal behind a status line
# that said ws:true. Require the process as well.
ws_process_alive() {
  ps -A -o ARGS 2>/dev/null | grep -E 'ssh-term\.js' | grep -qv grep
}
ws_healthy() {
  ws_port_open && ws_process_alive
}

dsh_process_alive() {
  ps -A -o ARGS 2>/dev/null | grep -E "dsh.*(web|--profile web).*--port $DSH_PORT" | grep -qv grep
}

module_install_ready() {
  [ -f "$ROOTFS/etc/os-release" ] || return 1
  [ -x "$ROOTFS/usr/local/bin/node" ] || return 1
  [ -x "$ROOTFS/usr/local/bin/dsh" ] || return 1
  [ -x "$ROOTFS/usr/sbin/sshd" ] || return 1
  [ -x "$ROOTFS/usr/bin/tmux" ] || return 1
}

module_bootstrap
