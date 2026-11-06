import Foundation

extension HostStore {
    /// The daemon's canonical user rows omit attachments. Store a small sidecar keyed by
    /// the unchanged client message ID, using existing file APIs instead of changing prompts.
    /// Publish BEFORE dispatch so another client can resolve the very first streamed row.
    func persistMessageImages(_ images: [ImageAttachment], messageId: String) async throws {
        guard !images.isEmpty else { return }
        let c = try conn()
        let info = await c.serverInfo
        guard info?.hasFeature("fsEntryOps") == true,
              info?.hasFeature("workspaceFileEditing") == true else { throw MessageImageError.unavailable }
        let fingerprints = images.map { MessageImageManifest.digest($0.data) }
        let existing = try await messageImages(messageId)
        if !existing.isEmpty {
            guard existing.map(\.sha256) == fingerprints, existing.map(\.mimeType) == images.map(\.mimeType) else {
                throw MessageImageError.invalidManifest
            }
            return
        }
        var references: [MessageImage] = []
        for (index, image) in images.enumerated() {
            let suffix = image.mimeType == "image/png" ? "png" : image.mimeType == "image/jpeg" ? "jpg" : "image"
            let file = try await upload(fileName: "image-\(index + 1).\(suffix)", mimeType: image.mimeType, data: image.data)
            guard let path = file.attachment["path"]?.stringValue, path.hasPrefix("/") else { throw MessageImageError.invalidManifest }
            references.append(MessageImage(id: file.id, path: path, mimeType: image.mimeType, sha256: fingerprints[index]))
        }
        let manifest = MessageImageManifest(messageId: messageId, images: references)
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= MessageImageManifest.maxBytes, let content = String(data: data, encoding: .utf8) else {
            throw MessageImageError.invalidManifest
        }
        try await ensureMessageImageDirectory(c)
        let name = MessageImageManifest.fileName(messageId)
        let created = try await c.request("fs.entry.create.request", [
            "cwd": .string(MessageImageManifest.directory), "parentPath": ".", "name": .string(name), "kind": "file",
        ])
        // Read the revision even after create: a simultaneous retry must never overwrite a
        // different, already-published attachment list for the same idempotency key.
        let file = try await readMessageImageFile(messageId, connection: c)
        guard let file else {
            messageImageDirectoryTask = nil
            throw ActionError.rejected(created["payload"]?["error"]?.stringValue ?? MessageImageError.unavailable.description)
        }
        if let text = file["content"]?.stringValue, !text.isEmpty {
            let winner = try MessageImageManifest.decode(Data(text.utf8), messageId: messageId)
            guard winner.images.map(\.sha256) == fingerprints, winner.images.map(\.mimeType) == images.map(\.mimeType) else {
                throw MessageImageError.invalidManifest
            }
            await messageImageCache.remember(winner.images, for: messageId)
            return
        }
        guard let revision = file["revision"]?.stringValue, let modified = file["modifiedAt"]?.stringValue else {
            throw MessageImageError.unavailable
        }
        let written = try await c.request("fs.file.write.request", [
            "cwd": .string(MessageImageManifest.directory), "path": .string(name),
            "content": .string(content), "contentEncoding": "utf-8", "expectedRevision": .string(revision),
            "expectedModifiedAt": .string(modified),
        ])
        guard written["payload"]?["result"]?["status"]?.stringValue == "written" else { throw MessageImageError.unavailable }
        await messageImageCache.remember(references, for: messageId)
    }

    public func messageImages(_ messageId: String) async throws -> [MessageImage] {
        let c = try conn()
        return try await messageImageCache.load(messageId) { [weak self] in
            guard let self else { throw CancellationError() }
            guard let file = try await self.readMessageImageFile(messageId, connection: c) else { return nil }
            guard file["encoding"]?.stringValue == "utf-8", let content = file["content"]?.stringValue else {
                throw MessageImageError.invalidManifest
            }
            if content.isEmpty { return nil } // reserved file from an interrupted publication
            return Data(content.utf8)
        }
    }

    private func readMessageImageFile(_ messageId: String, connection c: DaemonConnection) async throws -> JSONValue? {
        let r = try await c.request("file_explorer_request", [
            "cwd": .string(MessageImageManifest.directory), "path": .string(MessageImageManifest.fileName(messageId)),
            "mode": "file", "acceptBinary": false, "maxBytes": .number(Double(MessageImageManifest.maxBytes)),
        ], timeout: .seconds(8))
        if let error = r["payload"]?["error"]?.stringValue {
            if error.contains("ENOENT") { return nil }
            throw ActionError.rejected(error)
        }
        guard let file = r["payload"]?["file"], file != .null else { throw MessageImageError.unavailable }
        return file
    }

    private func ensureMessageImageDirectory(_ c: DaemonConnection) async throws {
        if let task = messageImageDirectoryTask { return try await task.value }
        let task = Task {
            for (parent, name) in [("~/.paseo", "native-message-images"), ("~/.paseo/native-message-images", "v1")] {
                let r = try await c.request("fs.entry.create.request", [
                    "cwd": .string(parent), "parentPath": ".", "name": .string(name), "kind": "directory",
                ])
                if r["payload"]?["success"]?.boolValue == true { continue }
                // Another device may have created it. Verify it really is a directory.
                let check = try await c.request("file_explorer_request", [
                    "cwd": .string(parent + "/" + name), "path": ".", "mode": "list",
                ])
                guard check["payload"]?["directory"] != nil, check["payload"]?["directory"] != .null,
                      check["payload"]?["error"] == nil || check["payload"]?["error"] == .null else {
                    throw MessageImageError.unavailable
                }
            }
        }
        messageImageDirectoryTask = task
        do { try await task.value } catch { messageImageDirectoryTask = nil; throw error }
    }
}
