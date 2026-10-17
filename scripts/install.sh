#!/system/bin/sh
# install.sh — first-run preparation for the standalone container.
# Downloads, verifies and unpacks the Ubuntu rootfs, then installs the guest runtime
# (Node.js, DSH, sshd, tmux) into it. No Termux, no proot-distro, no package manager here.
# Usage: install.sh [--force]
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/lib.sh"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

LAUNCHER_LIB="$LAUNCHER_DIR/lib:/system/lib64"

# The launcher, its libraries and the control scripts are validated and repaired by
# lib.sh on every invocation; here we only need to fail early with a clear message if a
# tool is genuinely absent after that repair.
need_tools() {
  ensure_exec "$LAUNCHER_DIR/bin/curl" || die "自带 curl 不可用: $LAUNCHER_DIR/bin/curl"
  ensure_exec "$LAUNCHER_DIR/bin/zstd" || die "自带 zstd 不可用: $LAUNCHER_DIR/bin/zstd"
  ensure_exec "$PROOT_BIN" || die "自带 proot 不可用: $PROOT_BIN"
  mkdir -p "$RUN_DIR/proot-tmp" "$RUN_DIR/proot-l2s" "$ROOTFS_CACHE" 2>/dev/null
  [ -d "$LAUNCHER_DIR/tmp" ] || die "无法创建 $LAUNCHER_DIR/tmp"
  [ -d "$LAUNCHER_DIR/l2s" ] || die "无法创建 $LAUNCHER_DIR/l2s"
  [ -d "$ROOTFS_CACHE" ] || die "无法创建 $ROOTFS_CACHE"
}

# install.sh 独有：这些校验不在 lib.sh 的通用自愈范围内

# fetch <url> <dest-file> <expected-sha256> <progress-base> <progress-span> <label>
#
# Reports byte-level download progress to the WebUI status file while curl runs. The
# file itself remains resumable; the digest is checked after the transfer and a bad file
# is deleted so it can never become a permanent cache hit.
# fetch <url> <destination> <sha256> <base-percent> <span-percent> <label>
# curl --progress-bar is sampled asynchronously into a status file, so slow transfers
# keep updating the WebUI instead of returning an empty 120-second call.
# fetch <url> <destination> <sha256> <base-percent> <span-percent> <label> <total-bytes>
# Partial data is kept in a .part file and resumed on retry. A finished file is only
# atomically promoted to the cache after its expected SHA-256 matches.
fetch() {
  _url="$1"; _dest="$2"; _want="${3:-}"; _base="${4:-5}"; _span="${5:-20}"; _label="${6:-资源}"; _full="${7:-0}"
  _part="${_dest}.part"
  _curl_log="${PROGRESS_FILE}.curl-errors"
  mkdir -p "$ROOTFS_CACHE" "$RUN_DIR/proot-tmp" "$RUN_DIR/proot-l2s" 2>/dev/null

  if [ -s "$_dest" ]; then
    if [ -z "$_want" ] || digest_matches "$_dest" "$_want"; then
      progress "$((_base + _span))" "$_label 已在本地且校验通过"
      return 0
    fi
    log "缓存文件校验不通过，删除并重新下载: $(basename "$_dest")"
    rm -f "$_dest"
  fi

  if [ -s "$_part" ]; then
    if [ -n "$_want" ] && [ "$(sha256_of "$_part")" = "$_want" ]; then
      mv -f "$_part" "$_dest" || die "无法激活已下载文件: $_dest"
      progress "$((_base + _span))" "$_label 已下载且校验通过"
      return 0
    fi
    log "发现未完成下载，将从已有字节继续: $(basename "$_part")"
  else
    : > "$_part"
  fi

  _curl_rc="${PROGRESS_FILE}.curl-rc"
  rm -f "$_curl_rc" "${PROGRESS_FILE}.curl-status" "${PROGRESS_FILE}.curl-errors"
  progress "$_base" "开始下载 $_label（0%，请保持安装页面打开）"
  (
    export PATH="$LAUNCHER_DIR/bin:$BIN_DIR"
    export LD_LIBRARY_PATH="$LAUNCHER_LIB"
    "$LAUNCHER_DIR/bin/curl" -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
      --speed-time 60 --speed-limit 8192 -C - --silent --show-error \
      -o "$_part" "$_url"
    _curl_result=$?
    printf '%s\n' "$_curl_result" > "$_curl_rc"
    exit 0
  ) >"${PROGRESS_FILE}.curl-status" 2>"${PROGRESS_FILE}.curl-errors" &
  _curl_pid=$!

  _last_bytes=-1
  _poll=0
  # Do not use kill -0 as a completion test: exited child processes can remain as zombies
  # until wait(), making kill -0 succeed forever on some Android shells. The worker writes
  # a small rc marker only after curl has completely exited.
  while [ ! -s "$_curl_rc" ]; do
    _bytes="$(wc -c < "$_part" 2>/dev/null | tr -d ' ')"
    case "$_bytes" in ''|*[!0-9]*) _bytes=0;; esac
    if [ "$_bytes" -ne "$_last_bytes" ] || [ "$_poll" -eq 0 ]; then
      _last_bytes="$_bytes"
      if [ "$_full" -gt 0 ]; then
        _pct=$((_base + _bytes * _span / _full))
        [ "$_pct" -le $((_base + _span)) ] || _pct=$((_base + _span))
        _mb="$(awk -v n="$_bytes" 'BEGIN {printf "%.1f", n/1048576}')"
        _total_mb="$(awk -v n="$_full" 'BEGIN {printf "%.1f", n/1048576}')"
        progress "$_pct" "正在下载 $_label（$_mb / $_total_mb MB）"
      else
        progress "$_base" "正在下载 $_label（已接收 $_bytes 字节）"
      fi
    fi
    _poll=$((_poll + 1))
    [ "$_poll" -lt 7200 ] || { kill "$_curl_pid" 2>/dev/null; die "下载等待超时（2小时）: $_url"; }
    sleep 1
  done
  wait "$_curl_pid" 2>/dev/null
  _rc="$(cat "$_curl_rc" 2>/dev/null)"
  rm -f "$_curl_rc" "${PROGRESS_FILE}.curl-status" "${PROGRESS_FILE}.curl-errors"
  if [ "$_rc" != "0" ]; then
    tail -8 "$_curl_log" >&2
    die "下载失败: $_url（未完成数据保留，可重试续传）"
  fi
  [ -s "$_part" ] || die "下载结果为空: $_url"

  if [ -n "$_want" ] && ! digest_matches "$_part" "$_want"; then
    _got="$(sha256_of "$_part")"
    rm -f "$_part"
    die "下载校验失败: $(basename "$_dest") 期望 $_want 实际 ${_got:-未知}（已删除损坏文件，请重试）"
  fi
  mv -f "$_part" "$_dest" || die "无法激活下载文件: $_dest"
  progress "$((_base + _span))" "$_label 下载并校验完成"
}

