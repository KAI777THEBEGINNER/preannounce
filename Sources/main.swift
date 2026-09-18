import Foundation
import Darwin

#if !DAEMON
import AppKit
import CoreImage
import CoreGraphics
#endif

// MARK: - 常量

private let kVersion = "1.0.0"
private let kDefaultSeconds = 3
private let kDefaultGraceMs = 2500
private let kDefaultTimeoutMs = 8000
private let kMaxSeconds = 10
private let kPanelHeight: CGFloat = 48
private let kIconOpticalOffsetY: CGFloat = 0.5   // × 的光学补偿：文字墨迹中心比行框中线低 0.4pt，把叉也对齐到那儿
private let kGlowRadius: CGFloat = 260          // 「奔赴刘海」感应区半径（以刘海中心为圆心）
private let kGlowFalloff: Double = 1.7          // 光晕随距离的衰减曲线（越大越集中在近处）
private let kPanelGap: CGFloat = 8            // 距菜单栏（刘海）下沿的间隙
private let kSlideIn: TimeInterval = 0.35
private let kSlideOut: TimeInterval = 0.4
private let kStateDirName = "CursorGuardState" // 见下方 stateDirURL 注释
private let kLaunchAgentLabel = "com.kai.preannounce"
private let kNotifyNotification = "com.kai.preannounce.ping"

private func homeURL() -> URL { FileManager.default.homeDirectoryForCurrentUser }

private func stateDirURL() -> URL {
    homeURL().appendingPathComponent("Library/Application Support/Preannounce", isDirectory: true)
}

private func socketPath() -> String {
    homeURL().appendingPathComponent("Library/Caches/preannounce/guard.sock").path
}

private func launchAgentPath() -> String {
    homeURL().appendingPathComponent("Library/LaunchAgents/\(kLaunchAgentLabel).plist").path
}

/// 本可执行文件所属的 .app 路径（命令行直接执行 Contents/MacOS/Preannounce 时也能解析）
private func appBundlePath() -> String {
    let bundle = Bundle.main.bundlePath
    if bundle.hasSuffix(".app") { return bundle }
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    if dir.lastPathComponent == "MacOS" { dir = dir.deletingLastPathComponent().deletingLastPathComponent() }
    return dir.path
}

private func binaryPath() -> String {
    URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
}

#if !DAEMON
/// 刘海宽度：屏幕总宽减去刘海左右两侧的辅助区域。无刘海屏返回一个保守上限。
private func notchWidth(for screen: NSScreen) -> CGFloat {
    if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
       left.width > 0, right.width > 0 {
        let notch = screen.frame.width - left.width - right.width
        if notch > 60 { return notch }
    }
    return 320
}
#endif

private func argValue(_ args: [String], _ name: String) -> String? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
    return args[index + 1]
}

// MARK: - 诊断日志（JSONL）

enum Diagnostics {
    static let iso = ISO8601DateFormatter()
    static let logURL = stateDirURL().appendingPathComponent("events.jsonl")
    private static let maxBytes = 1 << 20
    private static let queue = DispatchQueue(label: "preannounce.diagnostics")

    static func log(_ dict: [String: Any]) {
        queue.async {
            var payload = dict
            payload["ts"] = iso.string(from: Date())
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            try? FileManager.default.createDirectory(at: stateDirURL(), withIntermediateDirectories: true)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
               let size = attrs[.size] as? Int, size > maxBytes {
                try? FileManager.default.removeItem(at: logURL)
            }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: logURL)
            }
        }
    }
}

#if !DAEMON

// MARK: - 刘海胶囊 toast（动画技术继承自「褪黑素」）

/// 可点击关闭的胶囊面板
final class BannerPanel: NSPanel {
    fileprivate var fadeTimer: Timer?
    /// 点按胶囊 = 取消这次预告（调用方必须放弃那个动作）
    var onCancel: (() -> Void)?
    /// 鼠标进入／离开胶囊
    var onHover: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) { onCancel?() }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    /// 非激活面板也要收到 hover：activeAlways + inVisibleRect
    func installTracking() {
        guard let content = contentView else { return }
        content.addTrackingArea(NSTrackingArea(rect: .zero,
                                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                               owner: self, userInfo: nil))
    }

    func fadeOutThenClose() {
        fadeTimer?.invalidate()
        fadeTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.alphaValue -= 0.15
            if self.alphaValue <= 0 {
                t.invalidate()
                self.close()
            }
        }
        RunLoop.main.add(fadeTimer!, forMode: .common)
    }
}

/// 手动逐帧驱动窗口动画：NSWindow.animator() 在 LSUIElement 非激活窗口上不执行，
/// 必须显式 timer 每帧设置位置与透明度。可同步驱动高斯模糊渐变。
private func animatePanel(_ panel: NSPanel, toX: CGFloat, toY: CGFloat,
                          duration: TimeInterval,
                          easing: @escaping (Double) -> Double = { $0 },
                          blur: CIFilter? = nil, blurFrom: CGFloat = 0, blurTo: CGFloat = 0,
                          completion: (() -> Void)? = nil) {
    let startX = panel.frame.origin.x
    let startY = panel.frame.origin.y
    let startAlpha = panel.alphaValue
    let t0 = ProcessInfo.processInfo.systemUptime
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { t in
        let p = min((ProcessInfo.processInfo.systemUptime - t0) / duration, 1.0)
        let e = easing(p)
        panel.setFrameOrigin(NSPoint(x: startX + (toX - startX) * e, y: startY + (toY - startY) * e))
        panel.alphaValue = startAlpha + (1 - startAlpha) * e
        if let blur { blur.setValue(blurFrom + (blurTo - blurFrom) * e, forKey: kCIInputRadiusKey) }
        if p >= 1.0 {
            t.invalidate()
            completion?()
        }
    }
    timer.tolerance = 0.005
    RunLoop.main.add(timer, forMode: .common)
}

