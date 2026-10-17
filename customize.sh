#!/system/bin/sh
# customize.sh — runs at module install time (sourced by the manager).
#
# The corrective work lives in scripts/lib.sh so it also applies to every later entry
# point (WebUI actions, repair.sh, container.sh ...). Sourcing lib.sh here performs:
#   * module root resolution (installer sources this file, so $0 is not trustworthy)
#   * executable bit restoration for the shipped binaries and scripts
#   * webroot/index.html rendering when a build shipped only the template
source_lib() {
  # The module root must be proven to contain module.prop; see lib.sh for the rules.
  for _c in "$MODPATH" "$MODDIR" "$PWD" "$PWD/.." "${0%/*}"; do
    [ -n "$_c" ] && [ -f "$_c/module.prop" ] && { . "$_c/scripts/lib.sh" && return 0; }
  done
  return 1
}

if source_lib; then
  if page_ok "$MODDIR/webroot/index.html"; then
    ui_print "- 模块目录: $MODDIR"
    ui_print "- WebUI 入口就绪: webroot/index.html"
  else
    ui_print "- 模块目录: $MODDIR"
    ui_print "! 警告: webroot/index.html 不可用，请检查 webroot/index.html.in"
  fi
  # Report the launcher state so install logs show whether the bit needed fixing.
  for _b in proot curl zstd xz; do
    if [ -x "$LAUNCHER_DIR/bin/$_b" ]; then
      ui_print "- 启动器就绪: bin/$_b"
    else
      ui_print "! 警告: bin/$_b 不可用"
    fi
  done
else
  ui_print "! 未能定位模块目录，WebUI 可能无法打开"
  ui_print "! 请在 WebUI 中点击“修复文件”，或重新安装模块"
fi

ui_print "- DSH Container Standalone 已安装（不依赖 Termux）"
ui_print "- 首次使用请打开模块 WebUI，点击“安装资源”（下载约 78MB rootfs + 33MB Node）"
