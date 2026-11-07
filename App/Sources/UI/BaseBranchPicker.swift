import PaseoKit
import SwiftUI

struct BaseBranchPicker: View {
    let host: HostStore
    let workspace: Workspace
    let currentBase: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var branches: [HostStore.BranchOption] = []
    @State private var selection: String?
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("切换基准分支").font(.headline)
            Text("当前基准：\(currentBase)").font(.caption).foregroundStyle(Theme.muted)
            Text("修改用于比较差异和合并的基准，不会切换当前分支或修改文件。")
                .font(.caption).foregroundStyle(Theme.muted)
            TextField("搜索分支", text: $query).textFieldStyle(.roundedBorder).disabled(saving)
            if loading { ProgressView() }
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.destructive).textSelection(.enabled)
                Button("重试") { retry += 1 }.disabled(saving)
            }
            List(branches) { branch in
                Button { selection = branch.refName } label: {
                    HStack {
                        Image(systemName: selection == branch.refName ? "checkmark.circle.fill" : "circle")
                        Text(branch.label)
                        Spacer()
                        Text(branch.detail).foregroundStyle(Theme.muted)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .disabled(saving || loading)
            if !loading && error == nil && branches.isEmpty {
                Text("没有匹配的分支").font(.caption).foregroundStyle(Theme.muted)
            }
            HStack {
                Button("取消") { dismiss() }.disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection == nil || saving || loading || host.state != .connected)
            }
        }
        .padding(20)
        .frame(idealWidth: 440, maxWidth: 560, minHeight: 380, idealHeight: 480)
        .interactiveDismissDisabled(saving)
        .task(id: query + "\u{0}" + String(retry)) { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        selection = nil
        branches = []
        do {
            let result = try await host.fetchBranchSuggestions(cwd: workspace.directory, query: query)
            guard !Task.isCancelled else { return }
            branches = result
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            self.error = String(describing: error)
            loading = false
        }
    }

    private func save() {
        guard let selection else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await host.setWorkspaceBaseBranch(workspace, baseRef: selection)
                dismiss()
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}
