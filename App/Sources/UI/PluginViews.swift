// Native re-implementations of the installed plugins' UI. See docs/protocol/05-plugins.md §2.

import PaseoKit
import SwiftUI
import WebKit
import os

/// Context a plugin row needs: which host/agent it belongs to.
struct PluginRowContext {
    var host: HostStore?
    var agentId: String?
}

extension EnvironmentValues {
    @Entry var pluginContext = PluginRowContext()
}

struct PluginRowView: View {
    let rowId: String
    let pluginId: String
    let kind: String
    let data: JSONValue

    var body: some View {
        switch (pluginId, kind) {
        case ("turn-speed", "turn-speed"): EmptyView() // shown in the reply footer (TurnInfo.speed)
        case ("next-input", "next-input"): EmptyView() // shown above the composer (NextInputBar)
        default: UnknownPluginRow(pluginId: pluginId, kind: kind, data: data)
        }
    }
}

/// Plugin rows without a native renderer: a compact card with the data's text, if any.
private struct UnknownPluginRow: View {
    let pluginId: String
    let kind: String
    let data: JSONValue

    var body: some View {
        let text = data["text"]?.stringValue ?? data["message"]?.stringValue ?? data["summary"]?.stringValue
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "puzzlepiece.extension").foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(pluginId) · \(kind)").font(.system(size: 11)).foregroundStyle(Theme.extraMuted)
                if let text { Text(text).font(.system(size: Theme.base)).textSelection(.enabled) }
            }
        }
        .padding(.vertical, 2)
        .help("插件条目（原生客户端还没有这个插件的专门界面）")
    }
}

// MARK: turn-speed

/// turn-speed stats of one turn, shown in the footer of the turn's reply (not as a row of its own).
struct TurnSpeed {
    let tokensPerSecond: Double
    let outputTokens: Int
    let generationMs: Double
    let requests: Int

    /// The turn's stats row: the last one in `rows`, if no user message comes after it.
    init?(rows: [TimelineRow]) {
        for r in rows.reversed() {
            if case .userMessage = r.item { return nil }
            if case .plugin(_, "turn-speed", "turn-speed", _, let data) = r.item, let tps = data["tokensPerSecond"]?.doubleValue {
                tokensPerSecond = tps
                outputTokens = Int(data["outputTokens"]?.doubleValue ?? 0)
                generationMs = data["generationMs"]?.doubleValue ?? 0
                requests = Int(data["requests"]?.doubleValue ?? 1)
                return
            }
        }
        return nil
    }

    /// "⚡ 78.5 tok/s · 11,579 tokens · 2 分 27 秒"
    var short: String {
        ["⚡ " + String(format: "%.1f", tokensPerSecond) + " tok/s", "\(outputTokens.formatted()) tokens", duration].joined(separator: " · ")
    }

    var full: String {
        let speed = String(format: "%.1f", tokensPerSecond), tokens = outputTokens.formatted(), time = duration
        return String(localized: "上一轮：\(speed) tok/s · 输出 \(tokens) tokens · 生成 \(time) · \(requests) 次请求")
    }

    private var duration: String {
        let s = generationMs / 1000
        return s < 60 ? String(localized: "\(String(format: "%.1f", s)) 秒") : String(localized: "\(Int(s) / 60) 分 \(Int(s) % 60) 秒")
    }
}

// MARK: next-input

/// A ready next-input suggestion for the newest idle turn.
struct NextInputSuggestion: Equatable {
    let text: String
    let token: String
    /// Commands, paths, links, secrets or destructive verbs: must be edited before sending (plugin safety rule).
    var needsEditing: Bool { requiresEditing(text) }
}

/// Fetches next-input's suggestion and hands it to the composer, which shows it as the empty box's placeholder:
/// tap / Tab fills it, the suggestion send button sends it as-is. The plugin cannot reach the official composer;
/// ours can. Prediction still runs in the plugin on the daemon. Renders nothing itself.
struct NextInputSource: View {
    let host: HostStore
    let agentId: String
    @Binding var suggestion: NextInputSuggestion?
    @MainActor private static var cache: [String: String] = [:]

    /// Token of the newest next-input row of the last turn (none after a later user message), while idle.
    private var token: String? {
        guard host.agents[agentId]?.status == .idle else { return nil }
        for r in (host.timelines[agentId]?.rows ?? []).reversed() {
            if case .userMessage = r.item { return nil }
            if case .plugin(_, "next-input", "next-input", _, let data) = r.item { return data["token"]?.stringValue }
        }
        return nil
    }

    var body: some View {
        // A concrete view (not an empty Group) so .task has something to run on.
        Color.clear.frame(width: 0, height: 0)
            .task(id: token) {
                suggestion = nil
                guard let token else { return }
                var text = Self.cache[token]
                if text == nil {
                    guard let out = try? await host.invokePlugin("next-input", "suggestions.predict",
                                                                 ["agentId": .string(agentId), "token": .string(token)]) else { return }
                    text = out["status"]?.stringValue == "ready" ? out["text"]?.stringValue ?? "" : ""
                    Self.cache[token] = text
                }
                if !Task.isCancelled, let text, !text.isEmpty { suggestion = NextInputSuggestion(text: text, token: token) }
            }
    }

    static func send(_ s: NextInputSuggestion, host: HostStore, agentId: String) async throws {
        _ = try await host.invokePlugin("next-input", "suggestions.send",
                                        ["agentId": .string(agentId), "token": .string(s.token), "text": .string(s.text)])
    }
}