/// 通用补间（逐帧驱动，和 animatePanel 同源）
private func tween(duration: TimeInterval, easing: @escaping (Double) -> Double = easeOut,
                   step: @escaping (Double) -> Void, completion: (() -> Void)? = nil) {
    let t0 = ProcessInfo.processInfo.systemUptime
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { t in
        let p = min((ProcessInfo.processInfo.systemUptime - t0) / max(duration, 0.001), 1.0)
        step(easing(p))
        if p >= 1.0 {
            t.invalidate()
            completion?()
        }
    }
    timer.tolerance = 0.005
    RunLoop.main.add(timer, forMode: .common)
}

/// 以中心为基准向内缩进 fraction（0.03 = 缩 3%）
private func insetCentered(_ rect: NSRect, fraction: CGFloat) -> NSRect {
    rect.insetBy(dx: rect.width * fraction / 2, dy: rect.height * fraction / 2)
}

private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
private func easeIn(_ t: Double) -> Double { t * t * t }

/// 预告的三种结局
enum AnnounceOutcome {
    case shown          // 已倒计时告知，调用方可以动手
    case graceSkipped   // 刚预告过，同一动作会话内直接放行
    case cancelled      // 用户点按胶囊取消了这次操作，调用方必须放弃
}

/// 胶囊内光晕：越靠近刘海越亮的一圈内缘光 + 顶部径向晕。
/// 画在文本下面，不挡字；最亮也只有 0.3 左右的透明度（用户要求「别太亮」）。
final class InnerGlowView: NSView {
    var level: CGFloat = 0 {
        didSet { if abs(level - oldValue) > 0.004 { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard level > 0.01, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        ctx.saveGState()
        capsule.addClip()

        // 顶部中点是离刘海最近的位置，光从这里铺开
        let center = CGPoint(x: bounds.midX, y: bounds.maxY)
        let colors = [NSColor(calibratedWhite: 1.0, alpha: 0.20 * level).cgColor,
                      NSColor(calibratedWhite: 1.0, alpha: 0.0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: bounds.height * 1.7, options: [])
        }

        // 内缘一圈光：描边取内半边，被 clip 掉外半边
        capsule.lineWidth = 6
        NSColor(calibratedWhite: 1.0, alpha: 0.30 * level).setStroke()
        capsule.stroke()

        ctx.restoreGState()
    }
}

/// 一次等待放行的调用方
private final class Waiter {
    let completion: (_ outcome: AnnounceOutcome, _ coalesced: Bool) -> Void
    var coalesced = false
    init(_ completion: @escaping (_ outcome: AnnounceOutcome, _ coalesced: Bool) -> Void) {
        self.completion = completion
    }
}

/// 一轮正在进行的预告（倒计时途中到达的请求挂在 waiters 上，等这一轮结束一起放行）
private final class Countdown {
    let panel: BannerPanel
    let label: NSTextField
    let blur: CIFilter
    let message: String
    let originX: CGFloat
    let targetY: CGFloat
    let offTop: CGFloat
    let pill: NSView              // 玻璃本体：按下时缩放它
    let overlay: NSView           // 按下时变暗层
    let icon: NSImageView         // hover 时替换文本的 × 图标
    let glow: InnerGlowView       // 靠近刘海时亮起的内光晕
    let container: NSView         // 承载文字/叉/光晕/变暗层，随胶囊一起缩
    let fullFrame: NSRect
    var waiters: [Waiter] = []
    var timer: Timer?
    var remaining: Int
    var elapsedInSecond: TimeInterval = 0
    var paused = false
    var hovering = false
    var pressing = false
    var glowLevel: CGFloat = 0
    var approachSamples: [CGFloat] = []
    var proximityTick = 0
    var approaching = false

    init(panel: BannerPanel, label: NSTextField, blur: CIFilter, message: String,
         originX: CGFloat, targetY: CGFloat, offTop: CGFloat, seconds: Int,
         pill: NSView, overlay: NSView, icon: NSImageView, glow: InnerGlowView,
         container: NSView, fullFrame: NSRect) {
        self.panel = panel
        self.label = label
        self.blur = blur
        self.message = message
        self.originX = originX
        self.targetY = targetY
        self.offTop = offTop
        self.remaining = seconds
        self.pill = pill
        self.overlay = overlay
        self.icon = icon
        self.glow = glow
        self.container = container
        self.fullFrame = fullFrame
    }

    func text(for remaining: Int) -> String {
        message.replacingOccurrences(of: "{n}", with: "\(remaining)")
    }
}

/// 刘海胶囊的调度中心。全部在主线程调用，不做并发隔离（Timer / NSPanel 都要求主线程）。
final class ToastCenter {
    static let shared = ToastCenter()

    private var active: Countdown?
    private var lastFinishedAt: Date?

    /// 请求一次预告。completion 在主线程回调；shown=false 表示 grace 窗口内直接放行。
    func announce(message: String, seconds: Int, graceMs: Int,
                  completion: @escaping (_ outcome: AnnounceOutcome, _ coalesced: Bool) -> Void) {
        if let last = lastFinishedAt, Date().timeIntervalSince(last) * 1000 < Double(graceMs) {
            Diagnostics.log(["event": "announce", "result": "grace-skip", "graceMs": graceMs, "message": message])
            completion(.graceSkipped, false)
            return
        }
        if let current = active {
            let waiter = Waiter(completion)
            waiter.coalesced = true
            current.waiters.append(waiter)
            Diagnostics.log(["event": "announce", "result": "coalesced", "remaining": current.remaining,
                             "message": message])
            return
        }
        let countdown = build(message: message, seconds: seconds)
        countdown.waiters.append(Waiter(completion))
        active = countdown
        Diagnostics.log(["event": "announce", "result": "countdown-start", "seconds": seconds, "message": message])
        start(countdown)
    }

    /// 是否有正在进行的预告（cancel 命令用）
    var hasActive: Bool { active != nil }

    /// 用户点按胶囊 → 取消正在进行中的预告，等待中的调用方一律被拒
    func cancelActive() {
        guard let current = active else { return }
        Diagnostics.log(["event": "cancel", "message": current.message, "waiters": current.waiters.count])
        finish(current, outcome: .cancelled)
    }

    /// 守护通过 SIGTERM 取消正在进行的预告（socket 的 cancel 命令走这条路）
    func cancelFromSignal() {
        if active != nil {
            cancelActive()
        } else {
            exit(4)
        }
    }

    /// 手动打开 app / 二次双击时的就绪提示（不倒数，不阻塞任何调用方）
    func flash(message: String, seconds: Double = 2.5) {
        let countdown = build(message: message, seconds: 0)
        let panel = countdown.panel
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        animatePanel(panel, toX: countdown.originX, toY: countdown.targetY, duration: kSlideIn,
                     easing: easeOut, blur: countdown.blur, blurFrom: 6, blurTo: 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                animatePanel(panel, toX: countdown.originX, toY: countdown.offTop, duration: kSlideOut,
                             easing: easeIn, blur: countdown.blur, blurFrom: 0, blurTo: 6) { panel.close() }
            }
        }
    }

    // MARK: 内部

    private func build(message: String, seconds: Int) -> Countdown {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        var pill: NSView!
        let probeFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        var widest: CGFloat = 0
        let widthTemplate = message
        for n in [seconds, 1] where n > 0 {
            let sample = NSTextField(labelWithString: widthTemplate.replacingOccurrences(of: "{n}", with: "\(n)"))
            sample.font = probeFont
            sample.sizeToFit()
            widest = max(widest, sample.frame.width)
        }
        if widest == 0 {
            let sample = NSTextField(labelWithString: widthTemplate)
            sample.font = probeFont
            sample.sizeToFit()
            widest = sample.frame.width
        }
        // 胶囊宽度绝不超出刘海：按文字自适应，但封顶到刘海宽（这是用户明确要求的形态）
        let notch = notchWidth(for: screen)
        let natural = widest + 64
        let width = max(120, min(natural, notch))
        let textLimit = width - 40
        let x = screen.frame.midX - width / 2
        let targetY = screen.visibleFrame.maxY - kPanelHeight - kPanelGap
        let offTop = screen.visibleFrame.maxY + kPanelHeight

        let panel = BannerPanel(contentRect: NSRect(x: x, y: offTop, width: width, height: kPanelHeight),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.onCancel = { [weak self] in self?.cancelActive() }

        let displayTemplate = message
        let label = NSTextField(labelWithString: seconds > 0
                                ? displayTemplate.replacingOccurrences(of: "{n}", with: "\(seconds)")
                                : displayTemplate)
        label.font = probeFont
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.sizeToFit()
        if label.frame.width > textLimit {  // 文案过长则尾部省略，绝不撑破胶囊
            label.frame.size.width = textLimit
        }
        label.wantsLayer = true
        // 高斯模糊必须加在 label 层：加在容器层不生效（玻璃渲染管线不走容器层合成）
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.setDefaults()
        blur.setValue(0, forKey: kCIInputRadiusKey)
        label.layer?.filters = [blur]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: kPanelHeight))
        label.frame.origin = NSPoint(x: (width - label.frame.width) / 2,
                                     y: (kPanelHeight - label.frame.height) / 2)

        let glow = InnerGlowView(frame: container.bounds)
        glow.autoresizingMask = [.width, .height]
        container.addSubview(glow)   // 先加：光晕在文字之下，不糊字
        container.addSubview(label)

        // hover 时替换文本的 × 图标（同一个胶囊、同一个点击区，没有额外热区）
        let icon = NSImageView(frame: NSRect(x: (width - 22) / 2,
                                             y: (kPanelHeight - 22) / 2 - kIconOpticalOffsetY,
                                             width: 22, height: 22))
        let symbol = NSImage(systemSymbolName: "xmark", accessibilityDescription: "取消")
            ?? NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "取消")
        icon.image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyDown
        icon.isHidden = true
        container.addSubview(icon)