digest_matches() {
  _f="$1"; _want="$2"
  _got="$(sha256_of "$_f")"
  [ -n "$_got" ] || return 2
  [ "$_got" = "$_want" ]
}

# Android's toybox provides sha256sum, but it is not guaranteed to be readable in every
# context. When it is unavailable and the rootfs is already unpacked, hash inside the
# guest, where coreutils is always present.
sha256_of() {
  _h="$(/system/bin/sha256sum "$1" 2>/dev/null | awk '{print $1}')"
  if [ -z "$_h" ] && [ -d "$ROOTFS" ]; then
    _in="$(in_container "sha256sum '$1' 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '\r')"
    _h="$(printf '%s' "$_in" | awk '{print $NF}')"
  fi
  printf '%s' "$_h"
}

_url_name() { basename "$1"; }

verify_sha256() {
  _file="$1"; _want="$2"
  [ -n "$_want" ] || { log "未提供期望 SHA-256，跳过校验: $(basename "$_file")"; return 0; }
  _got="$(sha256_of "$_file")"
  [ -n "$_got" ] || die "无法计算 SHA-256（缺少 /system/bin/sha256sum）: $_file"
  [ "$_got" = "$_want" ] || die "SHA-256 不匹配: $_file 期望 $_want 实际 $_got"
  log "SHA-256 校验通过: $(basename "$_file")"
}

