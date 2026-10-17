# DSH Container Standalone — KernelSU 模块

不依赖 Termux 的自包含 Ubuntu 容器模块：内置 Android PRoot 启动器，容器内自带
Node.js、DeepSeek Harness (DSH)、OpenSSH 与 tmux，通过模块 WebUI 提供
**安装 / 容器开关 / DSH 开关 / 终端**。

## 与 0.8.0 的区别

| 项目 | 0.8.0（Termux 版） | 本模块（独立版） |
|---|---|---|
| PRoot | Termux 包的 `$PREFIX/bin/proot` | 模块自带 `libexec/launcher/bin/proot`（Android clang 构建，`$ORIGIN` RUNPATH） |
| rootfs | 依赖现有 proot-distro 容器 | 首次安装时下载官方 Ubuntu Minimal rootfs 到 `/data/adb/dsh_container/rootfs` |
| Node/dsh | 依赖容器内既有安装 | 安装流程内解包 Node 24 并由容器内 npm 安装 DSH |
| 宿主工具 | Termux 的 curl/ssh/node | 模块自带 curl/zstd 及其依赖库 |
| 宿主路径 | 硬编码 `$PREFIX`、`$HOME` | 全部模块内相对路径与 `/data/adb/dsh_container` |

## 目录结构

```
/data/adb/modules/dsh_container/          模块本体（只读挂载）
  module.prop
  scripts/    lib.sh install.sh install-status.sh container.sh dsh.sh term.sh deploy.sh
  assets/guest/  容器内资产模板（dsh-run / sshd-run / bridge / term / selftest）
  libexec/launcher/  自带 PRoot 启动器与 curl/zstd（含依赖库）
  webroot/   WebUI
/data/adb/dsh_container/                  运行时状态（可写）
  rootfs/     Ubuntu 根文件系统
  cache/      下载缓存（rootfs 归档、Node 归档）
  run/ logs/  PID 与日志
```

## 首次使用

1. KernelSU 管理器安装 zip 并启用模块。
2. 打开模块 WebUI → **安装容器资源**（下载约 78MB rootfs + 33MB Node，解包后约 1.3GB）。
3. 安装完成后点 **启动容器** → **启动 DSH**。
4. DSH 入口：`http://127.0.0.1:23991`（授权桥，自动完成令牌交换）。
5. 终端页使用容器内本地 pty（`script` + `bash`），经 WebSocket 提供；端口由
   `/data/adb/dsh_container/rootfs/root/.dsh-container/ws.endpoint` 给出（默认 23992，
   被占用时自动后移），连接必须带该文件里的一次性 token。

命令行等价入口（root shell）：

```sh
sh /data/adb/modules/dsh_container/scripts/container.sh install
sh /data/adb/modules/dsh_container/scripts/dsh.sh all-start
sh /data/adb/modules/dsh_container/scripts/dsh.sh selftest
sh /data/adb/modules/dsh_container/scripts/term.sh send "ls /root"
```

## 从容器操作宿主（`dsh-host`）

容器跑在 PRoot 里，只 bind 了 `/dev` `/proc` `/sys` `/sdcard`，**看不到 `/data`**，宿主也没有
Node（模块自带的 Node 是 glibc 构建，Android 是 bionic）。所以手机侧的 `adb`、`su`、`pm`、`am`、
`settings`、`screencap` 默认都调不到。

为此宿主侧有一个 root 执行器 `scripts/hostd.sh`，双方用都能看到的一个目录传命令：

```
<rootfs>/root/.dsh-container/hostq/
  <id>.req    命令（sh -c，宿主 root 执行）
  <id>.out    合并的 stdout+stderr（超过 2MB 自动截断）
  <id>.rc     退出码
  <id>.done   完成标记
```

容器里装好了入口 `/usr/local/bin/dsh-host`：

```sh
dsh-host id                                  # 宿主 root 身份
dsh-host 'ls /data/adb/modules'              # 任意宿主命令
dsh-host adb devices                         # 宿主上的 adb（Termux 的 android-tools）
dsh-host adb shell pm list packages          # 走 adb 拿 shell 用户视角
dsh-host tcpip                               # 让本机 adbd 开 TCP 并自连（后台，约 10s）
dsh-host tcpip-log                           # 看自连结果
dsh-host tcpip-off                           # 关掉 TCP adbd
dsh-host status                              # 执行器是否在线
printf 'id\nuname -a\n' | dsh-host sh        # 批量执行
```

宿主侧管理：

```sh
sh /data/adb/modules/dsh_container/scripts/dsh.sh hostd-start|hostd-stop|hostd-status
sh /data/adb/modules/dsh_container/scripts/dsh.sh host 'id'   # 不走容器，直接跑
```

- `service.sh` 会在开机 `late_start` 阶段自动拉起 hostd，重启后不用手动开。
- `dsh-host adb` 走的是 **Termux 的 `android-tools`**（`/data/data/com.termux/files/usr/bin/adb`）；
  没装就返回 `adb: 未找到`。hostd 会生成一个 `run/adb` 包装脚本，把 Termux 的 `LD_LIBRARY_PATH`
  隔离在子进程里，避免污染系统二进制；adb 自己的 `HOME` 指向 `run/adb-home`（宿主没有 `/root`），
  **server 端口跟 Termux 共用 5037**，不另设 `ADB_SERVER_PORT`，所以两边 `adb devices` 看到的是同一份列表。