        // 按下时变暗层（与胶囊同形状）
        let overlay = NSView(frame: container.bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.cgColor
        overlay.layer?.cornerRadius = kPanelHeight / 2
        overlay.layer?.masksToBounds = true
        overlay.alphaValue = 0
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: width, height: kPanelHeight))
            glass.cornerRadius = kPanelHeight / 2
            glass.style = .clear
            glass.tintColor = NSColor(calibratedWhite: 1.0, alpha: 0.02)
            glass.contentView = container // 玻璃必须包裹全尺寸透明容器，只包 label 会变成细条
            panel.contentView = glass
            pill = glass
        } else {
            let visual = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: kPanelHeight))
            visual.material = .hudWindow
            visual.blendingMode = .behindWindow
            visual.state = .active
            visual.wantsLayer = true
            visual.layer?.cornerRadius = kPanelHeight / 2
            visual.layer?.masksToBounds = true
            visual.addSubview(container)
            panel.contentView = visual
            pill = visual
        }
        panel.installTracking()
        return Countdown(panel: panel, label: label, blur: blur, message: message,
                         originX: x, targetY: targetY, offTop: offTop, seconds: seconds,
                         pill: pill, overlay: overlay, icon: icon, glow: glow, container: container,
                         fullFrame: NSRect(x: 0, y: 0, width: width, height: kPanelHeight))
    }

    private func start(_ countdown: Countdown) {
        let panel = countdown.panel
        panel.onCancel = { [weak self, weak countdown] in
            guard let self, let countdown else { return }
            self.pressAndCancel(countdown)
        }
        panel.onHover = { [weak self, weak countdown] hovering in
            guard let self, let countdown else { return }
            self.setHover(countdown, hovering: hovering)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless() // 不抢前台焦点
        animatePanel(panel, toX: countdown.originX, toY: countdown.targetY, duration: kSlideIn,
                     easing: easeOut, blur: countdown.blur, blurFrom: 6, blurTo: 0) {
            if countdown.remaining <= 0 {
                self.finish(countdown, outcome: .shown) // seconds = 0：只闪一下，不倒计时
                return
            }
            self.startHeartbeat(countdown)
        }
    }

    /// 心跳每 50ms 累加；每满一秒换一次数字，hover 期间不累加（暂停）
    private func startHeartbeat(_ countdown: Countdown) {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.heartbeat(countdown)
        }
        countdown.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func heartbeat(_ countdown: Countdown) {
        guard active === countdown else { return }
        updateProximity(countdown)                       // 光晕与「奔赴刘海」趋势，暂停时也要持续更新
        guard !countdown.hovering, !countdown.approaching else { return }
        countdown.elapsedInSecond += 0.05
        guard countdown.elapsedInSecond >= 1.0 else { return }
        countdown.elapsedInSecond = 0
        countdown.remaining -= 1
        if countdown.remaining <= 0 {
            finish(countdown, outcome: .shown)
            return
        }
        updateLabel(countdown)
    }

    /// 光晕亮度 = 鼠标到刘海中心的距离映射；持续变亮（越来越亮）= 用户在奔赴刘海 → 提前暂停倒计时
    private func updateProximity(_ countdown: Countdown) {
        guard let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        let center = CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
        let distance = hypot(mouse.x - center.x, mouse.y - center.y)
        let closeness = max(0, min(1, 1 - distance / kGlowRadius))
        let target = CGFloat(pow(Double(closeness), kGlowFalloff))

        // 亮起快、暗下慢，避免抖动
        let attack: CGFloat = target > countdown.glowLevel ? 0.45 : 0.10
        countdown.glowLevel += (target - countdown.glowLevel) * attack
        countdown.glow.level = countdown.glowLevel

        countdown.proximityTick += 1
        if countdown.proximityTick % 10 == 0 {   // 每 0.5 秒记一行，便于回看与调参
            Diagnostics.log(["event": "proximity", "level": Double(countdown.glowLevel),
                             "distance": Double(distance), "approaching": countdown.approaching,
                             "remaining": countdown.remaining])
        }

        // 最近 5 次采样（约 250ms）持续不降且涨幅够大 → 判定为「趋势」，不是偶然掠过
        countdown.approachSamples.append(countdown.glowLevel)
        if countdown.approachSamples.count > 5 { countdown.approachSamples.removeFirst() }
        let samples = countdown.approachSamples
        let rising = samples.count >= 5
            && zip(samples, samples.dropFirst()).allSatisfy { $1 >= $0 - 0.002 }
            && (samples.last! - samples.first!) > 0.12
            && samples.last! > 0.15
        if rising && !countdown.approaching {
            countdown.approaching = true
            Diagnostics.log(["event": "approach-pause", "level": Double(samples.last!)])
        } else if countdown.approaching && countdown.glowLevel < 0.08 {
            // 只是亮一下又暗下去 → 判定之前是误识别，继续倒计时
            countdown.approaching = false
            Diagnostics.log(["event": "approach-resume", "level": Double(countdown.glowLevel)])
        }
    }

    private func updateLabel(_ countdown: Countdown) {
        guard !countdown.hovering else { return } // hover 时显示的是 ×，别覆盖
        countdown.label.stringValue = countdown.text(for: countdown.remaining)
        countdown.label.sizeToFit()
        countdown.label.frame.origin.x = (countdown.panel.frame.width - countdown.label.frame.width) / 2
    }

    /// hover 进入：文本换成 × 并且倒计时暂停（用户在犹豫要不要取消）；离开：还原文本、继续倒数
    private func setHover(_ countdown: Countdown, hovering: Bool) {
        guard active === countdown, countdown.hovering != hovering else { return }
        countdown.hovering = hovering
        countdown.paused = hovering
        if hovering {
            countdown.label.isHidden = true
            countdown.icon.isHidden = false
            countdown.icon.alphaValue = 0
            tween(duration: 0.12) { p in countdown.icon.alphaValue = p }
        } else {
            countdown.label.isHidden = false
            countdown.icon.isHidden = true
            updateLabel(countdown)
        }
        Diagnostics.log(["event": hovering ? "hover-pause" : "hover-resume",
                         "remaining": countdown.remaining, "message": countdown.message])
    }

    /// 按下：先给可见的按压反馈（缩放 + 变暗），再取消
    private func pressAndCancel(_ countdown: Countdown) {
        guard active === countdown, !countdown.pressing else { return }
        countdown.pressing = true
        countdown.paused = true
        Diagnostics.log(["event": "press-cancel", "remaining": countdown.remaining, "message": countdown.message])
        tween(duration: 0.12) { p in
            let shrunk = insetCentered(countdown.fullFrame, fraction: 0.05 * p)
            countdown.pill.frame = shrunk
            // 内容容器跟着缩，并按缩后的宽度重新居中——否则叉会相对中心偏左
            countdown.container.frame = NSRect(origin: .zero, size: shrunk.size)
            countdown.icon.frame.origin.x = (shrunk.width - countdown.icon.frame.width) / 2
            countdown.icon.frame.origin.y = (shrunk.height - countdown.icon.frame.height) / 2 - kIconOpticalOffsetY
            countdown.label.frame.origin.x = (shrunk.width - countdown.label.frame.width) / 2
            countdown.overlay.alphaValue = 0.24 * p
        } completion: {
            // 记下按到底那一刻的实际几何：叉距中心应≈0
            Diagnostics.log(["event": "press-frame",
                             "pillWidth": Double(countdown.pill.frame.width),
                             "containerWidth": Double(countdown.container.frame.width),
                             "iconOffsetFromCenter": Double(countdown.icon.frame.midX - countdown.pill.frame.width / 2),
                             "iconOffsetY": Double(countdown.icon.frame.midY - countdown.container.frame.height / 2),
                             "labelOffsetFromCenter": Double(countdown.label.frame.midX - countdown.pill.frame.width / 2)])
            self.finish(countdown, outcome: .cancelled)
        }
    }

    private func finish(_ countdown: Countdown, outcome: AnnounceOutcome) {
        countdown.timer?.invalidate()
        countdown.timer = nil
        countdown.paused = false
        countdown.hovering = false
        active = nil
        // 被取消后不留 grace：下一次必须重新老老实实预告
        lastFinishedAt = outcome == .shown ? Date() : nil
        countdown.panel.onCancel = nil
        let waiters = countdown.waiters
        countdown.waiters.removeAll()
        let outcomeLabel: String
        switch outcome {
        case .cancelled: outcomeLabel = "cancelled-by-click"
        case .shown: outcomeLabel = "shown"
        case .graceSkipped: outcomeLabel = "grace"
        }
        Diagnostics.log(["event": "countdown-done", "waiters": waiters.count, "outcome": outcomeLabel])
        for waiter in waiters { waiter.completion(outcome, waiter.coalesced) }
        animatePanel(countdown.panel, toX: countdown.originX, toY: countdown.offTop, duration: kSlideOut,
                     easing: easeIn, blur: countdown.blur, blurFrom: 0, blurTo: 6) {
            countdown.panel.close()
        }
    }
}