unpack_rootfs() {
  # Dedicated names: helpers called from here must not overwrite the caller's variables.
  _unp_archive="$1"; _unp_dest="$2"
  _unp_tmp="$_unp_dest.tmp"
  log "解包 rootfs（约 1.3GB，需要几分钟，请勿关闭页面）"
  rm -rf "$_unp_tmp"
  mkdir -p "$_unp_tmp" || die "无法创建 $_unp_dest.tmp"

  # Extraction runs through run_extract_archive() so the launcher's own xz/zstd are on
  # PATH: toybox tar shells out for compression and fails with
  # "exec xz: No such file or directory" under the minimal system PATH.
  # Missing /dev nodes and a few hardlinks are expected without privileges, so the exit
  # status is not the gate; the layout checks below are.
  _log="$LOG_DIR/rootfs-unpack.log"
  # Capture failure non-fatally so we can distinguish tolerated device-node/link warnings
  # from a real decompressor failure while still letting set -e remain enabled.
  if run_extract_archive "$_unp_archive" "$_unp_tmp" 2>"$_log"; then
    _rc=0
  else
    _rc=$?
  fi
  if [ "$_rc" -ne 0 ]; then
    log "解包返回码 $_rc（非特权环境下属常见），继续校验布局"
  fi

  [ -f "$_unp_tmp/etc/os-release" ] || {
    log "解包日志尾部:"
    tail -20 "$_log" 2>/dev/null | sed 's/^/  /' >&2
    # Surface the single most common cause explicitly instead of a bare failure.
    if grep -q "exec xz\|exec zstd\|No such file or directory" "$_log" 2>/dev/null; then
      die "解包失败：缺少 xz/zstd（应随模块自带，请点“修复文件”或重装模块）"
    fi
    die "rootfs 解包结果缺少 /etc/os-release"
  }
  for f in bin/bash usr/bin/bash lib/ld-linux-aarch64.so.1 usr/bin/dpkg; do
    [ -e "$_unp_tmp/$f" ] || die "rootfs 缺少关键文件: /$f"
  done

  # dpkg needs perl for several post-install scripts; recreate the hardlink entry the
  # archive declares, since link(2) is unavailable for some paths here.
  if [ -x "$_unp_tmp/usr/bin/perlbug" ] && [ ! -s "$_unp_tmp/usr/bin/perlthanks" ]; then
    cp -f "$_unp_tmp/usr/bin/perlbug" "$_unp_tmp/usr/bin/perlthanks" 2>/dev/null || true
    chmod 755 "$_unp_tmp/usr/bin/perlthanks" 2>/dev/null || true
  fi

  rm -rf "$_unp_dest"
  mv "$_unp_tmp" "$_unp_dest" || die "rootfs 激活失败"
  _rootfs_bytes="$(du -sk "$_unp_dest" 2>/dev/null | awk '{print $1 * 1024}')"
  case "$_rootfs_bytes" in ''|*[!0-9]*) _rootfs_bytes=0;; esac
  printf '%s\n' "$_rootfs_bytes" > "$STATE_DIR/.rootfs-bytes" 2>/dev/null
  mkdir -p "$_unp_dest/proc" "$_unp_dest/sys" "$_unp_dest/dev" "$_unp_dest/tmp" "$_unp_dest/run"
  chmod 1777 "$_unp_dest/tmp" 2>/dev/null || true
  # The minimal cloud image points resolv.conf at systemd-resolved, which is absent here.
  mkdir -p "$_unp_dest/run/systemd/resolve"
  printf 'nameserver %s\n' "${DNS_SERVER:-8.8.8.8}" > "$_unp_dest/run/systemd/resolve/stub-resolv.conf"
  if [ ! -e "$_unp_dest/etc/resolv.conf" ]; then
    ln -sf ../run/systemd/resolve/stub-resolv.conf "$_unp_dest/etc/resolv.conf" 2>/dev/null || \
      cp -f "$_unp_dest/run/systemd/resolve/stub-resolv.conf" "$_unp_dest/etc/resolv.conf"
  fi
  log "rootfs 就绪: $(grep -m1 '^PRETTY_NAME=' "$_unp_dest/etc/os-release" 2>/dev/null | cut -d= -f2- | tr -d '\"')"
}

# Long stages run under PRoot for minutes. A background heartbeat keeps the WebUI's
# progress record moving; the stage itself runs in the foreground here because install.sh
# is already detached from the manager, so no nested subshell or exit-marker handshake is
# needed (that handshake raced with the rootfs layout checks in Android's sh).
run_container_stage() {
  _label="$1"; _pct="$2"; _cmd="$3"
  _stop="$PROGRESS_FILE.heartbeat-stop"
  rm -f "$_stop"
  progress "$_pct" "开始：$_label"
  progress_heartbeat "$_pct" "$_label" "$_stop" "$$" & _hb=$!
  if in_container "$_cmd" >> "$LOG_DIR/install.log" 2>&1; then
    _rc=0
  else
    _rc=$?
  fi
  : > "$_stop"; kill "$_hb" 2>/dev/null; wait "$_hb" 2>/dev/null
  rm -f "$_stop"
  [ "$_rc" -eq 0 ] || die "$_label 失败，详情见 $LOG_DIR/install.log"
}

