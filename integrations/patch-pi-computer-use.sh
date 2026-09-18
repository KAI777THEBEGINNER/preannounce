#!/bin/bash
# 给 pi-computer-use 打「预告」集成补丁：真实 HID 投递前先弹刘海倒数 toast。
#
# 为什么是补丁而不是改 native helper：helper 重新编译会换签名，TCC 的辅助功能与录屏授权会被作废。
# 补丁只改 TypeScript（决策层），不动已授权的二进制。
#
# 幂等：已打过则直接退出 0。`pi update npm:@injaneity/pi-computer-use` 会覆盖补丁，更新后重跑本脚本。
set -euo pipefail

PKG="${PI_COMPUTER_USE_PKG:-$HOME/.pi/agent/npm/node_modules/@injaneity/pi-computer-use}"
BRIDGE="$PKG/src/bridge.ts"

if [ ! -f "$BRIDGE" ]; then
    echo "找不到 $BRIDGE —— 先安装 npm:@injaneity/pi-computer-use" >&2
    exit 1
fi

/usr/bin/python3 - "$BRIDGE" <<'PYTHON'
import sys

path = sys.argv[1]
source = open(path, "r", encoding="utf-8").read()

import re

MARKER = "preannounce integration"

if MARKER in source:
    # 已打过：先剥离旧补丁再重新应用，保证补丁内容永远与脚本一致（幂等可重打）
    source = re.sub(r"// >>> preannounce integration.*?// <<< preannounce integration\n\n?", "", source, flags=re.S)
    source = re.sub(r"[ \t]*await requirePreannounce\(action\);\n", "", source)
    print("检测到旧补丁，已剥离，准备重打")

HELPER = '''// >>> preannounce integration (local patch by Kai; 重装/升级本包后跑 preannounce/integrations/patch-pi-computer-use.sh 重打)
const PREANNOUNCE_BIN = process.env.PREANNOUNCE_BIN
	?? path.join(os.homedir(), "Applications", "预告.app", "Contents", "MacOS", "Preannounce");

/** 真实 HID 投递会动用户的鼠标与键盘，动手前必须先让「预告」刘海 toast 倒数告知；未告知则拒绝动手 */
async function requirePreannounce(action: PreparedAction): Promise<void> {
	const keyboard = action.action === "typeText" || action.action === "keypress";
	const message = keyboard ? "{n} 秒之后将用你的真实键盘输入" : "{n} 秒之后光标将会移动";
	await new Promise<void>((resolve, reject) => {
		const child = spawn(PREANNOUNCE_BIN, ["announce", "--message", message, "--source", "pi-computer-use", "--timeout-ms", "120000"], { stdio: ["ignore", "ignore", "pipe"] });
		let stderr = "";
		child.stderr?.on("data", (chunk) => { stderr += String(chunk); });
		const timer = setTimeout(() => { child.kill(); reject(new Error("预告超时")); }, 130_000);  // hover 暂停可能持续很久
		child.on("error", (error) => { clearTimeout(timer); reject(error); });
		child.on("close", (exitCode) => {
			clearTimeout(timer);
			if (exitCode === 0) resolve();
			else {
				const failure = new Error(stderr.trim() || `预告工具退出码 ${exitCode}`) as Error & { exitCode?: number };
				failure.exitCode = exitCode ?? undefined;
				reject(failure);
			}
		});
	}).catch((error) => {
		// 退出码 4 = 用户点按胶囊取消了这次操作；其余 = 预告工具不可用
		if ((error as { exitCode?: number } | undefined)?.exitCode === 4) {
			throw new Error("用户取消了这次操作，物理输入已放弃。");
		}
		throw new Error(`物理输入已被阻止：无法向用户预告本次动作（${error instanceof Error ? error.message : String(error)}）。预告工具：${PREANNOUNCE_BIN}`);
	});
}
// <<< preannounce integration

'''

ANCHOR_HELPER = "function nativeInputDelivery("
ANCHOR_1 = "\tif ((action.usesCurrentFocus || action.needsForeground) && !headless) {\n\t\tconst foreground = checked("
ANCHOR_2 = "\t\tif (canRetryInForeground(action, result.outcome, headless)) {\n\t\t\tconst foreground = checked("
ANCHOR_3 = "\t\tconst foreground = checked(await currentPlatformBackend.act(helperActRequest(target, action, \"foreground\"), { signal, timeoutMs }));\n\t\tconst trace = executionTraceFromAct(foreground, \"foreground\");\n\t\ttrace.backgroundFirst = true;\n\t\ttrace.escalatedToForeground = true;\n\t\ttrace.escalationReason = code;"

edits = [
    (ANCHOR_HELPER, HELPER + ANCHOR_HELPER, "插入 requirePreannounce 辅助函数"),
    (ANCHOR_1, ANCHOR_1.replace("\t\tconst foreground = checked(", "\t\tawait requirePreannounce(action);\n\t\tconst foreground = checked(", 1), "前台投递（首次决定）"),
    (ANCHOR_2, ANCHOR_2.replace("\t\t\tconst foreground = checked(", "\t\t\tawait requirePreannounce(action);\n\t\t\tconst foreground = checked(", 1), "前台投递（键盘重试升级）"),
    (ANCHOR_3, ANCHOR_3.replace("\t\tconst foreground = checked(", "\t\tawait requirePreannounce(action);\n\t\tconst foreground = checked(", 1), "前台投递（foreground_required 升级）"),
]

for anchor, replacement, label in edits:
    count = source.count(anchor)
    if count != 1:
        print(f"补丁失败：锚点「{label}」在 bridge.ts 里出现 {count} 次（应为 1 次）——上游代码结构变了，需人工看一眼", file=sys.stderr)
        sys.exit(2)
    source = source.replace(anchor, replacement, 1)
    print(f"已应用：{label}")

if "import { spawn" not in source:
    print("补丁失败：bridge.ts 里没有 spawn 导入，无法插入预告调用", file=sys.stderr)
    sys.exit(2)

open(path, "w", encoding="utf-8").write(source)
print(f"补丁完成：{path}")
PYTHON