// MARK: - GUI 进程入口（toast / banner）

/// 弹一次倒数胶囊，结局写进退出码：0=已告知 4=用户取消 3=失败
private func runToast(_ args: [String]) -> Never {
    let message = argValue(args, "--message") ?? "{n} 秒之后将继续操作"
    let seconds = min(max(Int(argValue(args, "--seconds") ?? "") ?? kDefaultSeconds, 0), kMaxSeconds)
    let source = argValue(args, "--source") ?? "toast"

    // 守护的 cancel 命令 = 给本进程发 SIGTERM：走正常取消路径（有退场动画）后以 4 退出
    signal(SIGTERM, SIG_IGN)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    signalSource.setEventHandler { ToastCenter.shared.cancelFromSignal() }
    signalSource.resume()

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Diagnostics.log(["event": "toast-start", "seconds": seconds, "source": source, "message": message])
    ToastCenter.shared.announce(message: message, seconds: seconds, graceMs: 0) { outcome, _ in
        let code: Int32 = outcome == .shown ? 0 : (outcome == .cancelled ? 4 : 3)
        // 等退场动画播完再退，别把胶囊砍断
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { exit(code) }
    }
    application.run()
    exit(3)
}

/// 就绪横幅（双击打开 / 二次双击 / 守护已在跑时的打招呼），不参与任何倒数
private func runBanner(_ args: [String]) -> Never {
    let message = argValue(args, "--message") ?? "预告已在后台守候"
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    ToastCenter.shared.flash(message: message, seconds: 2.6)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { exit(0) }
    application.run()
    exit(0)
}

