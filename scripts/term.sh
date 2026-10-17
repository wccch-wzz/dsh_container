#!/system/bin/sh
# term.sh — run a command inside the container and return its output.
# Uses the container's own SSH client over loopback; no host tooling required.
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/lib.sh"

ssh_exec() {
  _cmd="$1"
  guest_exec "'/usr/bin/ssh' -p $SSH_PORT -i /root/.ssh/id_ed25519 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR \
    root@127.0.0.1 'sh -lc '\''$_cmd'\'''" 45
}

case "$1" in
  send)     shift; [ -n "$1" ] || die "用法: term.sh send <cmd>"; ssh_exec "$*" ;;
  sendfile) shift; [ -n "$1" ] || die "用法: term.sh sendfile <base64>"; _c=$(printf '%s' "$1" | base64 -d) || die "base64 解码失败"; ssh_exec "$_c" ;;
  read)     echo "SSH 模式：输出随命令返回，无需 read" ;;
  clear)    echo "SSH 模式：每个连接独立，无需清屏" ;;
  key)      echo "SSH 模式：不支持按键注入"; exit 0 ;;
  windows)  echo "session=ssh" ;;
  *) echo "用法: term.sh send <cmd> | sendfile <b64> | read | clear"; exit 2 ;;
esac
