import SwiftUI
import UIKit
import AVFoundation

// MARK: - 自定义相机（无镜头翻转，供底部栏「取消 | 拍照 | 从相册选择」使用）

/// 持有拍照触发闭包，由 VC 设置、SwiftUI 调用，避免跨边界传递 @escaping
final class CaptureTriggerHolder {
    var trigger: (() -> Void)?
}

final class CustomCameraViewController: UIViewController {
    private var captureSession: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var onImagePicked: (UIImage?) -> Void
    private var onDismiss: () -> Void
    var triggerHolder: CaptureTriggerHolder?

    init(onImagePicked: @escaping (UIImage?) -> Void, onDismiss: @escaping () -> Void) {
        self.onImagePicked = onImagePicked
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        captureSession?.startRunning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            onDismiss()
            return
        }
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCapturePhotoOutput()
        if session.canAddOutput(output) { session.addOutput(output) }
        photoOutput = output
        captureSession = session

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        triggerHolder?.trigger = { [weak self] in
            self?.capturePhoto()
        }
    }

    func capturePhoto() {
        guard let photoOutput = photoOutput else { return }
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

extension CustomCameraViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            onImagePicked(nil)
            onDismiss()
            return
        }
        onImagePicked(image)
        onDismiss()
    }
}

struct CustomCameraView: UIViewControllerRepresentable {
    var onImagePicked: (UIImage?) -> Void
    var onDismiss: () -> Void
    var triggerHolder: CaptureTriggerHolder

    func makeUIViewController(context: Context) -> CustomCameraViewController {
        let vc = CustomCameraViewController(onImagePicked: onImagePicked, onDismiss: onDismiss)
        vc.triggerHolder = triggerHolder
        return vc
    }

    func updateUIViewController(_ uiViewController: CustomCameraViewController, context: Context) {}
}