#endif

#if DAEMON

// MARK: - 预告宿主：把一次预告变成「拉起 toast 子进程 + 等它结束」

/// 常驻守护不链接 AppKit（实测物理占用 1.8MB vs AppKit 进程 15MB）。
/// 每次预告临时拉起 GUI 子进程，子进程退出码即结局：0=已告知 4=用户取消 其他=失败。
/// 子进程冷启动的 ~200ms 藏在倒数之前：用户看到的仍是完整的 N 秒倒数。
final class ToastHost {
    private final class Waiter {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome = "failed"
    }

    private let lock = NSLock()
    private var child: Process?
    private var waiters: [Waiter] = []
    private var lastFinishedAt: Date?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return child != nil
    }

    /// 阻塞直到有结论。返回：shown / grace / cancelled / failed
    func announce(message: String, seconds: Int, graceMs: Int, source: String) -> String {
        lock.lock()
        if child == nil, let last = lastFinishedAt,
           Date().timeIntervalSince(last) * 1000 < Double(graceMs) {
            lock.unlock()
            Diagnostics.log(["event": "announce", "result": "grace-skip", "graceMs": graceMs,
                             "source": source, "message": message])
            return "grace"
        }
        let coalesced = child != nil
        let waiter = Waiter()
        waiters.append(waiter)
        let shouldSpawn = !coalesced
        lock.unlock()

        Diagnostics.log(["event": "announce", "result": coalesced ? "coalesced" : "toast-spawn",
                         "seconds": seconds, "source": source, "message": message])
        if shouldSpawn { spawnToast(message: message, seconds: seconds, source: source) }

        _ = waiter.semaphore.wait(timeout: .now() + 900)
        return waiter.outcome
    }

    /// 让正在跑的 toast 走取消流程（子进程收到 SIGTERM 会播完退场动画并以 4 退出）
    func cancelRunningToast() -> Bool {
        lock.lock()
        let running = child
        lock.unlock()
        guard let running, running.isRunning else { return false }
        Diagnostics.log(["event": "cancel", "via": "signal"])
        running.terminate()
        return true
    }

    private func spawnToast(message: String, seconds: Int, source: String) {
        let toast = URL(fileURLWithPath: binaryPath()).deletingLastPathComponent()
            .appendingPathComponent("PreannounceToast")
        guard FileManager.default.isExecutableFile(atPath: toast.path) else {
            Diagnostics.log(["event": "toast-spawn", "result": "binary-missing", "path": toast.path])
            finish(outcome: "failed")
            return
        }
        let process = Process()
        process.executableURL = toast
        process.arguments = ["toast", "--message", message, "--seconds", "\(seconds)", "--source", source]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let outcome: String
            if finished.terminationReason == .uncaughtSignal {
                // 被信号杀死一律算失败：SIGILL 的编号正好是 4，若按退出码映射会误报成「用户取消」
                outcome = "failed"
            } else {
                switch finished.terminationStatus {
                case 0: outcome = "shown"
                case 4: outcome = "cancelled"
                default: outcome = "failed"
                }
            }
            self?.finish(outcome: outcome)
        }
        lock.lock()
        child = process
        lock.unlock()
        do {
            try process.run()
        } catch {
            Diagnostics.log(["event": "toast-spawn", "result": "failed", "error": error.localizedDescription])
            lock.lock()
            child = nil
            lock.unlock()
            finish(outcome: "failed")
        }
    }

    private func finish(outcome: String) {
        lock.lock()
        child = nil
        // 被取消／失败不留 grace：下一次必须重新老老实实预告
        lastFinishedAt = outcome == "shown" ? Date() : nil
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        Diagnostics.log(["event": "toast-finished", "outcome": outcome, "waiters": pending.count])
        for waiter in pending {
            waiter.outcome = outcome
            waiter.semaphore.signal()
        }
    }
}

