#!/system/bin/sh
# container.sh — standalone container lifecycle (bundled PRoot launcher).
# Usage: container.sh start|stop|status|enter|install
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/lib.sh"

preflight() {
  [ -x "$PROOT_BIN" ] || die "bundled launcher missing: $PROOT_BIN"
  [ -d "$ROOTFS" ] || die "rootfs missing: $ROOTFS (run: container.sh install)"
  [ -x "$ROOTFS/bin/bash" ] || die "rootfs has no /bin/bash: $ROOTFS"
  mkdir -p "$LAUNCHER_DIR/tmp" "$LAUNCHER_DIR/l2s" 2>/dev/null
}

do_start() {
  preflight
  if container_running; then
    if container_healthy; then
      log "容器已在运行 (pid $(container_pid))"
      return 0
    fi
    log "容器进程存在但执行器无响应，重启容器"
    do_stop
  fi
  module_install_ready || die "容器组件未就绪，请先执行安装"
  mkdir -p "$WORKSPACE_ROOT" "$WORKSPACE_TMP" 2>/dev/null
  sh "$DIR/deploy.sh" >/dev/null 2>&1 || log "deploy 警告（继续启动）"

  PROOT_MAIN="$(proot_prefix "--kill-on-exit")"
  GUEST_SETUP="export HOME=/root TMPDIR=$WORKSPACE_TMP; export PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin; cd $WORKSPACE_ROOT 2>/dev/null || cd /root; exec /bin/bash /root/.dsh-container/supervisor.sh >> /root/.dsh-container/agent.log 2>&1"

  # shellcheck disable=SC2086
  nohup $PROOT_MAIN /usr/bin/env -i HOME=/root USER=root TMPDIR=/tmp \
    PATH="$DEFAULT_PATH" TERM=xterm-256color /bin/bash -lc "$GUEST_SETUP" \
    >"$LOG_DIR/container-latest.log" 2>&1 &
  _pid=$!
  echo "$_pid" > "$PID_FILE"

  _i=0
  while [ "$_i" -lt 20 ]; do
    if kill -0 "$_pid" 2>/dev/null && guest_exec "true" 5 >/dev/null 2>&1; then
      log "容器已启动 (pid $_pid, agent 就绪)"
      return 0
    fi
    kill -0 "$_pid" 2>/dev/null || {
      rm -f "$PID_FILE"
      log "容器启动失败，日志尾部:"
      tail -5 "$LOG_DIR/container-latest.log" 2>/dev/null
      return 1
    }
    _i=$((_i + 1)); sleep 0.5
  done
  log "容器已启动 (pid $_pid, agent 就绪中…)"
  return 0
}

do_stop() {
  if ! container_running; then
    rm -f "$PID_FILE"
    log "容器未运行"
    return 0
  fi
  for _name in dsh module-bridge ssh-term; do
    _pf="$GUEST_DIR/$_name.pid"
    if [ -f "$_pf" ]; then
      _p="$(cat "$_pf" 2>/dev/null)"
      [ -n "$_p" ] && kill "$_p" 2>/dev/null
      rm -f "$_pf"
    fi
  done
  for _p in $(ps -A -o PID,ARGS 2>/dev/null | grep -E "dsh.*(web|--profile web).*--port $DSH_PORT|module-bridge\.js|ssh-term\.js" | grep -v grep | awk '{print $1}'); do
    kill "$_p" 2>/dev/null
  done
  sleep 1
  _pid="$(container_pid)"
  kill "$_pid" 2>/dev/null
  _i=0
  while [ "$_i" -lt 20 ]; do
    kill -0 "$_pid" 2>/dev/null || break
    _i=$((_i + 1)); sleep 0.25
  done
  kill -0 "$_pid" 2>/dev/null && { log "优雅停止超时，强制终止"; kill -9 "$_pid" 2>/dev/null; }
  rm -f "$PID_FILE"
  log "容器已停止"
  return 0
}

do_status() {
  _c=false; container_running && _c=true
  _a=false; [ "$_c" = true ] && guest_exec "true" 3 >/dev/null 2>&1 && _a=true
  _ready=false; module_install_ready && _ready=true
  printf '{"installed":%s,"container":{"running":%s,"pid":%s},"agent":{"alive":%s},"dsh":{"running":%s,"port":%s},"ssh":{"sshd":%s,"port":%s,"ws":%s}}\n' \
    "$_ready" "$_c" "$(container_pid 2>/dev/null || echo 0)" "$_a" \
    "$(dsh_port_open && echo true || echo false)" "$DSH_PORT" \
    "$(ssh_port_open && echo true || echo false)" "$SSH_PORT" \
    "$(ws_port_open && echo true || echo false)"
}

do_enter() {
  preflight
  # shellcheck disable=SC2046
  $(proot_prefix) /usr/bin/env -i HOME=/root USER=root TMPDIR=/tmp \
    PATH="$DEFAULT_PATH" TERM="${TERM:-xterm-256color}" /bin/bash -l
}

case "$1" in
  install) sh "$DIR/install.sh" "${2:-}" ;;
  start)
    # --detach：立即返回，真正的启动在后台跑。否则 WebUI 的同步 exec 会被卡住，
    # 页面上所有查询排队，看起来就像“卡死 + 一直查询中”。
    if [ "${2:-}" = "--detach" ]; then
      _dt="$LOG_DIR/container-start.log"
      _lk="$STATE_DIR/.boot.lock"
      mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null
      if ! mkdir "$_lk" 2>/dev/null; then
        _t=$(cat "$_lk/ts" 2>/dev/null || echo 0)
        _age=$(( $(date +%s) - _t ))
        if [ "$_t" != 0 ] && [ "$_age" -lt 300 ]; then
          echo "已有启动任务在进行中（${_age}s 前开始），忽略重复请求"
          exit 0
        fi
        rm -rf "$_lk"
        mkdir "$_lk" 2>/dev/null || { echo "启动锁竞争失败，请稍后再试"; exit 0; }
      fi
      date +%s > "$_lk/ts"
      nohup sh -c "sh '$DIR/container.sh' start >>'$_dt' 2>&1; rm -rf '$_lk'" >/dev/null 2>&1 &
      echo "容器启动已在后台进行，日志: $_dt"
      exit 0
    fi
    do_start ;;
  stop)   do_stop ;;
  restart) do_stop; do_start ;;
  status) do_status ;;
  enter)  do_enter ;;
  *) echo "用法: container.sh install|start|stop|restart|status|enter"; exit 2 ;;
esac
