import SwiftUI

struct WrongQuestionsView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var showAllQuestions: Bool = false
    @State private var analyzingQuestionIDs: Set<UUID> = []
    @State private var alertMessage: String?
    @State private var cropImageToShow: String?

    private var papersWithQuestions: [ScanItem] {
        store.items.filter { !$0.questions.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if papersWithQuestions.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            Toggle("显示全部题目", isOn: $showAllQuestions)
                        }

                        ForEach(papersWithQuestions) { paper in
                            Section {
                                questionsSectionContent(for: paper)
                            } header: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(paper.title)
                                        .font(.headline)
                                    Text("\(paper.subject.rawValue) · \(paper.grade.rawValue)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .textCase(nil)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("错题")
            .alert("提示", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button("确定", role: .cancel) {}
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
                    Text("无法加载切图")
                }
            }
        }
    }
}

private struct CropImageWrapper: Identifiable {
    let id = UUID()
    let fileName: String
}

/// 错题页单项卡片：板块分类仅加粗 Label；题干/题目与「生成答案与解析」及生成结果同卡展示，题目才有圆形按钮。
private struct ItemCard: View {
    let scanID: UUID
    let question: PaperQuestion
    let onToggleWrong: () -> Void
    let onAnalyze: () -> Void
    let isAnalyzing: Bool
    let onShowCropImage: () -> Void

    private var isSectionKind: Bool {
        (question.kind ?? "题目") == "板块分类"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fillBlankAwareText(question.text, isSection: isSectionKind)
                .fixedSize(horizontal: false, vertical: true)

            if question.isQuestionItem {
                if let answer = question.answer, !answer.isEmpty {
                    Text("正确答案：\(answer)")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 10)
                }
                if let explanation = question.explanation, !explanation.isEmpty {
                    Text("解析：\(explanation)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }

                HStack(alignment: .center, spacing: 12) {
                    if isAnalyzing {
                        ProgressView()
                            .controlSize(.small)
                        Text("解析生成中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(question.answer == nil && question.explanation == nil ? "生成答案与解析" : "重新生成解析") {
                            onAnalyze()
                        }
                        .font(.caption)
                        .foregroundStyle(.blue)
                    }
                    Spacer()
                    if question.cropImageFileName != nil {
                        Button(action: onShowCropImage) {
                            Image(systemName: "photo")
                                .foregroundStyle(.blue)
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("显示题目切图")
                    }
                    Button(action: onToggleWrong) {
                        Image(systemName: question.isWrong ? "xmark.circle.fill" : "circle")
                            .foregroundStyle(question.isWrong ? Color.red : Color.secondary)
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(question.isWrong ? "取消错题" : "标记为错题")
                }
                .padding(.top, 10)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension WrongQuestionsView {
    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("暂无题目")
                .font(.title3.weight(.semibold))
            Text("拍照识别作业/试卷后，会在这里按试卷展示题目。\n默认只显示你标记为错题的题目，可通过开关查看全部。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    func questionsSectionContent(for paper: ScanItem) -> some View {
        let questions = showAllQuestions
            ? paper.questions
            : paper.questions.filter { $0.isWrong }

        if questions.isEmpty {
            Text("暂无错题")
                .foregroundStyle(.secondary)
        } else {
            let grouped = Dictionary(grouping: questions) { (q: PaperQuestion) in
                (q.section?.isEmpty == false ? q.section! : "未分板块")
            }
            let orderedKeys = grouped.keys.sorted()

            ForEach(orderedKeys, id: \.self) { section in
                if section != "未分板块" {
                    Text(section)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(grouped[section] ?? []) { q in
                    ItemCard(
                        scanID: paper.id,
                        question: q,
                        onToggleWrong: { store.toggleWrong(scanID: paper.id, questionID: q.id) },
                        onAnalyze: { analyzeQuestion(paper: paper, question: q) },
                        isAnalyzing: analyzingQuestionIDs.contains(q.id),
                        onShowCropImage: { cropImageToShow = q.cropImageFileName }
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
    }

    func analyzeQuestion(paper: ScanItem, question: PaperQuestion) {
        guard !analyzingQuestionIDs.contains(question.id) else { return }
        analyzingQuestionIDs.insert(question.id)

        Task {
            defer { analyzingQuestionIDs.remove(question.id) }
            do {
                // Use the main text model with current bailian config.
                let cfg = (try? BailianConfig.load()) ?? BailianConfig()
                if cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    alertMessage = "请先在设置中配置百炼 API Key。"
                    return
                }
                let result = try await BailianClient().analyzeQuestion(
                    question: question.text,
                    subject: paper.subject,
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
    WrongQuestionsView()
        .environmentObject(ScanStore())
}