run_unpack_stage() {
  _archive="$1"; _dest="$2"
  # No background heartbeat here. Extraction of this rootfs completes in seconds, and a
  # concurrent `&` job in Android's sh interfered with the extraction subshell: tar was
  # reported as failing (rc!=0) while it actually finished writing the tree, which made
  # the layout check run against a partial directory. Run it synchronously instead.
  progress 30 "解包 Ubuntu rootfs（约 1.3GB）"
  unpack_rootfs "$_archive" "$_dest"
  _rc=$?
  [ "$_rc" -eq 0 ] || die "rootfs 解包失败；详情见 $LOG_DIR/rootfs-unpack.log"
  progress 55 "rootfs 解包完成"
}

install_guest_runtime() {
  _apt_cmd="$(cat <<'APT_CMD'
set -eu
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
if [ ! -f /etc/apt/sources.list.d/ubuntu.sources ] && [ ! -f /etc/apt/sources.list ]; then
  printf "deb http://ports.ubuntu.com/ubuntu-ports noble main universe restricted multiverse\n" > /etc/apt/sources.list
  printf "deb http://ports.ubuntu.com/ubuntu-ports noble-updates main universe restricted multiverse\n" >> /etc/apt/sources.list
  printf "deb http://ports.ubuntu.com/ubuntu-ports noble-security main universe restricted multiverse\n" >> /etc/apt/sources.list
fi
printf "#!/bin/sh\nexit 101\n" > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
mkdir -p /run/systemd/resolve
apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 update
apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-not-root install --no-install-recommends tmux openssh-server python3 ca-certificates xz-utils jq procps iproute2 less nano
rm -f /usr/sbin/policy-rc.d
rm -rf /var/cache/apt/archives/* /var/lib/apt/lists/*
APT_CMD
)"
  if [ "${TEST_SKIP_APT:-0}" = "1" ]; then
    progress 56 "测试模式：跳过 apt 阶段"
    return 0
  fi
  run_container_stage "安装 Ubuntu 基础软件包（apt）" 56 "$_apt_cmd"

  # Inside PRoot, link2symlink sometimes cannot create its shadow file, so dpkg leaves an
  # unreadable placeholder instead of the real binary and later reports "No such file or
  # directory". Repair those packages by unpacking their .deb on the host, where tar -h
  # materialises hardlinks as real files.
  repair_damaged_packages
}

repair_damaged_packages() {
  _arch="$ROOTFS/var/cache/apt/archives"
  [ -d "$_arch" ] || return 0
  _repaired=0
  for _deb in "$_arch"/*.deb; do
    [ -f "$_deb" ] || continue
    # Only touch packages dpkg still considers broken.
    _pkg="$(printf '%s' "$(basename "$_deb")" | sed 's/_.*//')"
    _state="$(in_container "dpkg-query -W -f='\${db:Status-Abbrev}' '$_pkg' 2>/dev/null" | tr -d '\r')"
    case "$_state" in
      ii) continue ;;
    esac
    log "修复未完成安装的软件包: $_pkg"
    sh "$DIR/fix-deb.sh" "$_deb" "$ROOTFS" "$LAUNCHER_DIR/bin" >> "$LOG_DIR/install.log" 2>&1 || true
    _repaired=$((_repaired + 1))
  done
  if [ "$_repaired" -gt 0 ]; then
    in_container 'DEBIAN_FRONTEND=noninteractive dpkg --force-not-root --configure -a >/dev/null 2>&1 || true'
    log "已修复 $_repaired 个软件包"
  fi
  # The packages must end up configured, otherwise later stages cannot use ssh/sshd.
  in_container 'dpkg --audit >/dev/null 2>&1' || log "提示: 仍有软件包未完全配置，详见 $LOG_DIR/install.log"
  return 0
}