- 连本机调试：Android 11+ 的**无线调试**需要先在系统里「使用配对码配对」（`adb pair`），端口随机，
  不能靠固定 5555 猜；若你已有一路 adb 连接，可先 `adb tcpip 5555` 再 `dsh-host connect 5555`。
- 更省事的做法是 `dsh-host tcpip`：以 root 直接 `setprop service.adb.tcp.port 5555` 并重启 adbd，
  然后 `adb connect 127.0.0.1:5555` —— 不需要电脑、不需要配对码，拿到的是普通 `shell` 用户的
  adb shell（不是 root；root 直接用 `dsh-host <cmd>`）。
  - 重启 adbd 会断掉当前所有 adb 会话（包括无线调试那条，端口可能变），所以整件事由宿主
    后台进程 `scripts/adb-self.sh` 执行，过程写在 `logs/adb-self.log`；用 `dsh-host tcpip-log` 看结果。
  - 连上之后目标地址是 `127.0.0.1:5599`，之后 `dsh-host adb shell ...` 会自动选中它（其他都是 offline）。
  - 为什么不是 5555：adb 会把 5555-5585 当模拟器端口扫，5555 会额外冒出一个 `emulator-5554`，
    让 `adb shell` 报 `more than one device`；5599 避开这段。
  - 容器里的 adb 和 Termux 共用同一个 5037 server，所以两边 `adb devices` 看到的是同一份列表；
    Termux 被彻底关掉时 root 会自己起一个 server，那时第一次连接会在手机上弹「允许 USB 调试」。
  - **用完请 `dsh-host tcpip-off`**：TCP adbd 会对局域网开放，公共 Wi-Fi 下等于把调试口暴露出去。
- 安全：`hostq` 在 rootfs 内部（`/data/adb` 仅 root 可读），命令以宿主 root 执行，
  等价于在手机上拿到 root shell —— 不要把 `dsh-host` 暴露给不受信任的模型/脚本。

### 两个发行包

| 包 | 内容 | 行为 |
|---|---|---|
| `dsh_container-<ver>.zip` | 内置工具版 | `assets/guest/host-tool.enabled` + `dsh-host-tool/` 一起打进包；`deploy.sh` 自动落地，`dsh.sh start` 自动挂进 web profile |
| `dsh_container-<ver>-lite.zip` | 精简版 | 两个文件都不存在；容器里没有 `dsh-host-tool`，也不会动用户的 profile（从内置版换过来时会自动卸下旧挂载） |

两个包 `id` 相同（`dsh_container`），可以直接互相覆盖安装；`name` 分别为 `DSH Container Standalone`
与 `DSH Container Standalone (Lite)`，在 KernelSU 列表里能分出来。
构建：`bash tools/build-variants.sh <模块目录> [输出目录]`。

### 让模型自己会用：`dsh-host-tool` 插件

`dsh-host` 只是个 CLI，模型默认并不知道它存在。`assets/guest/dsh-host-tool` 是一个 cordis
插件，把两个入口注册成真正的 dsh 工具：

| 工具 | 作用 | 参数 |
|---|---|---|
| `host_shell` | 宿主 root 执行命令（`sh -c`），返回 stdout+stderr 与退出码 | `command`、`timeout_ms` |
| `host_adb` | 宿主上执行 adb，自动选中 `127.0.0.1:5599` | `args`、`timeout_ms` |

底层仍然走 `hostq` 队列，所以 hostd 没在跑时工具会回 `hostd: 未运行`。

```sh
sh /data/adb/modules/dsh_container/scripts/dsh.sh host-tool status    # 本版本 + 是否已挂载
sh /data/adb/modules/dsh_container/scripts/dsh.sh host-tool install   # 手动补挂（内置版已自动）
sh /data/adb/modules/dsh_container/scripts/dsh.sh host-tool remove    # 卸下，保留容器
```

- 插件文件由 `deploy.sh` 落到 `rootfs/usr/local/lib/dsh-host-tool`；内置工具版在 `dsh.sh start` 时
  自动把它挂进 web profile（`dsh plugin --profile web add` 本地路径，不联网），会追加到
  `dsh.profile.bundles`，重启 dsh 后生效。
- 插件 apply 时会往 `rootfs/root/.dsh-container/host-tool.log` 写一行，可用来确认它真的在
  活进程里跑过（而不仅仅是在磁盘上）。
- 它是普通 npm 包，`dsh plugin --profile web remove dsh-host-tool` 即可卸下，不影响容器。

## 配置（可选）

`/data/adb/dsh_container/env.sh` 可覆盖 `DSH_PORT`、`BRIDGE_PORT`、`SSH_PORT`、`WS_PORT`、
`WORKSPACE_ROOT`、`DNS_SERVER`、`ROOTFS_URL`、`NODE_URL` 等；`install.sh` 与 `deploy.sh`
都会读取它。

