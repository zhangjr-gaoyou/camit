import SwiftUI

struct WrongQuestionsView: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var store: ScanStore
    @Binding var focusedPaperID: UUID?
    @State private var showAllQuestions: Bool = false
    @State private var analyzingQuestionIDs: Set<UUID> = []
    @State private var alertMessage: String?
    @State private var cropImageToShow: String?

    private var papersWithQuestions: [ScanItem] {
        let all = store.items.filter { !$0.questions.isEmpty }
        if let fid = focusedPaperID {
            return all.filter { $0.id == fid }
        }
        return all
    }

    var body: some View {
        NavigationStack {
            Group {
                if papersWithQuestions.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(papersWithQuestions) { paper in
                                paperSection(paper)
                            }

                            Color.clear.frame(height: 100)
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .background(AppTheme.pageBackground)
            .navigationTitle(L10n.tabWrong)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if focusedPaperID != nil {
                        Button(L10n.wrongShowAllPapers) {
                            focusedPaperID = nil
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.accentBlue)
                    }
                    Toggle(L10n.wrongShowAll, isOn: $showAllQuestions)
                        .toggleStyle(.switch)
                        .tint(AppTheme.accentGreen)
                }
            }
            .onAppear {
                if focusedPaperID != nil {
                    showAllQuestions = true
                }
            }
            .onChange(of: focusedPaperID) { newID in
                if newID != nil {
                    showAllQuestions = true
                }
            }
            .alert(L10n.alertTitle, isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button(L10n.alertOK, role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .sheet(item: Binding(
                get: { cropImageToShow.map { CropImageWrapper(fileName: $0) } },
                set: { cropImageToShow = $0?.fileName }
            )) { wrapper in
                if let url = try? store.imageURL(fileName: wrapper.fileName),
                   let ui = UIImage(contentsOfFile: url.path) {
                    ImageViewer(image: ui, allowZoomAndPan: true)
                } else {
                    Text(L10n.wrongLoadCropFailed)
                }
            }
        }
    }
}

private struct CropImageWrapper: Identifiable {
    let id = UUID()
    let fileName: String
}

/// 结构化解析展示：知识点标签 + 详细解析（题干理解、选项分析、结论）
private struct StructuredExplanationView: View {
    let explanation: String

    private struct Parsed {
        let knowledgePoints: [String]
        let detailedLines: [(style: LineStyle, text: String)]
        enum LineStyle { case heading, bullet, plain }
    }

