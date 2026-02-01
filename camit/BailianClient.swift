import Foundation

enum BailianError: LocalizedError {
    case invalidBaseURL
    case httpError(statusCode: Int, body: String)
    case emptyResponse
    case invalidResponseJSON

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Base URL 无效。"
        case let .httpError(statusCode, body):
            return "请求失败（HTTP \(statusCode)）：\(body)"
        case .emptyResponse:
            return "模型未返回有效内容。"
        case .invalidResponseJSON:
            return "模型返回内容无法解析为 JSON。"
        }
    }
}

/// Minimal client for DashScope (Bailian) OpenAI-compatible API.
struct BailianClient {
    func chat(prompt: String, config: BailianConfig) async throws -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base) else { throw BailianError.invalidBaseURL }

        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let body = ChatCompletionsRequest(
            model: config.model,
            messages: [
                .init(role: "user", content: prompt)
            ],
            temperature: 0.7,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BailianError.httpError(statusCode: -1, body: "无效响应")
        }

        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw BailianError.httpError(statusCode: http.statusCode, body: bodyText)
        }

        // Try OpenAI-compatible response first.
        if let decoded = try? JSONDecoder().decode(ChatCompletionsResponse.self, from: data),
           let content = decoded.choices.first?.message.content,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }

        // Fallback: return raw JSON if unexpected shape.
        let raw = String(data: data, encoding: .utf8) ?? ""
        if !raw.isEmpty { return raw }
        throw BailianError.emptyResponse
    }

    /// Use VL model to determine if the image is a paper/homework and extract all questions.
    func analyzePaper(imageJPEGData: Data, config: BailianConfig) async throws -> PaperVisionResult {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base) else { throw BailianError.invalidBaseURL }

        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let b64 = imageJPEGData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(b64)"

        let system = paperAnalysisSystemPromptText
        let userText = "请分析这张图片。"

        let body = VLChatCompletionsRequest(
            model: config.vlModel,
            messages: [
                .init(role: "system", content: .string(system)),
                .init(
                    role: "user",
                    content: .parts([
                        .text(userText),
                        .imageURL(dataURL)
                    ])
                )
            ],
            temperature: 0.2,
            stream: false
        )

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BailianError.httpError(statusCode: -1, body: "无效响应")
        }

        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw BailianError.httpError(statusCode: http.statusCode, body: bodyText)
        }

        guard let decoded = try? JSONDecoder().decode(ChatCompletionsResponse.self, from: data),
              let content = decoded.choices.first?.message.content
        else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw BailianError.httpError(statusCode: http.statusCode, body: raw)
        }

        let jsonText = extractFirstJSONObject(from: content) ?? content
        guard let jsonData = jsonText.data(using: .utf8),
              let result = try? JSONDecoder().decode(PaperVisionResult.self, from: jsonData)
        else {
            throw BailianError.invalidResponseJSON
        }

        return result
    }
}

struct ChatCompletionsRequest: Codable {
    struct Message: Codable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double?
    let stream: Bool?
}

struct ChatCompletionsResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let role: String?
            let content: String
        }
        let index: Int?
        let message: Message
        let finish_reason: String?
    }

    let id: String?
    let choices: [Choice]
}

struct PaperVisionItem: Codable, Equatable {
    let type: String  // 板块分类 / 题干 / 题目
    let content: String
    /// 题目在图片中的边界框（归一化坐标 0-1）：{x, y, width, height}
    let bbox: BBox?
}

struct BBox: Codable, Equatable {
    let x: Double      // 左上角 x（归一化 0-1）
    let y: Double      // 左上角 y（归一化 0-1）
    let width: Double  // 宽度（归一化 0-1）
    let height: Double // 高度（归一化 0-1）
}

struct PaperVisionResult: Codable, Equatable {
    let is_homework_or_exam: Bool
    let title: String
    let subject: String
    let grade: String
    /// 新格式：带类型的项列表（优先使用）
    let items: [PaperVisionItem]?
    /// 旧格式兼容：纯题目字符串列表（视为 type=题目）
    let questions: [String]?
    let score: Int?

    /// 统一为 (type, content, bbox) 列表
    var normalizedItems: [(type: String, content: String, bbox: BBox?)] {
        if let items = items, !items.isEmpty {
            return items.map { ($0.type, $0.content, $0.bbox) }
        }
        return (questions ?? []).map { ("题目", $0, nil) }
    }
}

struct QuestionAnalysisResult: Codable, Equatable {
    let section: String?
    let answer: String
    let explanation: String
}

struct VLChatCompletionsRequest: Codable {
    struct Message: Codable {
        let role: String
        let content: Content
    }

    enum Content: Codable {
        case string(String)
        case parts([ContentPart])

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case let .string(s):
                try c.encode(s)
            case let .parts(p):
                try c.encode(p)
            }
        }
    }

    struct ContentPart: Codable {
        struct ImageURL: Codable {
            let url: String
        }
        let type: String
        let text: String?
        let image_url: ImageURL?

        static func text(_ value: String) -> ContentPart {
            .init(type: "text", text: value, image_url: nil)
        }

        static func imageURL(_ url: String) -> ContentPart {
            .init(type: "image_url", text: nil, image_url: .init(url: url))
        }
    }

    let model: String
    let messages: [Message]
    let temperature: Double?
    let stream: Bool?
}

extension BailianClient {
    /// Analyze a single question using text model: derive section, correct answer, and explanation.
    func analyzeQuestion(
        question: String,
        subject: Subject,
        config: BailianConfig
    ) async throws -> QuestionAnalysisResult {
        let prompt = """
        你是一个 \(subject.rawValue) 老师，请针对下面一道题目给出结构化的解析。

        题目：
        \(question)

        要求：
        1. 判断这道题所属的考查板块/题型，例如：\"选择题\"、\"填空题\"、\"解答题\"、\"阅读理解\" 等。
        2. 给出这道题的标准答案（尽量简洁）。
        3. 给出分步、清晰的解析过程，帮助学生理解解题思路。

        严格只返回 JSON（不要加解释、不要代码块），格式如下：
        {
          "section": "选择题 或 解答题 等，若无法判断则为 null",
          "answer": "标准答案",
          "explanation": "详细解析"
        }
        """

        let text = try await chat(prompt: prompt, config: config)
        let jsonText = extractFirstJSONObject(from: text) ?? text
        guard let data = jsonText.data(using: .utf8) else {
            throw BailianError.invalidResponseJSON
        }
        return try JSONDecoder().decode(QuestionAnalysisResult.self, from: data)
    }
}

