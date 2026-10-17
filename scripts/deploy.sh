#!/system/bin/sh
# deploy.sh — write guest assets into the rootfs (dsh launcher, agent, supervisor,
# auth bridge, terminal bridge, sshd launcher). Runs from the host; touches rootfs
# files directly, no PRoot invocation.
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/lib.sh"

ASSETS="$MODDIR/assets/guest"
[ -d "$ROOTFS" ] || die "rootfs missing: $ROOTFS"
[ -d "$ASSETS" ] || die "assets missing: $ASSETS"
mkdir -p "$GUEST_DIR" || die "cannot create $GUEST_DIR"

# 两种发行版靠这个 marker 区分：
#   内置工具版：assets/guest/host-tool.enabled + assets/guest/dsh-host-tool/ → 自动挂进 web profile
#   精简版：两者都不存在 → 容器里不会有 dsh-host-tool，也不会动用户的 profile
host_tool_enabled() {
  [ -f "$ASSETS/host-tool.enabled" ] && [ -d "$ASSETS/dsh-host-tool" ]
}

if [ "${1:-}" = "--check" ]; then
  for f in dsh-run.sh agent.sh module-bridge.js ssh-term.js sshd-run.sh; do
    [ -s "$GUEST_DIR/$f" ] || { log "missing guest asset: $f"; exit 1; }
  done
  [ -x "$ROOTFS/usr/local/bin/dsh-host" ] || { log "missing guest CLI: dsh-host"; exit 1; }
  if host_tool_enabled; then
    [ -s "$ROOTFS/usr/local/lib/dsh-host-tool/lib/index.js" ] || { log "missing dsh plugin: dsh-host-tool"; exit 1; }
  fi
  [ "$(cat "$GUEST_DIR/.deployed-version" 2>/dev/null)" = "$(module_version)" ] || { log "guest assets are stale"; exit 1; }
  log "guest 资产已部署且为当前版本"
  exit 0
fi

render() { # render <template> <output> [extra sed args...]
  _tpl="$1"; _out="$2"; shift 2
  sed -e "s|@DSH_PORT@|$DSH_PORT|g" \
      -e "s|@BRIDGE_PORT@|$BRIDGE_PORT|g" \
      -e "s|@SSH_PORT@|$SSH_PORT|g" \
      -e "s|@WS_PORT@|$WS_PORT|g" \
      -e "s|@WORKSPACE_ROOT@|$WORKSPACE_ROOT|g" \
      -e "s|@WORKSPACE_TMP@|$WORKSPACE_TMP|g" \
      -e "s|@NODE@|/usr/local/bin/node|g" \
      -e "s|@DSH_ENTRY@|/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js|g" \
      "$@" "$_tpl" > "$_out"
  chmod 755 "$_out"
  if grep -qE '@[A-Z_]+@' "$_out"; then die "模板占位符未替换: $_out"; fi
}

render "$ASSETS/dsh-run.sh.in" "$GUEST_DIR/dsh-run.sh"
render "$ASSETS/sshd-run.sh.in" "$GUEST_DIR/sshd-run.sh"
render "$ASSETS/module-bridge.js.in" "$GUEST_DIR/module-bridge.js"
render "$ASSETS/ssh-term.js.in" "$GUEST_DIR/ssh-term.js"
render "$ASSETS/dsh-selftest.js.in" "$GUEST_DIR/dsh-selftest.js"
# 容器里的“宿主命令”入口：走 hostq 队列交给宿主侧 scripts/hostd.sh 以 root 执行
mkdir -p "$ROOTFS/usr/local/bin" 2>/dev/null
render "$ASSETS/dsh-host.sh.in" "$ROOTFS/usr/local/bin/dsh-host"

# dsh 插件：把宿主 root / adb 包成模型可直接调用的 tools（host_shell / host_adb）。
# 只有内置工具版才有这组文件；精简版会在这里把旧版本留下的副本清掉。
if host_tool_enabled; then
  mkdir -p "$ROOTFS/usr/local/lib" 2>/dev/null
  rm -rf "$ROOTFS/usr/local/lib/dsh-host-tool"
  cp -R "$ASSETS/dsh-host-tool" "$ROOTFS/usr/local/lib/dsh-host-tool" 2>/dev/null \
    || die "copy dsh-host-tool failed"
  chmod 755 "$ROOTFS/usr/local/lib/dsh-host-tool" 2>/dev/null
  find "$ROOTFS/usr/local/lib/dsh-host-tool" -type f -exec chmod 644 {} + 2>/dev/null
  chmod 755 "$ROOTFS/usr/local/lib/dsh-host-tool/lib" 2>/dev/null
else
  rm -rf "$ROOTFS/usr/local/lib/dsh-host-tool" 2>/dev/null
