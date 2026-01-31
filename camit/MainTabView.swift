import SwiftUI
import UIKit

struct MainTabView: View {
    @StateObject private var settings = AppSettings()
    @StateObject private var store = ScanStore()

    @State private var selectedTab: Tab = .papers
    @State private var isShowingCamera: Bool = false
    @State private var isAnalyzing: Bool = false
    @State private var alertMessage: String?

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
                        Text("识别中…")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(18)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .transition(.opacity)
            }
        }
        .alert("提示", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .papers:
            HomeView(settings: settings)
                .environmentObject(store)
        case .wrong:
            WrongQuestionsView()
                .environmentObject(store)
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            tabButton(
                title: "试卷",
                systemName: "doc.text",
                isSelected: selectedTab == .papers
            ) {
                selectedTab = .papers
            }

            Spacer()

            cameraButton

            Spacer()

            tabButton(
                title: "错题",
                systemName: "list.bullet.clipboard",
                isSelected: selectedTab == .wrong
            ) {
                selectedTab = .wrong
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.secondary.opacity(0.20))
                .frame(height: 0.5)
        }
    }

    private func tabButton(title: String, systemName: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(isSelected ? Color.blue : Color.secondary)
        }
        .accessibilityLabel(title)
    }

    private var cameraButton: some View {
        Button {
            isShowingCamera = true
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 62, height: 62)
                        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)

                    Image(systemName: "camera.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 22, weight: .bold))
                }
                Text("拍照")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .accessibilityLabel("拍照")
        .accessibilityHint("打开相机拍照扫描")
    }

    @MainActor
    private func analyzeAndSave(image: UIImage) async {
        let cfg = settings.bailianConfig
        if cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alertMessage = "请先在设置里填写百炼 API Key。"
            return
        }
        if cfg.vlModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alertMessage = "请先在设置里填写 VL 模型名称。"
            return
        }

        isAnalyzing = true
        defer { isAnalyzing = false }

        do {
            let item = try await store.analyzeAndAddScan(image: image, config: cfg)
            if item == nil {
                alertMessage = "识别结果：该图片不是作业/试卷，未保存。"
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
            Button("取消") { onDismiss() }
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
            .accessibilityLabel("从相册选择")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Color.black.opacity(0.35))
    }
}

#Preview {
    MainTabView()
}

