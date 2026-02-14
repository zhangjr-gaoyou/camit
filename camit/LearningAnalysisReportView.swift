import SwiftUI

private let subjectOrder: [Subject] = [
    .chinese, .math, .english, .geography, .physics, .chemistry, .other,
]

/// 学习分析报告页：基于错题信息，调用文本大模型生成学习报告
struct LearningAnalysisReportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ScanStore
    @ObservedObject var settings: AppSettings

    @State private var selectedReportID: UUID?
    @State private var isGenerating: Bool = false
    @State private var errorMessage: String?
    @State private var filterSubject: Subject?
    @State private var filterYearMonth: String?

    /// 有错题的试卷（用于筛选和生成摘要）
    private var papersWithWrong: [ScanItem] {
        store.items.filter { paper in
            !paper.questions.filter { $0.isWrong }.isEmpty
        }
    }

    /// 按科目、年月筛选后的试卷
    private var filteredPapers: [ScanItem] {
        var result = papersWithWrong
        if let s = filterSubject {
            result = result.filter { $0.subject == s }
        }
        if let ym = filterYearMonth {
            let cal = Calendar.current
            result = result.filter { paper in
                let comps = cal.dateComponents([.year, .month], from: paper.createdAt)
                let paperYM = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
                return paperYM == ym
            }
        }
        return result
    }

    /// 按科目分组的错题摘要，便于模型按科目分段生成报告
    private var wrongQuestionsSummary: String {
        var lines: [String] = []
        let grouped = Dictionary(grouping: filteredPapers) { $0.subject }
        for subject in subjectOrder {
            guard let papers = grouped[subject], !papers.isEmpty else { continue }
            lines.append("【科目】\(subject.displayName)")
            for paper in papers {
                let wrongOnes = paper.questions.filter { $0.isWrong }
                guard !wrongOnes.isEmpty else { continue }
                lines.append("【试卷】\(paper.title)（\(paper.subject.displayName)，\(paper.grade.displayName)）")
                for (idx, q) in wrongOnes.enumerated() {
                    var block = "  错题\(idx + 1)：\(q.text.prefix(500))\(q.text.count > 500 ? "…" : "")"
                    if let ans = q.answer, !ans.isEmpty {
                        block += "\n    参考答案：\(ans)"
                    }
                    if let exp = q.explanation, !exp.isEmpty {
                        block += "\n    解析摘要：\(exp.prefix(300))\(exp.count > 300 ? "…" : "")"
                    }
                    if let sub = q.subtype, !sub.isEmpty {
                        block += "\n    题型：\(sub)"
                    }
                    lines.append(block)
                }
                lines.append("")
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }

    /// 可选年月列表（从有错题的试卷中提取）
    private var availableYearMonths: [String] {
        let cal = Calendar.current
        var set = Set<String>()
        for paper in papersWithWrong {
            let comps = cal.dateComponents([.year, .month], from: paper.createdAt)
            if let y = comps.year, let m = comps.month {
                set.insert(String(format: "%04d-%02d", y, m))
            }
        }
        return set.sorted(by: >)
    }

    /// 当前筛选下匹配的报告
    private var filteredReports: [LearningReport] {
        store.learningReports.filter { report in
            let subjectMatch = (filterSubject == nil) || (report.subjectFilter == filterSubject)
            let monthMatch = (filterYearMonth == nil) || (report.yearMonthFilter == filterYearMonth)
            return subjectMatch && monthMatch
        }
    }

    private var hasWrongQuestions: Bool {
        !papersWithWrong.isEmpty
    }

    private var displayedContent: String? {
        if let id = selectedReportID,
           let r = store.learningReports.first(where: { $0.id == id }) {
            return r.content
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !hasWrongQuestions {
                        emptyState
                    } else {
                        filterRow
                        if isGenerating {
                            generatingState
                        } else if let err = errorMessage {
                            errorState(message: err)
                        } else if let content = displayedContent {
                            reportContentSection(content: content)
                        } else {
                            generateSection
                            reportListSection
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.pageBackground)
            .navigationTitle(L10n.learningAnalysisTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.settingsClose) {
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.accentBlue)
                }
                if displayedContent != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button(L10n.learningAnalysisBackToList) {
                            selectedReportID = nil
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.accentBlue)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(AppTheme.secondaryText)
            Text(L10n.learningAnalysisEmpty)
                .font(.body)
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.learningAnalysisFilterSubject)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText)
                    Menu {
                        Button(L10n.homeFilterAll) { filterSubject = nil }
                        ForEach(subjectOrder, id: \.self) { s in
                            Button(s.displayName) { filterSubject = s }
                        }
                    } label: {
                        FilterChip(title: filterSubject?.displayName ?? L10n.homeFilterAll, showsChevron: true)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.learningAnalysisFilterMonth)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText)
                    Menu {
                        Button(L10n.homeFilterAll) { filterYearMonth = nil }
                        ForEach(availableYearMonths, id: \.self) { ym in
                            Button(yearMonthDisplay(ym)) { filterYearMonth = ym }
                        }
                    } label: {
                        FilterChip(title: filterYearMonth.map { yearMonthDisplay($0) } ?? L10n.homeFilterAll, showsChevron: true)
                    }
                }
            }
        }
        .padding(12)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
    }

    private func yearMonthDisplay(_ ym: String) -> String {
        let parts = ym.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return ym }
        return "\(y)年\(m)月"
    }

    private var generatingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text(L10n.learningAnalysisGenerating)
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(L10n.learningAnalysisRetry) {
                errorMessage = nil
                generateReport()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accentBlue)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var generateSection: some View {
        VStack(spacing: 16) {
            Text(L10n.learningAnalysisPrompt)
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Button(L10n.learningAnalysisGenerate) {
                generateReport()
            }
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(hasFilteredWrongQuestions ? AppTheme.accentBlue : AppTheme.accentBlue.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
            .disabled(!hasFilteredWrongQuestions)
        }
        .padding(16)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
    }

    private var hasFilteredWrongQuestions: Bool {
        !wrongQuestionsSummary.isEmpty
    }

    private var reportListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.learningAnalysisReportList)
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)

            if filteredReports.isEmpty {
                Text(L10n.learningAnalysisNoReports)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.vertical, 16)
            } else {
                ForEach(filteredReports) { report in
                    reportRow(report)
                }
            }
        }
    }

    private func reportRow(_ report: LearningReport) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(reportTitle(report))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(reportSubtitle(report))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedReportID = report.id
            }

            Button {
                store.deleteLearningReport(id: report.id)
                if selectedReportID == report.id {
                    selectedReportID = nil
                }
            } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
    }

    private func reportTitle(_ report: LearningReport) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: report.createdAt)
    }

    private func reportSubtitle(_ report: LearningReport) -> String {
        var parts: [String] = []
        if let s = report.subjectFilter {
            parts.append(s.displayName)
        } else {
            parts.append(L10n.homeFilterAll)
        }
        if let ym = report.yearMonthFilter {
            parts.append(yearMonthDisplay(ym))
        } else {
            parts.append(L10n.homeFilterAll)
        }
        return parts.joined(separator: " · ")
    }

    private func reportContentSection(content: String) -> some View {
        MarkdownReportView(content: content)
            .padding(16)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
    }

    private func generateReport() {
        guard let config = settings.effectiveConfig() else {
            errorMessage = L10n.settingsApiKeyRequired
            return
        }
        let summary = wrongQuestionsSummary
        guard !summary.isEmpty else {
            errorMessage = L10n.learningAnalysisEmpty
            return
        }
        isGenerating = true
        errorMessage = nil
        Task {
            do {
                let prompt = learningAnalysisPrompt(wrongQuestionsSummary: summary)
                let text = try await LLMService.chat(prompt: prompt, provider: settings.provider, config: config)
                debugLogModelResponse(api: "learningReport", content: text)
                await MainActor.run {
                    let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.addLearningReport(
                        content: content,
                        subjectFilter: filterSubject,
                        yearMonthFilter: filterYearMonth
                    )
                    if let added = store.learningReports.first {
                        selectedReportID = added.id
                    }
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isGenerating = false
                }
            }
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
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.chipCornerRadius, style: .continuous))
        .foregroundStyle(.primary)
    }
}