/// Port of next-input's shared/safety.ts: risky suggestions must be edited before sending.
func requiresEditing(_ text: String) -> Bool {
    let t = text.lowercased()
    if t.contains("`") || t.contains("--force") || t.range(of: #"(^|\s)-f(\s|$)"#, options: .regularExpression) != nil { return true }
    if t.range(of: #"\b(rm|sudo|curl|ssh)\b|git\s+(push|reset)|https?://|token|secret|password"#, options: .regularExpression) != nil { return true }
    if t.range(of: #"(^|\s)(~|\.{0,2})/[\w.\-/]+"#, options: .regularExpression) != nil { return true }
    return ["删除", "推送", "部署", "发布", "强制", "上线", "清空"].contains { t.contains($0) }
}

// MARK: usage-reset
// Pixel-matched to the plugin's own UI (client/sidebar-item.tsx, client/usage-popover.tsx, locales/zh-CN.json).

/// Sidebar footer: one row per account — provider icon on the left, "98% 5h  12% 周  43% Fable" right-aligned.
private final class UsageReportBox: @unchecked Sendable { var list: [UsageReport] = [] }

/// Footer usage button: a ring showing the tightest limit window (grey while comfortable, orange under 20%,
/// red under 10%); click for the usage-reset breakdown. Without the plugin it is the plain usage button.
struct UsageFooterButton<Fallback: View>: View {
    @Environment(AppModel.self) private var model
    let openUsagePage: () -> Void
    @ViewBuilder let fallback: Fallback
    @State private var reports: [UsageReport] = []
    @State private var fetchedAt: Date?
    @State private var hidden: Set<String> = []
    @State private var showPopover = false
    /// 最近一次查看的会话所在机器；切到用量/机器等非会话页面时保持不变，环不跟着跳。
    @State private var sessionServerId: String?
    /// reports 属于哪台机器，换机器时先清空，避免短暂显示上一台的数据。
    @State private var reportsServerId: String?

    private func usable(_ h: HostStore) -> Bool {
        h.isPluginRunning("usage-reset") && h.state == .connected && h.usageQueriesEnabled
    }

    /// 优先当前会话所在机器；那台没装插件/未连接/关了用量查询时，退回第一台可用的机器。
    private var host: HostStore? {
        if let id = model.currentWorkspace?.serverId ?? sessionServerId, let h = model.host(id), usable(h) { return h }
        return model.hosts.first(where: usable)
    }

    private var windows: [(report: UsageReport, window: UsageWindow)] {
        reports.flatMap { r in r.windows.filter { !hidden.contains(r.sourceId + "/" + $0.id) }.map { (r, $0) } }
    }

    /// The lowest remaining share among windows that still have some left: an exhausted window (one of many models
    /// hitting 0) would otherwise pin the ring at 0 until it resets. Shows 0 only when every window is used up.
    private var tightest: Double? {
        let all = windows.map { remaining($0.window) }
        return all.filter { $0.rounded() > 0 }.min() ?? all.min()
    }

    private var ringColor: Color {
        guard let t = tightest else { return Theme.muted }
        return t < 10 ? levelColor(.danger) : t < 20 ? levelColor(.warning) : Theme.muted
    }

    private var summary: String {
        guard !windows.isEmpty else { return String(localized: "用量") }
        return String(localized: "用量（剩余）") + "\n" + windows.map { "\($0.report.sourceLabel) \(popoverLabel($0.window))：\(Int(remaining($0.window).rounded()))%" }
            .joined(separator: "\n")
    }

    var body: some View {
        content.onChange(of: model.currentWorkspace?.serverId, initial: true) { _, id in
            if let id { sessionServerId = id }
        }
    }

    private var pollingActive: Bool {
        #if os(iOS)
        model.appActive
        #else
        true
        #endif
    }

    @ViewBuilder private var content: some View {
        if let host {
            Button { showPopover.toggle() } label: {
                ZStack {
                    Circle().stroke(Theme.muted.opacity(0.2), lineWidth: 2)
                    Circle().trim(from: 0, to: (tightest ?? 0) / 100)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .overlay {
                    if let t = tightest {
                        Text("\(Int(t.rounded()))").font(.system(size: 8.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(t < 20 ? ringColor : Theme.foreground)
                    }
                }
                .frame(width: 22, height: 22)
                .frame(width: 36, height: 36)
                .background(showPopover || model.destination == .usage ? Theme.selection.opacity(0.8) : .clear, in: Circle())
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(summary)
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                UsageResetPopover(host: host, reports: $reports, fetchedAt: $fetchedAt, hidden: $hidden,
                                  refresh: { await load(host, force: true) },
                                  openUsagePage: { showPopover = false; openUsagePage() })
                    .compactPopover()
            }
            .task(id: host.id + model.connectionKey + (pollingActive ? ":active" : ":inactive")) {
                guard pollingActive else { return }
                if reportsServerId != host.id { reports = []; fetchedAt = nil; hidden = []; reportsServerId = host.id }
                #if DEBUG
                if model.debugSheet == "usageReset" { Task { try? await Task.sleep(for: .seconds(3)); showPopover = true } }
                #endif
                while !Task.isCancelled {
                    await load(host, force: false)
                    try? await Task.sleep(for: .seconds(300))
                }
            }
        } else {
            fallback
        }
    }

    private func load(_ host: HostStore, force: Bool) async {
        let box = UsageReportBox()
        do {
            try await host.usageReports(forceRefresh: force) { r in
                box.list.removeAll { $0.id == r.id }
                box.list.append(r)
            }
            try? await Task.sleep(for: .milliseconds(50))
            // Keep old data when a refresh fails; drop accounts without windows (plugin usage-data.ts).
            let fresh = box.list.filter { !$0.windows.isEmpty }
            // 切机器后旧任务的结果晚到，不能覆盖新机器的数据。
            guard !Task.isCancelled, reportsServerId == host.id else { return }
            if !fresh.isEmpty { reports = fresh.sorted { $0.sourceLabel < $1.sourceLabel }; fetchedAt = Date() }
        } catch {}
        if let s = try? await host.readPluginSettings("usage-reset", "sidebar") {
            hidden = Set((s.values["hidden"]?.arrayValue ?? []).compactMap(\.stringValue))
        }
    }
}

/// The provider's own SVG icon (currentColor → template image), falling back to a symbol.
struct ProviderIcon: View {
    let report: UsageReport
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = Self.image(report.iconSVG) { image.resizable().scaledToFit() }
            else { Image(systemName: "gauge.with.dots.needle.33percent").resizable().scaledToFit() }
        }
        .frame(width: size, height: size)
    }

    private static func image(_ svg: String?) -> Image? {
        guard let svg, let data = svg.data(using: .utf8) else { return nil }
        #if os(macOS)
        guard let ns = NSImage(data: data) else { return nil }
        ns.isTemplate = true
        return Image(nsImage: ns).renderingMode(.template)
        #else
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui).renderingMode(.template)
        #endif
    }
}

private func remaining(_ w: UsageWindow) -> Double { w.remainingPct ?? (100 - (w.usedPct ?? 0)) }

/// Popover labels: Session → 5 小时, Weekly → 周限额, Monthly → 月限额 (keeps suffixes like " · Fable").
private func popoverLabel(_ w: UsageWindow) -> String {
    for (prefix, english, zh) in [("five_hour", "Session", String(localized: "5 小时")), ("weekly", "Weekly", String(localized: "周限额")), ("monthly", "Monthly", String(localized: "月限额"))]
    where w.id.hasPrefix(prefix) && w.label.hasPrefix(english) {
        return zh + w.label.dropFirst(english.count)
    }
    return w.label
}

private enum BudgetLevel { case ok, warning, danger }

/// Daily (or hourly) budget vs. an even spend over the window (plugin usage-data.ts:139-176).
private func budget(_ w: UsageWindow) -> (pct: Double, hourly: Bool, level: BudgetLevel)? {
    guard let reset = w.resetsAt else { return nil }
    let spec: (unit: Double, units: Double, hourly: Bool)? =
        w.id.hasPrefix("five_hour") ? (3600, 5, true) : w.id.hasPrefix("weekly") ? (86400, 7, false) : w.id.hasPrefix("monthly") ? (86400, 30, false) : nil
    guard let spec else { return nil }
    let unitsLeft = reset.timeIntervalSinceNow / spec.unit
    guard unitsLeft >= 1 else { return nil }
    let perUnit = remaining(w) / unitsLeft
    let ratio = perUnit / (100 / spec.units)
    return (perUnit, spec.hourly, ratio < 0.5 ? .danger : ratio < 0.85 ? .warning : .ok)
}

private func levelColor(_ l: BudgetLevel) -> Color {
    switch l {
    case .ok: Color(light: 0x1F9D55, dark: 0x35C264)
    case .warning: Color(light: 0xE08600, dark: 0xDB932E)
    case .danger: Color(light: 0xE5484D, dark: 0xF7796D)
    }
}

private func barColor(_ pct: Double) -> Color {
    pct < 10 ? Color(light: 0xFF5A50, dark: 0xFF5A50) : pct < 30 ? Color(light: 0xFF9F0A, dark: 0xFF9F0A) : Color(light: 0x4A9DF8, dark: 0x4A9DF8)
}

private func minuteRounded(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded() * 60) }

private func hhmm(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

/// 今天 18:50 / 明天 09:00 / 周一 11/2 14:15 (also the usage page, next to the countdown).
func formatWhen(_ date: Date) -> String {
    let cal = Calendar.current
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
    if days == 0 { return String(localized: "今天 \(hhmm(date))") }
    if days == 1 { return String(localized: "明天 \(hhmm(date))") }
    let weekday = [String(localized: "周日"), String(localized: "周一"), String(localized: "周二"), String(localized: "周三"), String(localized: "周四"), String(localized: "周五"), String(localized: "周六")][cal.component(.weekday, from: date) - 1]
    return "\(weekday) \(cal.component(.month, from: date))/\(cal.component(.day, from: date)) " + hhmm(date)
}

private func formatRemaining(_ date: Date) -> String {
    let minutes = Int((date.timeIntervalSinceNow / 60).rounded())
    if minutes <= 0 { return String(localized: "已过刷新时间，点刷新更新") }
    let d = minutes / 1440, h = minutes % 1440 / 60, m = minutes % 60
    if d > 0 { return String(localized: "还有 \(d) 天 \(h) 小时") }
    if h > 0 { return String(localized: "还有 \(h) 小时 \(m) 分") }
    return String(localized: "还有 \(m) 分钟")
}

/// Thin rounded segments, 3pt wide with 2pt gaps; unfilled segments are the same color at 15%.
private struct SegmentBar: View {
    let pct: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let count = max(10, Int((geo.size.width + 2) / 5))
            let filled = Int((pct / 100 * Double(count)).rounded())
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule().fill(color.opacity(i < filled ? 1 : 0.15)).frame(width: 3)
                    if i < count - 1 { Spacer(minLength: 2) }
                }
            }
        }
        .frame(height: 12)
    }
}

