import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
typealias LightboxPlatformImage = NSImage
#else
import UIKit
typealias LightboxPlatformImage = UIImage
#endif

/// 大图查看器里的一张图。
struct LightboxPage: Identifiable {
    /// 稳定标识（附件 id、图片地址），也用作 iPhone 缩放过渡的来源 id。
    let id: String
    /// 已解码的缩略图，原图加载出来之前先垫着；没有就显示加载中。
    var placeholder: Image?
    var title = ""
    var source: ImageSource?
    var sourceType: UTType?
    /// 打开时就知道的尺寸（点）。exact 为 false 时只代表宽高比（缩略图）。
    var size: CGSize?
    var sizeIsExact = false
}

/// 一次「打开大图」：Mac 开独立窗口，iPhone/iPad 全屏盖住；同一条消息的多张图可以左右切换。
struct LightboxItem: Identifiable {
    let id = UUID()
    var pages: [LightboxPage]
    var index: Int
    /// iPhone 缩放过渡从哪张缩略图展开（点开的那张）。
    var sourceID: String { pages.indices.contains(index) ? pages[index].id : "" }

    init(pages: [LightboxPage], index: Int = 0) {
        self.pages = pages
        self.index = min(max(index, 0), max(pages.count - 1, 0))
    }

    init(page: LightboxPage) { self.init(pages: [page]) }
}

/// 全尺寸看图。Mac：独立窗口（可最大化 / 全屏），捏合或 ⌘+/⌘− 缩放，双击切换适合窗口 / 2×，←/→ 切图，Esc 关闭；
/// 小图默认按原始大小显示，不拉大发糊。iPhone/iPad：全屏，原生双指缩放、双击放大、左右滑切图、未放大时下拉关闭，长按存储或拷贝。
struct ImageLightbox: View {
    @Environment(\.dismiss) private var dismiss
    let pages: [LightboxPage]
    @State private var index: Int
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var copied = false

    init(item: LightboxItem) {
        pages = item.pages
        _index = State(initialValue: item.index)
    }

    private var page: LightboxPage? { pages.indices.contains(index) ? pages[index] : nil }

