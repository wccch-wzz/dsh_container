#!/system/bin/sh
# dsh.sh — DSH lifecycle and self-test for the standalone container.
# Usage: dsh.sh start|stop|status|log|selftest|ssh-start|ssh-restart|ssh-stop|all-start
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/lib.sh"

ensure_bridge() {
  bridge_port_open && return 0
  _pf="$GUEST_DIR/module-bridge.pid"
  if [ -f "$_pf" ]; then
    _p="$(cat "$_pf" 2>/dev/null)"
    [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && return 0
  fi
  ensure_guest_assets || return 1
  guest_exec "nohup /usr/local/bin/node /root/.dsh-container/module-bridge.js >> /root/.dsh-container/module-bridge.log 2>&1 & echo \$! > /root/.dsh-container/module-bridge.pid; echo bridge-started" 15
  sleep 2
  bridge_port_open && return 0
  log "命令队列未能拉起授权桥，改用宿主侧 PRoot 直接启动"
  spawn_guest module-bridge "/usr/local/bin/node /root/.dsh-container/module-bridge.js" module-bridge.log
}

# The WebUI terminal no longer goes through the container sshd: PRoot cannot serve
# accept()/accept4() here, so sshd logs "accept: Function not implemented" and every
# client stalls. ssh-term.js owns a local pty instead, so the sshd branch was dead code
# that only cost boot time and left a listening port nobody used — it is gone.
ensure_ssh() {
  _force="${1:-0}"
  # A still-running terminal from the previous build passes ws_healthy, so an explicit
  # restart has to kill first instead of trusting the health check.
  if [ "$_force" = "1" ]; then ws_kill_all; sleep 1; fi
  if ! ws_healthy; then
    ensure_guest_assets || return 1
    # The command queue backgrounds the child with nohup, and that child keeps getting
    # reaped: `ssh-start` reported success while the ws port stayed closed. Give the
    # terminal its own PRoot parent instead (same fallback used for dsh), and only fall
    # back to the queue if that fails.
    ws_clear_endpoint
    spawn_guest ssh-term "/usr/local/bin/node /root/.dsh-container/ssh-term.js" ssh-term.log
    sleep 3
    if ! ws_healthy; then
      log "宿主侧 PRoot 未能拉起终端，回退到命令队列"
      guest_exec "nohup /usr/local/bin/node /root/.dsh-container/ssh-term.js >> /root/.dsh-container/ssh-term.log 2>&1 & echo \$! > /root/.dsh-container/ssh-term.pid; echo ssh-term-started" 20 >/dev/null 2>&1 || true
      sleep 2
    fi
  fi
  return 0
}

ensure_guest_assets() {
  if ! sh "$DIR/deploy.sh" --check >/dev/null 2>&1; then
    sh "$DIR/deploy.sh" || return 1
  fi
  return 0
}

do_start() {
  if ! container_healthy; then
    sh "$DIR/container.sh" start || die "容器启动失败"
  fi
  if dsh_port_open && dsh_process_alive; then
    ensure_bridge
    log "dsh 已在运行 (port $DSH_PORT)"
    ensure_ssh
    return 0
  fi
  if dsh_port_open && ! dsh_process_alive; then
    log "端口 $DSH_PORT 被残留进程占用，清理后重启"
    guest_exec "for p in \$(ss -ltnp 2>/dev/null | awk '/:${DSH_PORT} /{print \$NF}' | grep -o 'pid=[0-9]*' | cut -d= -f2); do [ -n \"\$p\" ] && kill -9 \"\$p\" 2>/dev/null; done; rm -f /root/.dsh-container/dsh.pid; echo cleaned" 20 || true
    sleep 2
  fi
  ensure_guest_assets || die "guest 资产部署失败"
  guest_exec "nohup /bin/bash /root/.dsh-container/dsh-run.sh >> /root/.dsh-container/dsh.log 2>&1 & echo \$! > /root/.dsh-container/dsh.pid; sleep 1; echo dsh-started pid=\$(cat /root/.dsh-container/dsh.pid)" 25
  _rc=$?
  [ "$_rc" = 0 ] || { log "DSH 启动命令失败 rc=$_rc"; return $_rc; }
  # The queue normally detaches dsh correctly, but when the backgrounded child is reaped
  # the port stays closed and the start looks successful. Verify, then fall back to a
  # PRoot-parented launch instead of leaving the user with a dead WebUI.
  sleep 3
  if ! dsh_port_open && ! dsh_process_alive; then
    log "命令队列未能拉起 dsh，改用宿主侧 PRoot 直接启动"
    spawn_guest dsh "/bin/bash /root/.dsh-container/dsh-run.sh" dsh.log
  fi
  ensure_bridge >/dev/null 2>&1 || true
  ensure_ssh >/dev/null 2>&1 || true
  log "dsh 启动已发起（冷启动约 1 分钟）"
  return 0
}

do_stop() {
  container_running || { log "容器未运行，dsh 必然已停止"; return 0; }
  guest_exec "for s in dsh module-bridge ssh-term; do pf=/root/.dsh-container/\$s.pid; [ -f \"\$pf\" ] && kill \$(cat \"\$pf\") 2>/dev/null; rm -f \"\$pf\"; done; sleep 1; echo stopped" 20
  sleep 1
  dsh_port_open && { log "警告: 端口 $DSH_PORT 仍被占用（可重启容器）"; return 1; }
  log "dsh 已停止"
  return 0
}

do_status() {
  _run=false; dsh_port_open && _run=true
  _alive=false; dsh_process_alive && _alive=true
  printf '{"dsh":{"running":%s,"port":%s,"process_alive":%s},"bridge":{"running":%s,"port":%s},"ssh":{"ws":%s,"wsPort":%s,"tokenAuth":%s},"container":{"running":%s}}\n' \
    "$_run" "$DSH_PORT" "$_alive" \
    "$(bridge_port_open && echo true || echo false)" "$BRIDGE_PORT" \
    "$(ws_healthy && echo true || echo false)" "$(ws_endpoint_port)" \
    "$([ -f "$WS_ENDPOINT_FILE" ] && echo true || echo false)" \
    "$(container_running && echo true || echo false)"
}

do_log() {
  if [ -f "$GUEST_DIR/dsh.log" ]; then tail -n 40 "$GUEST_DIR/dsh.log"; else echo "(暂无 dsh 日志)"; fi
}

do_selftest() {
  container_running || { echo '{"ok":false,"reason":"container-not-running"}'; return 1; }
  ensure_guest_assets || { echo '{"ok":false,"reason":"deploy-failed"}'; return 1; }
  guest_exec '/usr/local/bin/node /root/.dsh-container/dsh-selftest.js' 40
}

do_all_start() {
  sh "$DIR/container.sh" start || exit 1
  do_start || exit 1
  ensure_ssh
  log "容器 + DSH + 终端均已启动"
}

case "$1" in
  start) do_start ;;
  stop)  do_stop ;;
  status) do_status ;;
  log)   do_log ;;
  selftest) do_selftest ;;
  ssh-start) ensure_ssh 0 && log "SSH 终端已就绪（端口 $(ws_endpoint_port)，token 鉴权）" ;;
  ssh-restart) ensure_ssh 1 && log "SSH 终端已重启（端口 $(ws_endpoint_port)）" ;;
  pnpm)  sh "$DIR/fix-pnpm.sh" ;;
  plugin)
    # 把参数拼成单引号串交给容器内 bash，避免外层引号被吃掉
    shift
    _args=""
    for _a in "$@"; do _args="$_args '$_a'"; done
    in_container "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; cd /root; dsh plugin$_args"
    exit $? ;;
  ssh-stop)
    ws_kill_all
    log "SSH 终端已停止" ;;
  all-start) do_all_start ;;
  *) echo "用法: dsh.sh start|stop|status|log|selftest|ssh-start|ssh-restart|ssh-stop|all-start|pnpm|plugin <dsh plugin 参数>"; exit 2 ;;
esac
