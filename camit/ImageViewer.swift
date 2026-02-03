import SwiftUI
import UIKit

// MARK: - 用 UIViewController 包装 UIScrollView，保证捏合手势能正确传递（SwiftUI 内嵌时 UIViewRepresentable 易丢触摸）
private final class ZoomableImageViewController: UIViewController {
    private let image: UIImage
    private let imageViewTag = 100
    private var scrollView: UIScrollView!
    private var imageView: UIImageView!
    private var baseContentSize: CGSize = .zero

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .black
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.tag = imageViewTag
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)
        scrollView.addSubview(imageView)
        layoutImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 {
            layoutImage()
        }
    }

    func setImage(_ newImage: UIImage) {
        imageView.image = newImage
        scrollView.zoomScale = scrollView.minimumZoomScale
        layoutImage()
    }

    private func layoutImage() {
        guard let img = imageView.image, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let size = view.bounds.size
        let wRatio = size.width / img.size.width
        let hRatio = size.height / img.size.height
        let ratio = min(wRatio, hRatio, 1.0)
        let w = img.size.width * ratio
        let h = img.size.height * ratio
        baseContentSize = CGSize(width: w, height: h)
        imageView.frame = CGRect(x: 0, y: 0, width: w, height: h)
        scrollView.contentSize = baseContentSize
        centerImageView()
    }

    private func centerImageView() {
        let boundsSize = scrollView.bounds.size
        var f = imageView.frame
        if f.width < boundsSize.width {
            f.origin.x = (boundsSize.width - f.width) / 2
        } else {
            f.origin.x = 0
        }
        if f.height < boundsSize.height {
            f.origin.y = (boundsSize.height - f.height) / 2
        } else {
            f.origin.y = 0
        }
        imageView.frame = f
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let loc = g.location(in: imageView)
            let rect = CGRect(x: loc.x - 40, y: loc.y - 40, width: 80, height: 80)
            scrollView.zoom(to: rect, animated: true)
        }
    }
}

extension ZoomableImageViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        scrollView.viewWithTag(imageViewTag)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        scrollView.contentSize = CGSize(
            width: baseContentSize.width * scrollView.zoomScale,
            height: baseContentSize.height * scrollView.zoomScale
        )
        centerImageView()
    }
}

private struct ZoomableImageUIView: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> ZoomableImageViewController {
        ZoomableImageViewController(image: image)
    }

    func updateUIViewController(_ vc: ZoomableImageViewController, context: Context) {
        if context.coordinator.lastImage !== image {
            context.coordinator.lastImage = image
            vc.setImage(image)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var lastImage: UIImage?
    }
}

struct ImageViewer: View {
    let image: UIImage
    /// 为 false 时仅展示图片，不支持缩放和拖动（用于试卷多图左右滑动查看）。
    var allowZoomAndPan: Bool = true
    /// 为 true 时在关闭按钮左侧显示「转向错题」按钮，点击后跳转到错题页该试卷
    var showNavigateButton: Bool = false
    var onNavigateToWrong: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if allowZoomAndPan {
                ZoomableImageUIView(image: image)
                    .ignoresSafeArea()
            } else {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }

            HStack(spacing: 8) {
                if showNavigateButton, let onNavigateToWrong {
                    Button {
                        onNavigateToWrong()
                    } label: {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(8)
                    }
                    .accessibilityLabel(L10n.wrongNavigateTo)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding()
                }
            }
        }
    }
}

#Preview {
    if let sample = UIImage(systemName: "doc.text") {
        ImageViewer(image: sample)
    }
}

