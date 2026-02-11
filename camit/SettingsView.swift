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
    @State private var geminiBaseURL: String = ""
    @State private var alertMessage: String?
    @State private var showHelpSheet: Bool = false
    @State private var connectionTestMessage: String?
    @State private var connectionTestLoading: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    providerSection
                    providerConfigSection
                    connectionTestResult
                    saveAndTestButtons
                    privacyNotice
                }
                .padding(16)
            }
            .background(AppTheme.pageBackground)
            .navigationTitle(L10n.settingsTitle)
            .toolbar {
#if os(macOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.settingsClose) { dismiss() }
                        .foregroundStyle(AppTheme.accentBlue)
                }
#else
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.settingsClose) { dismiss() }
                        .foregroundStyle(AppTheme.accentBlue)
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
                geminiBaseURL = settings.geminiConfig.baseURL
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

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.settingsProviderLabel)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Button {
                    showHelpSheet = true
                } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.accentBlue)
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
        .padding(16)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var providerConfigSection: some View {
        Group {
            switch settings.provider {
            case .bailian:
                configPanel(title: L10n.settingsBailianSection) {
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
                configPanel(title: L10n.settingsOpenAISection) {
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
                configPanel(title: L10n.settingsGeminiSection) {
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
                    labeledField(L10n.settingsLabelBaseURL) {
                        TextField("", text: $geminiBaseURL)
                            .modifier(PlatformTextInputTraits())
                    }
                }
            }
        }
    }

    private func configPanel<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)

            VStack(alignment: .leading, spacing: 16) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var connectionTestResult: some View {
        if let msg = connectionTestMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: msg.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(msg.isEmpty ? AppTheme.accentGreen : .orange)
                Text(msg.isEmpty ? L10n.settingsConnectionOK : (L10n.settingsConnectionError + msg))
                    .font(.subheadline)
                    .foregroundStyle(msg.isEmpty ? AppTheme.accentGreen : .orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background((msg.isEmpty ? AppTheme.accentGreen : Color.orange).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
        }
    }

    private var saveAndTestButtons: some View {
        HStack(spacing: 12) {
            Button(L10n.settingsSave) { save() }
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.accentBlue)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
                .disabled(connectionTestLoading)

            Button {
                testConnection()
            } label: {
                if connectionTestLoading {
                    ProgressView()
                        .scaleEffect(0.9)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                } else {
                    Text(L10n.settingsTestConnection)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.accentBlue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
            .disabled(connectionTestLoading)
        }
    }

    private var privacyNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.title3)
                .foregroundStyle(AppTheme.accentBlue.opacity(0.8))
            Text(L10n.settingsConfigFooter)
                .font(.footnote)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
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

    private func currentConfig() -> any LLMConfigProtocol {
        switch settings.provider {
        case .bailian:
            var c = BailianConfig()
            c.apiKey = bailianApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            c.model = bailianModel.trimmingCharacters(in: .whitespacesAndNewlines)
            c.vlModel = bailianVLModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let bURL = bailianBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            c.baseURL = bURL.isEmpty ? BailianConfig().baseURL : bURL
            return c
        case .openai:
            var c = OpenAIConfig()
            c.apiKey = openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            c.model = openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            c.vlModel = openAIVLModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let oURL = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            c.baseURL = oURL.isEmpty ? OpenAIConfig().baseURL : oURL
            return c
        case .gemini:
            var c = GeminiConfig()
            c.apiKey = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            c.model = geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            c.vlModel = geminiVLModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let gURL = geminiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            c.baseURL = gURL.isEmpty ? GeminiConfig().baseURL : gURL
            return c
        }
    }

    private func testConnection() {
        connectionTestMessage = nil
        connectionTestLoading = true
        Task {
            let config = currentConfig()
            let errorMsg = await LLMService.testConnection(provider: settings.provider, config: config)
            await MainActor.run {
                connectionTestLoading = false
                connectionTestMessage = errorMsg ?? ""
            }
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
        let gURL = geminiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.geminiConfig.baseURL = gURL.isEmpty ? GeminiConfig().baseURL : gURL

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
