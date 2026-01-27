import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings

    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var baseURL: String = ""
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("百炼配置") {
                    SecureField("API Key", text: $apiKey)
                        .modifier(PlatformTextContentTypePassword())

                    TextField("模型（例如：qwen-plus）", text: $model)
                        .modifier(PlatformTextInputTraits())

                    TextField("Base URL", text: $baseURL)
                        .modifier(PlatformTextInputTraits())
                }

                Section {
                    Button("保存") { save() }
                        .buttonStyle(.borderedProminent)
                }

                Section {
                    Text("配置会保存到应用支持目录下的 `bailian_config.json`。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar {
#if os(macOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
#else
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
#endif
            }
            .onAppear {
                apiKey = settings.bailianConfig.apiKey
                model = settings.bailianConfig.model
                baseURL = settings.bailianConfig.baseURL
            }
            .alert("提示", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    private func save() {
        settings.bailianConfig.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.bailianConfig.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.bailianConfig.baseURL = trimmedBaseURL.isEmpty ? BailianConfig().baseURL : trimmedBaseURL

        do {
            try settings.save()
            dismiss()
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

#if os(macOS)
private struct PlatformTextInputTraits: ViewModifier {
    func body(content: Content) -> some View { content }
}

private struct PlatformTextContentTypePassword: ViewModifier {
    func body(content: Content) -> some View { content }
}
#else
private struct PlatformTextInputTraits: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

private struct PlatformTextContentTypePassword: ViewModifier {
    func body(content: Content) -> some View {
        content.textContentType(.password)
    }
}
#endif

#Preview {
    SettingsView(settings: AppSettings())
}

