#!/system/bin/sh
# hostd.sh — host-side root executor for the container.
#
# Why this exists: the container runs under PRoot, so it sees the rootfs at "/" and only
# /dev, /proc, /sys and /sdcard are bound from the host. Everything the harness actually
# needs to drive the phone (adb, su, pm, am, settings, svc, logcat, screencap) lives on the
# host, and there is no way to call it from inside the rootfs: /data is not bound, and the
# host has no Node (the bundled Node is a glibc build, Android is bionic).
#
# So the host side runs this small polling executor as root, and both sides talk through the
# one directory they can already see: <rootfs>/root/.dsh-container/hostq.
#
# Protocol, one file per request, all inside $Q:
#   <id>.req   the command line, executed with `sh -c` as host root
#   <id>.out   combined stdout+stderr
#   <id>.rc    exit status
#   <id>.done  empty marker: "result is complete". The guest waits for this file and never
#              for .rc alone, because .rc is written before .done.
# The guest writes <id>.req.tmp and renames it, so a partially written command is never run.
#
# Usage: hostd.sh start|stop|status|daemon|run '<cmd>'
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/lib.sh"

Q="$GUEST_DIR/hostq"
PIDF="$STATE_DIR/run/hostd.pid"
LOG="$STATE_DIR/logs/hostd.log"
OUT_CAP=2000000        # 2MB: a runaway `logcat` must not fill /data
IDLE_SLEEP=0.2
HB_EVERY=2

TERMUX_BIN=""
for _c in /data/data/com.termux/files/usr/bin /data/data/com.termux/files/home/usr/bin; do
  [ -x "$_c/adb" ] && { TERMUX_BIN="$_c"; break; }
done
TERMUX_LIB=""
[ -n "$TERMUX_BIN" ] && TERMUX_LIB="$(dirname "$TERMUX_BIN")/lib"
# adb refuses to start when $HOME/.android cannot be created ("Cannot mkdir '/root/.android'")
# and the host has no /root, so it gets a private home inside the state dir.
# No ADB_SERVER_PORT on purpose: the container reuses the same 5037 server as Termux, so
# `dsh-host adb devices` shows exactly the devices the user sees there. If Termux's server
# is not running, the root adb starts its own one on the same port.
ADB_HOME="$STATE_DIR/run/adb-home"

# adb is a Termux (bionic) binary: it needs $PREFIX/lib on LD_LIBRARY_PATH, and putting that
# on the daemon's own environment would poison every system binary it spawns. Wrap it once
# and expose the wrapper on PATH instead.
make_adb_wrapper() {
  [ -n "$TERMUX_BIN" ] || return 1
  _w="$STATE_DIR/run/adb"
  mkdir -p "$STATE_DIR/run" "$ADB_HOME/.android" 2>/dev/null
  chmod 700 "$ADB_HOME" 2>/dev/null
  cat > "$_w" <<EOF
#!/system/bin/sh
exec /system/bin/env -i HOME=$ADB_HOME USER=root TMPDIR=/data/local/tmp \\
  PATH=$TERMUX_BIN:/system/bin:/system/xbin \\
  LD_LIBRARY_PATH=$TERMUX_LIB \\
  $TERMUX_BIN/adb "\$@"
EOF
  chmod 755 "$_w" 2>/dev/null
  return 0
}

