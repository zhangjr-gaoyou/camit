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

    static func analyzeQuestion(question: String, subject: Subject, provider: LLMProvider, config: any LLMConfigProtocol) async throws -> QuestionAnalysisResult {
        switch provider {
        case .bailian:
            guard let c = config as? BailianConfig else { throw BailianError.invalidBaseURL }
            return try await BailianClient().analyzeQuestion(question: question, subject: subject, config: c)
        case .openai:
            guard let c = config as? OpenAIConfig else { throw BailianError.invalidBaseURL }
            return try await OpenAIClient().analyzeQuestion(question: question, subject: subject, config: c)
        case .gemini:
            guard let c = config as? GeminiConfig else { throw BailianError.invalidBaseURL }
            return try await GeminiClient().analyzeQuestion(question: question, subject: subject, config: c)
        }
    }
}
