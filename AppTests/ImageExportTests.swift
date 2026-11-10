import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Paseo

struct ImageExportTests {
    @Test func namesComeFromPathOrURLWithRealExtension() {
        #expect(ImageExport.fileName("/tmp/shots/home page.png", type: .png) == "home page.png")
        #expect(ImageExport.fileName("https://x.dev/a/b/chart.webp?v=2", type: .jpeg) == "chart.jpeg")
        #expect(ImageExport.fileName("file:///Users/me/%E5%9B%BE.png", type: .png) == "图.png")
    }

    @Test func missingNamesFallBackToTimestamp() {
        for hint in ["", "Image", "图片"] {
            let name = ImageExport.fileName(hint, type: .png)
            #expect(name.hasPrefix("图片-") && name.hasSuffix(".png"), "\(hint) → \(name)")
        }
    }

    @Test func detectsFormatFromBytes() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        #expect(ImageExport.type(of: png) == .png)
        let url = try ImageExport.temporaryFile(png, name: "a.png")
        #expect(FileManager.default.fileExists(atPath: url.path) && url.lastPathComponent == "a.png")
    }

    /// 拖到 Finder 时系统走文件表示，拖进其他 App 走数据表示；两条都要拿到原图。
    @Test func dragProviderHandsOverOriginalFileAndData() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        let provider = ImageExport.itemProvider(ImageSource(name: "/tmp/shots/home.png", data: png), type: nil)
        #expect(provider.suggestedName == "home")
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.image.identifier))
        let file: (name: String, data: Data?) = try await withCheckedThrowingContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) { url, error in
                if let url { done.resume(returning: (url.lastPathComponent, try? Data(contentsOf: url))) }
                else { done.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        #expect(file.name.hasSuffix(".png"))
        #expect(file.data == png)
        let data: Data = try await withCheckedThrowingContinuation { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, error in
                if let data { done.resume(returning: data) } else { done.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        #expect(data == png)
    }

    @Test func failedLoadReportsErrorInsteadOfEmptyFile() async {
        let provider = ImageExport.itemProvider(ImageSource(name: "x.png") { nil }, type: .png)
        let failed = await withCheckedContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) { url, error in
                done.resume(returning: url == nil && error != nil)
            }
        }
        #expect(failed)
    }
}
