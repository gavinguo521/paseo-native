import Foundation
import ImageIO

/// 文件读取、快照写入和缩略图解码都在主线程外；缓存按字节数限制。
actor TimelineImageLoader {
    static let shared = TimelineImageLoader()
    private let images = NSCache<NSString, CGImage>()
    private let bytes = NSCache<NSString, NSData>()
    private var transfers: [String: Task<Data?, Never>] = [:]

    init() {
        images.totalCostLimit = 64 * 1024 * 1024
        bytes.totalCostLimit = 32 * 1024 * 1024
    }

    func image(key: String, url: String, snapshotKey: String?, maxPixel: Int?, reader: HostFileReader?) async -> CGImage? {
        let imageKey = "\(key)|\(maxPixel ?? 0)" as NSString
        if let hit = images.object(forKey: imageKey) { return hit }
        guard let data = await data(key: key, url: url, snapshotKey: snapshotKey, reader: reader),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let originalSize = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 1,
                               properties?[kCGImagePropertyPixelHeight] as? Int ?? 1)
        // 原尺寸也走方向变换，避免手机照片在放大后旋转。
        let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel ?? originalSize,
        ] as CFDictionary)
        if let cg { images.setObject(cg, forKey: imageKey, cost: cg.bytesPerRow * cg.height) }
        return cg
    }

    /// 原始字节：存储、拷贝和拖出图片时用，通常已在字节缓存里。
    func data(key: String, url: String, snapshotKey: String?, reader: HostFileReader?) async -> Data? {
        if let hit = bytes.object(forKey: key as NSString) { return hit as Data }
        if let transfer = transfers[key] { return await transfer.value }
        let task = Task<Data?, Never> {
            if let snapshotKey, let data = ImageSnapshotCache.load(snapshotKey) { return data }
            var data: Data?
            if let u = URL(string: url), u.scheme == "http" || u.scheme == "https" {
                if let (body, response) = try? await URLSession.shared.data(from: u),
                   let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) { data = body }
            } else {
                #if os(macOS)
                if let u = URL(string: url), u.isFileURL { data = try? Data(contentsOf: u) }
                #endif
                if data == nil, let reader {
                    let path = URL(string: url).flatMap { $0.isFileURL ? $0.path : nil } ?? url
                    data = await reader.read(path)
                }
            }
            if let data, let snapshotKey { ImageSnapshotCache.save(data, key: snapshotKey) }
            return data
        }
        transfers[key] = task
        let data = await task.value
        transfers[key] = nil
        if let data { bytes.setObject(data as NSData, forKey: key as NSString, cost: data.count) }
        return data
    }
}