private struct UsageResetPopover: View {
    let host: HostStore
    @Binding var reports: [UsageReport]
    @Binding var fetchedAt: Date?
    @Binding var hidden: Set<String>
    let refresh: () async -> Void
    var openUsagePage: (() -> Void)?
    @State private var refreshing = false
    @State private var error: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text("限额刷新").font(.system(size: 14, weight: .semibold))
                        Text(host.label).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let fetchedAt { Text(String(localized: "更新于 \(hhmm(fetchedAt))")).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                    Button {
                        refreshing = true
                        Task { await refresh(); refreshing = false }
                    } label: {
                        Text(refreshing ? "刷新中" : "刷新").font(.system(size: 11))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                    }
                    .buttonStyle(.plain)
                    .disabled(refreshing)
                }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.destructive) }
                if reports.isEmpty { Text("正在读取用量…").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                ForEach(Array(reports.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                    provider(r)
                }
                if let openUsagePage {
                    Rectangle().fill(Theme.border).frame(height: 1)
                    Button("查看完整用量", systemImage: "chart.bar", action: openUsagePage)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                }
            }
            .padding(16)
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surface0)
        .task { await refresh() }
    }

    private func provider(_ r: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                ProviderIcon(report: r, size: 16)
                Text(r.sourceLabel).font(.system(size: 13, weight: .semibold))
                if let plan = r.planLabel {
                    Text(plan.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
            }
            if let problem = r.problem { Text(problem).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            ForEach(r.windows) { w in window(r, w) }
        }
    }

    private func window(_ r: UsageReport, _ w: UsageWindow) -> some View {
        let key = r.sourceId + "/" + w.id
        let left = remaining(w)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(popoverLabel(w)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 8)
                    (Text("剩余 ").foregroundColor(Theme.muted) + Text("\(Int(left.rounded()))%").fontWeight(.bold).foregroundColor(Theme.foreground))
                        .monospacedDigit()
                }
                .font(.system(size: 12))
                SegmentBar(pct: left, color: barColor(left))
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 10))
                    if let reset = w.resetsAt.map(minuteRounded) {
                        Text(String(localized: "\(formatWhen(reset)) 刷新 · \(formatRemaining(reset))")).lineLimit(1)
                    } else {
                        Text("没有刷新时间")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                if let b = budget(w) {
                    Text(b.hourly ? String(localized: "每小时可用 \(Int(b.pct.rounded()))%") : String(localized: "日均可用 \(Int(b.pct.rounded()))%"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(levelColor(b.level))
                        .padding(.leading, 15)
                }
            }
            Button { toggle(key) } label: {
                Image(systemName: hidden.contains(key) ? "eye.slash" : "eye").font(.system(size: 14)).padding(2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .help(hidden.contains(key) ? "在侧边栏显示" : "不在侧边栏显示")
            .accessibilityLabel(hidden.contains(key) ? "在侧边栏显示" : "不在侧边栏显示")
        }
    }

    private func toggle(_ key: String) {
        Task {
            do {
                let current = try await host.readPluginSettings("usage-reset", "sidebar")
                var set = Set((current.values["hidden"]?.arrayValue ?? []).compactMap(\.stringValue))
                if set.contains(key) { set.remove(key) } else { set.insert(key) }
                let saved = try await host.writePluginSettings("usage-reset", "sidebar", revision: current.revision,
                                                               values: ["hidden": .array(set.sorted().map(JSONValue.string))])
                hidden = Set((saved.values["hidden"]?.arrayValue ?? []).compactMap(\.stringValue))
            } catch { self.error = "\(error)" }
        }
    }
}

// MARK: 当前会话的限额（上下文用量弹出面板里）

/// 当前会话所用账号的限额，放在上下文用量下面。daemon 按 agentId 只返回这个会话的提供方 / 账号那份报告
/// （usage-sources/index.ts）；带模型后缀的窗口（「周限额 · Fable」）只在当前模型名里含这个词时显示。
struct AgentQuotaSection: View {
    let host: HostStore
    let agentId: String
    /// 当前模型 id 或名字，用来挑带模型后缀的窗口。
    let model: String?
    @State private var reports: [UsageReport] = []
    @State private var loaded = false
    @State private var failed: String?

    static func available(_ host: HostStore) -> Bool {
        host.isPluginRunning("usage-reset") && host.state == .connected && host.usageQueriesEnabled
    }

    private func applies(_ w: UsageWindow) -> Bool {
        guard let r = w.label.range(of: " · ") else { return true }
        let suffix = w.label[r.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
        guard !suffix.isEmpty, let model = model?.lowercased() else { return false }
        return model.contains(suffix)
    }

    var body: some View {
        let rows = reports.flatMap { r in r.windows.filter(applies).map { (r, $0) } }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("限额").font(.system(size: 13, weight: .semibold))
                if let plan = reports.first?.planLabel {
                    Text(plan.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
            }
            if let failed {
                Text(String(localized: "读取失败：\(failed)")).font(.system(size: 11)).foregroundStyle(Theme.muted)
            } else if !loaded && rows.isEmpty {
                Text("正在读取限额…").font(.system(size: 11)).foregroundStyle(Theme.muted)
            } else if rows.isEmpty {
                Text("这个账号没有限额数据").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            ForEach(rows, id: \.1.id) { r, w in window(r, w) }
        }
        .task(id: agentId) { await load() }
    }

    private func window(_ r: UsageReport, _ w: UsageWindow) -> some View {
        let left = remaining(w)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(popoverLabel(w)).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                (Text("剩余 ").foregroundColor(Theme.muted) + Text("\(Int(left.rounded()))%").fontWeight(.bold).foregroundColor(Theme.foreground))
                    .monospacedDigit()
            }
            .font(.system(size: 12))
            SegmentBar(pct: left, color: barColor(left))
            HStack(spacing: 4) {
                if let reset = w.resetsAt.map(minuteRounded) {
                    Text(String(localized: "\(formatWhen(reset)) 刷新 · \(formatRemaining(reset))")).lineLimit(1)
                }
                if let b = budget(w) {
                    Text("· " + (b.hourly ? String(localized: "每小时可用 \(Int(b.pct.rounded()))%") : String(localized: "日均可用 \(Int(b.pct.rounded()))%")))
                        .fontWeight(.semibold).foregroundStyle(levelColor(b.level))
                }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    private func load() async {
        let box = UsageReportBox()
        do {
            try await host.usageReports(agentId: agentId) { r in
                box.list.removeAll { $0.id == r.id }
                box.list.append(r)
                reports = box.list.filter { !$0.windows.isEmpty }
            }
            failed = nil
        } catch {
            if reports.isEmpty { failed = "\(error)" }
        }
        loaded = true
    }
}

// MARK: agent-taskboard

/// The board is a local web app on the daemon's machine (127.0.0.1:7788): shown in a web view when this Mac can reach it.
struct BoardView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRef?
    var agent: AgentRef? = nil
    @State private var url: URL?
    @State private var problem: String?
    @State private var loading = true

    /// 看板服务只监听那台机器的 127.0.0.1，所以在 Mac 上优先用本机 daemon 的看板插件（这台 Mac 能打开的只有本机看板，
    /// 本机令牌也只交给它）；本机没装看板插件时才用当前工作区所在机器、或第一台装了插件的机器。
    private var host: HostStore? {
        #if os(macOS)
        if let local = LocalDaemon.shared.status?.serverId, let h = model.host(local), h.isPluginRunning("agent-taskboard") { return h }
        #endif
        return workspace.flatMap { model.host($0.serverId) }.flatMap { $0.isPluginRunning("agent-taskboard") ? $0 : nil }
            ?? model.hosts.first { $0.isPluginRunning("agent-taskboard") }
    }

    var body: some View {
        Group {
            if let url {
                // 本机的看板令牌只交给本机 daemon 的插件报出的、回环地址上的看板（别的机器报的地址不能信任）
                WebView(url: url, localStorage: tokenAllowed(url) ? boardToken.map { ["board-token": $0] } ?? [:] : [:])
            } else if let problem {
                ContentUnavailableView {
                    Label("看板打不开", systemImage: "rectangle.split.3x1")
                } description: {
                    Text(problem)
                } actions: {
                    Button("重试") { Task { await locate() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("看板")
        .task(id: (workspace?.workspaceId ?? "") + model.connectionKey) { await locate() }
    }

    private func locate() async {
        #if os(macOS)
        // 选哪台机器的看板插件、能不能注入本机令牌，都要用到本机 daemon 的 serverId，先取到再往下走
        if LocalDaemon.shared.status == nil { await LocalDaemon.shared.refresh() }
        #endif
        guard let host else { problem = String(localized: "没有机器启用了看板插件"); return }
        problem = nil
        url = nil
        var paths: [JSONValue] = []
        if let ref = workspace, let w = model.workspace(ref) {
            paths = [.string(w.directory), .string(w.projectRootPath)]
        } else if let r = agent, let a = model.agent(r), !a.cwd.isEmpty {
            paths = [.string(a.cwd)]
        }
        #if DEBUG
        boardDebug("host=\(host.id) workspace=\(workspace.map { $0.workspaceId } ?? "-") agent=\(agent?.agentId ?? "-") cwd=\(agent.flatMap { model.agent($0)?.cwd } ?? "-") paths=\(paths.compactMap(\.stringValue))")
        #endif
        do {
            let out = try await host.invokePlugin("agent-taskboard", "board.locate", ["paths": .array(paths)])
            #if DEBUG
            boardDebug("locate -> \(out)")
            #endif
            guard out["reachable"]?.boolValue == true, let base = out["url"]?.stringValue else {
                problem = String(localized: "看板服务没有响应：\(out["error"]?.stringValue ?? String(localized: "未知原因"))")
                return
            }
            var s = base
            let project = out["project"]?.stringValue
            Logger(subsystem: "paseo-native", category: "board").notice("board.locate host=\(host.id, privacy: .public) paths=\(paths.compactMap(\.stringValue), privacy: .public) project=\(project ?? "-", privacy: .public)")
            if let project {
                s += "/p/" + project.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
                // 只有定位到项目时才收起看板侧栏；首页要靠侧栏选项目，收起就是一片空白
                s += "?sidebar=collapsed"
            }
            guard let u = URL(string: s) else { problem = String(localized: "看板地址无效：\(s)"); return }
            // 127.0.0.1 is the daemon's machine: only reachable when this app runs there.
            if await reachable(u) { url = u } else { problem = String(localized: "看板在 \(host.label) 上（\(base)），只能在那台电脑上打开。") }
        } catch {
            problem = "\(error)"
        }
    }

    /// The board SPA reads its API token from localStorage; it lives in ~/.project-board/token on the same machine.
    private var boardToken: String? {
        #if os(macOS)
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".project-board/token")
        return (try? String(contentsOf: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return nil
        #endif
    }

    private func tokenAllowed(_ u: URL) -> Bool {
        #if os(macOS)
        guard let local = LocalDaemon.shared.status?.serverId, local == host?.id else { return false }
        return Self.isLoopback(u)
        #else
        return false
        #endif
    }

    static func isLoopback(_ u: URL) -> Bool {
        guard u.scheme == "http" || u.scheme == "https", let h = u.host?.lowercased() else { return false }
        return h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "[::1]"
    }

    private func reachable(_ u: URL) async -> Bool {
        var req = URLRequest(url: u)
        req.timeoutInterval = 3
        return (try? await URLSession.shared.data(for: req)) != nil
    }
}

#if DEBUG
/// PASEO_BOARD_LOG=<文件>：把看板定位过程追加写进文件（排查用）。
func boardDebug(_ s: String) {
    guard let path = ProcessInfo.processInfo.environment["PASEO_BOARD_LOG"],
          let data = (s + "\n").data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
    else { try? data.write(to: URL(fileURLWithPath: path)) }
}
#endif

/// WKWebView, optionally seeding localStorage for the page's origin before its scripts run
/// (only on that origin: the script is skipped if the page navigates elsewhere).
func makeWebView(url: URL, localStorage: [String: String]) -> WKWebView {
    let config = WKWebViewConfiguration()
    if !localStorage.isEmpty, let json = try? JSONSerialization.data(withJSONObject: localStorage),
       let obj = String(data: json, encoding: .utf8),
       let scheme = url.scheme, let host = url.host(percentEncoded: false),
       let originJSON = try? JSONSerialization.data(
           withJSONObject: "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)\(url.port.map { ":\($0)" } ?? "")",
           options: .fragmentsAllowed),
       let origin = String(data: originJSON, encoding: .utf8) {
        let js = "(function(){if(location.origin!==\(origin))return;var v=\(obj);for(var k in v){try{localStorage.setItem(k,v[k])}catch(e){}}})();"
        config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    let v = WKWebView(frame: .zero, configuration: config)
    v.load(URLRequest(url: url))
    #if DEBUG && os(macOS)
    // PASEO_WEB_SNAPSHOT=<png 路径>：加载 8 秒后把网页实际渲染的画面、页面文字和 localStorage 存下来（排查网页空白）
    if let out = ProcessInfo.processInfo.environment["PASEO_WEB_SNAPSHOT"] {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            v.takeSnapshot(with: nil) { image, _ in
                if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                }
            }
            v.evaluateJavaScript("JSON.stringify({url: location.href, size: [innerWidth, innerHeight], text: document.body.innerText.slice(0, 800), token: !!localStorage.getItem('board-token')})") { r, e in
                try? "\(r ?? "")\n\(e.map { "\($0)" } ?? "")".write(toFile: out + ".txt", atomically: true, encoding: .utf8)
            }
        }
    }
    #endif
    return v
}

#if os(macOS)
struct WebView: NSViewRepresentable {
    let url: URL
    var localStorage: [String: String] = [:]
    func makeNSView(context: Context) -> WKWebView { makeWebView(url: url, localStorage: localStorage) }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
#else
struct WebView: UIViewRepresentable {
    let url: URL
    var localStorage: [String: String] = [:]
    func makeUIView(context: Context) -> WKWebView { makeWebView(url: url, localStorage: localStorage) }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
#endif

// MARK: Plugin settings

/// Settings → machine → 插件: status of every plugin plus native settings pages for the known ones.
struct PluginsSection: View {
    let host: HostStore
    @State private var installing = false
    @State private var source = ""
    @State private var ref = ""
    @State private var busy = false
    @State private var error: String?
    @State private var companions: [CompanionPlugin]?

    var body: some View {
        Section("插件") {
            PluginsDisabledNotice(host: host)
            if host.plugins.isEmpty { Text("没有安装插件").foregroundStyle(Theme.muted) }
            if installing {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("git 地址，或主机上的插件目录（/ 开头）", text: $source)
                    if !source.hasPrefix("/") && !source.hasPrefix("~") { TextField("分支或标签（可选）", text: $ref) }
                    Text("插件会在 daemon 里运行代码，只安装你信任的来源。").font(.caption).foregroundStyle(Theme.dotWarning)
                    if let error { Text(error).font(.caption).foregroundStyle(Theme.destructive) }
                    HStack {
                        Spacer()
                        Button("取消") { installing = false; error = nil }
                        Button("安装") {
                            busy = true
                            Task {
                                do { try await host.installPlugin(source: source.trimmingCharacters(in: .whitespaces), ref: ref); installing = false; source = ""; ref = "" }
                                catch { self.error = "\(error)" }
                                busy = false
                            }
                        }
                        .buttonStyle(.borderedProminent).disabled(busy || source.trimmingCharacters(in: .whitespaces).isEmpty)
                        if busy { ProgressView().controlSize(.small) }
                    }
                }
            } else {
                let missing = CompanionPlugins.missing(on: host)
                if !missing.isEmpty {
                    Button("安装配套插件（还差 \(missing.count) 个）…") { companions = missing }
                }
                Button("安装插件…") { installing = true }
            }
            ForEach(host.plugins) { p in
                NavigationLink {
                    PluginDetailView(host: host, plugin: p)
                } label: {
                    HStack {
                        Circle().fill(p.isRunning ? Theme.dotSuccess : p.status == "failed" ? Theme.destructive : Theme.extraMuted).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pluginDisplayName(p))
                            if let e = p.error { Text(e).font(.caption).foregroundStyle(Theme.destructive).lineLimit(2) }
                        }
                        Spacer()
                        Text(p.isRunning ? "运行中" : p.status == "failed" ? "加载失败" : "已停用").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { companions != nil }, set: { if !$0 { companions = nil } })) {
            if let companions { CompanionPluginsSheet(host: host, plugins: companions) }
        }
    }
}

/// The daemon's global plugin switch is off (the default on a new daemon): no plugin runs, whatever its own toggle says.
struct PluginsDisabledNotice: View {
    let host: HostStore
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        if host.daemonConfig != nil && !host.pluginsGloballyEnabled {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("这台机器的插件总开关没开，所有插件都不会运行", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.dotWarning)
                    Spacer()
                    Button("启用插件") {
                        busy = true
                        Task {
                            do { try await host.patchDaemonConfig(["pluginsEnabled": true]) } catch { self.error = "\(error)" }
                            busy = false
                        }
                    }
                    .disabled(busy)
                }
                if let error { Text(error).font(.caption).foregroundStyle(Theme.destructive) }
            }
        }
    }
}

/// The wire carries no translations, so known plugins get their Chinese names here.
func pluginDisplayName(_ p: PluginInfo) -> String {
    ["title-style": String(localized: "标题风格"), "usage-reset": String(localized: "限额刷新时间"),
     "turn-speed": String(localized: "回合速度"), "next-input": String(localized: "下一句建议"), "agent-taskboard": String(localized: "看板")][p.id] ?? p.name
}

private struct PluginDetailView: View {
    let host: HostStore
    let plugin: PluginInfo
    @State private var values: [String: JSONValue] = [:]
    @State private var revision: String?
    @State private var error: String?
    @State private var logs: [String] = []
    @State private var claudePath: String?
    @State private var codexPath: String?
    /// Pending autosave; edits are written shortly after the last change (no save button).
    @State private var saveTask: Task<Void, Never>?

    @State private var confirmRemove = false
    @Environment(\.dismiss) private var dismissDetail

    private var settingsId: String? { ["title-style": "title-style", "next-input": "preferences"][plugin.id] }

    var body: some View {
        form
            .confirmationDialog("移除插件「\(pluginDisplayName(plugin))」？", isPresented: $confirmRemove) {
                Button("移除", role: .destructive) {
                    Task { do { try await host.removePlugin(plugin.id); dismissDetail() } catch { self.error = "\(error)" } }
                }
            } message: { Text("会从这台机器上卸载这个插件。") }
    }

    private var form: some View {
        Form {
            Section {
                PluginsDisabledNotice(host: host)
                Toggle("启用", isOn: Binding(get: { plugin.enabled }, set: { v in Task { try? await host.setPluginEnabled(plugin.id, v) } }))
                if let e = plugin.error { Text(e).foregroundStyle(Theme.destructive) }
                HStack {
                    Button("重新加载") { Task { do { try await host.reloadPlugin(plugin.id) } catch { self.error = "\(error)" } } }
                    Spacer()
                    Button("移除插件…", role: .destructive) { confirmRemove = true }
                }
            } footer: {
                Text(pluginBlurb(plugin.id))
            }
            if plugin.id == "title-style", revision != nil {
                Section("标题风格") {
                    Toggle("新会话自动起中文标题", isOn: bool("enabled"))
                    VStack(alignment: .leading) {
                        Text("命名要求")
                        TextEditor(text: string("instructions")).font(.system(size: 12)).frame(minHeight: 120)
                            .scrollContentBackground(.hidden).padding(6).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8))
                    }
                    TextField("模型（留空跟随自动命名设置，如 claude/claude-haiku-5-5）", text: string("model"))
                }
            }
            if plugin.id == "next-input", revision != nil {
                Section("下一句建议") {
                    Toggle("每轮结束后提供下一句建议", isOn: bool("enabled"))
                    NextInputModelRows(host: host, values: values, string: string, bool: bool)
                    LabeledContent("Claude CLI", value: claudePath ?? String(localized: "未找到"))
                    if values["engine"] != nil { LabeledContent("Codex CLI", value: codexPath ?? String(localized: "未找到")) }
                }
            }
            if let error { Text(error).foregroundStyle(Theme.destructive) }
            if !logs.isEmpty {
                Section("最近日志") {
                    ScrollView { Text(logs.suffix(60).joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                        .frame(height: 200)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(pluginDisplayName(plugin))
        .task(id: host.pluginSettingsRevision[plugin.id + "/" + (settingsId ?? "")]) { await load() }
        .toolbar { ToolbarItem { Button("日志") { Task { logs = await host.pluginLogs(plugin.id) } } } }
    }

    private func load() async {
        if plugin.id == "next-input", plugin.isRunning {
            // tools.status (Claude and Codex) on new versions; claude.status on older ones.
            if let out = try? await host.invokePlugin("next-input", "tools.status") {
                claudePath = out["claude"]?["path"]?.stringValue
                codexPath = out["codex"]?["path"]?.stringValue
            } else if let out = try? await host.invokePlugin("next-input", "claude.status") {
                claudePath = out["path"]?.stringValue
            }
        }
        guard let settingsId, plugin.isRunning else { return }
        do {
            let s = try await host.readPluginSettings(plugin.id, settingsId)
            values = s.values
            revision = s.revision
        } catch { self.error = "\(error)" }
    }

    /// Saves 0.8 s after the last edit, so typing in a text field writes once.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let settingsId, let revision else { return }
            error = nil
            do {
                let s = try await host.writePluginSettings(plugin.id, settingsId, revision: revision, values: values)
                self.revision = s.revision
            } catch { self.error = String(localized: "保存失败：\(error)") }
        }
    }

    private func bool(_ k: String) -> Binding<Bool> {
        Binding(get: { values[k]?.boolValue ?? false }, set: { values[k] = .bool($0); scheduleSave() })
    }

    private func string(_ k: String) -> Binding<String> {
        Binding(get: { values[k]?.stringValue ?? "" }, set: { values[k] = .string($0); scheduleSave() })
    }
}

private func pluginBlurb(_ id: String) -> String {
    switch id {
    case "title-style": String(localized: "新会话创建后，用大模型给工作区起一个中文任务标题。逻辑在 daemon 里，对所有客户端都生效。")
    case "usage-reset": String(localized: "在侧栏底部显示各限额窗口的剩余比例，点开看具体刷新时间和每日可用量。")
    case "turn-speed": String(localized: "每轮结束后统计生成速度，显示在那一轮回复底部「用时」后面。")
    case "next-input": String(localized: "每轮结束后用那台机器上的 Claude 预测你下一句可能要说的话，显示在空输入框里：Tab 或点一下填入，纸飞机直接发送。改动自动保存，从下一轮开始生效。")
    case "agent-taskboard": String(localized: "在侧栏打开本机的项目看板（只能在运行 daemon 的那台电脑上打开）。")
    default: ""
    }
}

/// 「输入预测」 on the general settings page: next-input's own settings (the same ones as its plugin page),
/// saved as soon as they change.
struct NextInputPreferencesSection: View {
    @Environment(AppModel.self) private var model
    @State private var values: [String: JSONValue] = [:]
    @State private var revision: String?
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?

    private var host: HostStore? { model.hosts.first { $0.isPluginRunning("next-input") && $0.state == .connected } }

    var body: some View {
        Section {
            if let host {
                if revision != nil {
                    Toggle("每轮结束后预测下一句", isOn: bool("enabled"))
                    NextInputModelRows(host: host, values: values, string: string, bool: bool)
                        .disabled(values["enabled"]?.boolValue == false)
                } else if error == nil {
                    ProgressView().controlSize(.small)
                }
                if let error { Text(error).foregroundStyle(Theme.destructive) }
            } else {
                Text("要先在机器上装好并启用「下一句建议」插件。").foregroundStyle(Theme.muted)
            }
        } header: {
            Text("输入预测")
        } footer: {
            // Codex wording only once the plugin has the engine setting (not yet published).
            Text(values["engine"] == nil
                 ? "在 \(host?.label ?? String(localized: "机器")) 上用那里登录的 Claude 账户预测，消耗该账户用量。改动自动保存，从下一轮开始生效。"
                 : "在 \(host?.label ?? String(localized: "机器")) 上用那里登录的 Claude 或 Codex 账户预测，消耗该账户用量。「跟随会话」时 Codex 会话用 Codex、其他用 Claude，没装的那个会自动换成另一个。改动自动保存，从下一轮开始生效。")
        }
        .task(id: (host?.id ?? "") + String(host?.pluginSettingsRevision["next-input/preferences"] ?? 0)) {
            if let host { await load(host) }
        }
    }

    private func load(_ host: HostStore) async {
        do {
            let s = try await host.readPluginSettings("next-input", "preferences")
            values = s.values
            revision = s.revision
            error = nil
        } catch { self.error = String(localized: "读取失败：\(error)") }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let host, let revision else { return }
            do {
                let s = try await host.writePluginSettings("next-input", "preferences", revision: revision, values: values)
                self.revision = s.revision
                error = nil
            } catch { self.error = String(localized: "保存失败：\(error)") }
        }
    }

    private func bool(_ k: String) -> Binding<Bool> {
        Binding(get: { values[k]?.boolValue ?? false }, set: { values[k] = .bool($0); scheduleSave() })
    }

    private func string(_ k: String) -> Binding<String> {
        Binding(get: { values[k]?.stringValue ?? "" }, set: { values[k] = .string($0); scheduleSave() })
    }
}

/// Prediction tool and models for next-input; the tool picker only exists on plugin versions with Codex support.
private struct NextInputModelRows: View {
    let host: HostStore
    let values: [String: JSONValue]
    let string: (String) -> Binding<String>
    let bool: (String) -> Binding<Bool>

    /// Codex models this host offers (same list as the composer's model picker).
    private var codexModels: [(id: String, label: String)] {
        let list = host.providers.first { $0["provider"]?.stringValue == "codex" }?["models"]?.arrayValue ?? []
        return list.compactMap { m in m["id"]?.stringValue.map { ($0, m["label"]?.stringValue ?? $0) } }
    }

    private var engine: String { values["engine"]?.stringValue ?? "claude" }

    var body: some View {
        if values["engine"] != nil {
            Picker("预测工具", selection: string("engine")) {
                Text("跟随会话").tag("auto"); Text("Claude").tag("claude"); Text("Codex").tag("codex")
            }
        }
        if engine != "codex" {
            Picker(engine == "auto" ? "Claude 模型" : "模型", selection: string("model")) {
                Text("Haiku（快、省）").tag("haiku"); Text("Sonnet").tag("sonnet"); Text("Opus").tag("opus"); Text("自定义").tag("custom")
            }
            if values["model"]?.stringValue == "custom" { TextField("Claude 模型 ID", text: string("customModel")) }
        }
        if engine != "claude" {
            let current = values["codexModel"]?.stringValue ?? ""
            Picker(engine == "auto" ? "Codex 模型" : "模型", selection: string("codexModel")) {
                Text("Codex 默认").tag("")
                ForEach(codexModels, id: \.id) { m in Text(m.label).tag(m.id) }
                // A model set earlier that this host no longer lists stays selectable.
                if !current.isEmpty && !codexModels.contains(where: { $0.id == current }) { Text(current).tag(current) }
            }
            // Only plugin versions with the setting (codexFast) can run predictions on Codex's fast tier.
            if values["codexFast"] != nil { Toggle("Codex 用 Fast 模式", isOn: bool("codexFast")) }
        }
    }
}
