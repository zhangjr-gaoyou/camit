import Foundation
import UIKit
@preconcurrency import Combine

private let parseSuccessScoreThreshold = 75

/// 归一化后的题目项：含题干/题目、选项图框、附图框
private typealias NormalizedItem = (type: String, subtype: String?, content: String, bbox: BBox?, optionBboxes: [String: BBox]?, figureBbox: BBox?)

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

        // 子任务 1：只负责题目解析与校验，不做切图和持久化
        guard let (result, bestItemsToUse) = try await runPaperAnalysis(
            imageData: data,
            provider: provider,
            config: config,
            pageNumber: 1,
            allowNonExamIfHasItems: false,
            progress: progress,
            caller: "analyzeAndAddScan",
            debugPhase: "VL+normalize"
        ) else {
            return nil
        }

        // 子任务 2：基于解析结果做切图与落库
        debugPrintParseItems(attempt: nil, rawItems: [] as [(type: String, subtype: String?, content: String)], normalizedItems: bestItemsToUse, phase: "analyzeAndAddScan final")
        debugPrintAllQuestions(bestItemsToUse)
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
            let cropFileName = cropQuestionImage(from: image, items: bestItemsToUse, index: idx, provider: provider)
            let optionCrops = cropOptionImages(from: image, optionBboxes: item.optionBboxes)
            let figureCrop = item.figureBbox.flatMap { cropImageByBBox(from: image, bbox: $0) }
            let isQuestionItem = normalizeItemType(item.type) == "题目"
            let idxValue: Int? = isQuestionItem ? (extractQuestionNumber(from: item.content) ?? (idx + 1)) : nil
            let processedContent = replaceTianziGeWithUnderline(item.content)
            debugPrintQuestionCreated(index: idxValue ?? idx + 1, kind: item.type, subtype: item.subtype, text: processedContent)
            return PaperQuestion(
                index: idxValue,
                kind: item.type,
                subtype: item.subtype,
                text: processedContent,
                isWrong: false,
                cropImageFileName: cropFileName,
                optionCropImageFileNames: optionCrops.isEmpty ? nil : optionCrops,
                figureCropImageFileName: figureCrop
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
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            print("[camit] addImage: 图片无法转为 JPEG")
            return
        }
        guard let i = items.firstIndex(where: { $0.id == scanID }) else {
            print("[camit] addImage: 未找到 scanID=\(scanID)")
            return
        }

        progress?(L10n.analyzeStagePreparing)

        // 子任务 1：只负责题目解析与校验，不做切图
        let pageNumber = items[i].imageFileNames.count + 1
        guard let (_, bestItemsToUse) = try await runPaperAnalysis(
            imageData: data,
            provider: provider,
            config: config,
            pageNumber: pageNumber,
            allowNonExamIfHasItems: true,
            progress: progress,
            caller: "addImage",
            debugPhase: "addImage VL+normalize"
        ) else {
            print("[camit] addImage: 解析失败或 VL 未返回有效题目")
            return
        }

        // 子任务 2：基于解析结果过滤需要追加的题目，再做切图与落库
        // 后续图片：仅保留「显式新板块」（内容含二、三、四、等序号），滤掉 VL 推断的续页板块（如「选择题」「一、选择题」）
        let itemsToAppend: [NormalizedItem] = bestItemsToUse.filter { item in
            if normalizeItemType(item.type) != "板块分类" { return true }
            let c = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return c.contains("二、") || c.contains("三、") || c.contains("四、") || c.contains("五、")
        }
        guard !itemsToAppend.isEmpty else {
            print("[camit] addImage: 过滤后无有效题目，原始数量=\(bestItemsToUse.count)")
            return
        }

        debugPrintParseItems(attempt: nil, rawItems: [] as [(type: String, subtype: String?, content: String)], normalizedItems: itemsToAppend, phase: "addImage final")
        debugPrintAllQuestions(itemsToAppend)
        progress?(L10n.analyzeStageCropping)

        let fileName = "scan-\(UUID().uuidString).jpg"
        if let url = try? imageURL(fileName: fileName) {
            try? data.write(to: url, options: [.atomic])
        }
        items[i].imageFileNames.append(fileName)

        let startIndex = items[i].questions.count
        let totalCount = itemsToAppend.count
        let newQuestions: [PaperQuestion] = itemsToAppend.enumerated().map { idx, item in
            let cropFileName = cropQuestionImage(from: image, items: itemsToAppend, index: idx, provider: provider)
            let optionCrops = cropOptionImages(from: image, optionBboxes: item.optionBboxes)
            let figureCrop = item.figureBbox.flatMap { cropImageByBBox(from: image, bbox: $0) }
            let isQuestionItem = normalizeItemType(item.type) == "题目"
            let idxValue: Int? = isQuestionItem ? (extractQuestionNumber(from: item.content) ?? (startIndex + idx + 1)) : nil
            let processedContent = replaceTianziGeWithUnderline(item.content)
            debugPrintQuestionCreated(index: idxValue ?? startIndex + idx + 1, kind: item.type, subtype: item.subtype, text: processedContent)
            return PaperQuestion(
                index: idxValue,
                kind: item.type,
                subtype: item.subtype,
                text: processedContent,
                isWrong: false,
                cropImageFileName: cropFileName,
                optionCropImageFileNames: optionCrops.isEmpty ? nil : optionCrops,
                figureCropImageFileName: figureCrop
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
    private func debugPrintParseItems<Raw: Collection, Norm: Collection>(
        attempt: Int?,
        rawItems: Raw,
        normalizedItems: Norm,
        phase: String
    ) where Raw.Element == (type: String, subtype: String?, content: String), Norm.Element == NormalizedItem {
        let prefix = "[camit] "
        let attStr = attempt.map { " attempt \($0)" } ?? ""
        print("\(prefix)===== Parse \(phase)\(attStr) =====")
        if !rawItems.isEmpty {
            print("\(prefix)Raw VL items (\(rawItems.count)):")
            for (i, it) in rawItems.enumerated() {
                let sub = it.subtype.map { "/\($0)" } ?? ""
                let full = it.content.replacingOccurrences(of: "\n", with: " ")
                print("\(prefix)  [\(i + 1)] type=\(it.type)\(sub) | \(full)")
            }
        }
        print("\(prefix)Normalized items (\(normalizedItems.count)):")
        for (i, it) in normalizedItems.enumerated() {
            let sub = it.subtype.map { "/\($0)" } ?? ""
            let full = it.content.replacingOccurrences(of: "\n", with: "↵")
            print("\(prefix)  [\(i + 1)] type=\(it.type)\(sub) | \(full)")
        }
        print("\(prefix)===== End \(phase) =====")
    }

    private func debugPrintQuestionCreated(index: Int, kind: String, subtype: String?, text: String) {
        let sub = subtype.map { "/\($0)" } ?? ""
        let full = text.replacingOccurrences(of: "\n", with: "↵")
        print("[camit] Question[\(index)] kind=\(kind)\(sub) | \(full)")
    }

    /// 调试：按顺序打印所有解析题目内容，前缀 ----题目----
    private func debugPrintAllQuestions(_ items: [NormalizedItem]) {
        for (i, item) in items.enumerated() {
            let sub = item.subtype.map { "/\($0)" } ?? ""
            let full = item.content.replacingOccurrences(of: "\n", with: "↵")
            print("----题目----[\(i + 1)] type=\(item.type)\(sub) | \(full)")
        }
    }

    /// 按供应商规范化项列表，统一 type 并合并题干+题目、附图等
    private func normalizeItemsForProvider(
        _ provider: LLMProvider,
        _ items: [(type: String, subtype: String?, content: String, bbox: BBox?, optionBboxes: [String: BBox]?)]
    ) -> [NormalizedItem] {
        let withType: [NormalizedItem] = items.map { item in
            let t = normalizeItemType(item.type)
            return (t, item.subtype, item.content, item.bbox, item.optionBboxes, nil as BBox?)
        }
        return normalizeAndMergeStemItem(items: withType)
    }

    /// 统一 type 为「板块分类/题干/题目/附图」，合并：1) 题干+附图+题目；2) 题目+附图+题目（选项）；3) 题干+题目；4) 两道题目（题干+选项）；5) 题目+附图
    private func normalizeAndMergeStemItem(items: [NormalizedItem]) -> [NormalizedItem] {
        var result: [NormalizedItem] = []
        var i = 0
        while i < items.count {
            let current = items[i]
            // 题干 + 附图 + 题目：带「如图」的完整选择题
            if current.type == "题干", i + 2 < items.count,
               normalizeItemType(items[i + 1].type) == "附图",
               normalizeItemType(items[i + 2].type) == "题目",
               !contentStartsNewQuestionNumber(items[i + 2].content) {
                let fig = items[i + 1]
                let next = items[i + 2]
                let mergedContent = current.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n\n"
                    + next.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let mergedBbox = unionBBox(current.bbox, unionBBox(fig.bbox, next.bbox))
                result.append(("题目", next.subtype, mergedContent, mergedBbox, next.optionBboxes, fig.bbox))
                i += 3
                continue
            }
            // 题目(stem) + 附图 + 题目(options)：题干与选项被拆开且中间有附图
            if current.type == "题目", i + 2 < items.count,
               normalizeItemType(items[i + 1].type) == "附图",
               normalizeItemType(items[i + 2].type) == "题目",
               contentLooksLikeStemOnly(current.content),
               contentLooksLikeOptionsOnly(items[i + 2].content),
               !contentStartsNewQuestionNumber(items[i + 2].content) {
                let fig = items[i + 1]
                let next = items[i + 2]
                let mergedContent = current.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n\n"
                    + next.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let mergedBbox = unionBBox(current.bbox, unionBBox(fig.bbox, next.bbox))
                let mergedOpts = next.optionBboxes ?? current.optionBboxes
                result.append(("题目", next.subtype, mergedContent, mergedBbox, mergedOpts, fig.bbox))
                i += 3
                continue
            }
            // 附图：合并到上一题（题干或题目）的 figureBbox
            if current.type == "附图" {
                if !result.isEmpty {
                    let last = result[result.count - 1]
                    let t = normalizeItemType(last.type)
                    if t == "题目" || t == "题干" {
                        let mergedBbox = unionBBox(last.bbox, current.bbox)
                        result[result.count - 1] = (last.type, last.subtype, last.content, mergedBbox, last.optionBboxes, current.bbox)
                    }
                }
                i += 1
                continue
            }
            if current.type == "题干", i + 1 < items.count, normalizeItemType(items[i + 1].type) == "题目",
               !contentStartsNewQuestionNumber(items[i + 1].content) {
                let next = items[i + 1]
                let mergedContent = current.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n\n"
                    + next.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let mergedBbox = unionBBox(current.bbox, next.bbox)
                result.append(("题目", next.subtype, mergedContent, mergedBbox, next.optionBboxes, next.figureBbox))
                i += 2
                continue
            }
            if current.type == "题目", i + 1 < items.count, normalizeItemType(items[i + 1].type) == "题目",
               contentLooksLikeStemOnly(current.content),
               contentLooksLikeOptionsOnly(items[i + 1].content),
               !contentStartsNewQuestionNumber(items[i + 1].content) {
                let next = items[i + 1]
                let mergedContent = current.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n\n"
                    + next.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let mergedBbox = unionBBox(current.bbox, next.bbox)
                let mergedOpts = next.optionBboxes ?? current.optionBboxes
                result.append(("题目", next.subtype, mergedContent, mergedBbox, mergedOpts, next.figureBbox))
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
        if t == "附图" || t.contains("附图") { return "附图" }
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

    /// 子任务 1：调用 VL 完成试卷解析 + 校验，只返回逻辑结构，不做切图和持久化
    private func runPaperAnalysis(
        imageData: Data,
        provider: LLMProvider,
        config: any LLMConfigProtocol,
        pageNumber: Int,
        allowNonExamIfHasItems: Bool,
        progress: ((String) -> Void)?,
        caller: String,
        debugPhase: String
    ) async throws -> (PaperVisionResult, [NormalizedItem])? {
        var bestResult: PaperVisionResult?
        var bestScore: Int = -1
        var bestItemsToUse: [NormalizedItem] = []

        for attempt in 0..<3 {
            let current = attempt + 1
            progress?(L10n.analyzeStageVisionAttempt(current: current, total: 3))
            let promptSuffix = (attempt > 0) ? paperAnalysisPromptSuffixForRetry : nil
            let result: PaperVisionResult
            do {
                result = try await LLMService.analyzePaper(
                    imageJPEGData: imageData,
                    provider: provider,
                    config: config,
                    pageNumber: pageNumber,
                    promptSuffix: promptSuffix
                )
            } catch {
                if attempt == 0 { throw error }
                continue
            }

            let itemsToUse = normalizeItemsForProvider(provider, result.normalizedItems)
            // 首页必须是试卷；后续页若识别为非试卷但有有效题目也允许
            if !result.is_homework_or_exam && !(allowNonExamIfHasItems && !itemsToUse.isEmpty) {
                if attempt == 0 && !allowNonExamIfHasItems {
                    return nil
                }
                continue
            }

            debugPrintParseItems(
                attempt: current,
                rawItems: result.normalizedItems.map { r in (type: r.type, subtype: r.subtype, content: r.content) },
                normalizedItems: itemsToUse,
                phase: debugPhase
            )

            let itemsSummary = itemsToUse
                .map { "[\($0.type)]\($0.subtype.map { "/\($0)" } ?? "") \(String($0.content.prefix(400)))" }
                .joined(separator: "\n\n")

            let validation: PaperValidationResult
            do {
                progress?(L10n.analyzeStageValidating(current: current, total: 3))
                validation = try await LLMService.validatePaperResult(
                    imageJPEGData: imageData,
                    itemsSummary: itemsSummary,
                    provider: provider,
                    config: config
                )
            } catch {
                if attempt == 0 { throw error }
                continue
            }

            var score = validation.score ?? 0
            // 额外自检：若存在「选择题 + option_bboxes + content 中没有任何 A./B./C./D. 行」，说明上一次遗漏了选项，强制视为解析不完整以触发重试
            if hasChoiceQuestionMissingOptions(itemsToUse) {
                print("[camit] \(caller): 检测到选择题只包含题干未包含选项，降低本次解析得分以触发重试")
                score = min(score, parseSuccessScoreThreshold - 1)
            }

            if score > bestScore {
                bestScore = score
                bestResult = result
                bestItemsToUse = itemsToUse
            }
            if score >= parseSuccessScoreThreshold {
                break
            }
        }

        guard let finalResult = bestResult, !bestItemsToUse.isEmpty else {
            return nil
        }
        return (finalResult, bestItemsToUse)
    }

    /// 是否存在「选择题 + option_bboxes + content 中没有任何 A./B./C./D. 行」的情况
    /// 这通常意味着 VL 只写了题干却漏掉了文字选项，需要强制重试并在提示词中强调补全选项
    private func hasChoiceQuestionMissingOptions(_ items: [NormalizedItem]) -> Bool {
        for item in items {
            let t = normalizeItemType(item.type)
            guard t == "题目" else { continue }
            // 仅关注存在 option_bboxes 的题目（VL 已检测到选项区域）
            guard let optionBboxes = item.optionBboxes, !optionBboxes.isEmpty else { continue }
            if contentLooksLikeStemOnly(item.content) {
                return true
            }
        }
        return false
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
    private func cropQuestionImage(from image: UIImage, items: [NormalizedItem], index: Int, provider: LLMProvider) -> String? {
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
            if (cropBottom <= cropTop + 1 || cur.y >= 0.98), index > 0, let prev = items[index - 1].bbox, isBBoxUsableForCrop(prev) {
                let (_, prevBottomPx) = bboxToPixelYRange(prev, imageHeight: imageHeight)
                cropTop = max(0, prevBottomPx - marginPx - upwardExpansion)
                cropBottom = imageHeight
            }
        } else {
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

    /// 按 option_bboxes 切出各选项小图（用于图形选项）
    private func cropOptionImages(from image: UIImage, optionBboxes: [String: BBox]?) -> [String: String] {
        guard let boxes = optionBboxes, !boxes.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for (label, bbox) in boxes {
            if let fn = cropImageByBBox(from: image, bbox: bbox) {
                result[label] = fn
            }
        }
        return result
    }

    /// 按 bbox 切图（选项、附图用）。先用 CV 精修边界，再按精修后的 bbox 裁剪
    private func cropImageByBBox(from image: UIImage, bbox: BBox) -> String? {
        let isValidBBox: (BBox) -> Bool = { b in
            b.x >= 0 && b.y >= 0 && b.width > 0 && b.height > 0 && b.x <= 1 && b.y <= 1
        }
        guard isValidBBox(bbox) else { return nil }

        let normalizedImage = normalizeImageOrientation(image)
        guard let cgImage = normalizedImage.cgImage else { return nil }
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        // 方案 C：CV 精修，找到紧贴图形边缘的边界框
        let effectiveBbox = GraphicCropRefinement.refineBBox(cgImage: cgImage, vlBbox: bbox) ?? bbox

        let rx = CGFloat(effectiveBbox.x) * imgW
        let ry = CGFloat(effectiveBbox.y) * imgH
        let rw = CGFloat(effectiveBbox.width) * imgW
        let rh = CGFloat(effectiveBbox.height) * imgH
        let cropRect = CGRect(x: rx, y: ry, width: rw, height: rh)
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        let croppedImage = UIImage(cgImage: cropped)
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

