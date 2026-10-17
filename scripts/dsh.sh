#!/system/bin/sh
# dsh.sh — DSH lifecycle and self-test for the standalone container.
# Usage: dsh.sh start|stop|status|log|selftest|ssh-start|ssh-restart|ssh-stop|all-start|hostd-start|hostd-stop|hostd-status|host|host-tool|pnpm|plugin
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

# dsh 进程存在但端口还没绑上（冷启动早期）：此时绝不能启第二份，否则第二份 EADDRINUSE。
dsh_node_present() {
  ps -A -o pid,args 2>/dev/null | grep -F 'dsh/lib/bin.js' | grep -v grep >/dev/null 2>&1
}

# 内置工具版：assets/guest/host-tool.enabled + assets/guest/dsh-host-tool/
# 精简版：两者都不存在
host_tool_enabled() {
  [ -f "$MODDIR/assets/guest/host-tool.enabled" ] && [ -d "$MODDIR/assets/guest/dsh-host-tool" ]
}

host_tool_mounted() {
  grep -q 'dsh-host-tool' "$ROOTFS/root/.dsh/profiles/web/package.json" 2>/dev/null
}

# 把「内置」真正变成自动：内置版缺挂载就补上，精简版有残留就卸下。
# 必须赶在 dsh 启动前跑，否则本进程看到的是旧 profile。
ensure_host_tool() {
  container_running || return 0
  if host_tool_enabled; then
    host_tool_mounted && return 0
    [ -s "$ROOTFS/usr/local/lib/dsh-host-tool/lib/index.js" ] || sh "$DIR/deploy.sh" >/dev/null 2>&1
    log "内置宿主工具：挂载 dsh-host-tool 到 web profile"
    in_container "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; cd /root; dsh plugin --profile web add /usr/local/lib/dsh-host-tool" >/dev/null 2>&1 \
      || log "警告: dsh-host-tool 挂载失败（可稍后跑 dsh.sh host-tool install）"
  else
    host_tool_mounted || return 0
    log "本版本不含宿主工具：从 web profile 卸下 dsh-host-tool"
    in_container "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; cd /root; dsh plugin --profile web remove dsh-host-tool" >/dev/null 2>&1 \
      || log "警告: 卸下 dsh-host-tool 失败"
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
  ensure_host_tool
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
  # 自动挂载要跑 pnpm，可能占用几十秒；它失败也不能拖死启动，更不应让下面的超时
  # 被误读成「dsh 启动失败」。
  ensure_host_tool || true
  # 60s：冷启动时这条命令要等容器里 bash 真正 fork 完，25s 会误报超时。
  guest_exec "nohup /bin/bash /root/.dsh-container/dsh-run.sh >> /root/.dsh-container/dsh.log 2>&1 & echo \$! > /root/.dsh-container/dsh.pid; sleep 1; echo dsh-started pid=\$(cat /root/.dsh-container/dsh.pid)" 60
  _rc=$?
  # 队列超时只代表「没等到回包」，dsh 可能已经起来了：不返回，继续走验证与兜底。
  [ "$_rc" = 0 ] || log "DSH 启动命令未按时回包 rc=$_rc，继续验证"
  # The queue normally detaches dsh correctly, but when the backgrounded child is reaped
  # the port stays closed and the start looks successful. Verify, then fall back to a
  # PRoot-parented launch instead of leaving the user with a dead WebUI.
  # Cold start binds the port late, so poll before deciding: a 3s check used to fire the
  # fallback against a perfectly healthy instance, and the duplicate then died with
  # EADDRINUSE — which looked exactly like a broken plugin in the startup log.
  # 冷启动可能远超 16s（容器刚重启、页面缓存冷），窗口太窄就会在 dsh 正常启动中
  # 误开兜底，结果两份抢 23099。这里给到 60s，只在真的一点动静都没有时才兜底。
  _i=0
  while [ "$_i" -lt 12 ]; do
    _i=$((_i + 1))
    dsh_port_open && break
    dsh_node_present && break
    sleep 5
  done
  if ! dsh_port_open && ! dsh_process_alive && ! dsh_node_present; then
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
  sh "$DIR/hostd.sh" start >/dev/null 2>&1 || true
  log "容器 + DSH + 终端 + 宿主执行器均已启动"
}

case "$1" in
  start)
    # --detach：立即返回，把真正的启动丢到后台。KernelSU 的 WebUI 执行通道是单通道
    # 同步的，如果 start 在里面跑几十秒，页面所有查询都会排队（表现为一直“查询中”）。
    if [ "${2:-}" = "--detach" ]; then
      _dt="$LOG_DIR/dsh-start.log"
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
      nohup sh -c "sh '$DIR/dsh.sh' start >>'$_dt' 2>&1; rm -rf '$_lk'" >/dev/null 2>&1 &
      echo "DSH 启动已在后台进行，日志: $_dt"
      exit 0
    fi
    do_start ;;
  stop)  do_stop ;;
  status) do_status ;;
  log)   do_log ;;
  selftest) do_selftest ;;
  ssh-start) ensure_ssh 0 && log "SSH 终端已就绪（端口 $(ws_endpoint_port)，token 鉴权）" ;;
  ssh-restart) ensure_ssh 1 && log "SSH 终端已重启（端口 $(ws_endpoint_port)）" ;;
  hostd-start) sh "$DIR/hostd.sh" start ;;
  hostd-stop) sh "$DIR/hostd.sh" stop ;;
  hostd-status) sh "$DIR/hostd.sh" status ;;
  host) shift; sh "$DIR/hostd.sh" run "$*" ;;
  host-tool)
    # 把宿主能力包成 dsh 工具（host_shell / host_adb）。插件文件由 deploy.sh 落到
    # rootfs/usr/local/lib/dsh-host-tool，这里只决定是否挂进 web profile。
    case "${2:-status}" in
      install)
        host_tool_enabled || { log "本版本（精简版）不含 dsh-host-tool，请换内置工具版 zip"; exit 2; }
        ensure_guest_assets || die "guest 资产部署失败"
        sh "$DIR/deploy.sh" >/dev/null 2>&1 || true
        in_container "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; cd /root; dsh plugin --profile web add /usr/local/lib/dsh-host-tool"
        _rc=$?
        [ "$_rc" = 0 ] && log "dsh-host-tool 已安装，重启 dsh 后模型即可看到 host_shell / host_adb"
        exit $_rc ;;
      remove)
        in_container "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; cd /root; dsh plugin --profile web remove dsh-host-tool"
        exit $? ;;
      status)
        if host_tool_enabled; then echo "本版本: 内置工具版"; else echo "本版本: 精简版（不含宿主工具）"; fi
        if [ -d "$ROOTFS/usr/local/lib/dsh-host-tool" ]; then echo "插件文件: 已部署"; else echo "插件文件: 无"; fi
        if host_tool_mounted; then echo "profile 挂载: 是"; else echo "profile 挂载: 否"; fi
        exit 0 ;;
      *) echo "用法: dsh.sh host-tool install|remove|status"; exit 2 ;;
    esac ;;
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
  *) echo "用法: dsh.sh start|stop|status|log|selftest|ssh-start|ssh-restart|ssh-stop|all-start|hostd-start|hostd-stop|hostd-status|host '<cmd>'|host-tool install|remove|status|pnpm|plugin <dsh plugin 参数>"; exit 2 ;;
esac