## 已验证 / 未验证

- 已在本机验证：自建 PRoot 启动器在净化环境下运行 Ubuntu bash、Node 24、npm、Python、
  tmux、sshd 与 `dsh --profile web`；DSH 授权链 `303 → cookie → 200`；容器命名空间内看不到
  Termux 前缀。
- 仍需在设备上验证：KernelSU root 与 SELinux 上下文下从模块目录运行、真实安装流程、
  重启后的持久化、更新与回滚。

## 自带启动器（libexec/launcher）

- `bin/proot`：用设备自带 Android clang 从 Termux PRoot 源码构建；`RUNPATH` 已改为
  `$ORIGIN/../lib:/system/lib64`，内嵌临时目录已从 Termux 私有路径改为 `/tmp/`。
- `bin/curl`、`bin/zstd`：下载与解包工具（含 OpenSSL/zstd/zlib/xz 依赖库）。
- `PROOT_TMP_DIR` / `PROOT_L2S_DIR` 指向模块内 `tmp/`、`l2s/`，因此 PRoot 的临时文件和
  link2symlink 影子文件都落在模块目录，不会写到 Termux 或其它应用空间。
- 容器与 WebUI 的临时态放在 `/data/adb/dsh_container`，不写模块只读挂载层。

## 安全说明

- 终端给的是 **root shell**，所以 WebSocket 端点要求一次性 token：`ssh-term.js` 启动时
  生成/读取 `rootfs/root/.dsh-container/ws.token`（mode 0600），并把实际端口与 token 写进
  同目录的 `ws.endpoint`。**没带 token 的升级请求一律 401，不会起 shell。**
- `ssh-term.js` 与 `module-bridge.js` 都只 `listen('127.0.0.1')`，不对局域网暴露。
- 即便如此，**设备上其它 App 仍可访问 loopback**：请勿把 token 贴到聊天/日志里；
  怀疑泄露时删掉 `ws.token` 再 `dsh.sh ssh-stop`，下次启动会重新生成。
- 授权桥 `23991` 为方便浏览器直接打开，未加 token；它只转发到本机 DSH 并携带 cookie，
  不提供 shell。

## 卸载

在 KernelSU 管理器里卸载模块会执行 `uninstall.sh`：

1. 结束 `dsh` / `module-bridge` / `ssh-term` / `sshd` 与容器主进程；
2. 删除 `/data/adb/dsh_container/rootfs` 与 `cache`（**约 1.3GB**）；
3. 保留 `run/`、`logs/` 与 `env.sh`。

如果希望**保留 rootfs 以便重装后免下载**，先创建标记文件：

```sh
mkdir -p /data/adb/dsh_container && : > /data/adb/dsh_container/keep-rootfs
```

## 许可

本模块代码以 MIT 许可发布，见 `LICENSE`。WebUI 内含 [xterm.js](https://github.com/xtermjs/xterm.js)
（MIT），其许可声明随文件保留。容器 rootfs 为 Ubuntu Minimal 官方镜像，遵循其自身许可；
`libexec/launcher` 内的 PRoot 与 curl/zstd 二进制由各自上游许可约束。

## 更新日志

### 0.10.2

- **修 WebUI 卡死**：`container.sh start` / `dsh.sh start` 在 KernelSU 的同步 exec 通道里
  要跑几十秒（`deploy.sh` + 等 agent 就绪），这一个调用不返回，页面上所有查询就全部排队，
  表现为一直“查询中”、只能重开 KernelSU。新增 `--detach`：点火即返回，WebUI 改为后台
  启动 + 2 秒轮询，点击后 1 秒内就有反馈。
- **修连点互杀**：两个启动并发时各自会 `do_stop` 掉对方。新增启动锁
  `$STATE_DIR/.boot.lock`（5 分钟自动过期），重复请求直接忽略。
- **修双实例**：队列启动后的验证窗口只有 16 秒，冷启动超过 16 秒就会误开 PRoot 兜底，
  结果两份抢 23099。窗口放宽到 60 秒，并在 `dsh_node_present` 命中时提前结束。
- 实测冷启动：容器 14 秒、dsh 端口就绪 37 秒、单实例。

### 0.10.1

- 新增 `dsh-host-tool` 插件，把宿主 root / adb 包成模型可直接调用的 `host_shell`、
  `host_adb`；内置工具版自动挂载，精简版自动卸下。
- 修 watchdog 无限重启：判据从 pid 文件改为 `/proc/*/cmdline`。
- 修 `do_start` 3 秒早判失败导致的 `EADDRINUSE`。

## 已知限制

- DSH 的 `web` profile 在 Node 24 下会因 HMR 服务缺少 Node 内部加载器而报一条警告
  （`--expose-internals is required for HMR service`）。该条警告不影响 web 服务启动、
  授权链和终端；若要保持日志干净，可在 `/root/.dsh/profiles/web/cordis.patch.yml`
  把 `hmr` 条目标记为 `disabled: true`。
- 首次安装需要联网下载 rootfs 与 Node 归档；中断后重新点击“安装资源”会复用已下载的
  归档并继续。
