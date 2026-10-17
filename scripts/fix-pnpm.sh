#!/system/bin/sh
# fix-pnpm.sh — 在容器内安装/修复 pnpm。
#
# `dsh plugin --profile web add <name>` 用 pnpm 做插件依赖安装，rootfs 里只有 Node 自带的
# npm，所以插件命令会直接失败：
#   dsh: pnpm was not found; install pnpm and make it available on PATH.
# 这里按 npm → corepack 的顺序补装，并输出 pnpm 的最终位置供排查。
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/lib.sh"

module_bootstrap || die "模块自检失败"
container_healthy || die "容器未运行，请先启动容器"

log "在容器内安装 pnpm（首次约 1-2 分钟）"

_rc=0
in_container 'set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG=/tmp/pnpm-install.log; : > "$LOG"
say() { echo "[pnpm] $*"; }

say "node=$(node -v 2>/dev/null) npm=$(npm -v 2>/dev/null)"
if command -v pnpm >/dev/null 2>&1; then
  say "pnpm 已就绪: $(pnpm -v) @ $(command -v pnpm)"
  exit 0
fi

ok=0
for reg in https://registry.npmjs.org https://registry.npmmirror.com; do
  say "npm install -g pnpm (registry=$reg)"
  if npm install -g pnpm --registry="$reg" --no-fund --no-audit >>"$LOG" 2>&1; then
    if command -v pnpm >/dev/null 2>&1; then ok=1; break; fi
  fi
  say "失败，日志尾部："
  tail -n 6 "$LOG" 2>/dev/null | sed "s/^/    /"
done

if [ "$ok" = 0 ] && command -v corepack >/dev/null 2>&1; then
  say "改用 corepack 启用 pnpm"
  if corepack enable --install-directory /usr/local/bin pnpm >>"$LOG" 2>&1 \
     && command -v pnpm >/dev/null 2>&1; then
    ok=1
  fi
fi

if [ "$ok" = 1 ]; then
  say "安装成功: pnpm $(pnpm -v 2>/dev/null) @ $(command -v pnpm)"
  exit 0
fi
say "安装失败，完整日志见容器内 $LOG"
tail -n 20 "$LOG" 2>/dev/null | sed "s/^/    /"
exit 1
' || _rc=$?

if [ "$_rc" -eq 0 ]; then
  log "pnpm 可用，可以重试: dsh plugin --profile web add dsh-purge"
else
  log "pnpm 安装失败（rc=$_rc）：通常是容器无网络或 npm registry 不可达"
fi
exit "$_rc"
