import SwiftUI
import UniformTypeIdentifiers

/// 文件选择器：支持从“文件”App 中选择任意文档或图片
struct DocumentPicker: UIViewControllerRepresentable {
    var onPicked: ([URL]) -> Void
    var onDismiss: () -> Void

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker

        init(parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPicked(urls)
            parent.onDismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onDismiss()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // 支持选择 PDF 及常见办公文档，统一复制到 App 沙盒
        let types: [UTType] = [.pdf, .item]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

