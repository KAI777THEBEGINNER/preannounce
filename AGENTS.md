# 预告（Preannounce）项目规则

## 项目是什么

macOS 后台守护工具，应用名「预告」：**任何自动化在做出「会打扰用户」的动作之前，必须先弹一个倒计时胶囊 toast，告诉用户 3 秒之后将要发生什么。**

起因：AI 助手做自动化时，有一类动作会打扰用户，但用户事先毫无察觉——

| 打扰类型 | 典型来源 | 用户感受 |
|---|---|---|
| 真实鼠标被夺取 | pi-computer-use 的 `hid` 投递（坐标点击、前台重试） | 光标突然自己动了 |
| 真实键盘被占用 | 同上（前台 typeText / keypress） | 字突然自己打进去了 |
| 前台被抢 | `open -a X`、`osascript … activate`、浏览器被导航 | 正在用的应用突然被顶掉 |
| 屏幕内容被改 | webbridge 驱动用户真实浏览器 | 眼前页面自己变了 |

用户的原话：「不要突然动我的光标，必须得让我知道。」「不仅只是服务于光标……涉及到这种会跟我抢的这种情况，都得有弹出 toast 告诉我说三秒钟之后要干嘛干嘛。至少让我知道。」

**交互形态（2026-09-19 定稿）**：无 GUI、无 Dock 图标、无菜单栏（LSUIElement 纯后台），开机自启。任何程序通过 Unix socket 或命令行请求「预告」，守护弹刘海胶囊，倒数 3→2→1 **并把要做的事写在胶囊里**，倒数结束才回复放行。用户双击打开时弹一次就绪横幅。

## 结构约定

```
preannounce/
├─ AGENTS.md          本文件（项目规则）
├─ DESIGN.md          问题定义 + 方案 + 踩坑记录（改动前先读）
├─ CODEBASE.md        代码地图（自动生成，改代码后 /map 刷新）
├─ README.md          交付说明
├─ Sources/
│  └─ main.swift      全部逻辑单文件，条件编译出两个二进制：
│                     -D DAEMON → Preannounce（常驻守护+CLI，不链接 AppKit，物理内存 3MB）
│                     无参数     → PreannounceToast（GUI 胶囊，守护按需拉起，弹完即退）
├─ integrations/
│  ├─ pi-bash-guard.ts             Pi 扩展：拦 bash 里会抢前台的命令
│  └─ patch-pi-computer-use.sh     给 pi-computer-use 打集成补丁（幂等，pi update 后重跑）
├─ scripts/
│  └─ build.sh                    一键构建 .app（编译/组装/签名）
└─ dist/              构建产物 预告.app（本目录可随时重建）
```

- 代码、命令、变量用英文；注释中文，全角标点
- 不引入任何第三方依赖；只依赖系统框架（AppKit / Foundation；socket 直接用 BSD API）
- 构建只用 `swiftc` + 系统自带工具，不依赖 Xcode 工程
- 排版与动画风格与「褪黑素」一致（同一作者、同一套刘海胶囊技术）

## 核心约束（不可破坏）

1. **零权限**：不请求 sudo、辅助功能、录屏、通知授权。NSPanel + NSGlassEffectView 不需要任何授权
2. **不抢焦点**：panel 必须 `.nonactivatingPanel` + `orderFrontRegardless()`，绝不能让用户当前应用失焦。**一个为了防止抢焦点而存在的工具，自己不能抢焦点**——这是本项目的立身之本
3. **失败即拒绝（fail-safe）**：调用方拿不到「已预告」的确认时，必须放弃那个会打扰用户的动作。宁可什么都不做，也不能静默打扰。命令行退出码 3 就是这个语义
4. **只预告会打扰的动作**：语义/后台操作（不动物理输入、不改前台）一次都不许拦，否则等于给所有自动化加 3 秒税
4b. **常驻进程必须足够轻**（用户明确要求）：常驻的 `Preannounce` 不允许链接 AppKit；GUI 只在预告的数秒内存在。子进程冷启动的 ~200ms 必须藏在倒数之前——用户看到的始终是完整 N 秒
4c. **子进程退出码映射**：0=已告知 4=用户取消 其他=失败；但 `terminationReason == .uncaughtSignal` 一律算失败（SIGILL 编号正好是 4，会把崩溃误报成「用户取消」）
5. **胶囊里必须写清「要做什么」**：不是泛泛的「即将操作」，而是「3 秒之后将打开 Dia」这种用户看得懂的信息。文案由调用方给，守护只负责把倒数数字填进 `{n}`
6. **一次预告管一个动作会话**：`graceMs` 内（默认 2500ms）的连续请求直接放行不重复弹窗（例如「后台失败→前台重试」）；但**倒计时进行中**到达的新请求必须等当前倒数结束才放行（用户必须被真正告知过）
7. **纯后台无 GUI**：LSUIElement（Info.plist）+ `setActivationPolicy(.accessory)` 双保险
8. **最低系统 macOS 26**（原生液态玻璃 NSGlassEffectView），低版本降级 NSVisualEffectView
9. **universal 双架构**：目标机器可能是 Intel Mac
10. **开机自启用 LaunchAgent**：`~/Library/LaunchAgents/com.kai.preannounce.plist`，`RunAtLoad=true` + `KeepAlive=true`，幂等（内容一致不重载，防 launchd 自杀循环）
11. **单实例互斥**：flock 锁文件。手动打开拿不到锁 → 广播通知已有实例弹横幅 → 退出；launchd 守护实例拿不到锁 → **阻塞等锁**（手动实例退出后无缝接手）
12. **刘海胶囊自绘**：NSGlassEffectView（macOS 26+，`.clear` + 极淡白 tint），高 48 全圆角，宽度按最长文案自适应，`.statusBar` level（全屏可见），刘海正下方居中（屏幕中轴，距菜单栏下沿 8pt）。从顶部滑入 0.35s easeOut → 倒数 → 向上滑出 0.4s easeIn，滑动中高斯模糊渐变（blur 加在 label.layer，加容器层不生效）
13. **NSWindow.animator() 在 LSUIElement 非激活窗口上不执行动画**——位置/透明度动画必须手动 Timer 逐帧驱动（继承自褪黑素的坑）
14. **诊断日志**：`~/Library/Application Support/Preannounce/events.jsonl`（JSONL 追加，1MB 轮转），记录请求来源、文案、倒计时起止、grace 跳过

