import Foundation
import UIKit
@preconcurrency import Combine

@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var items: [ScanItem] = []

    private let fileName = "scans.json"

    init() {
        load()
        if items.isEmpty {
            seed()
        }
    }

    /// Analyze the captured image with VL model; if it's a paper/homework, persist it and extracted questions.
    /// 解析后使用大模型校验题干/题目与切图；若有偏差则调整提示词重试，最多 3 次，取效果最好的一次。
    /// - Parameter progress: 可选进度回调，用于更新 UI 提示当前阶段
    func analyzeAndAddScan(
        image: UIImage,
        provider: LLMProvider,
        config: any LLMConfigProtocol,
        progress: ((String) -> Void)? = nil
    ) async throws -> ScanItem? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }

        progress?(L10n.analyzeStagePreparing)

        var bestResult: PaperVisionResult?
        var bestScore: Int = -1
        var bestItemsToUse: [(type: String, content: String, bbox: BBox?)] = []

        for attempt in 0..<3 {
            let current = attempt + 1
            progress?(L10n.analyzeStageVisionAttempt(current: current, total: 3))
            let promptSuffix = (attempt > 0) ? paperAnalysisPromptSuffixForRetry : nil
            let result: PaperVisionResult
            do {
                result = try await LLMService.analyzePaper(imageJPEGData: data, provider: provider, config: config, promptSuffix: promptSuffix)
            } catch {
                if attempt == 0 { throw error }
                continue
            }
            guard result.is_homework_or_exam else {
                if attempt == 0 { return nil }
                continue
            }
            let itemsToUse = normalizeItemsForProvider(provider, result.normalizedItems)
            let itemsSummary = itemsToUse.map { "[\($0.type)] \(String($0.content.prefix(400)))" }.joined(separator: "\n\n")
            let validation: PaperValidationResult
            do {
                progress?(L10n.analyzeStageValidating(current: current, total: 3))
                validation = try await LLMService.validatePaperResult(imageJPEGData: data, itemsSummary: itemsSummary, provider: provider, config: config)
            } catch {
                if attempt == 0 { throw error }
                continue
            }
            let score = validation.score ?? 0
            if score > bestScore {
                bestScore = score
                bestResult = result
                bestItemsToUse = itemsToUse
            }
        }

        guard let result = bestResult, !bestItemsToUse.isEmpty else {
            return nil
        }

        progress?(L10n.analyzeStageCropping)

        let now = Date()
        let imageFileName = "scan-\(UUID().uuidString).jpg"
        if let url = try? imageURL(fileName: imageFileName) {
            try? data.write(to: url, options: [.atomic])
        }

        let subject = Subject(rawValue: result.subject) ?? .other
        let grade = Grade(rawValue: result.grade) ?? .other
        let totalCount = bestItemsToUse.count
        let questions: [PaperQuestion] = bestItemsToUse.enumerated().map { idx, item in
            let cropFileName = cropQuestionImage(from: image, bbox: item.bbox, index: idx, totalCount: totalCount, provider: provider)
            return PaperQuestion(
                index: idx + 1,
                kind: item.type,
                text: item.content,
                isWrong: false,
                cropImageFileName: cropFileName
            )
        }

        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "试卷/作业 \(DateFormatter.shortDate.string(from: now))"
            : result.title

        let item = ScanItem(
            title: title,
            createdAt: now,
            grade: grade,
            subject: subject,
            imageFileNames: [imageFileName],
            questions: questions,
            isHomeworkOrExam: true,
            isArchived: false,
            score: result.score
        )

        items.insert(item, at: 0)
        save()
        return item
    }

    func toggleWrong(scanID: UUID, questionID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == scanID }) else { return }
        guard let q = items[i].questions.firstIndex(where: { $0.id == questionID }) else { return }
        items[i].questions[q].isWrong.toggle()
        save()
    }

    func archive(scanID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == scanID }) else { return }
        items[i].isArchived = true
        save()
    }

    func delete(scanID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == scanID }) else { return }
        for name in items[i].imageFileNames {
            if let url = try? imageURL(fileName: name) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        items.remove(at: i)
        save()
    }

    /// Add another image to an existing paper; run VL analysis and merge extracted questions.
    /// 与 analyzeAndAddScan 一致：解析后校验，最多重试 3 次，取效果最好的一次。
    func addImage(scanID: UUID, image: UIImage, provider: LLMProvider, config: any LLMConfigProtocol) async throws {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        guard let i = items.firstIndex(where: { $0.id == scanID }) else { return }

        var bestResult: PaperVisionResult?
        var bestScore: Int = -1
        var bestItemsToUse: [(type: String, content: String, bbox: BBox?)] = []

        for attempt in 0..<3 {
            let promptSuffix = (attempt > 0) ? paperAnalysisPromptSuffixForRetry : nil
            let result: PaperVisionResult
            do {
                result = try await LLMService.analyzePaper(imageJPEGData: data, provider: provider, config: config, promptSuffix: promptSuffix)
            } catch {
                if attempt == 0 { throw error }
                continue
            }
            guard result.is_homework_or_exam else { continue }
            let itemsToUse = normalizeItemsForProvider(provider, result.normalizedItems)
            let itemsSummary = itemsToUse.map { "[\($0.type)] \(String($0.content.prefix(400)))" }.joined(separator: "\n\n")
            let validation: PaperValidationResult
            do {
                validation = try await LLMService.validatePaperResult(imageJPEGData: data, itemsSummary: itemsSummary, provider: provider, config: config)
            } catch {
                if attempt == 0 { throw error }
                continue
            }
            let score = validation.score ?? 0
            if score > bestScore {
                bestScore = score
                bestResult = result
                bestItemsToUse = itemsToUse
            }
        }

        guard bestResult != nil, !bestItemsToUse.isEmpty else { return }

        let fileName = "scan-\(UUID().uuidString).jpg"
        if let url = try? imageURL(fileName: fileName) {
            try? data.write(to: url, options: [.atomic])
        }
        items[i].imageFileNames.append(fileName)

        let startIndex = items[i].questions.count
        let totalCount = bestItemsToUse.count
        let newQuestions: [PaperQuestion] = bestItemsToUse.enumerated().map { idx, item in
            let cropFileName = cropQuestionImage(from: image, bbox: item.bbox, index: startIndex + idx, totalCount: totalCount, provider: provider)
            return PaperQuestion(
                index: startIndex + idx + 1,
                kind: item.type,
                text: item.content,
                isWrong: false,
                cropImageFileName: cropFileName
            )
        }
        items[i].questions.append(contentsOf: newQuestions)
        save()
    }

    func updateMeta(
        scanID: UUID,
        title: String,
        grade: Grade,
        subject: Subject,
        score: Int?
    ) {
        guard let i = items.firstIndex(where: { $0.id == scanID }) else { return }
        items[i].title = title
        items[i].grade = grade
        items[i].subject = subject
        items[i].score = score
        save()
    }

    func updateQuestionAnalysis(
        scanID: UUID,
        questionID: UUID,
        section: String?,
        answer: String,
        explanation: String
    ) {
        guard let i = items.firstIndex(where: { $0.id == scanID }) else { return }
        guard let q = items[i].questions.firstIndex(where: { $0.id == questionID }) else { return }
        items[i].questions[q].section = section
        items[i].questions[q].answer = answer
        items[i].questions[q].explanation = explanation
        save()
    }

    func save() {
        do {
            let url = try dataURL()
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: [.atomic])
        } catch {
            // best-effort
        }
    }

    func load() {
        do {
            let url = try dataURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            items = try JSONDecoder().decode([ScanItem].self, from: data)
        } catch {
            // best-effort
        }
    }

    func imageURL(for item: ScanItem, index: Int = 0) -> URL? {
        guard index >= 0, index < item.imageFileNames.count else { return nil }
        let name = item.imageFileNames[index]
        return try? imageURL(fileName: name)
    }

    /// 根据文件名获取图片 URL（用于切图等）
    func imageURL(fileName: String) throws -> URL {
        let dir = try scansDir()
        return dir.appendingPathComponent(fileName, isDirectory: false)
    }

    /// 按供应商规范化项列表：Bailian 原样返回；Gemini/OpenAI 统一 type 为「板块分类/题干/题目」并合并题干+题目为一条
    private func normalizeItemsForProvider(
        _ provider: LLMProvider,
        _ items: [(type: String, content: String, bbox: BBox?)]
    ) -> [(type: String, content: String, bbox: BBox?)] {
        switch provider {
        case .bailian:
            return items
        case .gemini, .openai:
            return normalizeAndMergeStemItem(items: items)
        }
    }

    /// 统一 type 为「板块分类/题干/题目」，并将连续的 题干+题目 合并为一条 题目（同卡展示）
    private func normalizeAndMergeStemItem(
        items: [(type: String, content: String, bbox: BBox?)]
    ) -> [(type: String, content: String, bbox: BBox?)] {
        let normalized: [(type: String, content: String, bbox: BBox?)] = items.map { item in
            let t = normalizeItemType(item.type)
            return (t, item.content, item.bbox)
        }
        var result: [(type: String, content: String, bbox: BBox?)] = []
        var i = 0
        while i < normalized.count {
            let current = normalized[i]
            if current.type == "题干", i + 1 < normalized.count, normalized[i + 1].type == "题目" {
                let next = normalized[i + 1]
                let mergedContent = current.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n\n"
                    + next.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let mergedBbox = unionBBox(current.bbox, next.bbox)
                result.append(("题目", mergedContent, mergedBbox))
                i += 2
                continue
            }
            result.append(current)
            i += 1
        }
        return result
    }

    private func normalizeItemType(_ type: String) -> String {
        let t = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "板块分类" || t.lowercased().contains("section") || (t.contains("分类") && !t.contains("题干")) { return "板块分类" }
        if t == "题干" || t.lowercased().contains("stem") || t == "问句" { return "题干" }
        if t == "题目" || t.lowercased().contains("item") { return "题目" }
        return t.isEmpty ? "题目" : "题目"
    }

    private func unionBBox(_ a: BBox?, _ b: BBox?) -> BBox? {
        guard let a = a else { return b }
        guard let b = b else { return a }
        let minY = min(a.y, b.y)
        let maxBottom = max(a.y + a.height, b.y + b.height)
        return BBox(x: 0, y: minY, width: 1, height: maxBottom - minY)
    }

    /// 根据 bbox 从图片中切出题目横条；扩充比例按供应商区分。当 bbox 为空（如 OpenAI 未返回）时按题目序号均分高度估算区域
    private func cropQuestionImage(from image: UIImage, bbox: BBox?, index: Int, totalCount: Int, provider: LLMProvider) -> String? {
        let effectiveBbox: BBox
        if let b = bbox {
            effectiveBbox = b
        } else if totalCount > 0 {
            let n = Double(totalCount)
            let stripHeight = 1.0 / n
            effectiveBbox = BBox(x: 0, y: Double(index) * stripHeight, width: 1, height: stripHeight)
        } else {
            return nil
        }

        // 先校正图片方向，确保 cgImage 的宽高和显示方向一致
        let normalizedImage = normalizeImageOrientation(image)
        guard let cgImage = normalizedImage.cgImage else { return nil }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        // 归一化坐标转像素坐标
        let bboxY = CGFloat(effectiveBbox.y) * imageHeight
        let bboxHeight = CGFloat(effectiveBbox.height) * imageHeight

        // 宽度：整个试卷宽度（不裁剪左右）
        let x: CGFloat = 0
        let width = imageWidth

        // 高度：按供应商区分扩充比例（Bailian 正确；Gemini/OpenAI 上部多扩 50% 以弥补 bbox 偏小）
        let (expandTopRatio, expandBottomRatio): (CGFloat, CGFloat) = {
            switch provider {
            case .bailian:
                return (1.0, 0.5)   // 上部 100%，下部 50%
            case .gemini, .openai:
                return (1.5, 0.5)   // 上部 150%，下部 50%
            }
        }()
        let expandHeightTop = bboxHeight * expandTopRatio
        let expandHeightBottom = bboxHeight * expandBottomRatio
        let y = max(0, bboxY - expandHeightTop)
        var height = bboxHeight + expandHeightTop + expandHeightBottom
        
        // 确保不超出图片边界
        if y + height > imageHeight {
            height = imageHeight - y
        }

        let cropRect = CGRect(x: x, y: y, width: width, height: height)
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return nil }
        let croppedImage = UIImage(cgImage: croppedCGImage)

        guard let data = croppedImage.jpegData(compressionQuality: 0.85) else { return nil }
        let fileName = "crop-\(UUID().uuidString).jpg"
        if let url = try? imageURL(fileName: fileName) {
            try? data.write(to: url, options: [.atomic])
        }
        return fileName
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

    private func dataURL() throws -> URL {
        let dir = try appSupportDir()
        return dir.appendingPathComponent(fileName, isDirectory: false)
    }

    private func appSupportDir() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("camit", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func scansDir() throws -> URL {
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = docs.appendingPathComponent("camit_scans", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func seed() {
        let now = Date()
        items = [
            ScanItem(title: "数学单元测验", createdAt: now, grade: .primary5, subject: .math, imageFileNames: [], questions: []),
            ScanItem(title: "英语阅读测试", createdAt: now.addingTimeInterval(-2 * 3600), grade: .primary6, subject: .english, imageFileNames: [], questions: []),
            ScanItem(title: "物理期中试卷", createdAt: now.addingTimeInterval(-8 * 24 * 3600), grade: .junior2, subject: .physics, imageFileNames: [], questions: []),
            ScanItem(title: "化学习题作业", createdAt: now.addingTimeInterval(-9 * 24 * 3600), grade: .junior3, subject: .chemistry, imageFileNames: [], questions: []),
        ]
        save()
    }
}

private enum DateFormatter {
    static let shortDate: Foundation.DateFormatter = {
        let f = Foundation.DateFormatter()
        f.locale = .current
        f.dateFormat = "M/d"
        return f
    }()
}