run_one() {
  _f="$1"
  _id="${_f##*/}"; _id="${_id%.req}"
  [ -n "$_id" ] || { rm -f "$_f"; return 0; }
  _out="$Q/$_id.out"; _rc="$Q/$_id.rc"; _done="$Q/$_id.done"
  _cmd="$(cat "$_f" 2>/dev/null)"
  : > "$_out" 2>/dev/null
  # The daemon already runs as root; `sh -c` here is the "direct root shell" the guest asks
  # for. PATH gets the module run dir first so `adb` hits the wrapper above.
  PATH="$STATE_DIR/run:/system/bin:/system/xbin:/system/sbin"
  export PATH
  cd / 2>/dev/null || cd /
  /system/bin/sh -c "$_cmd" >> "$_out" 2>&1
  _st=$?
  _sz=$(wc -c < "$_out" 2>/dev/null | tr -d ' ')
  case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
  if [ "$_sz" -gt "$OUT_CAP" ]; then
    tail -c "$OUT_CAP" "$_out" > "$_out.tmp" 2>/dev/null && mv -f "$_out.tmp" "$_out"
    # 先截断再写标记：反过来的话标记本身会被 tail -c 切掉
    printf '\n[hostd] output truncated to last %s bytes (total %s)\n' "$OUT_CAP" "$_sz" >> "$_out"
  fi
  printf '%s\n' "$_st" > "$_rc" 2>/dev/null
  : > "$_done" 2>/dev/null
  rm -f "$_f" 2>/dev/null
  printf '%s\t%s\t%s\n' "$(date '+%F %T')" "$_id" "$_st" >> "$STATE_DIR/logs/hostd-cmds.log" 2>/dev/null
}

daemon() {
  mkdir -p "$Q" "$STATE_DIR/run" "$STATE_DIR/logs" 2>/dev/null
  chmod 700 "$Q" 2>/dev/null
  echo "$$" > "$PIDF"
  make_adb_wrapper >/dev/null 2>&1
  printf 'HOSTD START %s pid=%s adb=%s\n' "$(date '+%F %T')" "$$" "${TERMUX_BIN:-none}" >> "$LOG"
  _last_hb=0
  while :; do
    for _f in "$Q"/*.req; do
      [ -f "$_f" ] || continue
      run_one "$_f"
    done
    _now=$(date +%s)
    if [ $((_now - _last_hb)) -ge "$HB_EVERY" ]; then
      _last_hb=$_now
      printf '%s\n' "$_now" > "$Q/.heartbeat" 2>/dev/null
      # 30 分钟前的孤儿结果（guest 崩溃/超时留下的）直接清掉
      find "$Q" \( -name '*.out' -o -name '*.rc' -o -name '*.done' \) -mmin +30 -delete 2>/dev/null
    fi
    sleep "$IDLE_SLEEP"
  done
}

running() {
  _p="$(cat "$PIDF" 2>/dev/null)"
  [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null
}

case "$1" in
  start)
    if running; then
      log "宿主执行器已在运行 (pid $(cat "$PIDF"))"
      exit 0
    fi
    mkdir -p "$STATE_DIR/run" "$STATE_DIR/logs" "$Q" 2>/dev/null
    chmod 700 "$Q" 2>/dev/null
    nohup /system/bin/sh "$DIR/hostd.sh" daemon >> "$LOG" 2>&1 &
    sleep 1
    if running; then
      log "宿主执行器已启动 (pid $(cat "$PIDF")，adb=$([ -n "$TERMUX_BIN" ] && echo "$TERMUX_BIN/adb" || echo 未找到))"
    else
      log "宿主执行器启动失败，看 $LOG"
      exit 1
    fi
    ;;
  stop)
    _p="$(cat "$PIDF" 2>/dev/null)"
    if [ -n "$_p" ]; then kill "$_p" 2>/dev/null; sleep 0.5; kill -9 "$_p" 2>/dev/null; fi
    rm -f "$PIDF"
    log "宿主执行器已停止"
    ;;
  status)
    if running; then
      printf '{"hostd":true,"pid":%s,"queue":"%s","adb":%s}\n' "$(cat "$PIDF")" "$Q" \
        "$([ -n "$TERMUX_BIN" ] && echo true || echo false)"
    else
      printf '{"hostd":false,"queue":"%s","adb":%s}\n' "$Q" \
        "$([ -n "$TERMUX_BIN" ] && echo true || echo false)"
    fi
    ;;
  daemon) daemon ;;
  run)
    # Same PATH as the queue path, otherwise `adb` resolves to nothing here and the exact
    # same command works through dsh-host — a difference that only shows up in testing.
    shift
    PATH="$STATE_DIR/run:/system/bin:/system/xbin:/system/sbin"
    export PATH
    make_adb_wrapper >/dev/null 2>&1
    /system/bin/sh -c "$*"
    ;;
  *) echo "用法: hostd.sh start|stop|status|daemon|run '<cmd>'"; exit 2 ;;
esac