    private var parsed: Parsed? {
        let kpMarker = "【知识点】"
        let detMarker = "【详细解析】"
        guard explanation.contains(kpMarker) else { return nil }
        var kps: [String] = []
        var detailed: [(Parsed.LineStyle, String)] = []
        var remaining = explanation
        if let r = remaining.range(of: kpMarker) {
            remaining = String(remaining[r.upperBound...])
            if let r2 = remaining.range(of: detMarker) {
                let kpText = String(remaining[..<r2.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                kps = kpText.components(separatedBy: CharacterSet(charactersIn: "、，,"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                remaining = String(remaining[r2.upperBound...])
            }
        }
        if let r = remaining.range(of: detMarker) {
            remaining = String(remaining[r.upperBound...])
        }
        let lines = remaining.components(separatedBy: .newlines)
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if t.hasPrefix("1)") || t.hasPrefix("2)") || t.hasPrefix("3)") || t.hasPrefix("4)") {
                detailed.append((.heading, t))
            } else if t.hasPrefix("•") || t.hasPrefix("-") || t.hasPrefix("·") {
                let content = String(t[t.index(t.startIndex, offsetBy: 1)...])
                    .trimmingCharacters(in: .whitespaces)
                detailed.append((.bullet, content))
            } else {
                detailed.append((.plain, t))
            }
        }
        return Parsed(knowledgePoints: kps, detailedLines: detailed)
    }

    /// 标题行：标签（如 1) 题干理解：）加粗，后面的内容换行显示、与选项分析同字体
    @ViewBuilder
    private func headingWithNormalContent(_ text: String) -> some View {
        if let r = text.range(of: "：") ?? text.range(of: ":") {
            let label = String(text[..<r.upperBound])
            let content = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(content)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    var body: some View {
        if let p = parsed, !p.knowledgePoints.isEmpty || !p.detailedLines.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !p.knowledgePoints.isEmpty {
                    Text("知识点")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    FlowLayout(spacing: 6) {
                        ForEach(p.knowledgePoints, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                if !p.detailedLines.isEmpty {
                    Text("详细解析")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(p.detailedLines.enumerated()), id: \.offset) { _, item in
                            switch item.style {
                            case .heading:
                                headingWithNormalContent(item.text)
                            case .bullet:
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                        .font(.subheadline)
                                        .foregroundStyle(AppTheme.secondaryText)
                                    Text(item.text)
                                        .font(.footnote)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                            case .plain:
                                Text(item.text)
                                    .font(.footnote)
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Text("\(L10n.wrongExplanation)\(explanation)")
                .font(.footnote)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }
}

/// 简单流式布局：横向排列，超宽换行
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (i, pos) in result.positions.enumerated() where i < subviews.count {
            subviews[i].place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

/// 解析选择题：题干 + A/B/C/D 选项。根据选项长度选择一行一条或一行两条。
private struct ParsedChoiceQuestion {
    let stem: String
    let options: [(label: String, text: String)] // e.g. ("A", "Mount Fuji")

    /// 选项是否适合一行两条（选项较短时）
    var useTwoColumns: Bool {
        let maxLen = options.map { $0.text.count }.max() ?? 0
        return maxLen <= 16
    }

    /// 选项是否为图片占位符（如 [图片 A]、[图A] 等），需显示完整切图而非占位文字
    var optionsAreImagePlaceholders: Bool {
        guard !options.isEmpty else { return false }
        let imagePatterns = ["[图片", "[图"]
        return options.allSatisfy { opt in
            let t = opt.text.trimmingCharacters(in: .whitespaces)
            return imagePatterns.contains(where: { p in t.contains(p) && t.contains("]") })
        }
    }

    static func parse(_ text: String) -> ParsedChoiceQuestion? {
        let lines = text.components(separatedBy: .newlines)
        var stemLines: [String] = []
        var opts: [(String, String)] = []
        let optionPattern = try? NSRegularExpression(pattern: "^([ABCD])[\\.、\\)\\s]+(.*)$", options: .caseInsensitive)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                if opts.isEmpty { stemLines.append(line) }
                continue
            }
            if let m = optionPattern?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let labelRange = Range(m.range(at: 1), in: trimmed),
               let contentRange = Range(m.range(at: 2), in: trimmed) {
                let label = String(trimmed[labelRange]).uppercased()
                let content = String(trimmed[contentRange]).trimmingCharacters(in: .whitespaces)
                opts.append((label, content))
            } else if opts.isEmpty {
                stemLines.append(line)
            } else {
                break
            }
        }
        guard opts.count >= 2, opts.count <= 6 else { return nil }
        let stem = stemLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty else { return nil }
        let parsed = ParsedChoiceQuestion(stem: stem, options: opts)
        let stemPreview = String(stem.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        print("[camit] ParsedChoiceQuestion ✓ stem(\(stem.count) chars)=\(stemPreview)… | options=\(opts.map { $0.0 }.joined())")
        return parsed
    }
}

/// 错题页单项卡片：板块分类仅加粗 Label；题干/题目与「生成答案与解析」及生成结果同卡展示，题目才有圆形按钮。
private struct ItemCard: View {
    @EnvironmentObject private var store: ScanStore
    let scanID: UUID
    let question: PaperQuestion
    let onToggleWrong: () -> Void
    let onAnalyze: () -> Void
    let isAnalyzing: Bool
    let onShowCropImage: () -> Void

    private var isSectionKind: Bool {
        (question.kind ?? "题目") == "板块分类"
    }

    private var questionIndexText: String {
        if let idx = question.index {
            return L10n.wrongQuestionNum(idx)
        }
        return ""
    }

    /// 当已显示题号（如「第7题」）时，去掉题干开头的题号前缀（如「7.」「第7题」），避免重复显示。
    private func stemForDisplay(_ raw: String) -> String {
        guard !questionIndexText.isEmpty else { return raw }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return raw }
        // 去掉开头的 "7." / "7．" / "7、" / "第7题"
        if let idx = question.index {
            for prefix in ["第\(idx)题", "\(idx)．", "\(idx)、", "\(idx)."] {
                if s.hasPrefix(prefix) {
                    let rest = String(s[s.index(s.startIndex, offsetBy: prefix.count)...])
                        .trimmingCharacters(in: .whitespaces)
                    return rest.isEmpty ? raw : rest
                }
            }
        }
        // 任意「数字 + .／、」开头也去掉（与当前题号无关的题干题号）
        var i = s.startIndex
        while i < s.endIndex, s[i].isNumber { i = s.index(after: i) }
        if i > s.startIndex, i < s.endIndex {
            let next = s[i]
            if next == "." || next == "．" || next == "、" {
                i = s.index(after: i)
                let rest = String(s[i...]).trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? raw : rest
            }
        }
        return raw
    }

    @ViewBuilder
    private func optionBox(label: String, text: String, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if text.contains("$") {
                LaTeXRichTextView("\(label). \(text)", isSection: false)
                    .foregroundStyle(isSelected ? AppTheme.accentBlue : .primary)
                    .multilineTextAlignment(.leading)
            } else {
                Text("\(label). \(text)")
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? AppTheme.accentBlue : .primary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AppTheme.accentBlue.opacity(0.12) : AppTheme.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? AppTheme.accentBlue : Color(.separator), lineWidth: isSelected ? 2 : 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 解析正文中的【填空】…【/填空】与下划线，填空处在界面上下划线并着色以明显标识。
    private func fillBlankAwareText(_ raw: String, isSection: Bool) -> Text {
        let font = isSection ? Font.headline : Font.subheadline
        let weight = isSection ? Font.Weight.bold : Font.Weight.regular
        let open = "【填空】"
        let close = "【/填空】"
        var result = Text("")
        var remaining = raw
        while !remaining.isEmpty {
            if let rStart = remaining.range(of: open) {
                let before = String(remaining[..<rStart.lowerBound])
                if !before.isEmpty { result = result + Text(before).font(font).fontWeight(weight) }
                remaining = String(remaining[rStart.upperBound...])
                if let rEnd = remaining.range(of: close) {
                    let blank = String(remaining[..<rEnd.lowerBound])
                    if #available(iOS 17.0, *) {
                        result = result + Text(blank.isEmpty ? "_____" : blank)
                            .font(font).fontWeight(weight)
                            .underline(true, color: .blue)
                            .foregroundStyle(.blue)
                    } else {
                        // Fallback on earlier versions
                    }
                    remaining = String(remaining[rEnd.upperBound...])
                } else {
                    result = result + Text(remaining).font(font).fontWeight(weight)
                    break
                }
            } else {
                result = result + Text(remaining).font(font).fontWeight(weight)
                break
            }
        }
        return result == Text("") ? Text(raw).font(font).fontWeight(weight) : result
    }

    private var parsedChoice: ParsedChoiceQuestion? {
        guard question.isQuestionItem else { return nil }
        return ParsedChoiceQuestion.parse(replaceTianziGeWithUnderline(question.text))
    }

    /// 从答案字符串解析出选中选项标签，如 "D. Big Ben" -> "D"
    private var selectedOptionLabel: String? {
        guard let ans = question.answer, !ans.isEmpty else { return nil }
        let t = ans.trimmingCharacters(in: .whitespaces)
        if let first = t.first, "ABCD".contains(first.uppercased()) {
            return String(first).uppercased()
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let sub = question.subtype, !sub.isEmpty, question.isQuestionItem {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Capsule())
                    .padding(.bottom, 6)
            }
            if let parsed = parsedChoice {
                // 选择题：题干 + 选项网格（或完整切图）；题干去题号前缀避免与「第n题」重复；支持 LaTeX 公式渲染
                LaTeXRichTextView(stemForDisplay(parsed.stem), isSection: isSectionKind)

                if parsed.optionsAreImagePlaceholders {
                    if let cropName = question.cropImageFileName,
                       let url = try? store.imageURL(fileName: cropName),
                       let ui = UIImage(contentsOfFile: url.path) {
                        // 选项为图片占位符时，显示完整切图
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(.top, 12)
                            .contentShape(Rectangle())
                            .onTapGesture { onShowCropImage() }
                    } else {
                        // 题目为图形但切图未保存或加载失败，显示提示而非 [图片A] 占位符
                        Text(L10n.wrongGraphicCropMissing)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .padding(.top, 12)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                } else {
                    let cols: [GridItem] = parsed.useTwoColumns
                        ? [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                        : [GridItem(.flexible())]
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(Array(parsed.options.enumerated()), id: \.offset) { _, opt in
                            let isSelected = selectedOptionLabel == opt.label
                            optionBox(label: opt.label, text: opt.text, isSelected: isSelected)
                        }
                    }
                    .padding(.top, 12)
                }
            } else {
                LaTeXRichTextView(stemForDisplay(replaceTianziGeWithUnderline(question.text)), isSection: isSectionKind)
            }

            if question.isQuestionItem {
                if let answer = question.answer, !answer.isEmpty {
                    HStack(spacing: 8) {
                        Text("\(L10n.wrongCorrectAnswer)\(answer)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.accentGreen)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.accentGreen.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 10)
                }
                if let explanation = question.explanation, !explanation.isEmpty {
                    StructuredExplanationView(explanation: explanation)
                        .padding(.top, 10)
                }

                HStack(alignment: .center, spacing: 12) {
                    if isAnalyzing {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.wrongParsing)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    } else {
                        Button {
                            onAnalyze()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.subheadline.weight(.semibold))
                                Text(question.answer == nil && question.explanation == nil ? L10n.wrongGenerateAnswer : L10n.wrongRegenerate)
                                    .font(.subheadline.weight(.medium))
                            }
                            .foregroundStyle(AppTheme.accentBlue)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if question.cropImageFileName != nil {
                        Button(action: onShowCropImage) {
                            Image(systemName: "photo")
                                .foregroundStyle(AppTheme.secondaryText)
                                .font(.system(size: 18, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.wrongShowCrop)
                    }
                    Button(action: onToggleWrong) {
                        Image(systemName: question.isWrong ? "xmark.circle.fill" : "circle")
                            .foregroundStyle(question.isWrong ? Color.red : AppTheme.secondaryText)
                            .font(.system(size: 20, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(question.isWrong ? L10n.wrongUnmarkWrong : L10n.wrongMarkWrong)
                }
                .padding(.top, 10)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(AppTheme.cardShadowOpacity), radius: AppTheme.cardShadowRadius, x: 0, y: AppTheme.cardShadowY)
    }
}

private extension WrongQuestionsView {
    /// 是否为某个板块下的「答题说明」：type=答题说明，或旧数据中 type=题干 且无题号
    func isSectionInstruction(_ q: PaperQuestion) -> Bool {
        let k = q.kind ?? "题目"
        if k == "答题说明" { return true }
        if k == "题干", q.index == nil { return true }
        return false
    }

    func paperSection(_ paper: ScanItem) -> some View {
        let questions = showAllQuestions
            ? paper.questions
            : paper.questions.filter { $0.isWrong }

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(paper.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                Text("\(paper.subject.displayName) · \(paper.grade.displayName)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if questions.isEmpty {
                emptySectionCard
            } else {
                ForEach(Array(questions.enumerated()), id: \.element.id) { index, q in
                    // 如果上一条是板块分类，当前是该板块下的答题说明题干，则已在上一条卡片中展示，这里跳过
                    if index > 0,
                       let prevKind = questions[index - 1].kind,
                       prevKind == "板块分类",
                       isSectionInstruction(q) {
                        EmptyView()
                    }
                    // 板块分类 + 紧随其后的答题说明题干，合并到同一张卡片
                    else if let kind = q.kind,
                            kind == "板块分类",
                            index + 1 < questions.count,
                            isSectionInstruction(questions[index + 1]) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(q.text)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.primary)
                            Text(questions[index + 1].text)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
                        .shadow(color: .black.opacity(AppTheme.cardShadowOpacity),
                                radius: AppTheme.cardShadowRadius,
                                x: 0, y: AppTheme.cardShadowY)
                    }
                    // 其他正常题目/题干/板块，仍用统一的 ItemCard 展示
                    else {
                        ItemCard(
                            scanID: paper.id,
                            question: q,
                            onToggleWrong: { store.toggleWrong(scanID: paper.id, questionID: q.id) },
                            onAnalyze: { analyzeQuestion(paper: paper, question: q) },
                            isAnalyzing: analyzingQuestionIDs.contains(q.id),
                            onShowCropImage: { cropImageToShow = q.cropImageFileName }
                        )
                    }
                }
            }
        }
    }

    var emptySectionCard: some View {
        Text(L10n.wrongNoCrop)
            .font(.subheadline)
            .foregroundStyle(AppTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .background(AppTheme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(AppTheme.secondaryText.opacity(0.5))
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
            Text(L10n.wrongEmptyTitle)
                .font(.title3.weight(.semibold))
            Text(L10n.wrongEmptyHint)
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.pageBackground)
    }

    func analyzeQuestion(paper: ScanItem, question: PaperQuestion) {
        guard !analyzingQuestionIDs.contains(question.id) else { return }
        guard let cfg = settings.effectiveConfig() else { return }
        if cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alertMessage = L10n.settingsApiKeyRequired
            return
        }
        analyzingQuestionIDs.insert(question.id)

        Task {
            defer { analyzingQuestionIDs.remove(question.id) }
            do {
                let result = try await LLMService.analyzeQuestion(
                    question: question.text,
                    subject: paper.subject,
                    grade: paper.grade,
                    provider: settings.provider,
                    config: cfg
                )
                store.updateQuestionAnalysis(
                    scanID: paper.id,
                    questionID: question.id,
                    section: result.section,
                    answer: result.answer,
                    explanation: result.explanation
                )
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    WrongQuestionsView(settings: AppSettings(), focusedPaperID: .constant(nil))
        .environmentObject(ScanStore())
}

