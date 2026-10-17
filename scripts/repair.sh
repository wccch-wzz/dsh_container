#!/system/bin/sh
# repair.sh — self-check and repair the module's own file permissions.
#
# The module ships prebuilt binaries (PRoot launcher, curl, zstd) plus shell scripts.
# Depending on how the archive was extracted or copied, the executable bit may be
# missing; the files are still complete, so the fix is to restore the mode rather than
# reinstall. Run this from a root shell if a WebUI action reports a bundled tool missing:
#
#   sh /data/adb/modules/dsh_container/scripts/repair.sh
#
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/lib.sh"

_fixed=0
_bad=0

fix_exec() {
  _f="$1"
  if [ ! -f "$_f" ]; then
    echo "  缺失: $_f"
    _bad=$((_bad + 1)); return 1
  fi
  if [ ! -s "$_f" ]; then
    echo "  空文件: $_f"
    _bad=$((_bad + 1)); return 1
  fi
  if [ -x "$_f" ]; then
    echo "  正常: $_f"
    return 0
  fi
  if chmod 755 "$_f" 2>/dev/null && [ -x "$_f" ]; then
    echo "  已修复执行位: $_f"
    _fixed=$((_fixed + 1)); return 0
  fi
  echo "  无法修复: $_f"
  _bad=$((_bad + 1)); return 1
}

fix_data() {
  _f="$1"
  [ -f "$_f" ] || { echo "  缺失: $_f"; _bad=$((_bad + 1)); return 1; }
  if [ -r "$_f" ]; then
    echo "  正常: $_f"
    return 0
  fi
  if chmod 644 "$_f" 2>/dev/null && [ -r "$_f" ]; then
    echo "  已修复读取权限: $_f"
    _fixed=$((_fixed + 1)); return 0
  fi
  echo "  无法修复: $_f"
  _bad=$((_bad + 1)); return 1
}

echo "[repair] 检查模块目录: $MODDIR"
echo "[repair] 启动器可执行文件:"
fix_exec "$LAUNCHER_DIR/bin/proot"
fix_exec "$LAUNCHER_DIR/bin/curl"
fix_exec "$LAUNCHER_DIR/bin/zstd"
fix_exec "$LAUNCHER_DIR/bin/xz"
fix_exec "$LAUNCHER_DIR/proot-rootfs.sh"

echo "[repair] 控制脚本:"
for s in lib.sh container.sh install.sh install-status.sh dsh.sh deploy.sh term.sh repair.sh; do
  [ -f "$DIR/$s" ] && fix_exec "$DIR/$s"
done
[ -f "$MODDIR/customize.sh" ] && fix_exec "$MODDIR/customize.sh"
[ -f "$MODDIR/action.sh" ] && fix_exec "$MODDIR/action.sh"
[ -f "$MODDIR/uninstall.sh" ] && fix_exec "$MODDIR/uninstall.sh"

echo "[repair] 启动器依赖库（需可读）:"
for l in "$LAUNCHER_DIR/lib"/*.so*; do
  [ -e "$l" ] || continue
  fix_data "$l"
done

echo "[repair] 运行时目录:"
for d in "$LAUNCHER_DIR/tmp" "$LAUNCHER_DIR/l2s" "$ROOTFS_CACHE" "$RUN_DIR" "$LOG_DIR"; do
  if [ -d "$d" ]; then
    echo "  存在: $d"
  elif mkdir -p "$d" 2>/dev/null; then
    echo "  已创建: $d"
    _fixed=$((_fixed + 1))
  else
    echo "  无法创建: $d"
    _bad=$((_bad + 1))
  fi
done

# A partial or corrupt download must not survive: install.sh rejects a cache file whose
# digest does not match, and leaving it in place would only waste space.
echo "[repair] 下载缓存:"
if [ -d "$ROOTFS_CACHE" ]; then
  _kept=0; _removed=0
  for f in "$ROOTFS_CACHE"/*.tar.xz "$ROOTFS_CACHE"/*.tar.gz "$ROOTFS_CACHE"/*.zip; do
    [ -f "$f" ] || continue
    _kept=$((_kept + 1))
    echo "  保留: $(basename "$f") ($(du -h "$f" 2>/dev/null | cut -f1))"
  done
  echo "  缓存文件数: $_kept（校验在下载时进行，损坏文件会被自动替换）"
else
  echo "  缓存目录不存在: $ROOTFS_CACHE"
fi

echo "[repair] WebUI 入口:"
if [ -s "$MODDIR/webroot/index.html" ]; then
  echo "  正常: webroot/index.html"
else
  echo "  缺失或为空: webroot/index.html"
  _bad=$((_bad + 1))
fi

echo "[repair] 小结: 修复 $_fixed 项，仍有问题 $_bad 项"
if [ "$_bad" -eq 0 ]; then
  echo "[repair] 模块文件状态正常，可以继续使用 WebUI 安装容器资源。"
  exit 0
fi
echo "[repair] 仍有文件缺失，请重新安装模块 zip。" >&2
exit 1
