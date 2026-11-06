// 仅开发用（Mac）：PASEO_SIDEBAR_BENCH=<点/秒> 启动后把鼠标移到侧栏上，用合成的滚轮事件把侧栏上下滚两遍，
// 打印掉帧数、侧栏 body 重算次数和悬停切换次数。用 Release 优化 + DEBUG 编译才接近日常安装版的手感（见 docs/STATUS.md）。

#if DEBUG
import Foundation
#if os(macOS)
import AppKit
#endif

@MainActor final class SidebarBench: NSObject {
    static var bodyCount = 0
    static var hoverCount = 0
    static var groupCount = 0
    static var rowCount = 0
    #if os(macOS)
    private static var running: SidebarBench?

    static func startIfRequested() {
        FileHandle.standardError.write(Data("SBENCH requested\n".utf8))
        guard running == nil, let v = ProcessInfo.processInfo.environment["PASEO_SIDEBAR_BENCH"], let speed = Double(v) else { return }
        let delay = Double(ProcessInfo.processInfo.environment["PASEO_SIDEBAR_BENCH_DELAY"] ?? "") ?? 10
        let bench = SidebarBench(speed: speed)
        running = bench
        Task {
            try? await Task.sleep(for: .seconds(delay))
            bench.start()
        }
    }

    private let speed: CGFloat
    private var scrollView: NSScrollView?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var direction: CGFloat = 1
    private var legs = 0
    private var frames = 0
    private var dropped = 0
    private var hitchTime: CFTimeInterval = 0
    private var elapsed: CFTimeInterval = 0
    private var worst: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var targets: [Int: Int] = [:]
    private var bodyAtStart = 0
    private var hoverAtStart = 0

    private init(speed: Double) { self.speed = speed }

    private func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    private func start() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
              let root = window.contentView else { log("SBENCH no window"); return }
        var all: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, let doc = s.documentView, doc.frame.height > s.contentView.bounds.height * 1.2 { all.append(s) }
            v.subviews.forEach(walk)
        }
        walk(root)
        // 侧栏：最靠左、宽度不到 500 的可滚动视图
        guard let s = all.filter({ $0.convert($0.bounds, to: nil).minX < 40 && $0.bounds.width < 500 })
            .max(by: { $0.bounds.height < $1.bounds.height }) else { log("SBENCH no sidebar scroll view (\(all.count) candidates)"); return }
        scrollView = s
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 鼠标放到侧栏中间，滚动时分组标题会从鼠标下经过（触发悬停），和真实滚动一样
        let rectInWindow = s.convert(s.bounds, to: nil)
        let onScreen = window.convertToScreen(rectInWindow)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.midX, y: mainHeight - onScreen.midY))
        log("SBENCH start content=\(Int(s.documentView?.frame.height ?? 0)) view=\(Int(s.contentView.bounds.height)) speed=\(Int(speed))")
        bodyAtStart = Self.bodyCount
        hoverAtStart = Self.hoverCount
        let link = s.displayLink(target: self, selector: #selector(tick))
        let maximum = Float(window.screen?.maximumFramesPerSecond ?? 60)
        log("SBENCH displayMax=\(Int(maximum))Hz")
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let s = scrollView else { return }
        let budget = link.targetTimestamp - link.timestamp
        if last > 0 {
            let dt = link.timestamp - last
            frames += 1
            elapsed += dt
            worst = max(worst, dt)
            intervals.append(dt * 1000)
            if budget > 0 { targets[Int((1 / budget).rounded()), default: 0] += 1 }
            if budget > 0, dt > budget * 1.5 {
                dropped += Int((dt / budget).rounded()) - 1
                hitchTime += dt - budget
            }
            let y = s.contentView.bounds.origin.y
            let bottom = max(0, (s.documentView?.frame.height ?? 0) - s.contentView.bounds.height)
            if direction > 0, y >= bottom - 1 { direction = -1; legs += 1 }
            else if direction < 0, y <= 1 { direction = 1; legs += 1 }
            // 合成滚轮事件交给窗口分发（走和真实滚动一样的路径：滚动 + 更新悬停区域）
            let delta = Int32((direction * speed * CGFloat(min(dt, 0.05))).rounded())
            let mouse = NSEvent.mouseLocation
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -delta, wheel2: 0, wheel3: 0) {
                cg.location = CGPoint(x: mouse.x, y: mainHeight - mouse.y)
                if let e = NSEvent(cgEvent: cg) { s.scrollWheel(with: e) }
            }
        }
        last = link.timestamp
        if legs >= 4 { finish() }
    }

    private func finish() {
        link?.invalidate()
        let ms = elapsed > 0 ? hitchTime * 1000 / elapsed : 0
        let sorted = intervals.sorted()
        log("SBENCH callbackFPS=\(elapsed > 0 ? Double(frames) / elapsed : 0) p95ms=\(sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]) targetHz=\(targets)")
        log(String(format: "SBENCH done frames=%d dropped=%d hitch=%.1fms/s worst=%.1fms seconds=%.1f body=%d hover=%d",
                     frames, dropped, ms, worst * 1000, elapsed, Self.bodyCount - bodyAtStart, Self.hoverCount - hoverAtStart))
        Self.running = nil
        if ProcessInfo.processInfo.environment["PASEO_SIDEBAR_BENCH_QUIT"] == "1" { NSApp.terminate(nil) }
    }
    #endif
}
#endif