// MARK: - Unix socket 服务

final class GuardServer {
    private let path: String
    private let host = ToastHost()
    private var listenFD: Int32 = -1

    init(path: String) { self.path = path }

    func start() {
        guard let fd = makeListener() else {
            Diagnostics.log(["event": "server", "result": "listen-failed", "path": path])
            return
        }
        listenFD = fd
        Diagnostics.log(["event": "server", "result": "listening", "path": path, "pid": Int(getpid())])
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    private func makeListener() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        unlink(path) // 清掉陈旧 socket 文件
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else {
            close(fd)
            return nil
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                strncpy(destination, path, capacity - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            var clientAddr = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
            }
            if client < 0 {
                usleep(50_000)
                continue
            }
            Thread.detachNewThread { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ fd: Int32) {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65_536 {
            let read = recv(fd, &buffer, buffer.count, 0)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
            if data.contains(UInt8(ascii: "\n")) { break }
        }

        guard let raw = String(data: data, encoding: .utf8),
              let line = raw.split(separator: "\n").first,
              let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            respond(fd, ["ok": false, "error": "bad request"])
            return
        }

        let id = (json["id"] as? String) ?? ""
        switch (json["cmd"] as? String) ?? "" {
        case "ping":
            respond(fd, ["ok": true, "id": id, "pid": Int(getpid()), "version": kVersion, "message": "pong"])

        case "announce":
            let message = ((json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "{n} 秒之后将继续操作"
            let seconds = min(max((json["seconds"] as? Int) ?? kDefaultSeconds, 0), kMaxSeconds)
            let graceMs = max((json["graceMs"] as? Int) ?? kDefaultGraceMs, 0)
            let source = (json["source"] as? String) ?? "unknown"
            let coalesced = host.isRunning
            // 阻塞本连接线程直到有结论（每个连接一个线程，阻塞是安全的）
            let outcome = host.announce(message: message, seconds: seconds, graceMs: graceMs, source: source)
            Diagnostics.log(["event": "announce-done", "source": source, "outcome": outcome, "message": message])
            switch outcome {
            case "cancelled":
                // 用户取消：调用方必须放弃这个动作
                self.respond(fd, ["ok": false, "id": id, "cancelled": true, "error": "用户取消了这次操作"])
            case "grace":
                self.respond(fd, ["ok": true, "id": id, "shown": false, "reason": "grace", "coalesced": coalesced])
            case "shown":
                self.respond(fd, ["ok": true, "id": id, "shown": true, "coalesced": coalesced])
            default:
                self.respond(fd, ["ok": false, "id": id, "error": "预告窗口启动失败"])
            }

        case "cancel":
            self.respond(fd, ["ok": true, "id": id, "cancelled": host.cancelRunningToast()])

        case "shutdown":
            respond(fd, ["ok": true, "id": id])
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }

        default:
            respond(fd, ["ok": false, "id": id, "error": "unknown command"])
        }
    }

    private func respond(_ fd: Int32, _ object: [String: Any]) {
        defer { close(fd) }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        _ = payload.withUnsafeBytes { pointer -> Int in
            var written = 0
            while written < payload.count {
                let n = write(fd, pointer.baseAddress!.advanced(by: written), payload.count - written)
                if n <= 0 { break }
                written += n
            }
            return written
        }
    }
}

// MARK: - 单实例锁 + LaunchAgent

private var instanceLockFD: Int32 = -1

private func lockURL() -> URL {
    try? FileManager.default.createDirectory(at: stateDirURL(), withIntermediateDirectories: true)
    return stateDirURL().appendingPathComponent("preannounce.lock")
}

private func acquireSingleInstanceLock() -> Bool {
    let path = lockURL().path
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    let fd = open(path, O_RDWR)
    guard fd >= 0 else { return false }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        instanceLockFD = fd
        return true
    }
    close(fd)
    return false
}

private func acquireSingleInstanceLockBlocking() {
    let path = lockURL().path
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    let fd = open(path, O_RDWR)
    guard fd >= 0 else { exit(1) }
    if flock(fd, LOCK_EX) != 0 { exit(1) }
    instanceLockFD = fd
}

private func installLaunchAgent() -> Bool {
    let binary = binaryPath()
    let plist: [String: Any] = [
        "Label": kLaunchAgentLabel,
        "ProgramArguments": [binary, "autostart"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "ProcessType": "Interactive",
    ]
    guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
        return false
    }
    let path = launchAgentPath()
    if let existing = try? Data(contentsOf: URL(fileURLWithPath: path)), existing == data { return true }
    do {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        Diagnostics.log(["event": "launchagent", "result": "write-failed", "error": String(describing: error)])
        return false
    }
    for arguments in [["bootout", "gui/\(getuid())/\(kLaunchAgentLabel)"],
                      ["bootstrap", "gui/\(getuid())", path]] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
    Diagnostics.log(["event": "launchagent", "result": "installed", "path": path])
    return true
}

// MARK: - 命令行客户端

private func connectSocket(timeoutMs: Int) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    var timeout = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    let path = socketPath()
    guard path.utf8.count < capacity else { close(fd); return -1 }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
            strncpy(destination, path, capacity - 1)
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
    }
    guard result == 0 else { close(fd); return -1 }
    return fd
}

