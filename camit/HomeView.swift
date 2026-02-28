import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var store: ScanStore
    @ObservedObject var settings: AppSettings
    var onNavigateToWrongQuestions: ((UUID) -> Void)? = nil
    var onOpenCamera: (() -> Void)? = nil
    var onOpenWrongTab: (() -> Void)? = nil
    /// 进入 Chatbot 页面，携带初始提问
    var onStartChat: ((String) -> Void)? = nil

    @State private var searchText: String = ""
    @State private var isAllScanSelected: Bool = true
    @State private var selectedGrade: Grade? = nil
    @State private var selectedSubject: Subject? = nil
    @State private var selectedScore: ScoreFilter = .all

    @State private var isShowingSettings: Bool = false

    @State private var viewerItem: ScanItem?

    @State private var actionTarget: ScanItem?
    @State private var isShowingActions: Bool = false

    @State private var editingItem: ScanItem?
    @State private var addImageForItem: ScanItem?
    @State private var isAddingImageToPaper: Bool = false
    @State private var addingImageMessage: String = L10n.analyzing
    @State private var askInputText: String = ""
    @State private var isSendingAsk: Bool = false
    @State private var isShowingAttachmentSheet: Bool = false
    @State private var isShowingAlbumPicker: Bool = false
    @State private var isShowingDocumentPicker: Bool = false
    @State private var attachedImageCount: Int = 0
    @State private var attachedFileNames: [String] = []

    /// 首页内部导航：总览 / 试卷库 / 学习报告
    private enum HomePage {
        case overview
        case papersLibrary
        case learningReport
    }

    @State private var currentPage: HomePage = .overview

    private var baseItems: [ScanItem] {
        store.items.filter {
            !$0.isArchived &&
            $0.isHomeworkOrExam &&
            !$0.imageFileNames.isEmpty
        }
    }

    private var baseArchivedItems: [ScanItem] {
        store.items.filter {
            $0.isArchived &&
            $0.isHomeworkOrExam &&
            !$0.imageFileNames.isEmpty
        }
    }

    private var filteredItems: [ScanItem] {
        var results = baseItems
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            results = results.filter { $0.title.localizedCaseInsensitiveContains(q) }
        }
        if let g = selectedGrade { results = results.filter { $0.grade == g } }
        if let s = selectedSubject { results = results.filter { $0.subject == s } }
        // score filter 预留，将来可根据 score 字段补充
        return results
    }

    private var filteredArchivedItems: [ScanItem] {
        var results = baseArchivedItems
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            results = results.filter { $0.title.localizedCaseInsensitiveContains(q) }
        }
        if let g = selectedGrade { results = results.filter { $0.grade == g } }
        if let s = selectedSubject { results = results.filter { $0.subject == s } }
        return results.sorted { $0.createdAt > $1.createdAt }
    }

    /// 本周所有试卷（按创建时间范围），用于「本周 / 最近添加」区块
    private var recentItems: [ScanItem] {
        let calendar = Calendar.current
        let now = Date()
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now) else {
            return filteredItems
        }
        return filteredItems.filter { weekInterval.contains($0.createdAt) }
    }

    /// 上周所有试卷（按创建时间范围），用于「上周」区块
    private var lastWeekItems: [ScanItem] {
        let calendar = Calendar.current
        let now = Date()
        guard
            let thisWeekInterval = calendar.dateInterval(of: .weekOfYear, for: now),
            let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekInterval.start),
            let lastWeekInterval = calendar.dateInterval(of: .weekOfYear, for: lastWeekStart)
        else {
            return []
        }
        return filteredItems.filter { lastWeekInterval.contains($0.createdAt) }
    }

    /// 当前未归档试卷中的所有可作答题目
    private var activeQuestions: [PaperQuestion] {
        baseItems.flatMap { item in
            item.questions.filter { $0.isQuestionItem }
        }
    }

    /// 当前未归档试卷中的所有错题
    private var activeWrongQuestions: [PaperQuestion] {
        activeQuestions.filter { $0.isWrong }
    }

    /// 根据题目错对情况综合估计一个分数（0-100）
    private var estimatedScore: Int {
        let total = activeQuestions.count
        guard total > 0 else { return 0 }
        let wrong = activeWrongQuestions.count
        let correct = max(0, total - wrong)
        let ratio = Double(correct) / Double(total)
        return max(0, min(100, Int((ratio * 100).rounded())))
    }

    /// 错题集中出现的知识点（优先使用题目所在 section，其次按科目名，属于本地统计）
    private var knowledgeTags: [String] {
        var counts: [String: Int] = [:]
        for q in activeWrongQuestions {
            if let sec = q.section?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sec.isEmpty {
                counts[sec, default: 0] += 1
            }
        }
        // 如果没有结构化 section，则退化为按科目汇总
        if counts.isEmpty {
            for item in baseItems {
                let wrongCount = item.questions.filter { $0.isWrong }.count
                guard wrongCount > 0 else { continue }
                let key = item.subject.displayName
                counts[key, default: 0] += wrongCount
            }
        }
        let sorted = counts.sorted { $0.value > $1.value }.map(\.key)
        return Array(sorted.prefix(5))
    }

    /// 通过大模型从错题文本中抽取出的知识点（作为补充）
    @State private var modelKnowledgeTags: [String] = []
    @State private var isExtractingKnowledgeTags: Bool = false

    /// 实际用于展示与指导的知识点（优先使用结构化统计，其次模型抽取）
    private var effectiveKnowledgeTags: [String] {
        if !knowledgeTags.isEmpty {
            return knowledgeTags
        }
        if !modelKnowledgeTags.isEmpty {
            return modelKnowledgeTags
        }
        return []
    }

    /// 默认的「最近指导」提示（在未触发对话或模型失败时使用）
    private var defaultGuidanceText: String {
        let wrongCount = activeWrongQuestions.count
        if wrongCount == 0 {
            return L10n.homeGuidanceNoWrong
        }
        let tags = effectiveKnowledgeTags
        let tagPart: String
        if tags.isEmpty {
            tagPart = L10n.homeGuidanceGenericTags
        } else if tags.count == 1 {
            tagPart = tags[0]
        } else if tags.count == 2 {
            tagPart = tags.joined(separator: "、")
        } else {
            let head = tags.prefix(2).joined(separator: "、")
            tagPart = head + " 等知识点"
        }
        return L10n.homeGuidanceByStats(tagSummary: tagPart, wrongCount: wrongCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            mainContent
        }
        .padding(.top, 8)
        .background(AppTheme.pageBackground)
        .overlay(alignment: .bottomTrailing) {
            if currentPage == .overview {
                floatingChatButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 28)
            }
        }
        .confirmationDialog("添加附件", isPresented: $isShowingAttachmentSheet, titleVisibility: .visible) {
            Button("从相册选择") {
                isShowingAlbumPicker = true
                isShowingAttachmentSheet = false
            }
            Button("从文件中选择") {
                isShowingDocumentPicker = true
                isShowingAttachmentSheet = false
            }
            Button(L10n.cancel, role: .cancel) {}
        }
        .sheet(isPresented: $isShowingAlbumPicker) {
            PhotoLibraryPicker(
                onImagePicked: { image in
                    if image != nil {
                        attachedImageCount += 1
                    }
                    isShowingAlbumPicker = false
                },
                onDismiss: {
                    isShowingAlbumPicker = false
                }
            )
        }
        .sheet(isPresented: $isShowingDocumentPicker) {
            DocumentPicker(
                onPicked: { urls in
                    let names = urls.map { $0.lastPathComponent }
                    attachedFileNames.append(contentsOf: names)
                },
                onDismiss: {
                    isShowingDocumentPicker = false
                }
            )
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(settings: settings)
#if !os(macOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
#endif
        }
        .sheet(item: $viewerItem) { item in
            if item.imageFileNames.isEmpty {
                Text(L10n.noImage)
            } else if item.imageFileNames.count == 1,
                      let url = store.imageURL(for: item, index: 0),
                      let ui = UIImage(contentsOfFile: url.path) {
                ImageViewer(
                    image: ui,
                    allowZoomAndPan: true,
                    showNavigateButton: true,
                    onNavigateToWrong: {
                        viewerItem = nil
                        onNavigateToWrongQuestions?(item.id)
                    }
                )
            } else {
                TabView {
                    ForEach(0..<item.imageFileNames.count, id: \.self) { index in
                        if let url = store.imageURL(for: item, index: index),
                           let ui = UIImage(contentsOfFile: url.path) {
                            ImageViewer(
                                image: ui,
                                allowZoomAndPan: true,
                                showNavigateButton: true,
                                onNavigateToWrong: {
                                    viewerItem = nil
                                    onNavigateToWrongQuestions?(item.id)
                                }
                            )
                        } else {
                            Color.gray.opacity(0.3)
                        }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .ignoresSafeArea()
            }
        }
        .confirmationDialog(L10n.paperActions, isPresented: $isShowingActions, titleVisibility: .visible) {
            if let target = actionTarget {
                if target.isArchived {
                    Button(L10n.unarchiveAction) {
                        store.unarchive(scanID: target.id)
                    }
                } else {
                    Button(L10n.archiveAction) {
                        store.archive(scanID: target.id)
                    }
                }
                Button(L10n.deleteAction, role: .destructive) {
                    store.delete(scanID: target.id)
                }
            }
            Button(L10n.cancel, role: .cancel) {}
        }
        .sheet(item: $editingItem) { item in
            PaperMetaEditorView(item: item) { title, grade, subject, score in
                store.updateMeta(
                    scanID: item.id,
                    title: title,
                    grade: grade,
                    subject: subject,
                    score: score
                )
            }
        }
        .sheet(item: $addImageForItem) { item in
            CameraSheetView(
                onImagePicked: { image in
                    guard let image, let cfg = settings.effectiveConfig() else { return }
                    addImageForItem = nil
                    addingImageMessage = L10n.analyzeStagePreparing
                    isAddingImageToPaper = true
                    Task {
                        defer { isAddingImageToPaper = false }
                        try? await store.addImage(
                            scanID: item.id,
                            image: image,
                            provider: settings.provider,
                            config: cfg,
                            progress: { message in
                                Task { @MainActor in
                                    addingImageMessage = message
                                }
                            }
                        )
                    }
                },
                onDismiss: { addImageForItem = nil }
            )
        }
        .overlay {
            if isAddingImageToPaper {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(addingImageMessage)
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(18)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .onChange(of: store.items) { _ in
            // Ensure selected filter values still exist in the list.
            if let g = selectedGrade, !Set(baseItems.map(\.grade)).contains(g) {
                selectedGrade = nil
            }
            if let s = selectedSubject, !Set(baseItems.map(\.subject)).contains(s) {
                selectedSubject = nil
            }
            triggerKnowledgeTagExtractionIfNeeded()
        }
        .onAppear {
            triggerKnowledgeTagExtractionIfNeeded()
        }
    }

    // MARK: - 页面内容

    @ViewBuilder
    private var mainContent: some View {
        switch currentPage {
        case .overview:
            overviewPage
        case .papersLibrary:
            papersLibraryPage
        case .learningReport:
            learningReportPage
        }
    }

    /// 总览首页（张老师 + AI 卡片 + 快捷入口 + 最近指导）
    private var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                newHeader
                aiProgressReportCard
                quickAccessGrid
                recentGuidanceCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    /// 试卷库整页
    private var papersLibraryPage: some View {
        VStack(spacing: 0) {
            HStack {
                Button(L10n.homeBackHome) {
                    currentPage = .overview
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.accentBlue)

                Spacer()

                Text(L10n.homeQuickPapers)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()
                    .frame(width: 44)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            VStack(spacing: 12) {
                searchBar
                filterRow
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section(title: L10n.homeRecent, items: recentItems)
                        section(title: L10n.homeLastWeek, items: lastWeekItems)
                        section(title: L10n.homeArchived, items: filteredArchivedItems, isArchived: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                }
            }
            .padding(.top, 8)
        }
        .background(AppTheme.pageBackground)
    }

    /// 学习报告整页
    private var learningReportPage: some View {
        LearningAnalysisReportView(settings: settings, onBackHome: {
            currentPage = .overview
        })
        .environmentObject(store)
    }

    // MARK: - 新首页 UI（参考张老师 设计）

    private var newHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(AppTheme.accentBlue.opacity(0.9))

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.homeAITeacherName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(L10n.homeAIStatus)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.accentBlue)
            }

            Spacer()

            CircleIconButton(systemName: "gearshape") {
                isShowingSettings = true
            }
        }
        .padding(.horizontal, 4)
    }

    private var aiProgressReportCard: some View {
        let papersThisWeek = recentItems.count
        let target = 20
        let percent = min(100, target > 0 ? (papersThisWeek * 100 / target) : 0)
        let improvement = 12
        let summary = L10n.homeAIProgressSummary(papersCount: papersThisWeek, percent: improvement, focusHint: L10n.homeGeometryFocusHint)

        return VStack(alignment: .leading, spacing: 14) {
            Text(L10n.homeAIProgressTitle)
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)

            Text(summary.replacingOccurrences(of: "**", with: ""))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                completionBlock(score: estimatedScore)
                focusBlock(tags: effectiveKnowledgeTags)
            }
        }
        .padding(18)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(AppTheme.cardShadowOpacity), radius: AppTheme.cardShadowRadius, x: 0, y: AppTheme.cardShadowY)
    }

    private func completionBlock(score: Int) -> some View {
        let clamped = max(0, min(100, score))
        let progress = CGFloat(clamped) / 100
        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.homeCompletionTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color(.tertiarySystemFill), lineWidth: 6)
                        .frame(width: 52, height: 52)
                    Circle()
                        .trim(from: 0, to: min(1, progress))
                        .stroke(AppTheme.accentBlue, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 52, height: 52)
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(clamped)")
                            .font(.subheadline.weight(.bold))
                        Text("/100")
                            .font(.caption2)
                    }
                    .foregroundStyle(.primary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("基于当前试卷错题情况的综合估计约 \(clamped) 分（满分 100）")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
        .padding(.top, 10)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .background(Color(.tertiarySystemFill).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func focusBlock(tags: [String]) -> some View {
        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.homeFocusTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
            if tags.isEmpty {
                Text(L10n.homeFocusNoData)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                FlexibleTagWrap(tags: tags)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
        .padding(.top, 10)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .background(Color(.tertiarySystemFill).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var quickAccessGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            QuickAccessButton(icon: "doc.viewfinder", title: L10n.homeQuickScan, color: AppTheme.accentBlue) {
                onOpenCamera?()
            }
            QuickAccessButton(icon: "folder", title: L10n.homeQuickPapers, color: AppTheme.accentBlue) {
                currentPage = .papersLibrary
            }
            QuickAccessButton(icon: "exclamationmark.circle.fill", title: L10n.homeQuickWrong, color: Color.orange) {
                onOpenWrongTab?()
            }
            QuickAccessButton(icon: "chart.bar.fill", title: L10n.homeQuickReport, color: Color.purple) {
                currentPage = .learningReport
            }
        }
    }

    private var recentGuidanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.homeRecentGuidance)
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(L10n.homeAITeacherName)
                        .font(.subheadline.weight(.semibold))
                    Text(L10n.homeGuidanceJustNow)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                MarkdownReportView(content: defaultGuidanceText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(AppTheme.cardShadowOpacity), radius: AppTheme.cardShadowRadius, x: 0, y: AppTheme.cardShadowY)
        }
    }

    /// 首页右下角的「张老师」浮动按钮，点击进入学习问答页面
    private var floatingChatButton: some View {
        Button {
            onStartChat?("")
        } label: {
            ZStack {
                Circle()
                    .fill(AppTheme.accentBlue)
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
                Image("laoshi")
                    .resizable()
                    .frame(width: 34, height: 34)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("学习问答")
    }

    // 对话内容不再单独展示，仅保留底部单行输入框用于向模型提问

    // MARK: - 跳转到 Chatbot 页面

    private func sendAskToChat() {
        let text = askInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var question = text
        var attachmentLines: [String] = []
        if attachedImageCount > 0 {
            attachmentLines.append("附带 \(attachedImageCount) 张图片（来自相册）")
        }
        if !attachedFileNames.isEmpty {
            let names = attachedFileNames.joined(separator: "、")
            attachmentLines.append("附带文件：\(names)")
        }
        if !attachmentLines.isEmpty {
            question += "\n\n【附件说明】\n" + attachmentLines.joined(separator: "\n")
        }
        onStartChat?(question)
        askInputText = ""
        attachedImageCount = 0
        attachedFileNames = []
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.secondaryText)
            TextField(L10n.searchPlaceholder, text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var filterRow: some View {
        HStack(spacing: 10) {
            Button {
                isAllScanSelected.toggle()
                if isAllScanSelected {
                    selectedGrade = nil
                    selectedSubject = nil
                    selectedScore = .all
                }
            } label: {
                Text(L10n.homeFilterAll)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isAllScanSelected ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isAllScanSelected ? AppTheme.accentBlue : AppTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.chipCornerRadius, style: .continuous))
            }

            Menu {
                Button(L10n.homeFilterAll) { selectedGrade = nil; isAllScanSelected = false }
                ForEach(gradeOrder, id: \.self) { g in
                    Button(g.displayName) { selectedGrade = g; isAllScanSelected = false }
                }
            } label: {
                FilterChip(title: selectedGrade?.displayName ?? L10n.filterGrade, showsChevron: true)
            }

            Menu {
                Button(L10n.homeFilterAll) { selectedSubject = nil; isAllScanSelected = false }
                ForEach(subjectOrder, id: \.self) { s in
                    Button(s.displayName) { selectedSubject = s; isAllScanSelected = false }
                }
            } label: {
                FilterChip(title: selectedSubject?.displayName ?? L10n.filterSubject, showsChevron: true)
            }

            Menu {
                ForEach(ScoreFilter.allCases, id: \.self) { s in
                    Button(s.displayName) { selectedScore = s; isAllScanSelected = false }
                }
            } label: {
                FilterChip(title: selectedScore.displayName, showsChevron: true)
            }
        }
        .padding(.horizontal, 16)
    }

    private func section(title: String, items: [ScanItem], isArchived: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)

            if items.isEmpty {
                Text(isArchived ? L10n.homeArchivedEmpty : "")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(items) { item in
                        ScanCardView(
                            item: item,
                            onTapImage: { handleTap(on: item) },
                            onLongPress: { handleLongPress(on: item) },
                            onTapTitle: { handleEditMeta(on: item) },
                            onAddImage: { addImageForItem = item }
                        )
                    }
                }
            }
        }
    }
}

