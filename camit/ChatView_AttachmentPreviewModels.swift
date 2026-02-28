import UIKit

/// 当前正在预览的图片附件
struct ImagePreviewItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// 当前正在预览的文件附件（PDF/Word）
struct FilePreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

