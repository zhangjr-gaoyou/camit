import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var store: ScanStore
    @ObservedObject var settings: AppSettings

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

    private var baseItems: [ScanItem] {
        store.items.filter {
            !$0.isArchived &&
            $0.isHomeworkOrExam &&
            $0.imageFileName != nil
        }
    }

    private var availableGrades: [Grade] {
        let present = Set(baseItems.map(\.grade))
        return gradeOrder.filter { present.contains($0) }
    }

    private var availableSubjects: [Subject] {
        let present = Set(baseItems.map(\.subject))
        return subjectOrder.filter { present.contains($0) }
    }

    private var filteredItems: [ScanItem] {
        var results = baseItems
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            results = results.filter { $0.title.localizedCaseInsensitiveContains(q) }
        }
        if let g = selectedGrade { results = results.filter { $0.grade == g } }
        if let s = selectedSubject { results = results.filter { $0.subject == s } }
        // score is placeholder (no score in model yet)
        return results
    }

    private var recentItems: [ScanItem] {
        Array(filteredItems.prefix(2))
    }

    private var lastWeekItems: [ScanItem] {
        Array(filteredItems.dropFirst(2).prefix(4))
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            searchBar
            filterRow

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(title: "最近添加", items: recentItems)
                    section(title: "上周", items: lastWeekItems)
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
            if let url = store.imageURL(for: item),
               let ui = UIImage(contentsOfFile: url.path) {
                ImageViewer(image: ui)
            } else {
                Text("无法加载试卷图片")
            }
        }
        .confirmationDialog("试卷操作", isPresented: $isShowingActions, titleVisibility: .visible) {
            if let target = actionTarget {
                Button("归档") {
                    store.archive(scanID: target.id)
                }
                Button("删除", role: .destructive) {
                    store.delete(scanID: target.id)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("通知", isPresented: $isShowingNotifications) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("暂无新通知。")
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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.blue)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "book.pages")
                        .foregroundStyle(.white)
                )

            Text("试卷管家")
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
            TextField("搜索试卷、科目、年级…", text: $searchText)
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
                Text("全部试卷")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isAllScanSelected ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isAllScanSelected ? Color.blue : Color.secondary.opacity(0.10))
                    .clipShape(Capsule())
            }

            Menu {
                Button("全部") { selectedGrade = nil; isAllScanSelected = false }
                ForEach(availableGrades, id: \.self) { g in
                    Button(g.rawValue) { selectedGrade = g; isAllScanSelected = false }
                }
            } label: {
                FilterChip(title: selectedGrade?.rawValue ?? "年级", showsChevron: true)
            }

            Menu {
                Button("全部") { selectedSubject = nil; isAllScanSelected = false }
                ForEach(availableSubjects, id: \.self) { s in
                    Button(s.rawValue) { selectedSubject = s; isAllScanSelected = false }
                }
            } label: {
                FilterChip(title: selectedSubject?.rawValue ?? "科目", showsChevron: true)
            }

            Menu {
                ForEach(ScoreFilter.allCases, id: \.self) { s in
                    Button(s.rawValue) { selectedScore = s; isAllScanSelected = false }
                }
            } label: {
                FilterChip(title: selectedScore.rawValue, showsChevron: true)
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
                        onTapTitle: { handleEditMeta(on: item) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                cardImage
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(item.subject.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(hex: item.subject.badgeColorHex))
                    .clipShape(Capsule())
                    .padding(10)
            }

            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .onTapGesture(perform: onTapTitle)

            Text("\(relativeTime(item.createdAt)) · \(item.grade.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(perform: onLongPress)
    }

    @ViewBuilder
    private var cardImage: some View {
        if let url = store.imageURL(for: item),
           let ui = UIImage(contentsOfFile: url.path) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .onTapGesture(perform: onTapImage)
        } else {
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