install_node_and_dsh() {
  _tarball="$ROOTFS_CACHE/$(basename "$NODE_URL")"
  fetch "$NODE_URL" "$_tarball" "$NODE_SHA256" 78 10 "Node.js" 30473480
  log "解包 Node.js 到容器 /usr/local"
  rm -rf "$ROOTFS_CACHE/node-dist"
  mkdir -p "$ROOTFS_CACHE/node-dist"
  # tar needs the launcher's xz on PATH here as well (toybox does not implement xz).
  run_extract_archive "$_tarball" "$ROOTFS_CACHE/node-dist" --strip-components=1 \
    || die "Node.js 解包失败（缺少 xz 时请点“修复文件”后重试）"
  mkdir -p "$ROOTFS/usr/local/bin" "$ROOTFS/usr/local/lib/node_modules"
  cp -f "$ROOTFS_CACHE/node-dist/bin/node" "$ROOTFS/usr/local/bin/node"
  chmod 755 "$ROOTFS/usr/local/bin/node"
  rm -rf "$ROOTFS/usr/local/lib/node_modules/npm"
  cp -a "$ROOTFS_CACHE/node-dist/lib/node_modules/npm" "$ROOTFS/usr/local/lib/node_modules/npm"
  ln -sfn ../lib/node_modules/npm/bin/npm-cli.js "$ROOTFS/usr/local/bin/npm"
  ln -sfn ../lib/node_modules/npm/bin/npx-cli.js "$ROOTFS/usr/local/bin/npx"

  if [ -n "${DSH_BUNDLE_URL:-}" ]; then
    _dsh="$ROOTFS_CACHE/$(basename "$DSH_BUNDLE_URL")"
    fetch "$DSH_BUNDLE_URL" "$_dsh" "${DSH_BUNDLE_SHA256:-}" 88 4 "DSH" 0
    log "解包 DSH 包到容器 /usr/local/lib/node_modules"
    mkdir -p "$ROOTFS/usr/local/lib/node_modules/@deepseek-ai"
    /system/bin/tar -xzf "$_dsh" -C "$ROOTFS/usr/local/lib/node_modules/@deepseek-ai" \
      || /system/bin/tar -xf "$_dsh" -C "$ROOTFS/usr/local/lib/node_modules/@deepseek-ai" \
      || die "DSH 包解包失败"
  else
    log "未设置 DSH_BUNDLE_URL，改由容器内 npm 安装 @deepseek-ai/dsh"
    if [ "${TEST_SKIP_DSH_NPM:-0}" = "1" ]; then
      progress 89 "测试模式：跳过 DSH npm 阶段"
    else
      _dsh_cmd="set -eu; export PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin; npm install -g --no-fund --no-audit ${DSH_PACKAGE:-@deepseek-ai/dsh}"
      run_container_stage "安装 DSH npm 包" 89 "$_dsh_cmd"
    fi
  fi
  ln -sfn ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js "$ROOTFS/usr/local/bin/dsh"
  [ -x "$ROOTFS/usr/local/bin/dsh" ] || die "dsh 入口缺失: $ROOTFS/usr/local/bin/dsh"

  in_container 'set -eu
export PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
node --version; npm --version; dsh --version 2>/dev/null || dsh --profile web --help | head -1
tmux -V; sshd -V 2>&1 | head -1; python3 --version
' || die "容器运行组件自检失败"

  # `dsh plugin ... add <name>` 靠 pnpm 装插件依赖，而 rootfs 只带 Node 自带的 npm。
  # 这一步失败不致命（核心 DSH 仍可用），所以只记日志、不 die。
  log "安装 pnpm（dsh plugin 依赖）"
  in_container 'set -u
export PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
if command -v pnpm >/dev/null 2>&1; then echo "pnpm 已存在 $(pnpm -v)"; exit 0; fi
for reg in https://registry.npmjs.org https://registry.npmmirror.com; do
  npm install -g pnpm --registry="$reg" --no-fund --no-audit >/tmp/pnpm-install.log 2>&1 && break
done
command -v pnpm >/dev/null 2>&1 && pnpm -v
' || log "提示: pnpm 未装上（dsh plugin 会不可用），可稍后执行 scripts/fix-pnpm.sh 重试"
}

