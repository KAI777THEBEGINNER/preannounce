# CODEBASE.md —— preannounce 代码地图

> 自动生成于 2026-09-19 01:33（pi codebase-map）。改动代码后运行 `/map` 刷新。
> 用法：先读本图建立全局认知，再按需 read 具体文件；不要每次全量扫仓库。

## 总览

- 技术栈：.sh/.swift/.ts
- 源码文件：4 个
- 入口：`Sources/main.swift`
- 常用命令：bash scripts/build.sh

## 目录结构

```
├── Sources/  (1 files)
├── integrations/  (2 files)
└── scripts/  (1 files)
```

## 文档

- `AGENTS.md`
- `DESIGN.md`
- `README.md`

## 源码地图

### Sources/
- `main.swift` —— 本可执行文件所属的 .app 路径（命令行直接执行 Contents/MacOS/Preannounce 时也能解析） （符号：homeURL、stateDirURL、socketPath、launchAgentPath、appBundlePath、binaryPath、argValue、Diagnostics、BannerPanel、installTracking、fadeOutThenClose、animatePanel、tween、insetCentered、easeOut）

### integrations/
- `pi-bash-guard.ts` —— 预告守卫（Preannounce Guard）—— Pi 全局扩展 作用：拦住那些会打扰用户的 shell 命令，在执行前先让「预告」刘海 toast 倒数 3 秒。 为什么需要它：AI 可能忘记先问用户，这类命令一旦执行，用户的前台就被抢了 —— 这是机械兜底。 安装：把本文件 （符号：BIN、MODE、MAX_MESSAGE、MUTATING_WEBRIDGE_ACTIONS、INTERACTIVE_CAPTURE、clip、describeOpenTarget、detect、runAnnounce、preannounceGuard）
- `patch-pi-computer-use.sh` —— 给 pi-computer-use 打「预告」集成补丁：真实 HID 投递前先弹刘海倒数 toast。

### scripts/
- `build.sh` —— 预告（Preannounce）一键构建：编译 → 组装 .app → ad-hoc 签名 产物：dist/预告.app
