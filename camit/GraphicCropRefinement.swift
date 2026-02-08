import Foundation
import UIKit
import CoreGraphics

/// 方案 C：在 VL 给出的 bbox 区域内，用图像处理精修边界，找到紧贴图形的实际裁剪框
enum GraphicCropRefinement {

    /// 背景阈值：大于此亮度视为空白背景（试卷通常为白底）
    private static let backgroundLuminanceThreshold: UInt8 = 248

    /// 精修后最小占比：若精修结果过小（可能误检）则放弃，返回 nil
    private static let minAreaRatio: Double = 0.02

    /// 在 VL bbox 区域内精修出紧贴图形边缘的边界框
    /// - Parameters:
    ///   - cgImage: 已校正方向的整图
    ///   - vlBbox: VL 返回的归一化 bbox（可能含多余空白）
    /// - Returns: 精修后的归一化 bbox，失败时返回 nil（应使用原始 bbox）
    static func refineBBox(cgImage: CGImage, vlBbox: BBox) -> BBox? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let rx = vlBbox.x * w
        let ry = vlBbox.y * h
        let rw = vlBbox.width * w
        let rh = vlBbox.height * h

        let cropRect = CGRect(x: rx, y: ry, width: rw, height: rh)
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }

        let cropW = cropped.width
        let cropH = cropped.height
        guard cropW > 0, cropH > 0 else { return nil }

        guard let tightRect = contentBoundingRect(cgImage: cropped) else { return nil }

        // 映射回原图归一化坐标
        let nx = vlBbox.x + Double(tightRect.minX) / Double(cropW) * vlBbox.width
        let ny = vlBbox.y + Double(tightRect.minY) / Double(cropH) * vlBbox.height
        let nw = Double(tightRect.width) / Double(cropW) * vlBbox.width
        let nh = Double(tightRect.height) / Double(cropH) * vlBbox.height

        // 有效性检查
        guard nw > 0, nh > 0 else { return nil }
        let areaRatio = nw * nh / (vlBbox.width * vlBbox.height)
        guard areaRatio >= minAreaRatio else { return nil }

        let clampedX = max(0, min(1 - 0.001, nx))
        let clampedY = max(0, min(1 - 0.001, ny))
        let clampedW = max(0.001, min(nw, 1 - clampedX))
        let clampedH = max(0.001, min(nh, 1 - clampedY))
        return BBox(x: clampedX, y: clampedY, width: clampedW, height: clampedH)
    }

    /// 在裁剪图中找到非背景像素的边界矩形（像素坐标）
    private static func contentBoundingRect(cgImage: CGImage) -> CGRect? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return nil }

        let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        var minX = width
        var maxX = 0
        var minRow = height
        var maxRow = 0
        var contentCount = 0

        for row in 0..<height {
            for col in 0..<width {
                let offset = (row * bytesPerRow) + (col * bytesPerPixel)
                let r = buffer[offset]
                let g = buffer[offset + 1]
                let b = buffer[offset + 2]
                let luminance = UInt8((Int(r) + Int(g) + Int(b)) / 3)
                if luminance < backgroundLuminanceThreshold {
                    contentCount += 1
                    minX = min(minX, col)
                    maxX = max(maxX, col)
                    minRow = min(minRow, row)
                    maxRow = max(maxRow, row)
                }
            }
        }

        guard contentCount > 0 else { return nil }
        // CGContext 默认原点在左下：row 0 = 图像底部，row 增大向上。图形坐标 y 向下为正
        let imgMinY = height - 1 - maxRow
        let imgMaxY = height - 1 - minRow
        return CGRect(x: minX, y: imgMinY, width: maxX - minX + 1, height: imgMaxY - imgMinY + 1)
    }
}
