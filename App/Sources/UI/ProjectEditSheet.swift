// Edit a project's name and icon (official components/project-edit-sheet.tsx: rename + custom icon / automatic).
// Both are per machine: the same folder on another machine is a separate project.

import ImageIO
import PaseoKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The project being edited and its machine.
struct ProjectEditTarget: Identifiable {
    let host: HostStore
    let project: Project
    var id: String { host.id + "/" + project.id }
}

struct ProjectEditSheet: View {
    let host: HostStore
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    /// Square PNG picked for the icon, not yet saved.
    @State private var picked: Data?
    @State private var useAutomatic = false
    @State private var importing = false
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    #endif
    @State private var saving = false
    @State private var error: String?

    init(host: HostStore, project: Project) {
        self.host = host
        self.project = project
        _name = State(initialValue: project.displayName)
    }

    private var supportsIcon: Bool { host.serverInfo?.hasFeature("projectCustomIcon") == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字", text: $name)
                } header: {
                    Text("名字")
                } footer: {
                    Text("留空恢复成按目录得到的默认名字。只改「\(host.label)」上的这个项目。")
                }
                if supportsIcon {
                    Section {
                        HStack(spacing: 14) {
                            preview.frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 6) {
                                #if os(iOS)
                                PhotosPicker("从相册选择…", selection: $photo, matching: .images)
                                Button("从文件选择…") { importing = true }
                                #else
                                Button("选择图片…") { importing = true }
                                #endif
                                Button("使用自动图标") { picked = nil; useAutomatic = true }
                            }
                            .buttonStyle(.borderless)
                        }
                    } header: {
                        Text("图标")
                    } footer: {
                        Text(useAutomatic ? "保存后恢复自动图标（项目里的 logo 或首字）。" : "图片会裁成正方形、缩到 256 像素。")
                    }
                }
                if let error {
                    Text(error).foregroundStyle(Theme.destructive)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("编辑项目")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "正在保存…" : "保存") { save() }.disabled(saving)
                }
            }
            #if os(iOS)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { usePicked(data) }
                    else { error = String(localized: "读不了这张照片，换一张试试") }
                }
            }
            #endif
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { usePicked(data) } else { error = String(localized: "读不了这张图片，换一张 PNG 或 JPEG 试试") }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 320)
        #endif
    }

    private func usePicked(_ data: Data) {
        if let png = IconImage.squarePNG(data) {
            picked = png
            useAutomatic = false
            error = nil
        } else {
            error = String(localized: "读不了这张图片，换一张 PNG 或 JPEG 试试")
        }
    }

    @ViewBuilder private var preview: some View {
        if let picked, let image = IconImage.image(picked) {
            image.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
        } else if useAutomatic {
            Image(systemName: "wand.and.stars").font(.system(size: 20)).foregroundStyle(Theme.muted)
        } else {
            ProjectIcon(host: host, name: project.displayName, workspace: nil, size: 44, project: project)
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != project.displayName { try await host.renameProject(project.id, name: trimmed) }
                if let picked {
                    try await host.setProjectIcon(project.id, base64: picked.base64EncodedString())
                } else if useAutomatic {
                    try await host.setProjectIcon(project.id, base64: nil)
                }
                dismiss()
            } catch {
                self.error = String(localized: "保存失败：\(error)")
            }
            saving = false
        }
    }
}

/// Project icon images: the daemon takes a square image up to 1024×1024 and 512 KB.
enum IconImage {
    /// Center-crops to a square and scales down to at most `side` pixels, as PNG. Honors EXIF orientation.
    static func squarePNG(_ data: Data, side: Int = 256) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let edge = min(image.width, image.height)
        guard edge > 0, let square = image.cropping(to: CGRect(x: (image.width - edge) / 2, y: (image.height - edge) / 2,
                                                                 width: edge, height: edge)) else { return nil }
        let out = min(side, edge)
        guard let ctx = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: out, height: out))
        guard let final = ctx.makeImage() else { return nil }
        let result = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, final, nil)
        return CGImageDestinationFinalize(dest) ? result as Data : nil
    }

    static func image(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}
