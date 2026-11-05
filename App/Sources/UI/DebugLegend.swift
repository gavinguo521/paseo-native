// DEBUG: PASEO_RENDER_LEGEND=<file.png> draws every sidebar / tab marker with the real components and quits.

#if DEBUG && os(macOS)
import PaseoKit
import SwiftUI

struct MarkerLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("侧栏会话标题前的状态").font(.headline)
            row("需要输入（等你批权限或回答问题）") { StatusDot(bucket: .needsInput) }
            row("失败（出错停下）") { StatusDot(bucket: .failed) }
            row("运行中（转动的蓝圈；超过 10 分钟没动静时行尾加橙色「N 分钟」）") { StatusDot(bucket: .running) }
            row("待查看（跑完了，你还没看）") { StatusDot(bucket: .attention) }
            row("已完成（看过了）：没有标记") { StatusDot(bucket: .done) }
            Divider()
            Text("会话行上的其他信息").font(.headline)
            row("工作区未提交的改动行数") {
                HStack(spacing: 3) {
                    Text("+151").foregroundStyle(Theme.diffAdd)
                    Text("−0").foregroundStyle(Theme.diffRemove)
                }.font(.system(size: 10.5, design: .monospaced))
            }
            row("PR 编号；左边的点是 CI：绿=通过、红=失败、橙=进行中") {
                HStack(spacing: 12) {
                    ForEach(["success", "failure", "pending"], id: \.self) { s in
                        HStack(spacing: 3) { ChecksDot(status: s); Text("#42").font(.system(size: 11, design: .monospaced)).fixedSize() }
                    }
                }
                .foregroundStyle(Theme.muted)
            }
            row("PR 已合并：紫色编号") { Text("#40").font(.system(size: 11, design: .monospaced)).foregroundStyle(SwiftUI.Color.purple) }
            row("按住 ⌘ 时显示的快捷键") {
                Text("⌘1").font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(Theme.muted)
            }
            row("分组折叠时：组里最急的那个状态") { StatusDot(bucket: .needsInput) }
        }
        .font(.system(size: 13))
        .padding(24)
        .frame(width: 620, alignment: .leading)
        .background(Theme.surface0)
    }

    private func row<M: View>(_ title: String, @ViewBuilder marker: () -> M) -> some View {
        HStack(spacing: 14) {
            marker().frame(width: 170, alignment: .trailing)
            Text(title).foregroundStyle(Theme.foreground)
        }
    }
}
#endif