main() {
  rm -f "$PROGRESS_FILE.error" 2>/dev/null
  progress_running
  printf 'percent=0\nmessage=准备安装\nupdated=%s\n' "$(date +%s 2>/dev/null)" > "$PROGRESS_FILE" 2>/dev/null
  progress 1 "检查运行环境"

  need_tools
  if [ "$FORCE" -eq 0 ] && [ -f "$INSTALL_MARKER" ] \
     && [ "$(cat "$INSTALL_MARKER" 2>/dev/null)" = "$(module_version)" ] \
     && module_install_ready; then
    progress 100 "资源已就绪，无需重新安装"
    progress_done
    rm -f "$PROGRESS_FILE.pid" 2>/dev/null
    return 0
  fi

  # Scratch space belongs in the writable runtime data directory, not the module ZIP.
  # The module path may be read-only on some KernelSU installs, so PRoot's unbundled ELF
  # loader and link2symlink helper must never be extracted under $MODDIR.
  PROOT_TMP_DIR="$RUN_DIR/proot-tmp"
  PROOT_L2S_DIR="$RUN_DIR/proot-l2s"
  export PROOT_TMP_DIR PROOT_L2S_DIR
  mkdir -p "$PROOT_TMP_DIR" "$PROOT_L2S_DIR" || die "无法创建 PRoot 临时目录（检查 /data/adb/dsh_container/run 权限）"

  _archive="$ROOTFS_CACHE/$(basename "$ROOTFS_URL")"

  if [ -s "$_archive" ] && [ "$(sha256_of "$_archive")" = "$ROOTFS_SHA256" ]; then
    progress 25 "rootfs 归档已在本地，跳过下载"
  else
    progress 5 "下载 rootfs（约 78MB）"
    fetch "$ROOTFS_URL" "$_archive" "$ROOTFS_SHA256" 5 20 "rootfs" 81656416
    progress 25 "rootfs 下载并校验完成"
  fi

  run_unpack_stage "$_archive" "$ROOTFS"

  progress 55 "正在安装 Ubuntu 基础软件包（apt，首次运行需要几分钟）"
  install_guest_runtime
  progress 76 "Ubuntu 基础软件包安装完成"

  progress 78 "准备安装 Node.js 与 DSH"
  install_node_and_dsh
  progress 93 "Node.js 与 DSH 运行组件安装完成"

  progress 95 "部署容器内脚本"
  sh "$DIR/deploy.sh" || die "guest 资产部署失败"

  printf '%s\n' "$(module_version)" > "$INSTALL_MARKER"
  progress 100 "安装完成，可以启动容器了"
  progress_done
  rm -f "$PROGRESS_FILE.pid" 2>/dev/null
}

# --detach runs the install in the background and returns immediately: the WebUI's
# exec bridge has a 120s ceiling, while a full install takes much longer. Progress is
# reported through $PROGRESS_FILE and surfaced by install-status.sh.
case "${1:-}" in
  --detach)
    mkdir -p "$RUN_DIR" "$LOG_DIR" 2>/dev/null
    # Reap any heartbeat left by a previous run before publishing new state, otherwise it
    # would keep overwriting this run's progress with its stale message.
    for _hp in $(ps -A -o PID,ARGS 2>/dev/null | grep "sh /data/adb" | grep "install.sh --force" | awk '{print $1}'); do
      [ "$_hp" = "$$" ] && continue
      kill "$_hp" 2>/dev/null
    done
    rm -f "$PROGRESS_FILE.error" "$PROGRESS_FILE.pid" "$PROGRESS_FILE.stage-rc" \
      "$PROGRESS_FILE.unpack-rc" "$PROGRESS_FILE.heartbeat-stop" 2>/dev/null
    : > "$PROGRESS_FILE.error" 2>/dev/null
    progress_running
    progress 0 "准备启动安装任务"
    _self="$DIR/$(basename "$0")"
    # Keep one process, not two. Android shells can kill ordinary background children at
    # callback exit; setsid detaches the foreground worker into its own session when present.
    if command -v setsid >/dev/null 2>&1; then
      setsid /system/bin/sh "$_self" --force </dev/null >> "$LOG_DIR/install.log" 2>&1 &
    else
      nohup /system/bin/sh "$_self" --force </dev/null >> "$LOG_DIR/install.log" 2>&1 &
    fi
    _pid=$!
    printf '%s\n' "$_pid" > "$PROGRESS_FILE.pid" 2>/dev/null
    progress 1 "安装任务已在后台启动（pid $_pid）"
    echo "installing pid=$_pid"
    exit 0
    ;;
  --status)
    cat "$PROGRESS_FILE.status" 2>/dev/null || echo idle
    exit 0
    ;;
esac

main