    private var title: String {
        let t = page?.title ?? ""
        return t.isEmpty || t == "Image" ? String(localized: "图片") : t
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content.background(Theme.surface1)
        }
        .macOnly { $0.frame(minWidth: 480, minHeight: 360) }
        .onChange(of: index) { scale = 1; base = 1; copied = false }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if pages.count > 1 {
                Text("\(index + 1) / \(pages.count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
            }
            Spacer()
            #if os(macOS)
            if pages.count > 1 {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: []).disabled(index == 0).help("上一张（←）")
                    .accessibilityLabel("上一张")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: []).disabled(index == pages.count - 1).help("下一张（→）")
                    .accessibilityLabel("下一张")
            }
            Button { zoom(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.keyboardShortcut("-", modifiers: .command)
                .accessibilityLabel("缩小")
            Text("\(Int(scale * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted).frame(width: 44)
            Button { zoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }.keyboardShortcut("=", modifiers: .command)
                .accessibilityLabel("放大")
            Button { scale = 1; base = 1 } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .keyboardShortcut("0", modifiers: .command).help("适合窗口")
                .accessibilityLabel("适合窗口")
            #endif
            if let source = page?.source {
                Button { copy(source) } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .keyboardShortcut("c", modifiers: .command).help("拷贝图片（⌘C）")
                    .accessibilityLabel(copied ? "已拷贝" : "拷贝图片")
                ImageSaveButton(source: source)
            }
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        if let page {
            MacImagePage(page: page, scale: $scale, base: $base).id(page.id)
        }
        #else
        if pages.count > 1 {
            TabView(selection: $index) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { i, p in
                    PhoneImagePage(page: p) { dismiss() }.tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(edges: .bottom)
        } else if let page {
            PhoneImagePage(page: page) { dismiss() }.ignoresSafeArea(edges: .bottom)
        }
        #endif
    }

    private func step(_ d: Int) {
        let next = index + d
        if pages.indices.contains(next) { index = next }
    }

    private func zoom(_ f: CGFloat) {
        withAnimation(.snappy(duration: 0.15)) { scale = min(max(scale * f, 0.5), 8); base = scale }
    }

    private func copy(_ source: ImageSource) {
        Task {
            await ImageExport.copy(source)
            copied = true
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// 打开后按需取原始字节解码原图。
private func loadFullImage(_ page: LightboxPage) async -> LightboxPlatformImage? {
    guard let data = await page.source?.load() else { return nil }
    return LightboxPlatformImage(data: data)
}

#if os(macOS)
private struct MacImagePage: View {
    let page: LightboxPage
    @Binding var scale: CGFloat
    @Binding var base: CGFloat
    @State private var full: NSImage?

    var body: some View {
        GeometryReader { geo in
            let fit = fitted(in: geo.size)
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if let full {
                        Image(nsImage: full).resizable().scaledToFit()
                    } else if let placeholder = page.placeholder {
                        placeholder.resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: fit.width * scale, height: fit.height * scale)
                .imageExport(page.source, type: page.sourceType)
                .onTapGesture(count: 2) { withAnimation(.snappy) { scale = scale > 1 ? 1 : 2; base = scale } }
                // 比窗口小时居中，而不是贴在左上角。
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .gesture(MagnifyGesture()
                .onChanged { scale = min(max(base * $0.magnification, 0.5), 8) }
                .onEnded { _ in base = scale })
        }
        .task(id: page.id) { full = await loadFullImage(page) }
    }

    /// 100% 对应的显示尺寸：比窗口大就缩到适合窗口，比窗口小就按原始大小（截图这类小图不拉大发糊）。
    private func fitted(in available: CGSize) -> CGSize {
        let natural = full?.size ?? (page.sizeIsExact ? page.size : nil)
        guard let natural, natural.width > 0, natural.height > 0 else { return available }
        let ratio = min(1, available.width / natural.width, available.height / natural.height)
        return CGSize(width: natural.width * ratio, height: natural.height * ratio)
    }
}

/// 图片窗口的标识。Image 不能编码，内容放在内存表里按 id 取；窗口不参与恢复，重启后不会出现空窗口。
struct ImageWindowID: Codable, Hashable {
    let id: UUID
}

@MainActor enum ImageWindowStore {
    static var items: [UUID: LightboxItem] = [:]
}

struct ImageWindowContent: View {
    let id: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let item = ImageWindowStore.items[id] {
            let ideal = Self.idealSize(item.pages.indices.contains(item.index) ? item.pages[item.index] : nil)
            ImageLightbox(item: item)
                .navigationTitle(item.pages.first.map { $0.title.isEmpty || $0.title == "Image" ? String(localized: "图片") : $0.title } ?? String(localized: "图片"))
                // 窗口按图片比例打开（PaseoApp 里的 defaultWindowPlacement 读这个理想尺寸）。
                .frame(idealWidth: ideal.width, idealHeight: ideal.height)
                .onDisappear { ImageWindowStore.items[id] = nil }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    /// 图片区按比例放进 1200×860 以内；已知原始尺寸更小时按原始大小，再加上顶部工具栏。
    static func idealSize(_ page: LightboxPage?) -> CGSize {
        let box = CGSize(width: 1200, height: 860)
        let toolbar: CGFloat = 50
        guard let size = page?.size, size.width > 0, size.height > 0 else { return CGSize(width: 1100, height: 820) }
        var ratio = min(box.width / size.width, box.height / size.height)
        if page?.sizeIsExact == true { ratio = min(ratio, 1) }
        return CGSize(width: max(size.width * ratio, 480), height: max(size.height * ratio, 320) + toolbar)
    }
}
#else
private struct PhoneImagePage: View {
    let page: LightboxPage
    let onDismiss: () -> Void
    @State private var full: UIImage?

    var body: some View {
        Group {
            if let full {
                ZoomableImageView(image: full, onDismiss: onDismiss, menu: menu)
            } else if let placeholder = page.placeholder {
                placeholder.resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: page.id) { full = await loadFullImage(page) }
    }

    /// 长按图片：存储或分享、拷贝。
    private var menu: UIMenu? {
        guard let source = page.source else { return nil }
        return UIMenu(children: [
            UIAction(title: String(localized: "存储或分享图片…"), image: UIImage(systemName: "square.and.arrow.up")) { _ in
                Task { await ImageExport.save(source) }
            },
            UIAction(title: String(localized: "拷贝图片"), image: UIImage(systemName: "doc.on.doc")) { _ in
                Task { await ImageExport.copy(source) }
            },
        ])
    }
}

/// UIScrollView 自带的捏合缩放：缩放中心跟手、可平移、松手回弹，双击在适合屏幕与放大之间切换。
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// 未放大时上下拖动一段距离松手：关闭。
    var onDismiss: (() -> Void)?
    /// 长按菜单。
    var menu: UIMenu?

    func makeUIView(context: Context) -> ZoomImageScrollView { ZoomImageScrollView() }

    func updateUIView(_ view: ZoomImageScrollView, context: Context) {
        if view.image !== image { view.image = image }
        view.onDismiss = onDismiss
        view.menu = menu
    }
}

final class ZoomImageScrollView: UIScrollView, UIScrollViewDelegate, UIContextMenuInteractionDelegate {
    private let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero
    var onDismiss: (() -> Void)?
    var menu: UIMenu?

    var image: UIImage? {
        didSet {
            imageView.image = image
            laidOutSize = .zero
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 8
        bouncesZoom = true
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = String(localized: "图片")
        imageView.addInteraction(UIContextMenuInteraction(delegate: self))
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 尺寸变了（首次布局、旋转）才回到适合屏幕；缩放过程中的布局不动它。
        if bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 {
            laidOutSize = bounds.size
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fittedSize())
            contentSize = imageView.frame.size
        }
        centerImage()
    }

    private func fittedSize() -> CGSize {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return bounds.size }
        let ratio = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * ratio, height: size.height * ratio)
    }

    private func centerImage() {
        let x = max((bounds.width - contentSize.width) / 2, 0)
        let y = max((bounds.height - contentSize.height) / 2, 0)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != inset { contentInset = inset }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard zoomScale <= minimumZoomScale + 0.01, let onDismiss else { return }
        let pulled = contentOffset.y + contentInset.top
        if abs(pulled) > 100 || abs(velocity.y) > 2 { onDismiss() }
    }

    @objc private func toggleZoom(_ g: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let p = g.location(in: imageView)
            let target: CGFloat = 2.5
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}
#endif

private struct LightboxPresenter: ViewModifier {
    @Binding var item: LightboxItem?
    var namespace: Namespace.ID?
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onChange(of: item?.id) { _, id in
            guard let id, let item else { return }
            ImageWindowStore.items[id] = item
            openWindow(value: ImageWindowID(id: id))
            self.item = nil
        }
        #else
        content.fullScreenCover(item: $item) { item in
            if let namespace {
                // 从点开的缩略图放大展开，关闭时缩回去。
                ImageLightbox(item: item).navigationTransition(.zoom(sourceID: item.sourceID, in: namespace))
            } else {
                ImageLightbox(item: item)
            }
        }
        #endif
    }
}

extension View {
    /// 打开大图：Mac 新窗口（可最大化 / 全屏），iPhone/iPad 全屏可双指缩放。
    /// 传 namespace 并给缩略图加 `lightboxSource` 时，iPhone 上从缩略图放大展开。
    func imageLightbox(_ item: Binding<LightboxItem?>, namespace: Namespace.ID? = nil) -> some View {
        modifier(LightboxPresenter(item: item, namespace: namespace))
    }

    /// 标记大图过渡的来源缩略图（只 iPhone/iPad 有效果）。
    @ViewBuilder func lightboxSource(_ id: String, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
        matchedTransitionSource(id: id, in: namespace)
        #else
        self
        #endif
    }
}

/// 一个会话里所有图片的登记表：每张缩略图显示时登记自己（含在时间线里的位置），点开任意一张时按从上到下的顺序
/// 组成图集，在整个会话的图片之间左右切换。引用类型、不触发视图刷新：滚动时更新位置不会让时间线重算。
/// 折叠起来的回合里的图不在视图里，不会进图集。
@MainActor final class LightboxGallery {
    static let coordinateSpace = "lightboxTimeline"

    private struct Entry {
        var page: LightboxPage
        var frame: CGRect
    }

    private var entries: [String: Entry] = [:]

    func register(_ key: String, page: LightboxPage, frame: CGRect) {
        entries[key] = Entry(page: page, frame: frame)
    }

    func updateFrame(_ key: String, _ frame: CGRect) {
        entries[key]?.frame = frame
    }

    func remove(_ key: String) {
        entries[key] = nil
    }

    /// 以 key 这张为起点的图集；同一张图出现多次只留第一次。没登记过返回 nil。
    func item(startingAt key: String) -> LightboxItem? {
        guard let selected = entries[key] else { return nil }
        let ordered = entries.values.sorted {
            abs($0.frame.minY - $1.frame.minY) > 1 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
        }
        var seen = Set<String>()
        let pages = ordered.map(\.page).filter { seen.insert($0.id).inserted }
        guard let index = pages.firstIndex(where: { $0.id == selected.page.id }) else { return nil }
        return LightboxItem(pages: pages, index: index)
    }
}

extension EnvironmentValues {
    @Entry var lightboxGallery: LightboxGallery? = nil
}

private struct LightboxGalleryEntry: ViewModifier {
    let key: String
    let page: LightboxPage?
    @Environment(\.lightboxGallery) private var gallery
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        if let gallery {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LightboxGallery.coordinateSpace)) } action: { f in
                    frame = f
                    gallery.updateFrame(key, f)
                }
                .onChange(of: page?.id, initial: true) {
                    if let page { gallery.register(key, page: page, frame: frame) } else { gallery.remove(key) }
                }
                .onDisappear { gallery.remove(key) }
        } else {
            content
        }
    }
}

extension View {
    /// 把这张图登记进当前会话的图集（外层提供了 `lightboxGallery` 时才生效）。page 为 nil 表示还没加载好，先不登记。
    func lightboxGalleryEntry(_ key: String, page: LightboxPage?) -> some View {
        modifier(LightboxGalleryEntry(key: key, page: page))
    }
}
