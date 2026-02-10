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
        let questions: [PaperQuestion] = bestItemsToUse.enumerated().map { idx, item in
            let cropFileName = cropQuestionImage(from: image, items: bestItemsToUse, index: idx, provider: provider)
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
        let newQuestions: [PaperQuestion] = bestItemsToUse.enumerated().map { idx, item in
            // index 仅用于可作答小题（type=题目），表示整份试卷中的题号
            let cropFileName = cropQuestionImage(from: image, items: bestItemsToUse, index: idx, provider: provider)
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
            // 「请用楷书抄写下面的文字……（3分）」+ 待抄写段落：当前误识别为 答题说明+题干，合并为一条 题目/填空题
            if current.type == "答题说明", i + 1 < items.count, items[i + 1].type == "题干",
               contentLooksLikeCopyInstruction(current.content), contentLooksLikeParagraphToCopy(items[i + 1].content) {
                let next = items[i + 1]
                let mergedContent = current.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n\n"
                    + next.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let mergedBbox = unionBBox(current.bbox, next.bbox)
                result.append(("题目", "填空题", mergedContent, mergedBbox))
                i += 2
                continue
            }
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
            // 填空题「一题干+多填空小题」：题干（如「在（）里填上">"、"<"或"="。」）后跟多条填空小题（如 80毫升（＜）8升），合并为一条
            if current.type == "题目", (current.subtype ?? "") == "填空题", contentLooksLikeFillInStemOnly(current.content),
               i + 1 < items.count {
                var j = i + 1
                var subParts: [String] = [current.content.trimmingCharacters(in: .whitespacesAndNewlines)]
                var mergedBbox = current.bbox
                while j < items.count, items[j].type == "题目", (items[j].subtype ?? "") == "填空题",
                      contentLooksLikeFillInSubItem(items[j].content), !contentStartsNewQuestionNumber(items[j].content) {
                    subParts.append(items[j].content.trimmingCharacters(in: .whitespacesAndNewlines))
                    mergedBbox = unionBBox(mergedBbox, items[j].bbox)
                    j += 1
                }
                if subParts.count > 1 {
                    let mergedContent = subParts.joined(separator: "\n\n")
                    result.append(("题目", "填空题", mergedContent, mergedBbox))
                    i = j
                    continue
                }
            }
            result.append(current)
            i += 1
        }
        return result
    }

    /// 是否为填空题的「题干」：如「在（）里填上">"、"<"或"="。」，一句或两句，以句号或」结尾
    private func contentLooksLikeFillInStemOnly(_ content: String) -> Bool {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let hasStemMarker = t.contains("填上") || t.contains("里填")
        let lineCount = t.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let endsWithInstruction = t.hasSuffix("。") || t.hasSuffix("」") || t.hasSuffix("=")
        return hasStemMarker && lineCount <= 3 && endsWithInstruction
    }

    /// 是否为填空题的「填空小题项」：短句、不以题号「N.」开头，常含（）、＜＞＝或单位等
    private func contentLooksLikeFillInSubItem(_ content: String) -> Bool {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 120 else { return false }
        if contentStartsNewQuestionNumber(t) { return false }
        let lines = t.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.count <= 2
    }

    /// 是否为「抄写题」的作答要求：如「请用楷书抄写下面的文字……（3分）」
    private func contentLooksLikeCopyInstruction(_ content: String) -> Bool {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return (t.contains("抄写") && (t.contains("下面的文字") || t.contains("下面"))) || (t.contains("书写") && t.contains("工整"))
    }

    /// 是否为待抄写/待填空的段落：整段叙述、以句号结尾、无选项（无 A./B./C./D.）、无问号
    private func contentLooksLikeParagraphToCopy(_ content: String) -> Bool {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count >= 20 else { return false }
        if t.contains("？") || t.contains("?") { return false }
        if contentLooksLikeOptionsOnly(t) { return false }
        return t.hasSuffix("。") || t.hasSuffix("」")
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
    
    /// bbox 是否可用于裁切：放宽校验，允许 y>1（页面底部内容 VL 常返回 1.02 等）
    private func isBBoxUsableForCrop(_ b: BBox) -> Bool {
        guard b.width > 0, b.height > 0 else { return false }
        guard b.x >= -0.02, b.x <= 1.02, b.y >= -0.02, b.y <= 1.2 else { return false }
        return true
    }

    /// 将归一化 bbox 转为像素 y 范围，并 clamp 到 [0, imageHeight]
    private func bboxToPixelYRange(_ b: BBox, imageHeight: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let yNorm = max(0, min(1, b.y))
        let bottomNorm = max(0, min(1, b.y + b.height))
        let top = yNorm * imageHeight
        let bottom = max(top, bottomNorm * imageHeight)
        return (top, min(imageHeight, bottom))
    }

    /// 以 VL bbox 为主做裁切，上下各留少量边距；无 bbox 时回退为上一项底～下一项顶。支持 y>1 的页面底部 bbox（clamp 后使用）。
    private func cropQuestionImage(
        from image: UIImage,
        items: [(type: String, subtype: String?, content: String, bbox: BBox?)],
        index: Int,
        provider: LLMProvider
    ) -> String? {
        let normalizedImage = normalizeImageOrientation(image)
        guard let cgImage = normalizedImage.cgImage else { return nil }
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        let marginPx: CGFloat = 4
        let upwardExpansion: CGFloat = min(90, imageHeight * 0.12)  // 向上多扩 90px 或 12% 高度，补偿 VL bbox 系统性偏低

        var cropTop: CGFloat
        var cropBottom: CGFloat

        if let cur = items[index].bbox, isBBoxUsableForCrop(cur) {
            let (py, bottomPx) = bboxToPixelYRange(cur, imageHeight: imageHeight)
            cropTop = max(0, py - marginPx - upwardExpansion)
            cropBottom = min(imageHeight, bottomPx + marginPx)
            // 页面底部特殊处理：若当前 bbox 顶部十分靠下或高度异常小，则用上一题的底部到页面底部作为区域
            if (cropBottom <= cropTop + 1 || cur.y >= 0.98),
               index > 0,
               let prev = items[index - 1].bbox,
               isBBoxUsableForCrop(prev) {
                let (_, prevBottomPx) = bboxToPixelYRange(prev, imageHeight: imageHeight)
                cropTop = max(0, prevBottomPx - marginPx - upwardExpansion)
                cropBottom = imageHeight
            }
        } else {
            // 无 bbox：使用上一题底部与下一题顶部之间的区域
            let prevBottom: CGFloat
            if index > 0, let prev = items[index - 1].bbox, isBBoxUsableForCrop(prev) {
                let (_, pb) = bboxToPixelYRange(prev, imageHeight: imageHeight)
                prevBottom = pb
            } else {
                prevBottom = 0
            }
            let nextTop: CGFloat
            if index < items.count - 1, let next = items[index + 1].bbox, isBBoxUsableForCrop(next) {
                let (nt, _) = bboxToPixelYRange(next, imageHeight: imageHeight)
                nextTop = nt
            } else {
                nextTop = imageHeight
            }
            cropTop = max(0, prevBottom - marginPx - upwardExpansion)
            cropBottom = min(imageHeight, nextTop + marginPx)
        }

        let bottomClamped = max(cropBottom, cropTop + 1)
        let cropH = max(1, bottomClamped - cropTop)
        let cropRect = CGRect(x: 0, y: cropTop, width: imageWidth, height: cropH)

        // 调试日志：方便后续排查切图偏移
        let curBboxStr: String
        if let cur = items[index].bbox, isBBoxUsableForCrop(cur) {
            let px = max(0, min(1, cur.x)) * imageWidth
            let (py, pb) = bboxToPixelYRange(cur, imageHeight: imageHeight)
            curBboxStr = "x=\(px) y=\(py) 宽=\(imageWidth) 高=\(pb - py) px"
        } else {
            curBboxStr = "无"
        }
        let nextBboxStr: String
        if index < items.count - 1, let next = items[index + 1].bbox, isBBoxUsableForCrop(next) {
            let px = max(0, min(1, next.x)) * imageWidth
            let (py, pb) = bboxToPixelYRange(next, imageHeight: imageHeight)
            nextBboxStr = "x=\(px) y=\(py) 宽=\(imageWidth) 高=\(pb - py) px"
        } else {
            nextBboxStr = "无"
        }
        print("---坐标---题目[\(index + 1)] 当前题bbox \(curBboxStr)")
        print("---坐标---题目[\(index + 1)] 下一题bbox \(nextBboxStr)")
        print("---坐标---题目[\(index + 1)] 切图 x=\(cropRect.origin.x) y=\(cropRect.origin.y) 宽=\(cropRect.width) 高=\(cropRect.height)")

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