/// 拉起 GUI 二进制（就绪横幅等一次性提示）
private func spawnToastBinary(_ arguments: [String]) {
    let toast = URL(fileURLWithPath: binaryPath()).deletingLastPathComponent()
        .appendingPathComponent("PreannounceToast")
    guard FileManager.default.isExecutableFile(atPath: toast.path) else { return }
    let process = Process()
    process.executableURL = toast
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

private func launchDaemon() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: binaryPath())
    task.arguments = ["autostart"]
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
}

private func exchange(fd: Int32, request: [String: Any], timeoutMs: Int) -> [String: Any]? {
    guard var payload = try? JSONSerialization.data(withJSONObject: request) else { return nil }
    payload.append(UInt8(ascii: "\n"))
    let sent = payload.withUnsafeBytes { pointer -> Int in
        write(fd, pointer.baseAddress!, payload.count)
    }
    guard sent == payload.count else { return nil }

    var timeout = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count < 65_536 {
        let read = recv(fd, &buffer, buffer.count, 0)
        if read <= 0 { break }
        data.append(contentsOf: buffer[0..<read])
        if data.contains(UInt8(ascii: "\n")) { break }
    }
    guard let raw = String(data: data, encoding: .utf8),
          let line = raw.split(separator: "\n").first,
          let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
    return json
}

