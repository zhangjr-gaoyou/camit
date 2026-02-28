import SwiftUI
import PDFKit

/// 简单的 PDF 文档查看器：支持缩放、滚动和关闭按钮
struct PDFViewer: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PDFKitContainer(url: url)
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(8)
                        .background(.black.opacity(0.28), in: Circle())
                }
                .padding(.trailing, 12)
                .padding(.top, 4)
            }
        }
    }
}

private struct PDFKitContainer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .black
        if let doc = PDFDocument(url: url) {
            view.document = doc
        }
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if let doc = PDFDocument(url: url) {
            uiView.document = doc
        }
    }
}

