// Adding a machine on iPhone/iPad: scan the QR code `paseo daemon pair` prints, with the camera or from a photo.

#if os(iOS)
import AVFoundation
import CoreImage
import PaseoKit
import PhotosUI
import SwiftUI
import Vision
import VisionKit

struct QRScannerSheet: View {
    /// Called with a pairing link that parses; the sheet closes itself.
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var camera: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var photo: PhotosPickerItem?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    ContentUnavailableView("这台设备不能扫码", systemImage: "camera",
                                           description: Text("可以点右上角从照片识别二维码"))
                } else if camera == .denied || camera == .restricted {
                    ContentUnavailableView {
                        Label("没有相机权限", systemImage: "camera")
                    } description: {
                        Text("到系统设置里允许 Paseo 使用相机，或从照片识别")
                    } actions: {
                        Button("打开设置") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                    }
                } else if camera == .authorized {
                    QRCameraView { handle($0) }.ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottom) {
                Text(message ?? "对准电脑上 paseo daemon pair 显示的二维码")
                    .font(.callout)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.bottom, 24)
            }
            .navigationTitle("扫描配对二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    PhotosPicker(selection: $photo, matching: .images) { Label("从照片识别", systemImage: "photo") }
                }
            }
            .task {
                if camera == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                    camera = AVCaptureDevice.authorizationStatus(for: .video)
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { message = "读不了这张图片"; return }
                    let codes = await Self.qrCodes(in: data)
                    if codes.isEmpty { message = "这张图片里没有找到二维码" }
                    else if !codes.contains(where: handle) { message = "这不是 Paseo 的配对二维码" }
                }
            }
        }
    }

    /// True (and done) when the payload is a pairing link.
    @discardableResult private func handle(_ payload: String) -> Bool {
        let link = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? PairingOffer.parse(link)) != nil else {
            message = "这不是 Paseo 的配对二维码"
            return false
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onFound(link)
        dismiss()
        return true
    }

    static func qrCodes(in data: Data) async -> [String] {
        guard let image = UIImage(data: data)?.cgImage else { return [] }
        return await Task.detached {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let found = (request.results ?? []).compactMap(\.payloadStringValue)
            if !found.isEmpty { return found }
            // Vision's model needs the Neural Engine (empty in the simulator); Core Image's detector works anywhere.
            let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            return (detector?.features(in: CIImage(cgImage: image)) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        }.value
    }
}

/// The system scanner (VisionKit), QR codes only; reports every payload it sees until one is accepted.
private struct QRCameraView: UIViewControllerRepresentable {
    let onPayload: (String) -> Bool

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPayload: (String) -> Bool
        private var done = false
        init(onPayload: @escaping (String) -> Bool) { self.onPayload = onPayload }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in items {
                if let s = code.payloadStringValue, onPayload(s) { done = true; scanner.stopScanning(); return }
            }
        }
    }
}
#endif
