import Foundation

/// Supported LLM providers
enum LLMProvider: String, Codable, CaseIterable {
    case bailian = "bailian"
    case openai = "openai"
    case gemini = "gemini"
}

/// Protocol for LLM configs used by paper/question analysis
protocol LLMConfigProtocol {
    var apiKey: String { get }
    var effectiveVLModel: String { get }
    var effectiveTextModel: String { get }
    var displayName: String { get }
}

extension BailianConfig: LLMConfigProtocol {
    var effectiveVLModel: String { vlModel }
    var effectiveTextModel: String { model }
    var displayName: String { "Bailian/Qwen" }
}

struct OpenAIConfig: Codable, Equatable, LLMConfigProtocol {
    var apiKey: String = ""
    var model: String = "gpt-4o-mini"
    var vlModel: String = "gpt-4o-mini"
    var baseURL: String = "https://api.openai.com/v1"

    var effectiveVLModel: String { vlModel }
    var effectiveTextModel: String { model }
    var displayName: String { "OpenAI" }

    static func configFileURL() throws -> URL {
        try BailianConfig.configFileURL().deletingLastPathComponent().appendingPathComponent("openai_config.json")
    }

    static func load() throws -> OpenAIConfig {
        let url = try configFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return OpenAIConfig() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(OpenAIConfig.self, from: data)
    }

    func save() throws {
        let url = try Self.configFileURL()
        try JSONEncoder().encode(self).write(to: url, options: [.atomic])
    }
}

struct GeminiConfig: Codable, Equatable, LLMConfigProtocol {
    var apiKey: String = ""
    var model: String = "gemini-2.5-flash"
    var vlModel: String = "gemini-2.5-flash"
    var baseURL: String = "https://generativelanguage.googleapis.com/v1"

    var effectiveVLModel: String { vlModel }
    var effectiveTextModel: String { model }
    var displayName: String { "Google Gemini" }

    static func configFileURL() throws -> URL {
        try BailianConfig.configFileURL().deletingLastPathComponent().appendingPathComponent("gemini_config.json")
    }

    static func load() throws -> GeminiConfig {
        let url = try configFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return GeminiConfig() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GeminiConfig.self, from: data)
    }

    func save() throws {
        let url = try Self.configFileURL()
        try JSONEncoder().encode(self).write(to: url, options: [.atomic])
    }
}
