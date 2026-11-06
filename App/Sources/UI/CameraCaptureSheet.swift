#if os(iOS)
import AVFoundation
import PaseoKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// System still-photo capture. A confirmed photo joins the draft; Cancel leaves it unchanged.
struct CameraCaptureSheet: View {
    let onCapture: (ImageAttachment) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)

    private var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        Group {
            if available, authorization == .authorized {
                CameraPicker { image in
                    if let image, let attachment = ImageTools.cameraAttachment(from: image) {
                        onCapture(attachment)
                    }
                    dismiss()
                }
                .ignoresSafeArea()
            } else {
                NavigationStack {
                    Group {
                        if available, authorization == .notDetermined {
                            ProgressView()
                        } else {
                            ContentUnavailableView {
                                Label(available ? String(localized: "没有相机权限") : String(localized: "相机不可用"), systemImage: "camera")
                            } description: {
                                Text(available ? String(localized: "请在系统设置中允许 Paseo 使用相机拍照") : String(localized: "此设备没有可用的相机，可以从相册或文件添加图片"))
                            } actions: {
                                if available, authorization == .denied {
                                    Button("打开设置") {
                                        if let url = URL(string: UIApplication.openSettingsURLString) {
                                            UIApplication.shared.open(url)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("相机拍照")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { dismiss() }
                        }
                    }
                }
            }
        }
        .task {
            if available, authorization == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                authorization = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { authorization = AVCaptureDevice.authorizationStatus(for: .video) }
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
#endif