fi

cat > "$GUEST_DIR/agent.sh" <<'AEOF'
#!/bin/bash
# agent.sh — command queue executor, run by the container supervisor.
Q=/root/.dsh-container/queue
CWD_FILE=/root/.dsh-container/cwd
mkdir -p "$Q"
[ -f "$CWD_FILE" ] || echo /root > "$CWD_FILE"
echo "$$" > /root/.dsh-container/agent.pid
echo "AGENT READY $(date '+%F %T')" > "$Q/out.txt"
echo 0 > "$Q/exit.txt"
_last_ka=0
while true; do
  if [ -f "$Q/cmd.txt" ]; then
    if mv -f "$Q/cmd.txt" "$Q/run.txt" 2>/dev/null; then
      CMD="$(cat "$Q/run.txt")"
      CWD="$(cat "$CWD_FILE" 2>/dev/null)"
      [ -d "$CWD" ] || CWD=/root
      {
        echo "RUN $(date '+%T')"
        ( cd "$CWD" 2>/dev/null || cd /root; eval "$CMD"; pwd > "$CWD_FILE" 2>/dev/null )
        echo "DONE rc=$? $(date '+%T')"
      } > "$Q/out.txt" 2>&1
      rm -f "$Q/run.txt"
      echo 0 > "$Q/exit.txt"
    fi
  fi
  _now=$(date +%s)
  if [ $((_now - _last_ka)) -ge 10 ]; then
    _last_ka=$_now
    if [ ! -f /root/.dsh-container/no-keepalive ]; then
      for _svc in dsh module-bridge ssh-term sshd; do
        case "$_svc" in
          dsh) _pat="dsh/lib/bin.js" ;;
          module-bridge) _pat="module-bridge.js" ;;
          ssh-term) _pat="ssh-term.js" ;;
          sshd) _pat="sshd-run.sh" ;;
        esac
        _pf="/root/.dsh-container/$_svc.pid"
        # 活没活着看 /proc，不看 pid 文件：dsh 因端口被占而退出时，
        # 旧的 pid 文件会诱使 watchdog 每 10s 重启一次，把进程刷成死循环，
        # 而每次新实例都撞 EADDRINUSE，日志里看起来像插件坏了。
        _live=""
        for _p in /proc/[0-9]*; do
          [ -r "$_p/cmdline" ] || continue
          if tr '\0' ' ' < "$_p/cmdline" 2>/dev/null | grep -qF "$_pat"; then
            _live="${_p#/proc/}"
            break
          fi
        done
        if [ -n "$_live" ]; then
          [ "$(cat "$_pf" 2>/dev/null)" = "$_live" ] || echo "$_live" > "$_pf"
          continue
        fi
        [ -f "$_pf" ] || continue
        echo "WATCHDOG $(date '+%T') $_svc 不在运行 -> restart" >> /root/.dsh-container/keepalive.log
        case "$_svc" in
          dsh) nohup /bin/bash /root/.dsh-container/dsh-run.sh >> /root/.dsh-container/dsh.log 2>&1 & echo $! > "$_pf" ;;
          module-bridge) nohup /usr/local/bin/node /root/.dsh-container/module-bridge.js >> /root/.dsh-container/module-bridge.log 2>&1 & echo $! > "$_pf" ;;
          ssh-term) nohup /usr/local/bin/node /root/.dsh-container/ssh-term.js >> /root/.dsh-container/ssh-term.log 2>&1 & echo $! > "$_pf" ;;
          sshd) nohup /bin/bash /root/.dsh-container/sshd-run.sh >> /root/.dsh-container/sshd.log 2>&1 & echo $! > "$_pf" ;;
        esac
      done
    fi
  fi
  sleep 0.5
done
AEOF
chmod 755 "$GUEST_DIR/agent.sh"

cat > "$GUEST_DIR/supervisor.sh" <<'SEOF'
#!/bin/bash
# supervisor.sh — keeps the agent alive; the agent supervises the guest services.
while true; do
  /bin/bash /root/.dsh-container/agent.sh >> /root/.dsh-container/agent.log 2>&1
  echo "AGENT-RESTART $(date '+%T')" >> /root/.dsh-container/agent.log
  sleep 1
done
SEOF
chmod 755 "$GUEST_DIR/supervisor.sh"

printf '%s\n' "$(module_version)" > "$GUEST_DIR/.deployed-version"
log "deploy 完成: dsh + agent + supervisor + bridge + term + dsh-host$(host_tool_enabled && echo ' + dsh-host-tool') (dsh=$DSH_PORT bridge=$BRIDGE_PORT ssh=$SSH_PORT ws=$WS_PORT)"
