// 「选择文本」保留为整条消息的纯文本入口，可跨过时间线内表格、图片等独立交互区域。
// 助手正文的连续文字区已支持原位跨段选择，无须先打开此弹窗。

import SwiftUI

struct SelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .navigationTitle("选择文本")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button(copied ? "已复制" : "全部复制") { Pasteboard.copy(text); copied = true }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
    }
}

#if os(macOS)
/// macOS 上一个 Text 就能用鼠标拖选任意范围。
private struct SelectableText: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: Theme.content))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
    }
}
#else
/// iOS 上 Text 的 textSelection 只能整块复制，拖选范围要用只读的 UITextView。
private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.backgroundColor = .clear
        v.font = .systemFont(ofSize: Theme.content)
        v.textColor = .label
        v.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        v.alwaysBounceVertical = true
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
    }
}
#endif
