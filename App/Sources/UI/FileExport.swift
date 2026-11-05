// Files of a workspace outside the app: Quick Look, reveal in Finder, drag to other apps.
// A host on this Mac uses the real file; a remote one is fetched into a temporary folder first.

#if os(macOS)
import AppKit
import CoreTransferable
import PaseoKit
import SwiftUI
import UniformTypeIdentifiers

enum HostFiles {
    /// The daemon of this Mac (~/.paseo/server-id); its paths are local paths.
    private static let localServerId: String? = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".paseo/server-id")
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    static func isLocal(_ host: HostStore) -> Bool { localServerId != nil && host.id == localServerId }

    /// A file URL other apps can read: the file itself on this Mac, else a downloaded copy.
    @MainActor static func materialize(host: HostStore, path: String) async throws -> URL {
        if isLocal(host), FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        let dir = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        let content = try await host.readFile(cwd: dir, path: name)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Paseo Files", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try content.data.write(to: url)
        return url
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// Dragging a workspace file out to Finder, Mail, another editor…
struct HostFileDrag: Transferable {
    let host: HostStore
    let path: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            SentTransferredFile(try await HostFiles.materialize(host: file.host, path: file.path))
        }
        .suggestedFileName { ($0.path as NSString).lastPathComponent }
    }
}

extension View {
    /// Drag a file row out of the app; `path` is absolute on the host.
    func hostFileDrag(host: HostStore, path: String) -> some View {
        draggable(HostFileDrag(host: host, path: path)) {
            Label((path as NSString).lastPathComponent, systemImage: "doc")
        }
    }
}

struct HostFileMenuItems: View {
    let host: HostStore
    let path: String
    @Binding var quickLook: URL?

    var body: some View {
        Button("快速查看", systemImage: "eye") { preview(host: host, path: path, into: $quickLook) }
        if HostFiles.isLocal(host) {
            Button("在访达中显示", systemImage: "folder") { HostFiles.reveal(path) }
        }
    }
}

/// Fetch (if remote) and show the file in Quick Look.
@MainActor func preview(host: HostStore, path: String, into quickLook: Binding<URL?>) {
    Task {
        if let url = try? await HostFiles.materialize(host: host, path: path) { quickLook.wrappedValue = url }
    }
}
#endif
