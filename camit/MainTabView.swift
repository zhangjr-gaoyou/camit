import SwiftUI
import UIKit

struct MainTabView: View {
    @StateObject private var settings = AppSettings()
    @StateObject private var store = ScanStore()

    @State private var selectedTab: Tab = .papers
    @State private var isShowingCamera: Bool = false
    @State private var isAnalyzing: Bool = false
    @State private var analyzingMessage: String = L10n.analyzing
    @State private var alertMessage: String?
    @State private var isShowingSettings: Bool = false
    /// 从试卷 TAB 转向错题 TAB 时，聚焦到此试卷并显示全部题目
    @State private var navigateToWrongPaperID: UUID?

    enum Tab: Hashable {
        case papers
        case wrong
    }

    var body: some View {
        ZStack {
            content
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .sheet(isPresented: $isShowingCamera) {
            CameraSheetView(
                onImagePicked: { image in
                    guard let image else { return }
                    Task { await analyzeAndSave(image: image) }
                },
                onDismiss: { isShowingCamera = false }
            )
        }
        .overlay {
            if isAnalyzing {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(analyzingMessage)
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(18)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .transition(.opacity)
            }
        }
        .alert(L10n.alertTitle, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 {
                if alertMessage == L10n.settingsConfigRequiredForCamera {
                    isShowingSettings = true
                }
                alertMessage = nil
            } }
        )) {
            Button(L10n.alertOK, role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(settings: settings)
#if !os(macOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
#endif
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .papers:
            HomeView(settings: settings, onNavigateToWrongQuestions: { paperID in
                selectedTab = .wrong
                navigateToWrongPaperID = paperID
            })
            .environmentObject(store)
        case .wrong:
            WrongQuestionsView(settings: settings, focusedPaperID: $navigateToWrongPaperID)
                .environmentObject(store)
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            tabButton(
                title: L10n.tabPapers,
                systemName: "doc.text",
                isSelected: selectedTab == .papers
            ) {
                selectedTab = .papers
            }

            Spacer()

            cameraButton

            Spacer()

            tabButton(
                title: L10n.tabWrong,
                systemName: "exclamationmark.square",
                isSelected: selectedTab == .wrong
            ) {
                selectedTab = .wrong
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(AppTheme.cardBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
        }
    }

    private func tabButton(title: String, systemName: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .medium))
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(isSelected ? AppTheme.accentBlue : AppTheme.secondaryText)
        }
        .accessibilityLabel(title)
    }

    private var cameraButton: some View {
        Button {
            if let cfg = settings.effectiveConfig(),
               !cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !cfg.effectiveVLModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isShowingCamera = true
            } else {
                alertMessage = L10n.settingsConfigRequiredForCamera
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(AppTheme.accentBlue)
                        .frame(width: 62, height: 62)
                        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 6)

                    Image(systemName: "camera.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 22, weight: .bold))
                }
                Text(L10n.tabCamera)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
        }
        }
        .accessibilityLabel("拍照")
        .accessibilityHint("打开相机拍照扫描")
    }

    @MainActor
    private func analyzeAndSave(image: UIImage) async {
        guard let cfg = settings.effectiveConfig() else { return }
        if cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alertMessage = L10n.settingsApiKeyRequired
            return
        }
        if cfg.effectiveVLModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alertMessage = L10n.settingsVLModelRequired
            return
        }

        analyzingMessage = L10n.analyzeStagePreparing
        isAnalyzing = true
        defer { isAnalyzing = false }

        do {
            let item = try await store.analyzeAndAddScan(
                image: image,
                provider: settings.provider,
                config: cfg,
                progress: { message in
                    // 确保在主线程更新 UI
                    Task { @MainActor in
                        analyzingMessage = message
                    }
                }
            )
            if item == nil {
                alertMessage = L10n.notPaperMessage
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

// MARK: - 拍照窗口：取消 | 拍照 | 从相册选择（无镜头翻转）（可复用：首页「+」加图也用此窗口）
struct CameraSheetView: View {
    @State private var triggerHolder = CaptureTriggerHolder()
    @State private var showAlbum = false
    var onImagePicked: (UIImage?) -> Void
    var onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            CustomCameraView(
                onImagePicked: onImagePicked,
                onDismiss: onDismiss,
                triggerHolder: triggerHolder
            )
            .ignoresSafeArea()

            bottomBar
        }
        .fullScreenCover(isPresented: $showAlbum) {
            PhotoLibraryPicker(
                onImagePicked: { image in
                    if let image { onImagePicked(image) }
                    showAlbum = false
                    onDismiss()
                },
                onDismiss: { showAlbum = false }
            )
            .ignoresSafeArea()
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 0) {
            Button(L10n.cameraCancel) { onDismiss() }
                .foregroundStyle(.white)
                .font(.body)

            Spacer()

            VStack(spacing: 6) {
                Text("PHOTO")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.yellow)
                Button {
                    triggerHolder.trigger?()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)
                        Circle()
                            .strokeBorder(.black.opacity(0.3), lineWidth: 2)
                            .frame(width: 72, height: 72)
                    }
                }
                .accessibilityLabel("拍照")
            }

            Spacer()

            Button {
                showAlbum = true
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(L10n.cameraFromAlbum)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Color.black.opacity(0.35))
    }
}

#Preview {
    MainTabView()
}

