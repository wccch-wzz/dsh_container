#!/system/bin/sh
# service.sh — KernelSU late_start hook.
#
# Only one thing has to survive a reboot: the host-side root executor (hostd). The container
# and DSH are started on demand from the WebUI, but hostd is the channel the harness uses to
# reach host commands (adb/su/pm/am), so leaving it down until someone opens the WebUI means
# every boot starts with `dsh-host` returning "执行器未运行".
MODDIR="${MODDIR:-${0%/*}}"
[ -f "$MODDIR/scripts/hostd.sh" ] || exit 0

# Do not fight the WebUI: if hostd is already up, start is a no-op.
/system/bin/sh "$MODDIR/scripts/hostd.sh" start >> /data/adb/dsh_container/logs/service.log 2>&1
exit 0
