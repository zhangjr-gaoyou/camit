import Foundation
@preconcurrency import Combine

@MainActor
final class AppSettings: ObservableObject {
    @Published var provider: LLMProvider = .bailian
    @Published var bailianConfig: BailianConfig
    @Published var openAIConfig: OpenAIConfig
    @Published var geminiConfig: GeminiConfig

    init() {
        self.bailianConfig = (try? BailianConfig.load()) ?? BailianConfig()
        self.openAIConfig = (try? OpenAIConfig.load()) ?? OpenAIConfig()
        self.geminiConfig = (try? GeminiConfig.load()) ?? GeminiConfig()
        if let raw = UserDefaults.standard.string(forKey: "camit_llm_provider"),
           let p = LLMProvider(rawValue: raw) {
            self.provider = p
        } else {
            // 默认：中文语言用 Bailian/Qwen，英文用 OpenAI
            let preferred = Locale.preferredLanguages.first ?? ""
            self.provider = preferred.hasPrefix("zh") ? .bailian : .openai
        }
    }

    func save() throws {
        try bailianConfig.save()
        try openAIConfig.save()
        try geminiConfig.save()
        UserDefaults.standard.set(provider.rawValue, forKey: "camit_llm_provider")
    }

    func effectiveConfig() -> (any LLMConfigProtocol)? {
        switch provider {
        case .bailian: return bailianConfig
        case .openai: return openAIConfig
        case .gemini: return geminiConfig
        }
    }
}

