/**
 * 预告守卫（Preannounce Guard）—— Pi 全局扩展
 *
 * 作用：拦住那些会打扰用户的 shell 命令，在执行前先让「预告」刘海 toast 倒数 3 秒。
 * 为什么需要它：AI 可能忘记先问用户，这类命令一旦执行，用户的前台就被抢了 —— 这是机械兜底。
 *
 * 安装：把本文件放到 ~/.pi/agent/extensions/preannounce-guard.ts（全局扩展目录），重启 Pi 生效。
 * 依赖：~/Applications/预告.app（缺失时按 fail-safe 处理：拦住命令并提示安装路径）
 *
 * 环境变量：
 *   PREANNOUNCE_BIN    预告可执行文件路径（默认 ~/Applications/预告.app/Contents/MacOS/Preannounce）
 *   PREANNOUNCE_MODE   enforce（默认，预告失败就拦命令）| warn（只提示不拦）| off
 */
import { execFile } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { isToolCallEventType, type ExtensionAPI } from "@earendil-works/pi-coding-agent";

const BIN = process.env.PREANNOUNCE_BIN
	?? path.join(os.homedir(), "Applications", "预告.app", "Contents", "MacOS", "Preannounce");
const MODE = (process.env.PREANNOUNCE_MODE ?? "enforce").toLowerCase();
const MAX_MESSAGE = 26;

interface Finding {
	/** toast 文案，{n} 会被倒数数字替换 */
	message: string;
	/** 给日志/通知看的人类可读原因 */
	reason: string;
}

/** 会被浏览器驱动的写操作：会改变用户眼前看到的东西 */
const MUTATING_WEBRIDGE_ACTIONS = new Set([
	"navigate", "close_tab", "close_session", "click", "mouse_click", "fill",
	"key_type", "send_keys", "evaluate", "upload", "cdp",
]);

/** 会夺走用户屏幕交互的截屏模式（-i 交互、-s 选区、-w 选窗口） */
const INTERACTIVE_CAPTURE = /(^|\s)-[a-zA-Z]*[isw][a-zA-Z]*(\s|$)/;

function clip(text: string): string {
	const trimmed = text.trim().replace(/\s+/g, " ");
	return trimmed.length <= MAX_MESSAGE ? trimmed : `${trimmed.slice(0, MAX_MESSAGE - 1)}…`;
}

