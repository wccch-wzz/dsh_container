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

if [ "${1:-}" = "--check" ]; then
  for f in dsh-run.sh agent.sh module-bridge.js ssh-term.js sshd-run.sh; do
    [ -s "$GUEST_DIR/$f" ] || { log "missing guest asset: $f"; exit 1; }
  done
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
        _pf="/root/.dsh-container/$_svc.pid"
        [ -f "$_pf" ] || continue
        _dp="$(cat "$_pf" 2>/dev/null)"
        [ -n "$_dp" ] || continue
        if ! kill -0 "$_dp" 2>/dev/null; then
          echo "WATCHDOG $(date '+%T') $_svc(pid=$_dp) died -> restart" >> /root/.dsh-container/keepalive.log
          case "$_svc" in
            dsh) nohup /bin/bash /root/.dsh-container/dsh-run.sh >> /root/.dsh-container/dsh.log 2>&1 & echo $! > "$_pf" ;;
            module-bridge) nohup /usr/local/bin/node /root/.dsh-container/module-bridge.js >> /root/.dsh-container/module-bridge.log 2>&1 & echo $! > "$_pf" ;;
            ssh-term) nohup /usr/local/bin/node /root/.dsh-container/ssh-term.js >> /root/.dsh-container/ssh-term.log 2>&1 & echo $! > "$_pf" ;;
            sshd) nohup /bin/bash /root/.dsh-container/sshd-run.sh >> /root/.dsh-container/sshd.log 2>&1 & echo $! > "$_pf" ;;
          esac
        fi
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
log "deploy 完成: dsh + agent + supervisor + bridge + term (dsh=$DSH_PORT bridge=$BRIDGE_PORT ssh=$SSH_PORT ws=$WS_PORT)"
