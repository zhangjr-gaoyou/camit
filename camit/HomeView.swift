import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var store: ScanStore
    @ObservedObject var settings: AppSettings
    var onNavigateToWrongQuestions: ((UUID) -> Void)? = nil

    @State private var searchText: String = ""
    @State private var isAllScanSelected: Bool = true
    @State private var selectedGrade: Grade? = nil
    @State private var selectedSubject: Subject? = nil
    @State private var selectedScore: ScoreFilter = .all

    @State private var isShowingSettings: Bool = false
    @State private var isShowingNotifications: Bool = false

    @State private var viewerItem: ScanItem?

    @State private var actionTarget: ScanItem?
    @State private var isShowingActions: Bool = false

    @State private var editingItem: ScanItem?
    @State private var addImageForItem: ScanItem?
    @State private var isAddingImageToPaper: Bool = false

    private var baseItems: [ScanItem] {
        store.items.filter {
            !$0.isArchived &&
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

    var body: some View {
        VStack(spacing: 12) {
            header
            searchBar
            filterRow

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(title: L10n.homeRecent, items: recentItems)
                    section(title: L10n.homeLastWeek, items: lastWeekItems)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .padding(.top, 8)
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
                    allowZoomAndPan: false,
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
                                allowZoomAndPan: false,
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
                Button(L10n.archiveAction) {
                    store.archive(scanID: target.id)
                }
                Button(L10n.deleteAction, role: .destructive) {
                    store.delete(scanID: target.id)
                }
            }
            Button(L10n.cancel, role: .cancel) {}
        }
        .alert(L10n.notificationTitle, isPresented: $isShowingNotifications) {
            Button(L10n.alertOK, role: .cancel) {}
        } message: {
            Text(L10n.noNotifications)
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
                    isAddingImageToPaper = true
                    Task {
                        defer { isAddingImageToPaper = false }
                        try? await store.addImage(scanID: item.id, image: image, provider: settings.provider, config: cfg)
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
                        Text(L10n.parsing)
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
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)

            Text(L10n.appTitle)
                .font(.title3.weight(.semibold))

            Spacer()

            CircleIconButton(systemName: "bell") {
                isShowingNotifications = true
            }

            CircleIconButton(systemName: "gearshape") {
                isShowingSettings = true
            }
        }
        .padding(.horizontal, 16)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.searchPlaceholder, text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .background(isAllScanSelected ? Color.blue : Color.secondary.opacity(0.10))
                    .clipShape(Capsule())
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

    private func section(title: String, items: [ScanItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.bold))

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

private let gradeOrder: [Grade] = [
    .primary1, .primary2, .primary3, .primary4, .primary5, .primary6,
    .junior1, .junior2, .junior3,
    .other,
]

private let subjectOrder: [Subject] = [
    .chinese, .math, .english, .geography, .physics, .chemistry, .other,
]

private struct CircleIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)
                .padding(12)
                .background(Color.secondary.opacity(0.10))
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
                .font(.subheadline.weight(.semibold))
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.10))
        .clipShape(Capsule())
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
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(item.subject.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(hex: item.subject.badgeColorHex))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.92))
                    .clipShape(Capsule())
                    .padding(10)

                if item.imageFileNames.count > 1 {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "doc.on.doc")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
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
                .lineLimit(1)
                .onTapGesture(perform: onTapTitle)

            Text("\(relativeTime(item.createdAt)) · \(item.grade.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
}

#Preview {
    HomeView(settings: AppSettings())
        .environmentObject(ScanStore())
}