function describeOpenTarget(parts: string[]): string {
	const appIndex = parts.findIndex((part) => part === "-a" || part === "-b");
	if (appIndex >= 0 && parts[appIndex + 1]) return clip(parts[appIndex + 1].replace(/^["']|["']$/g, ""));
	const positional = parts.find((part) => !part.startsWith("-"));
	if (!positional) return "一个应用";
	const cleaned = positional.replace(/^["']|["']$/g, "");
	if (/^https?:\/\//.test(cleaned)) {
		try {
			return clip(new URL(cleaned).host);
		} catch {
			return "一个网页";
		}
	}
	if (cleaned.endsWith(".app")) return clip(cleaned.replace(/\.app$/, "").split("/").pop() ?? "一个应用");
	const base = cleaned.split("/").filter(Boolean).pop();
	return clip(base ?? "一个文件");
}

/** 扫描命令，返回需要预告的动作（不需要则 undefined） */
export function detect(command: string): Finding | undefined {
	if (!command.trim()) return undefined;
	// 呼叫预告工具本身不算打扰，避免自锁
	if (/Preannounce\s+announce/.test(command)) return undefined;

	const segments = command.replace(/\\\n/g, " ").split(/&&|\|\||;|\n|\|/);

	for (const raw of segments) {
		const segment = raw.trim().replace(/^(?:sudo|command|time)\s+/, "").replace(/^(?:env\s+(?:\S+=\S+\s+)*)/, "");
		if (!segment) continue;

		// 1) open：默认会把目标应用/文件顶到前台（-g 是后台打开，不打扰）
		if (/^open(?:\s|$)/.test(segment)) {
			const parts = segment.slice(4).trim().match(/"[^"]*"|'[^']*'|\S+/g) ?? [];
			if (parts.some((part) => /^-[a-zA-Z]*g[a-zA-Z]*$/.test(part))) continue;
			return {
				message: `{n} 秒之后将打开 ${describeOpenTarget(parts)}`,
				reason: `open 会把目标顶到前台：${clip(segment)}`,
			};
		}

		// 2) osascript 激活应用 / 抢前台
		if (/^osascript\b/.test(segment) && /\b(activate|frontmost)\b/i.test(command)) {
			return { message: "{n} 秒之后将把应用切到前台", reason: `AppleScript 抢前台：${clip(segment)}` };
		}

		// 3) webbridge：驱动用户真实浏览器
		if (/\/command\b/.test(segment) && /(127\.0\.0\.1:10086|agent-webbridge|webbridge)/.test(command)) {
			const action = /"(?:action|tool|command)"\s*:\s*"([a-zA-Z_]+)"/.exec(command)?.[1];
			if (action && MUTATING_WEBRIDGE_ACTIONS.has(action)) {
				return { message: "{n} 秒之后将操作你的浏览器", reason: `webbridge 写操作：${action}` };
			}
			if (action) continue; // 只读操作（list_tabs / screenshot / snapshot 等）不打扰
			return { message: "{n} 秒之后将操作你的浏览器", reason: "webbridge 调用（无法判定动作，按打扰处理）" };
		}

		// 4) 重启 Dock / Finder
		const restart = /killall\s+(Dock|Finder|SystemUIServer)\b/.exec(segment);
		if (restart) return { message: `{n} 秒之后将重启 ${restart[1]}`, reason: `重启 UI 进程：${clip(segment)}` };

		// 5) 交互式截屏（-i / -s / -w 会接管鼠标）
		if (/^screencapture\b/.test(segment) && INTERACTIVE_CAPTURE.test(segment)) {
			return { message: "{n} 秒之后将接管你的屏幕操作", reason: `交互式截屏：${clip(segment)}` };
		}

		// 6) 让电脑睡眠 / 关机
		if (/\bpmset\s+sleepnow\b/.test(segment) || /^(?:sudo\s+)?(?:shutdown|reboot)\b/.test(segment)) {
			return { message: "{n} 秒之后将让电脑睡眠或关机", reason: `电源操作：${clip(segment)}` };
		}
	}
	return undefined;
}

function runAnnounce(message: string): Promise<void> {
	return new Promise((resolve, reject) => {
		execFile(BIN, ["announce", "--message", message, "--source", "pi-bash-guard", "--timeout-ms", "120000"],
			{ timeout: 130_000 }, (error, _stdout, stderr) => {
				if (!error) {
					resolve();
					return;
				}
				const failure = new Error(String(stderr || error.message).trim() || "预告失败") as Error & { exitCode?: number };
				if (typeof error.code === "number") failure.exitCode = error.code;
				reject(failure);
			});
	});
}

export default function preannounceGuard(pi: ExtensionAPI): void {
	if (MODE === "off") return;

	pi.on("tool_call", async (event, ctx) => {
		if (!isToolCallEventType("bash", event)) return;
		const command = String(event.input.command ?? "");
		const finding = detect(command);
		if (!finding) return;

		try {
			await runAnnounce(finding.message);
			ctx.ui.notify(`预告已提醒：${finding.reason}`, "info");
			return;
		} catch (error) {
			const detail = error instanceof Error ? error.message : String(error);
			if ((error as { exitCode?: number } | undefined)?.exitCode === 4) {
				// 用户点按胶囊取消了：这是明确拒绝，任何模式下都必须拦住
				return {
					block: true,
					reason: `你取消了这次操作，命令已放弃执行。\n命令：${command.slice(0, 200)}`,
				};
			}
			if (MODE === "warn") {
				ctx.ui.notify(`预告不可用（warn 模式放行）：${detail}`, "warning");
				return;
			}
			return {
				block: true,
				reason: [
					"这条命令会抢走你的前台，但预告工具不可用，已按 fail-safe 拦住。",
					`命令：${command.slice(0, 200)}`,
					`原因：${detail}`,
					`预告工具路径：${BIN}`,
					"修好预告后可重试；或临时设 PREANNOUNCE_MODE=warn 只警告不拦。",
				].join("\n"),
			};
		}
	});
}
