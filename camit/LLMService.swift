import Foundation

/// Unified LLM service that routes to Bailian, OpenAI, or Gemini based on provider
enum LLMService {
    /// - Parameter promptSuffix: 重试时追加到系统提示词后的强调说明，首次传 nil
    static func analyzePaper(imageJPEGData: Data, provider: LLMProvider, config: any LLMConfigProtocol, promptSuffix: String? = nil) async throws -> PaperVisionResult {
        switch provider {
        case .bailian:
            guard let c = config as? BailianConfig else { throw BailianError.invalidBaseURL }
            return try await BailianClient().analyzePaper(imageJPEGData: imageJPEGData, config: c, promptSuffix: promptSuffix)
        case .openai:
            guard let c = config as? OpenAIConfig else { throw BailianError.invalidBaseURL }
            return try await OpenAIClient().analyzePaper(imageJPEGData: imageJPEGData, config: c, promptSuffix: promptSuffix)
        case .gemini:
            guard let c = config as? GeminiConfig else { throw BailianError.invalidBaseURL }
            return try await GeminiClient().analyzePaper(imageJPEGData: imageJPEGData, config: c, promptSuffix: promptSuffix)
        }
    }

    static func validatePaperResult(imageJPEGData: Data, itemsSummary: String, provider: LLMProvider, config: any LLMConfigProtocol) async throws -> PaperValidationResult {
        switch provider {
        case .bailian:
            guard let c = config as? BailianConfig else { throw BailianError.invalidBaseURL }
            return try await BailianClient().validatePaperResult(imageJPEGData: imageJPEGData, itemsSummary: itemsSummary, config: c)
        case .openai:
            guard let c = config as? OpenAIConfig else { throw BailianError.invalidBaseURL }
            return try await OpenAIClient().validatePaperResult(imageJPEGData: imageJPEGData, itemsSummary: itemsSummary, config: c)
        case .gemini:
            guard let c = config as? GeminiConfig else { throw BailianError.invalidBaseURL }
            return try await GeminiClient().validatePaperResult(imageJPEGData: imageJPEGData, itemsSummary: itemsSummary, config: c)
        }
    }

    static func analyzeQuestion(question: String, subject: Subject, grade: Grade, provider: LLMProvider, config: any LLMConfigProtocol) async throws -> QuestionAnalysisResult {
        switch provider {
        case .bailian:
            guard let c = config as? BailianConfig else { throw BailianError.invalidBaseURL }
            return try await BailianClient().analyzeQuestion(question: question, subject: subject, grade: grade, config: c)
        case .openai:
            guard let c = config as? OpenAIConfig else { throw BailianError.invalidBaseURL }
            return try await OpenAIClient().analyzeQuestion(question: question, subject: subject, grade: grade, config: c)
        case .gemini:
            guard let c = config as? GeminiConfig else { throw BailianError.invalidBaseURL }
            return try await GeminiClient().analyzeQuestion(question: question, subject: subject, grade: grade, config: c)
        }
    }

    /// 纯文本对话，用于学习报告等非 JSON 场景
    static func chat(prompt: String, provider: LLMProvider, config: any LLMConfigProtocol) async throws -> String {
        switch provider {
        case .bailian:
            guard let c = config as? BailianConfig else { throw BailianError.invalidBaseURL }
            return try await BailianClient().chat(prompt: prompt, config: c)
        case .openai:
            guard let c = config as? OpenAIConfig else { throw BailianError.invalidBaseURL }
            return try await OpenAIClient().chat(prompt: prompt, config: c)
        case .gemini:
            guard let c = config as? GeminiConfig else { throw BailianError.invalidBaseURL }
            return try await GeminiClient().chat(prompt: prompt, config: c)
        }
    }

    /// 使用 "hi" 测试模型连接，成功返回 nil，失败返回错误描述
    static func testConnection(provider: LLMProvider, config: any LLMConfigProtocol) async -> String? {
        do {
            switch provider {
            case .bailian:
                guard let c = config as? BailianConfig else { return L10n.settingsConfigInvalid }
                _ = try await BailianClient().chat(prompt: "hi", config: c)
            case .openai:
                guard let c = config as? OpenAIConfig else { return L10n.settingsConfigInvalid }
                _ = try await OpenAIClient().chat(prompt: "hi", config: c)
            case .gemini:
                guard let c = config as? GeminiConfig else { return L10n.settingsConfigInvalid }
                _ = try await GeminiClient().chat(prompt: "hi", config: c)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