private let gradeOrder: [Grade] = [
    .primary1, .primary2, .primary3, .primary4, .primary5, .primary6,
    .junior1, .junior2, .junior3,
    .other,
]

private let subjectOrder: [Subject] = [
    .chinese, .math, .english, .geography, .physics, .chemistry, .other,
]

private struct QuickAccessButton: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(AppTheme.cardShadowOpacity), radius: AppTheme.cardShadowRadius, x: 0, y: AppTheme.cardShadowY)
        }
        .buttonStyle(.plain)
    }
}

private struct CircleIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill))
                .clipShape(Circle())
        }
    }
}

private struct FilterChip: View {
    let title: String
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.chipCornerRadius, style: .continuous))
        .foregroundStyle(.primary)
    }
}

private struct ScanCardView: View {
    @EnvironmentObject private var store: ScanStore
    let item: ScanItem
    let onTapImage: () -> Void
    let onLongPress: () -> Void
    let onTapTitle: () -> Void
    let onAddImage: () -> Void

    private let cardHeight: CGFloat = 160
    private let stackOffset: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                cardImageStack
                    .frame(height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))

                Text(item.subject.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 28)
                    .background(Color(hex: item.subject.badgeColorHex).opacity(0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(10)

                if item.imageFileNames.count > 1 {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "doc.on.doc")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.black.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .padding(10)
                        }
                        Spacer()
                    }
                    .frame(height: cardHeight)
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: onAddImage) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        }
                        .padding(8)
                    }
                }
                .frame(height: cardHeight)
            }

            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .onTapGesture(perform: onTapTitle)

            Text("\(relativeTime(item.createdAt)) · \(item.grade.displayName)")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(12)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(AppTheme.cardShadowOpacity), radius: AppTheme.cardShadowRadius, x: 0, y: AppTheme.cardShadowY)
        .contentShape(Rectangle())
        .onLongPressGesture(perform: onLongPress)
    }

    @ViewBuilder
    private var cardImageStack: some View {
        if item.imageFileNames.isEmpty {
            ZStack {
                placeholderGradient
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTapImage)
        } else {
            ZStack {
                ForEach(Array(item.imageFileNames.enumerated().reversed()), id: \.offset) { idx, _ in
                    singleCardImage(index: idx)
                        .offset(
                            x: stackOffset * CGFloat(item.imageFileNames.count - 1 - idx),
                            y: stackOffset * CGFloat(item.imageFileNames.count - 1 - idx)
                        )
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTapImage)
        }
    }

    @ViewBuilder
    private func singleCardImage(index: Int) -> some View {
        if let url = store.imageURL(for: item, index: index),
           let ui = UIImage(contentsOfFile: url.path) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
        } else {
            placeholderGradient
        }
    }

    private var placeholderGradient: some View {
        LinearGradient(
            colors: [
                Color.secondary.opacity(0.25),
                Color.secondary.opacity(0.12),
                Color.secondary.opacity(0.20),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60)分钟前" }
        if seconds < 24 * 3600 { return "\(seconds / 3600)小时前" }
        return "\(seconds / (24 * 3600))天前"
    }
}

