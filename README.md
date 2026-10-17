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

## 已知限制

- DSH 的 `web` profile 在 Node 24 下会因 HMR 服务缺少 Node 内部加载器而报一条警告
  （`--expose-internals is required for HMR service`）。该条警告不影响 web 服务启动、
  授权链和终端；若要保持日志干净，可在 `/root/.dsh/profiles/web/cordis.patch.yml`
  把 `hmr` 条目标记为 `disabled: true`。
- 首次安装需要联网下载 rootfs 与 Node 归档；中断后重新点击“安装资源”会复用已下载的
  归档并继续。
