// Development only: PASEO_SCROLL_BENCH=<points per second> drives the open session's scroll view up to the top
// and back down twice at that speed and prints how many frames were dropped. Build with Release optimisation
// plus DEBUG (see docs/STATUS.md) to measure what a real install feels like.

#if DEBUG && os(iOS)
import UIKit

@MainActor final class ScrollBench: NSObject {
    private static var started = false

    static func startIfRequested(loadHistory: @escaping () async -> Void) {
        guard !started, let v = ProcessInfo.processInfo.environment["PASEO_SCROLL_BENCH"], let speed = Double(v) else { return }
        let delay = Double(ProcessInfo.processInfo.environment["PASEO_SCROLL_BENCH_DELAY"] ?? "") ?? 12
        started = true
        Task {
            await loadHistory()
            try? await Task.sleep(for: .seconds(delay))
            ScrollBench(speed: speed).start()
        }
    }

    private static var running: ScrollBench?
    private let speed: CGFloat
    private var scrollView: UIScrollView?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var direction: CGFloat = -1
    private var legs = 0
    private var frames = 0
    private var dropped = 0
    private var hitchTime: CFTimeInterval = 0
    private var elapsed: CFTimeInterval = 0
    private var worst: CFTimeInterval = 0
    private var droppedPerLeg = [0, 0, 0, 0, 0]
    /// Frames where the content height changed, and where something other than us moved the offset.
    private var sizeChanges = [0, 0, 0, 0, 0]
    private var offsetJumps = [0, 0, 0, 0, 0]
    private var lastSize: CGFloat = 0
    private var expected: CGFloat?

    private init(speed: Double) { self.speed = speed }

    private func start() {
        // The session timeline: the widest tall scroll view (the sidebar list is narrower).
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var all: [UIScrollView] = []
        func walk(_ v: UIView) {
            if let s = v as? UIScrollView, s.contentSize.height > s.bounds.height * 1.5 { all.append(s) }
            v.subviews.forEach(walk)
        }
        windows.forEach(walk)
        guard let s = all.max(by: { ($0.bounds.width, $0.contentSize.height) < ($1.bounds.width, $1.contentSize.height) }) else {
            print("BENCH no scroll view"); return
        }
        scrollView = s
        print("BENCH start content=\(Int(s.contentSize.height)) view=\(Int(s.bounds.height)) speed=\(Int(speed))")
        Self.running = self
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
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
            if budget > 0, dt > budget * 1.5 {
                dropped += Int((dt / budget).rounded()) - 1
                droppedPerLeg[min(legs, 4)] += Int((dt / budget).rounded()) - 1
                hitchTime += dt - budget
            }
            let leg = min(legs, 4)
            if lastSize > 0, s.contentSize.height != lastSize { sizeChanges[leg] += 1 }
            if let expected, abs(s.contentOffset.y - expected) > 1 { offsetJumps[leg] += 1 }
            lastSize = s.contentSize.height
            let top = -s.adjustedContentInset.top
            let bottom = max(top, s.contentSize.height - s.bounds.height + s.adjustedContentInset.bottom)
            var y = s.contentOffset.y + direction * speed * CGFloat(min(dt, 0.05))
            if y <= top { y = top; direction = 1; legs += 1 }
            else if y >= bottom, direction > 0 { y = bottom; direction = -1; legs += 1 }
            s.contentOffset.y = y
            expected = y
        }
        last = link.timestamp
        if legs >= 4 { finish() }
    }

    private func finish() {
        link?.invalidate()
        let ms = elapsed > 0 ? hitchTime * 1000 / elapsed : 0
        print(String(format: "BENCH done frames=%d dropped=%d hitch=%.1fms/s worst=%.1fms seconds=%.1f content=%d legs=%@",
                     frames, dropped, ms, worst * 1000, elapsed, Int(scrollView?.contentSize.height ?? 0),
                     droppedPerLeg.prefix(4).map(String.init).joined(separator: "/"))
              + " sizeChanges=" + sizeChanges.prefix(4).map(String.init).joined(separator: "/")
              + " jumps=" + offsetJumps.prefix(4).map(String.init).joined(separator: "/"))
        Self.running = nil
    }
}
#endif