/// 简单的标签换行布局，用于展示 3-5 个知识点标签
private struct FlexibleTagWrap: View {
    let tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(computedRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppTheme.cardBackground)
                            .foregroundStyle(AppTheme.accentBlue)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    /// 简单按顺序分行（不测量真实宽度），保证最多两行展示常见 3-5 个标签
    private var computedRows: [[String]] {
        var currentRow: [String] = []
        var rows: [[String]] = []
        for tag in tags {
            if currentRow.count >= 3 {
                rows.append(currentRow)
                currentRow = []
            }
            currentRow.append(tag)
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }
}

// Chat 相关 UI 已移至单独的对话页面

private extension HomeView {
    func handleTap(on item: ScanItem) {
        viewerItem = item
    }

    func handleLongPress(on item: ScanItem) {
        actionTarget = item
        isShowingActions = true
    }

    func handleEditMeta(on item: ScanItem) {
        editingItem = item
    }

    /// 若没有结构化知识点标签，则尝试通过大模型从错题文本中抽取 3-5 个知识点
    func triggerKnowledgeTagExtractionIfNeeded() {
        if !knowledgeTags.isEmpty { return }
        if !modelKnowledgeTags.isEmpty { return }
        if activeWrongQuestions.isEmpty { return }
        if isExtractingKnowledgeTags { return }
        guard let cfg = settings.effectiveConfig() else { return }

        let text = buildWrongQuestionsSummaryForTags()
        guard !text.isEmpty else { return }

        isExtractingKnowledgeTags = true
        Task {
            let prompt = """
你是一位中学老师，请阅读下面学生的错题文本，抽取 3-5 个最核心的知识点短语，作为后续复习的重点。
要求：
1. 每个知识点不超过 10 个汉字。
2. 用一行一个知识点的形式输出，不要编号，不要多余说明。

【错题文本】
\(text)
"""
            do {
                let reply = try await LLMService.chat(prompt: prompt, provider: settings.provider, config: cfg)
                let rawLines = reply
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                var tags: [String] = []
                for line in rawLines {
                    var t = line
                    // 去掉可能的编号或项目符号
                    if let range = t.range(of: #"^[-*\d\.\)\s]+"#, options: .regularExpression) {
                        t.removeSubrange(range)
                        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if t.isEmpty { continue }
                    if t.count > 10 {
                        t = String(t.prefix(10))
                    }
                    if !tags.contains(t) {
                        tags.append(t)
                    }
                    if tags.count >= 5 { break }
                }
                await MainActor.run {
                    modelKnowledgeTags = tags
                }
            } catch {
                // 忽略模型错误，保持空标签
            }
            await MainActor.run {
                isExtractingKnowledgeTags = false
            }
        }
    }

    /// 抽取知识点时使用的错题文本摘要
    func buildWrongQuestionsSummaryForTags() -> String {
        let maxQuestions = 12
        let selected = activeWrongQuestions.prefix(maxQuestions)
        guard !selected.isEmpty else { return "" }
        let parts = selected.enumerated().map { idx, q in
            "题目\(idx + 1)：\(q.text.prefix(120))"
        }
        return parts.joined(separator: "\n")
    }
}

#Preview {
    HomeView(settings: AppSettings())
        .environmentObject(ScanStore())
}

