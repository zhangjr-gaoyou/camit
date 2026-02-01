import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings

    @State private var bailianApiKey: String = ""
    @State private var bailianModel: String = ""
    @State private var bailianVLModel: String = ""
    @State private var bailianBaseURL: String = ""

    @State private var openAIApiKey: String = ""
    @State private var openAIModel: String = ""
    @State private var openAIVLModel: String = ""
    @State private var openAIBaseURL: String = ""

    @State private var geminiApiKey: String = ""
    @State private var geminiModel: String = ""
    @State private var geminiVLModel: String = ""
    @State private var alertMessage: String?
    @State private var showHelpSheet: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(L10n.settingsProviderLabel)
                        Spacer()
                        Button {
                            showHelpSheet = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.title3)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.settingsHelpTitle)
                    }
                    Picker(L10n.settingsProviderPicker, selection: $settings.provider) {
                        Text("Bailian / Qwen").tag(LLMProvider.bailian)
                        Text("OpenAI").tag(LLMProvider.openai)
                        Text("Google Gemini").tag(LLMProvider.gemini)
                    }
                    .pickerStyle(.menu)
                }

                providerConfigSection

                Section {
                    Button(L10n.settingsSave) { save() }
                        .buttonStyle(.borderedProminent)
                }

                Section {
                    Text(L10n.settingsConfigFooter)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.settingsTitle)
            .toolbar {
#if os(macOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.settingsClose) { dismiss() }
                }
#else
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.settingsClose) { dismiss() }
                }
#endif
            }
            .onAppear {
                bailianApiKey = settings.bailianConfig.apiKey
                bailianModel = settings.bailianConfig.model
                bailianVLModel = settings.bailianConfig.vlModel
                bailianBaseURL = settings.bailianConfig.baseURL
                openAIApiKey = settings.openAIConfig.apiKey
                openAIModel = settings.openAIConfig.model
                openAIVLModel = settings.openAIConfig.vlModel
                openAIBaseURL = settings.openAIConfig.baseURL
                geminiApiKey = settings.geminiConfig.apiKey
                geminiModel = settings.geminiConfig.model
                geminiVLModel = settings.geminiConfig.vlModel
            }
            .alert(L10n.alertTitle, isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button(L10n.alertOK, role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .sheet(isPresented: $showHelpSheet) {
                SettingsHelpView()
            }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
#endif
    }

    @ViewBuilder
    private var providerConfigSection: some View {
        switch settings.provider {
        case .bailian:
            Section(L10n.settingsBailianSection) {
                labeledField(L10n.settingsLabelApiKey) {
                    SecureField("", text: $bailianApiKey)
                        .modifier(PlatformTextContentTypePassword())
                }
                labeledField(L10n.settingsLabelModel) {
                    TextField("", text: $bailianModel)
                        .modifier(PlatformTextInputTraits())
                }
                labeledField(L10n.settingsLabelVLModel) {
                    TextField("", text: $bailianVLModel)
                        .modifier(PlatformTextInputTraits())
                }
                labeledField(L10n.settingsLabelBaseURL) {
                    TextField("", text: $bailianBaseURL)
                        .modifier(PlatformTextInputTraits())
                }
            }
        case .openai:
            Section(L10n.settingsOpenAISection) {
                labeledField(L10n.settingsLabelApiKey) {
                    SecureField("", text: $openAIApiKey)
                        .modifier(PlatformTextContentTypePassword())
                }
                labeledField(L10n.settingsLabelOpenAIModel) {
                    TextField("", text: $openAIModel)
                        .modifier(PlatformTextInputTraits())
                }
                labeledField(L10n.settingsLabelVLModel) {
                    TextField("", text: $openAIVLModel)
                        .modifier(PlatformTextInputTraits())
                }
                labeledField(L10n.settingsLabelBaseURL) {
                    TextField("", text: $openAIBaseURL)
                        .modifier(PlatformTextInputTraits())
                }
            }
        case .gemini:
            Section(L10n.settingsGeminiSection) {
                labeledField(L10n.settingsLabelApiKey) {
                    SecureField("", text: $geminiApiKey)
                        .modifier(PlatformTextContentTypePassword())
                }
                labeledField(L10n.settingsLabelGeminiModel) {
                    TextField("", text: $geminiModel)
                        .modifier(PlatformTextInputTraits())
                }
                labeledField(L10n.settingsLabelVLModel) {
                    TextField("", text: $geminiVLModel)
                        .modifier(PlatformTextInputTraits())
                }
            }
        }
    }

    @ViewBuilder
    private func labeledField<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        settings.bailianConfig.apiKey = bailianApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.bailianConfig.model = bailianModel.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.bailianConfig.vlModel = bailianVLModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let bURL = bailianBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.bailianConfig.baseURL = bURL.isEmpty ? BailianConfig().baseURL : bURL

        settings.openAIConfig.apiKey = openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.openAIConfig.model = openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.openAIConfig.vlModel = openAIVLModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let oURL = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.openAIConfig.baseURL = oURL.isEmpty ? OpenAIConfig().baseURL : oURL

        settings.geminiConfig.apiKey = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.geminiConfig.model = geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.geminiConfig.vlModel = geminiVLModel.trimmingCharacters(in: .whitespacesAndNewlines)

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
