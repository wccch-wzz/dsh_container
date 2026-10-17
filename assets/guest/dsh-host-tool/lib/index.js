// dsh-host-tool — 把 Android 宿主能力暴露成模型可直接调用的工具。
//
// 背景：容器跑在 PRoot 里，只 bind 了 /dev /proc /sys /sdcard，看不到 /data，
// 宿主也没有 Node。所以「宿主 root」和「adb」只能通过宿主侧的 hostd 队列
// （容器内入口 /usr/local/bin/dsh-host）转发。本插件把那两个入口包成 tools，
// 模型不必先知道 shell 命令怎么写。
//
// 依赖：hostd 在跑（开机 service.sh 自动拉起，或 `dsh.sh hostd-start`）。
import { execFile } from "node:child_process";
import fs from "node:fs";

export const name = "dsh-host-tool";
export const inject = ["tools"];

/** 容器内 CLI 入口，由模块 deploy.sh 渲染到 rootfs。 */
const CLI = "/usr/local/bin/dsh-host";
/** 与 hostd 的 2MB 输出上限保持一致，留一点余量给 stderr。 */
const MAX_BUFFER = 3 * 1024 * 1024;
const DEFAULT_TIMEOUT_MS = 120_000;
const MAX_TIMEOUT_MS = 600_000;

function clampTimeout(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_TIMEOUT_MS;
  return Math.min(Math.max(Math.trunc(n), 1_000), MAX_TIMEOUT_MS);
}

function runCli(args, timeoutMs) {
  return new Promise((resolve) => {
    execFile(
      CLI,
      args,
      { timeout: timeoutMs, maxBuffer: MAX_BUFFER, killSignal: "SIGKILL" },
      (err, stdout, stderr) => {
        const out = String(stdout ?? "");
        const errText = String(stderr ?? "");
        let text = out;
        if (errText) text = text ? `${text}\n[stderr]\n${errText}` : errText;
        text = text.trim();
        let exitCode = 0;
        if (err) {
          exitCode = typeof err.code === "number" ? err.code : 1;
          if (err.killed || err.signal) text += `\n[timeout] 超过 ${timeoutMs}ms 被终止`;
        }
        if (!text) text = "(无输出)";
        if (exitCode !== 0) text += `\n[exit ${exitCode}]`;
        resolve({ text, exitCode });
      },
    );
  });
}

const outputSpec = {
  schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      text: { type: "string" },
      exitCode: { type: "number" },
    },
  },
  render: (_args, value) => [{ type: "text", text: String(value?.text ?? "") }],
};

/** 挂载痕迹：证明插件真的在活进程里跑过 apply，而不是只落在磁盘上。 */
const MARKER = "/root/.dsh-container/host-tool.log";

function mark(line) {
  try {
    fs.appendFileSync(MARKER, `${new Date().toISOString()} ${line}\n`);
  } catch {
    // 标记失败不影响工具本身
  }
}

export function apply(ctx) {
  if (!ctx.tools) {
    mark("apply: 没有 tools 服务，跳过注册");
    return;
  }
  mark(`apply: 注册 host_shell / host_adb (pid=${process.pid})`);

  // 自检：用公开 API 回读注册表，确认模型侧能看到的清单里真的有这两个工具。
  // ctx.tools.schemas() 就是「投影给模型看的 schema 集合」；get() 是单个工具解析。
  // apply 时其他 bundle 还没加载完，所以延迟再扫一次。
  const probe = (tag) => {
    try {
      const all = ctx.tools.schemas();
      const names = all.map((s) => s.name);
      const self = ctx.tools.get("host_shell");
      const desc = self?.description ? String(self.description).slice(0, 24) : "";
      mark(`${tag} 可见工具(${names.length}) host_shell=${names.includes("host_shell")} host_adb=${names.includes("host_adb")} get=${self ? "有" : "无"}${desc ? ` desc=${desc}...` : ""}`);
      mark(`${tag} 清单: ${names.join(",")}`);
    } catch (e) {
      mark(`${tag} 探测失败: ${e?.message ?? e}`);
    }
  };
  probe("t+0");
  setTimeout(() => probe("t+8s"), 8000).unref?.();

  ctx.tools.register({
    name: "host_shell",
    description: [
      "在 Android 宿主上以 root 执行 shell 命令（不经过容器 / PRoot）。",
      "容器里看不到 /data，也调不到宿主二进制；需要访问 /data/adb、模块目录、",
      "`pm`、`am`、`settings`、`dumpsys`、`screencap`、`svc`、`magisk`/`ksud` 时用这个。",
      "返回 stdout+stderr 合并文本与退出码；输出超过 2MB 会被截断并标注。",
      "注意：这是真正的 root，命令会立即生效，不要用来做破坏性操作。",
    ].join(" "),
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["command"],
      properties: {
        command: {
          type: "string",
          description: "交给宿主 `sh -c` 执行的命令，例如 `id` 或 `ls /data/adb/modules`",
        },
        timeout_ms: {
          type: "number",
          description: `超时毫秒，默认 ${DEFAULT_TIMEOUT_MS}，上限 ${MAX_TIMEOUT_MS}`,
        },
      },
    },
    output: outputSpec,
    async execute(args) {
      const command = String(args?.command ?? "").trim();
      if (!command) return { text: "ERROR: command 为空", exitCode: 2 };
      return runCli([command], clampTimeout(args?.timeout_ms));
    },
  });

  ctx.tools.register({
    name: "host_adb",
    description: [
      "在宿主上执行 adb 命令，目标已自动选中本机自连设备 127.0.0.1:5599（shell 用户，非 root）。",
      "用于 `shell <cmd>`、`devices`、`install`、`uninstall`、`logcat`、`push`/`pull`、`screencap` 等。",
      "需要 root 权限时改用 host_shell。若返回 `hostd: 未运行`，说明宿主执行器没起来。",
    ].join(" "),
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["args"],
      properties: {
        args: {
          type: "string",
          description: "adb 子命令与参数，例如 `shell id` 或 `devices -l`（不要写 adb 本身）",
        },
        timeout_ms: {
          type: "number",
          description: `超时毫秒，默认 ${DEFAULT_TIMEOUT_MS}，上限 ${MAX_TIMEOUT_MS}`,
        },
      },
    },
    output: outputSpec,
    async execute(args) {
      const rest = String(args?.args ?? "").trim();
      if (!rest) return { text: "ERROR: args 为空", exitCode: 2 };
      return runCli(["adb", rest], clampTimeout(args?.timeout_ms));
    },
  });

  mark("apply: 完成");
}
