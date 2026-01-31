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
    private var guideFrameView: UIView?
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
        updateGuideFrame()
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
        
        setupGuideFrame()
    }
    
    private func setupGuideFrame() {
        let frameView = UIView()
        frameView.backgroundColor = .clear
        frameView.layer.borderColor = UIColor.white.cgColor
        frameView.layer.borderWidth = 2
        frameView.layer.cornerRadius = 12
        view.addSubview(frameView)
        guideFrameView = frameView
        
        // 添加四个角标
        let cornerLength: CGFloat = 20
        let cornerWidth: CGFloat = 3
        let corners: [UIRectCorner] = [
            .topLeft,
            .topRight,
            .bottomLeft,
            .bottomRight
        ]
        
        for corner in corners {
            let horizontal = UIView()
            horizontal.backgroundColor = .systemYellow
            frameView.addSubview(horizontal)
            
            let vertical = UIView()
            vertical.backgroundColor = .systemYellow
            frameView.addSubview(vertical)
            
            horizontal.translatesAutoresizingMaskIntoConstraints = false
            vertical.translatesAutoresizingMaskIntoConstraints = false
            
            switch corner {
            case .topLeft:
                NSLayoutConstraint.activate([
                    horizontal.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
                    horizontal.topAnchor.constraint(equalTo: frameView.topAnchor),
                    horizontal.widthAnchor.constraint(equalToConstant: cornerLength),
                    horizontal.heightAnchor.constraint(equalToConstant: cornerWidth),
                    
                    vertical.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
                    vertical.topAnchor.constraint(equalTo: frameView.topAnchor),
                    vertical.widthAnchor.constraint(equalToConstant: cornerWidth),
                    vertical.heightAnchor.constraint(equalToConstant: cornerLength)
                ])
            case .topRight:
                NSLayoutConstraint.activate([
                    horizontal.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
                    horizontal.topAnchor.constraint(equalTo: frameView.topAnchor),
                    horizontal.widthAnchor.constraint(equalToConstant: cornerLength),
                    horizontal.heightAnchor.constraint(equalToConstant: cornerWidth),
                    
                    vertical.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
                    vertical.topAnchor.constraint(equalTo: frameView.topAnchor),
                    vertical.widthAnchor.constraint(equalToConstant: cornerWidth),
                    vertical.heightAnchor.constraint(equalToConstant: cornerLength)
                ])
            case .bottomLeft:
                NSLayoutConstraint.activate([
                    horizontal.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
                    horizontal.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
                    horizontal.widthAnchor.constraint(equalToConstant: cornerLength),
                    horizontal.heightAnchor.constraint(equalToConstant: cornerWidth),
                    
                    vertical.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
                    vertical.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
                    vertical.widthAnchor.constraint(equalToConstant: cornerWidth),
                    vertical.heightAnchor.constraint(equalToConstant: cornerLength)
                ])
            case .bottomRight:
                NSLayoutConstraint.activate([
                    horizontal.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
                    horizontal.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
                    horizontal.widthAnchor.constraint(equalToConstant: cornerLength),
                    horizontal.heightAnchor.constraint(equalToConstant: cornerWidth),
                    
                    vertical.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
                    vertical.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
                    vertical.widthAnchor.constraint(equalToConstant: cornerWidth),
                    vertical.heightAnchor.constraint(equalToConstant: cornerLength)
                ])
            default:
                break
            }
        }
        
        // 添加提示文字
        let label = UILabel()
        label.text = "将试卷对准框内"
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        label.layer.cornerRadius = 6
        label.clipsToBounds = true
        view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            label.heightAnchor.constraint(equalToConstant: 32),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        label.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    }
    
    private func updateGuideFrame() {
        guard let frameView = guideFrameView else { return }
        
        // 取景框尺寸：A4 纸比例约 1:1.414（宽:高），留边距
        let margin: CGFloat = 40
        let availableWidth = view.bounds.width - margin * 2
        let availableHeight = view.bounds.height - margin * 2 - view.safeAreaInsets.top - view.safeAreaInsets.bottom
        
        // 按 A4 比例计算
        let a4Ratio: CGFloat = 1.0 / 1.414
        var frameWidth = availableWidth
        var frameHeight = frameWidth / a4Ratio
        
        if frameHeight > availableHeight {
            frameHeight = availableHeight
            frameWidth = frameHeight * a4Ratio
        }
        
        let frameX = (view.bounds.width - frameWidth) / 2
        let frameY = (view.bounds.height - frameHeight) / 2
        
        frameView.frame = CGRect(x: frameX, y: frameY, width: frameWidth, height: frameHeight)
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
        
        // 根据取景框裁剪图片
        let croppedImage = cropImageToGuideFrame(image)
        onImagePicked(croppedImage)
        onDismiss()
    }
    
    /// 根据取景框裁剪图片
    private func cropImageToGuideFrame(_ image: UIImage) -> UIImage {
        guard let guideFrame = guideFrameView?.frame,
              let previewLayer = previewLayer else {
            return image
        }
        
        // 先校正图片方向
        let normalizedImage = normalizeImageOrientation(image)
        guard let cgImage = normalizedImage.cgImage else { return image }
        
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let previewSize = previewLayer.bounds.size
        
        // 计算预览层中实际显示的图片区域（考虑 .resizeAspectFill）
        let imageAspect = imageSize.width / imageSize.height
        let previewAspect = previewSize.width / previewSize.height
        
        var visibleRect: CGRect
        if imageAspect > previewAspect {
            // 图片更宽，左右被裁剪
            let visibleWidth = previewAspect * imageSize.height
            let offsetX = (imageSize.width - visibleWidth) / 2
            visibleRect = CGRect(x: offsetX, y: 0, width: visibleWidth, height: imageSize.height)
        } else {
            // 图片更高，上下被裁剪
            let visibleHeight = imageSize.width / previewAspect
            let offsetY = (imageSize.height - visibleHeight) / 2
            visibleRect = CGRect(x: 0, y: offsetY, width: imageSize.width, height: visibleHeight)
        }
        
        // 将取景框在预览中的位置转换为图片坐标
        let scaleX = visibleRect.width / previewSize.width
        let scaleY = visibleRect.height / previewSize.height
        
        let cropX = visibleRect.origin.x + guideFrame.origin.x * scaleX
        let cropY = visibleRect.origin.y + guideFrame.origin.y * scaleY
        let cropWidth = guideFrame.width * scaleX
        let cropHeight = guideFrame.height * scaleY
        
        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
        
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return normalizedImage }
        return UIImage(cgImage: croppedCGImage)
    }
    
    /// 校正图片方向，返回正向的图片
    private func normalizeImageOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return normalizedImage ?? image
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
