import Foundation

/// Unified LLM service that routes to Bailian, OpenAI, or Gemini based on provider
enum LLMService {
    static func analyzePaper(imageJPEGData: Data, provider: LLMProvider, config: any LLMConfigProtocol) async throws -> PaperVisionResult {
        switch provider {
        case .bailian:
            guard let c = config as? BailianConfig else { throw BailianError.invalidBaseURL }
            return try await BailianClient().analyzePaper(imageJPEGData: imageJPEGData, config: c)
        case .openai:
            guard let c = config as? OpenAIConfig else { throw BailianError.invalidBaseURL }
            return try await OpenAIClient().analyzePaper(imageJPEGData: imageJPEGData, config: c)
        case .gemini:
            guard let c = config as? GeminiConfig else { throw BailianError.invalidBaseURL }
            return try await GeminiClient().analyzePaper(imageJPEGData: imageJPEGData, config: c)
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