private func runAnnounce(_ args: [String]) -> Int32 {
    let message = argValue(args, "--message") ?? "{n} 秒之后将继续操作"
    let seconds = min(max(Int(argValue(args, "--seconds") ?? "") ?? kDefaultSeconds, 0), kMaxSeconds)
    let graceMs = max(Int(argValue(args, "--grace-ms") ?? "") ?? kDefaultGraceMs, 0)
    // hover 暂停没有上限，超时不能卡死在几秒：默认 = 倒数时长 + 90 秒
    let defaultTimeout = seconds * 1000 + 90_000
    let timeoutMs = max(Int(argValue(args, "--timeout-ms") ?? "") ?? defaultTimeout, 500)
    let source = argValue(args, "--source") ?? "cli"
    let request: [String: Any] = ["id": UUID().uuidString, "cmd": "announce", "message": message,
                                  "seconds": seconds, "graceMs": graceMs, "source": source]

    var fd = connectSocket(timeoutMs: 3000)
    if fd < 0 {
        launchDaemon() // 守护不在就先拉起来（LaunchAgent 只在登录时启动）
        let deadline = Date().addingTimeInterval(3.0)
        while fd < 0 && Date() < deadline {
            usleep(150_000)
            fd = connectSocket(timeoutMs: 3000)
        }
    }
    guard fd >= 0 else {
        FileHandle.standardError.write(Data("预告失败：守护进程不可用，已放弃该动作。\n".utf8))
        return 3
    }
    defer { close(fd) }
    guard let reply = exchange(fd: fd, request: request, timeoutMs: timeoutMs) else {
        FileHandle.standardError.write(Data("预告失败：等待倒计时回执超时或出错，已放弃该动作。\n".utf8))
        return 3
    }
    if (reply["cancelled"] as? Bool) == true {
        FileHandle.standardError.write(Data("用户取消了这次操作，已放弃该动作。\n".utf8))
        return 4
    }
    return 0
}

private func runDiagnose() -> Int32 {
    let path = Diagnostics.logURL.path
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("预告诊断：还没有任何记录（守护未收到过请求）。日志路径：\(path)")
        return 0
    }
    let lines = content.split(separator: "\n")
    var announces = 0, shown = 0, skipped = 0, coalesced = 0, failed = 0
    var sources: [String: Int] = [:]
    var recent: [String] = []
    for line in lines {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        switch (json["event"] as? String) ?? "" {
        case "announce":
            announces += 1
            let result = (json["result"] as? String) ?? "countdown-start"
            if result == "grace-skip" { skipped += 1 }
            if result == "coalesced" { coalesced += 1 }
            let source = (json["source"] as? String) ?? ((json["result"] as? String) ?? "?")
            let ts = (json["ts"] as? String) ?? ""
            let message = (json["message"] as? String) ?? ""
            recent.append("  \(ts)  [\(source)] \(message)")
            if recent.count > 12 { recent.removeFirst() }
        case "announce-done":
            if (json["shown"] as? Bool) == true { shown += 1 } else { failed += 1 }
            let source = (json["source"] as? String) ?? "unknown"
            sources[source, default: 0] += 1
        default:
            break
        }
    }
    print("""
    预告（Preannounce）诊断
    ─────────────────────────────
    日志：\(path)
    请求总数：\(announces)    真正弹窗预告：\(shown)    grace 跳过：\(skipped)    并发合并：\(coalesced)
    按来源：\(sources.isEmpty ? "无" : sources.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "  "))

    最近请求：
    \(recent.isEmpty ? "  （无）" : recent.joined(separator: "\n"))
    """)
    return 0
}

#endif  // DAEMON 段结束

// MARK: - 进程入口分发（两个二进制各自编译其中一支）

signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())

#if DAEMON

// 常驻守护（不链接 AppKit）：只做 socket 服务 + 拉起 toast 子进程 + CLI 客户端

if arguments.first == "announce" { exit(runAnnounce(arguments)) }
if arguments.first == "diagnose" { exit(runDiagnose()) }

if arguments.first == "autostart" {
    // launchd 守护：拿不到锁就阻塞等待手动实例退出（配合 KeepAlive 自愈）
    acquireSingleInstanceLockBlocking()
} else {
    // 双击打开：无论守护在不在，都先弹一次横幅给反馈
    spawnToastBinary(["banner", "--message", "预告已在后台守候"])
    if !acquireSingleInstanceLock() {
        // 已有守护在跑：打完招呼就退
        Diagnostics.log(["event": "daemon", "result": "already-running"])
        exit(0)
    }
}

_ = installLaunchAgent()
// 必须用顶层常量持有：临时值会在 start() 返回后被释放，
// 连接就在内核 backlog 里排队没人 accept（客户端只表现为超时）
let guardServer = GuardServer(path: socketPath())
guardServer.start()
Diagnostics.log(["event": "daemon", "result": "ready", "pid": Int(getpid())])
RunLoop.main.run()

#else

// GUI 二进制（PreannounceToast）：只做「弹一次胶囊」这一件事，弹完就退出

if arguments.first == "toast" { runToast(arguments) }
runBanner(arguments)

#endif
