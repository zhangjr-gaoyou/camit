import SwiftUI
import UIKit

struct ImageViewer: View {
    let image: UIImage
    /// 为 false 时仅展示图片，不支持缩放和拖动（用于试卷多图左右滑动查看）。
    var allowZoomAndPan: Bool = true
    /// 为 true 时在关闭按钮左侧显示「转向错题」按钮，点击后跳转到错题页该试卷
    var showNavigateButton: Bool = false
    var onNavigateToWrong: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                let size = proxy.size
                let imageContent = Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(allowZoomAndPan ? scale : 1.0)
                    .offset(allowZoomAndPan ? offset : .zero)
                    .animation(.spring(response: 0.25, dampingFraction: 0.9), value: scale)
                    .animation(.spring(response: 0.25, dampingFraction: 0.9), value: offset)

                if allowZoomAndPan {
                    imageContent.gesture(zoomAndPanGesture)
                } else {
                    imageContent
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

    private var zoomAndPanGesture: some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    scale = min(max(1.0, lastScale * value), 4.0)
                }
                .onEnded { _ in
                    lastScale = scale
                },
            DragGesture()
                .onChanged { value in
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                }
                .onEnded { _ in
                    lastOffset = offset
                }
        )
    }
}

#Preview {
    if let sample = UIImage(systemName: "doc.text") {
        ImageViewer(image: sample)
    }
}

