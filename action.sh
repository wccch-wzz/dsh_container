#!/system/bin/sh
# action.sh — manager "action" button: compact status summary.
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/scripts/lib.sh"
sh "$DIR/scripts/install-status.sh"
echo "----"
sh "$DIR/scripts/container.sh" status
echo "----"
dsh_port_open && echo "DSH : http://127.0.0.1:$BRIDGE_PORT (授权桥)" || echo "DSH : 已停止"
echo "完整控制请打开模块 WebUI。"
