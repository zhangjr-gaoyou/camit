import Foundation
import UIKit
@preconcurrency import Combine

private let parseSuccessScoreThreshold = 75

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
        var bestItemsToUse: [(type: String, subtype: String?, content: String, bbox: BBox?)] = []

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
            debugPrintParseItems(attempt: current, rawItems: result.normalizedItems, normalizedItems: itemsToUse, phase: "VL+normalize")
            let itemsSummary = itemsToUse.map { "[\($0.type)]\($0.subtype.map { "/\($0)" } ?? "") \(String($0.content.prefix(400)))" }.joined(separator: "\n\n")
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
            if score >= parseSuccessScoreThreshold {
                break
            }
        }

        guard let result = bestResult, !bestItemsToUse.isEmpty else {
            return nil
        }

        debugPrintParseItems(attempt: nil, rawItems: [], normalizedItems: bestItemsToUse, phase: "analyzeAndAddScan final")
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
            let isQuestionItem = normalizeItemType(item.type) == "题目"
            let idxValue: Int? = isQuestionItem ? (idx + 1) : nil
            let processedContent = replaceTianziGeWithUnderline(item.content)
            debugPrintQuestionCreated(index: idx + 1, kind: item.type, subtype: item.subtype, text: processedContent)
            return PaperQuestion(
                index: idxValue,
                kind: item.type,
                subtype: item.subtype,
                text: processedContent,
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
    /// - Parameter progress: 可选进度回调，用于更新 UI 提示当前阶段
    func addImage(
        scanID: UUID,
        image: UIImage,
        provider: LLMProvider,
        config: any LLMConfigProtocol,
        progress: ((String) -> Void)? = nil
    ) async throws {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        guard let i = items.firstIndex(where: { $0.id == scanID }) else { return }

        progress?(L10n.analyzeStagePreparing)

        var bestResult: PaperVisionResult?
        var bestScore: Int = -1
        var bestItemsToUse: [(type: String, subtype: String?, content: String, bbox: BBox?)] = []

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
            guard result.is_homework_or_exam else { continue }
            let itemsToUse = normalizeItemsForProvider(provider, result.normalizedItems)
            debugPrintParseItems(attempt: current, rawItems: result.normalizedItems, normalizedItems: itemsToUse, phase: "addImage VL+normalize")
            let itemsSummary = itemsToUse.map { "[\($0.type)]\($0.subtype.map { "/\($0)" } ?? "") \(String($0.content.prefix(400)))" }.joined(separator: "\n\n")
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
            if score >= parseSuccessScoreThreshold {
                break
            }
        }

        guard bestResult != nil, !bestItemsToUse.isEmpty else { return }

        debugPrintParseItems(attempt: nil, rawItems: [], normalizedItems: bestItemsToUse, phase: "addImage final")
        progress?(L10n.analyzeStageCropping)

        let fileName = "scan-\(UUID().uuidString).jpg"
        if let url = try? imageURL(fileName: fileName) {
            try? data.write(to: url, options: [.atomic])
        }
        items[i].imageFileNames.append(fileName)

        let startIndex = items[i].questions.count
        let totalCount = bestItemsToUse.count
        let newQuestions: [PaperQuestion] = bestItemsToUse.enumerated().map { idx, item in
            // index 仅用于可作答小题（type=题目），表示整份试卷中的题号
            let cropFileName = cropQuestionImage(from: image, bbox: item.bbox, index: idx, totalCount: totalCount, provider: provider)
            let isQuestionItem = normalizeItemType(item.type) == "题目"
            let idxValue: Int? = isQuestionItem ? (startIndex + idx + 1) : nil
            let processedContent = replaceTianziGeWithUnderline(item.content)
            debugPrintQuestionCreated(index: startIndex + idx + 1, kind: item.type, subtype: item.subtype, text: processedContent)
            return PaperQuestion(
                index: idxValue,
                kind: item.type,
                subtype: item.subtype,
                text: processedContent,
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

    /// 调试：打印解析内容到 console，便于排查题干/选项合并等问题
    private func debugPrintParseItems(
        attempt: Int?,
        rawItems: [(type: String, subtype: String?, content: String, bbox: BBox?)],
        normalizedItems: [(type: String, subtype: String?, content: String, bbox: BBox?)],
        phase: String
    ) {
        let prefix = "[camit] "
        let attStr = attempt.map { " attempt \($0)" } ?? ""
        print("\(prefix)===== Parse \(phase)\(attStr) =====")
        if !rawItems.isEmpty {
            print("\(prefix)Raw VL items (\(rawItems.count)):")
            for (i, it) in rawItems.enumerated() {
                let sub = it.subtype.map { "/\($0)" } ?? ""
                let preview = String(it.content.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                print("\(prefix)  [\(i + 1)] type=\(it.type)\(sub) | \(preview)\(it.content.count > 120 ? "…" : "")")
            }
        }
        print("\(prefix)Normalized items (\(normalizedItems.count)):")
        for (i, it) in normalizedItems.enumerated() {
            let sub = it.subtype.map { "/\($0)" } ?? ""
            let preview = String(it.content.prefix(200)).replacingOccurrences(of: "\n", with: "↵")
            print("\(prefix)  [\(i + 1)] type=\(it.type)\(sub) | \(preview)\(it.content.count > 200 ? "…" : "")")
        }
        print("\(prefix)===== End \(phase) =====")
    }

    private func debugPrintQuestionCreated(index: Int, kind: String, subtype: String?, text: String) {
        let sub = subtype.map { "/\($0)" } ?? ""
        let preview = String(text.prefix(150)).replacingOccurrences(of: "\n", with: "↵")
        print("[camit] Question[\(index)] kind=\(kind)\(sub) | \(preview)\(text.count > 150 ? "…" : "")")
    }

    /// 按供应商规范化项列表，统一 type 并合并题干+题目（或两道「题目」中题干+选项）为一条
    private func normalizeItemsForProvider(
        _ provider: LLMProvider,
        _ items: [(type: String, subtype: String?, content: String, bbox: BBox?)]
    ) -> [(type: String, subtype: String?, content: String, bbox: BBox?)] {
        let normalized: [(type: String, subtype: String?, content: String, bbox: BBox?)] = items.map { item in
            let t = normalizeItemType(item.type)
            return (t, item.subtype, item.content, item.bbox)
        }
        return normalizeAndMergeStemItem(items: normalized)
    }

    /// 统一 type 为「板块分类/题干/题目」，合并：1) 题干+题目；2) 两道题目（前者仅题干、后者仅 A/B/C/D 选项）为一条
    private func normalizeAndMergeStemItem(
        items: [(type: String, subtype: String?, content: String, bbox: BBox?)]
    ) -> [(type: String, subtype: String?, content: String, bbox: BBox?)] {
        var result: [(type: String, subtype: String?, content: String, bbox: BBox?)] = []
        var i = 0
        while i < items.count {
            let current = items[i]
            if current.type == "题干", i + 1 < items.count, items[i + 1].type == "题目",
               !contentStartsNewQuestionNumber(items[i + 1].content) {
                let next = items[i + 1]
                let mergedContent = current.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n\n"
                    + next.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let mergedBbox = unionBBox(current.bbox, next.bbox)
                result.append(("题目", next.subtype, mergedContent, mergedBbox))
                i += 2
                continue
            }
            if current.type == "题目", i + 1 < items.count, items[i + 1].type == "题目",
               contentLooksLikeStemOnly(current.content),
               contentLooksLikeOptionsOnly(items[i + 1].content),
               !contentStartsNewQuestionNumber(items[i + 1].content) {
                let next = items[i + 1]
                let mergedContent = current.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n\n"
                    + next.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let mergedBbox = unionBBox(current.bbox, next.bbox)
                result.append(("题目", next.subtype, mergedContent, mergedBbox))
                i += 2
                continue
            }
            result.append(current)
            i += 1
        }
        return result
    }

    private func contentLooksLikeStemOnly(_ content: String) -> Bool {
        let lines = content.components(separatedBy: .newlines)
        let hasOptionLine = lines.contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2 else { return false }
            let first = t.first!.uppercased()
            let second = t[t.index(t.startIndex, offsetBy: 1)]
            return (first == "A" || first == "B" || first == "C" || first == "D") && (second == "." || second == "、" || second == ")")
        }
        return !hasOptionLine
    }

    private func contentLooksLikeOptionsOnly(_ content: String) -> Bool {
        let lines = content.components(separatedBy: .newlines)
        var optionCount = 0
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2 else { continue }
            let first = t.first!.uppercased()
            let second = t[t.index(t.startIndex, offsetBy: 1)]
            if (first == "A" || first == "B" || first == "C" || first == "D") && (second == "." || second == "、" || second == ")") {
                optionCount += 1
            }
        }
        return optionCount >= 2
    }

    /// 内容是否以新题号开头（如 2. 3．），若是则不应与上一条合并
    private func contentStartsNewQuestionNumber(_ content: String) -> Bool {
        let lines = content.components(separatedBy: .newlines)
        guard let firstLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        let t = firstLine.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return false }
        var i = t.startIndex
        while i < t.endIndex, t[i].isNumber { i = t.index(after: i) }
        guard i > t.startIndex, i < t.endIndex else { return false }
        let next = t[i]
        return next == "." || next == "．" || next == "、"
    }

    private func normalizeItemType(_ type: String) -> String {
        let t = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "板块分类" || t.lowercased().contains("section") || (t.contains("分类") && !t.contains("题干")) { return "板块分类" }
        if t == "答题说明" || t.contains("说明") { return "答题说明" }
        if t == "题干" || t.lowercased().contains("stem") || t == "问句" { return "题干" }
        if t == "题目" || t.lowercased().contains("item") { return "题目" }
        return t.isEmpty ? "题目" : t
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
        // 对部分模型返回的 bbox 做简单校验（坐标超界或高度太小则视为无效）
        let isValidBBox: (BBox) -> Bool = { b in
            return b.x >= 0 &&
                b.y >= 0 &&
                b.width > 0 &&
                b.height > 0 &&
                b.x <= 1 &&
                b.y <= 1
        }

        let effectiveBbox: BBox
        if let b = bbox, isValidBBox(b) {
            effectiveBbox = b
        } else if totalCount > 0 {
            let n = Double(totalCount)
            let clampedIndex = max(0, min(index, Int(n) - 1))
            let stripHeight = 1.0 / n
            effectiveBbox = BBox(
                x: 0,
                y: Double(clampedIndex) * stripHeight,
                width: 1,
                height: stripHeight
            )
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