## 协议（Unix socket，一行 JSON 一问一答）

socket：`~/Library/Caches/preannounce/guard.sock`

```json
请求 {"id":"abc","cmd":"announce","message":"{n} 秒之后将打开 Dia","seconds":3,"graceMs":2500,"source":"pi-bash-guard"}
回复 {"ok":true,"shown":true,"countdownMs":3000}     // 已预告，可以动手
回复 {"ok":true,"shown":false,"reason":"grace"}      // grace 内直接放行
请求 {"id":"x","cmd":"ping"}
回复 {"ok":true,"pid":123,"version":"1.0.0"}
```

命令行（同一个二进制的子命令）：

```
Preannounce announce [--message "..."] [--seconds 3] [--grace-ms 2500] [--timeout-ms 8000] [--source name]
    文案里的 {n} 会被倒数数字替换；退出码 0 = 已预告可动手，3 = 预告失败必须放弃
Preannounce diagnose     打印中文诊断报告
Preannounce autostart    launchd 守护模式（静默）
Preannounce             手动打开：守护 + 弹一次就绪横幅
```

## 集成（谁必须调它）

| 集成点 | 文件 | 触发条件 |
|---|---|---|
| Pi bash 工具 | `integrations/pi-bash-guard.ts` | 命令会抢前台：`open -a/-b/<url>`、`osascript … activate/frontmost`、webbridge `navigate`/`new_tab` |
| pi-computer-use | `integrations/patch-pi-computer-use.sh` | 本次 act 会走 `hid` 真实投递（动真实鼠标或键盘） |

**新增任何会打扰用户的工具时，必须同时加一个集成点，并在本表登记。** 这是这个项目存在的唯一理由。

## 验证方式

- 构建：`bash scripts/build.sh`，产物 `dist/预告.app`
- 冒烟：`open "dist/预告.app"` → 刘海下方出现胶囊；`pgrep -fl Preannounce` 存活
- 预告链路：`"dist/预告.app/Contents/MacOS/Preannounce" announce --message "{n} 秒之后将打开 Dia"` → 应见 3→2→1 倒数胶囊，命令返回 0
- 窗口在场证明（无需录屏权限）：倒计时进行中
  `osascript -e 'tell application "System Events" to tell process "Preannounce" to get {position, size, value of static text 1 of window 1}'`
- 失败即拒绝：杀掉守护后 `announce --timeout-ms 1200` → 守护会被自动拉起；若拉起失败必须退出码 3
- grace：连续两次 `announce --grace-ms 3000` → 第二次秒回且 `shown:false`
- 不打扰自己：预告期间用户的前台应用不能变化（`lsappinfo front` 前后一致）
- 集成链路：让 pi-computer-use 做一次坐标点击（hid）→ 必须先见 toast；`setText`（ax）**不该**弹任何东西

## 已知限制

- toast 是自绘窗口，不依赖系统通知（系统通知在 ad-hoc 签名下不可用，褪黑素已踩过）
- 只保护「被调用告知」的动作；绕开本工具的自动化（脚本里直接发 CGEvent）不在范围内
- 锁屏/屏保状态下无法保证可见（此时也没有人在看）
- bash 守卫是模式匹配，不是沙箱：绕过模式的方式仍然存在（如把命令写进脚本文件再执行）
