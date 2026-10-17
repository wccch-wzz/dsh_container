#!/system/bin/sh
# adb-self.sh — 让这台手机用自己的 adb 连上自己（root 全自动，不需要电脑）。
#
# 为什么不能直接 `adb connect 127.0.0.1:5555`：adbd 默认只走 USB，TCP 监听要靠
# `adb tcpip <port>` 打开，而那条命令本身必须由「已授权」的 adb 客户端发出 —— 手机对自己
# 没有这条路。但我们是 root，可以直接改属性并重启 adbd，绕开这个鸡生蛋。
#
# 注意：重启 adbd 会断掉当前的 adb 会话（包括无线调试那条），所以本脚本由宿主侧的
# hostd 以「后台进程」方式启动：它不属于任何 adb 会话，adbd 重启不会把它杀掉。
#
# 用法: adb-self.sh [port]
# 端口默认 5599 而不是 5555：adb 会扫 5555-5585 当模拟器，5555 会额外冒出一个
# emulator-5554 transport，让 `adb shell` 报 "more than one device"。
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/lib.sh"

PORT="${1:-5599}"
ADB="$STATE_DIR/run/adb"
ADB_HOME="$STATE_DIR/run/adb-home"
LOG="$STATE_DIR/logs/adb-self.log"

say() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

mkdir -p "$STATE_DIR/run" "$ADB_HOME/.android" "$STATE_DIR/logs" 2>/dev/null
say "== 开始（port=$PORT）=="
[ -x "$ADB" ] || { say "缺少 adb 包装脚本，先执行 hostd.sh start"; exit 1; }

# 1) 确保 root 侧有自己的 adbkey（adbd 要求客户端提供密钥）
"$ADB" start-server >> "$LOG" 2>&1
if [ ! -f "$ADB_HOME/.android/adbkey" ]; then
  say "生成 adbkey"
  "$ADB" keygen "$ADB_HOME/.android/adbkey" >> "$LOG" 2>&1
fi

# 2) 打开 adbd 的 TCP 监听
say "setprop service.adb.tcp.port=$PORT"
setprop service.adb.tcp.port "$PORT"
say "重启 adbd"
setprop ctl.restart adbd

# 3) 等 adbd 起来（重启会断当前会话，所以必须等）
_i=0
while [ "$_i" -lt 15 ]; do
  sleep 1
  _i=$((_i + 1))
  netstat -ltn 2>/dev/null | grep -q ":$PORT " && break
done
say "端口状态: $(netstat -ltn 2>/dev/null | grep ":$PORT " || echo 未监听)"

# 4) 连自己（刚重启的 adbd 会先报 offline，要 disconnect 后再连，单靠 connect 会被“already connected”卡住）
_st=""
_i=0
while [ "$_i" -lt 8 ]; do
  _i=$((_i + 1))
  "$ADB" disconnect "127.0.0.1:$PORT" >> "$LOG" 2>&1
  say "adb connect 127.0.0.1:$PORT（第 $_i 次）"
  "$ADB" connect "127.0.0.1:$PORT" >> "$LOG" 2>&1
  _j=0
  while [ "$_j" -lt 3 ]; do
    _j=$((_j + 1))
    sleep 1
    _st=$("$ADB" devices 2>/dev/null | awk -v p="127.0.0.1:$PORT" '$1==p {print $2}')
    [ "$_st" = "device" ] && break
  done
  [ "$_st" = "device" ] && break
done

# 5) 清掉过期的离线 transport：它们会让 adb 报 "more than one device/emulator"
for _d in $("$ADB" devices 2>/dev/null | awk 'NR>1 && $2=="offline"{print $1}'); do
  say "清理离线 transport: $_d"
  "$ADB" disconnect "$_d" >> "$LOG" 2>&1
done
# adb 把 5555-5585 当模拟器端口，若之前用过 5555，这里把多出来的别名也断掉
for _e in $("$ADB" devices 2>/dev/null | awk 'NR>1 && $1 ~ /^emulator-/ {print $1}'); do
  say "清理模拟器别名: $_e"
  "$ADB" disconnect "$_e" >> "$LOG" 2>&1
done

say "adb devices:"
"$ADB" devices -l >> "$LOG" 2>&1

# 6) 判断结果：unauthorized 说明手机上会弹「允许 USB 调试」，点一次即可
case "$_st" in
  device) say "成功：adb shell 可用（shell 用户）" ;;
  unauthorized) say "等待授权：请在手机上点「允许 USB 调试」（勾选始终允许）" ;;
  *) say "未连上（状态=${_st:-无}），看上面的 adb 输出" ;;
esac
say "== 结束 =="
