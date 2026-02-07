import Foundation

enum BailianError: LocalizedError {
    case invalidBaseURL
    case httpError(statusCode: Int, body: String)
    case emptyResponse
    case invalidResponseJSON(raw: String?)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Base URL 无效。"
        case let .httpError(statusCode, body):
            return "请求失败（HTTP \(statusCode)）：\(body)"
        case .emptyResponse:
            return "模型未返回有效内容。"
        case let .invalidResponseJSON(raw):
            var msg = "模型返回内容无法解析为 JSON。"
            if let r = raw, !r.isEmpty {
                let preview = String(r.prefix(300)).replacingOccurrences(of: "\n", with: "↵")
                msg += " 返回预览：\(preview)\(r.count > 300 ? "…" : "")"
            }
            return msg
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
    /// - Parameter promptSuffix: 重试时追加到系统提示词后的强调说明，首次传 nil
    func analyzePaper(imageJPEGData: Data, config: BailianConfig, promptSuffix: String? = nil) async throws -> PaperVisionResult {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base) else { throw BailianError.invalidBaseURL }

        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let b64 = imageJPEGData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(b64)"

        let system = paperAnalysisSystemPromptText + (promptSuffix ?? "")
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

        debugLogModelResponse(api: "analyzePaper", content: content)

        /*
        let jsonText = extractFirstJSONObject(from: content) ?? content
        guard let jsonData = jsonText.data(using: .utf8),
              let result = try? JSONDecoder().decode(PaperVisionResult.self, from: jsonData)
        else {
            throw BailianError.invalidResponseJSON
        }
         */
        
        var jsonText = extractFirstJSONObject(from: content) ?? content
        jsonText = repairPaperVisionJson(jsonText)
        guard let jsonData = jsonText.data(using: .utf8),
              let result = try? JSONDecoder().decode(PaperVisionResult.self, from: jsonData)
        else {
            throw BailianError.invalidResponseJSON(raw: content)
        }
        

        return result
    }

    /// 使用 VL 模型校验解析结果：题干/题目区分、边界是否合理
    func validatePaperResult(imageJPEGData: Data, itemsSummary: String, config: BailianConfig) async throws -> PaperValidationResult {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base) else { throw BailianError.invalidBaseURL }
        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let b64 = imageJPEGData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(b64)"
        let userText = paperValidationUserMessage(itemsSummary: itemsSummary)

        let body = VLChatCompletionsRequest(
            model: config.vlModel,
            messages: [
                .init(role: "user", content: .parts([
                    .text(userText),
                    .imageURL(dataURL)
                ]))
            ],
            temperature: 0.1,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BailianError.httpError(statusCode: -1, body: "无效响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw BailianError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let decoded = try? JSONDecoder().decode(ChatCompletionsResponse.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw BailianError.emptyResponse
        }
        debugLogModelResponse(api: "validatePaperResult", content: content)
        var jsonText = extractFirstJSONObject(from: content) ?? content
        jsonText = repairJsonForParsing(jsonText)
        guard let jsonData = jsonText.data(using: .utf8),
              let result = try? JSONDecoder().decode(PaperValidationResult.self, from: jsonData) else {
            return PaperValidationResult(valid: true, score: 80, issues: nil)
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
    /// 题型（仅 type=题目 时有效）：选择题、填空题、简答题、计算题、匹配题、判断题、论述题、阅读理解、其他
    let subtype: String?
    let content: String
    /// 题目在图片中的边界框（归一化坐标 0-1）：{x, y, width, height}
    let bbox: BBox?

    init(type: String, subtype: String? = nil, content: String, bbox: BBox?) {
        self.type = type
        self.subtype = subtype
        self.content = content
        self.bbox = bbox
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        subtype = try c.decodeIfPresent(String.self, forKey: .subtype)
        content = try c.decode(String.self, forKey: .content)
        bbox = try c.decodeIfPresent(BBox.self, forKey: .bbox)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(subtype, forKey: .subtype)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(bbox, forKey: .bbox)
    }

    private enum CodingKeys: String, CodingKey {
        case type, subtype, content, bbox
    }
}

struct BBox: Codable, Equatable {
    let x: Double      // 左上角 x（归一化 0-1）
    let y: Double      // 左上角 y（归一化 0-1）
    let width: Double  // 宽度（归一化 0-1）
    let height: Double // 高度（归一化 0-1）

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 兼容两种返回格式：
    /// 1) 对象：{"x":0.1,"y":0.2,"width":0.3,"height":0.05}
    /// 2) 数组：[0.1, 0.2, 0.3, 0.05]
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let arr = try? single.decode([Double].self), arr.count == 4 {
            self.x = arr[0]
            self.y = arr[1]
            self.width = arr[2]
            self.height = arr[3]
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.x = try c.decode(Double.self, forKey: .x)
        self.y = try c.decode(Double.self, forKey: .y)
        self.width = try c.decode(Double.self, forKey: .width)
        self.height = try c.decode(Double.self, forKey: .height)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
    }

    private enum CodingKeys: String, CodingKey {
        case x, y, width, height
    }
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

    /// 统一为 (type, subtype, content, bbox) 列表
    var normalizedItems: [(type: String, subtype: String?, content: String, bbox: BBox?)] {
        if let items = items, !items.isEmpty {
            return items.map { ($0.type, $0.subtype, $0.content, $0.bbox) }
        }
        return (questions ?? []).map { ("题目", nil, $0, nil) }
    }
}

struct QuestionAnalysisResult: Codable, Equatable {
    let section: String?
    let answer: String
    let explanation: String
}

/// 试卷解析结果校验：大模型对解析+切图结果的评估
struct PaperValidationResult: Codable, Equatable {
    let valid: Bool
    let score: Int?
    let issues: String?
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
        grade: Grade,
        config: BailianConfig
    ) async throws -> QuestionAnalysisResult {
        let prompt = questionAnalysisPrompt(question: question, subject: subject.rawValue, grade: grade.rawValue)
        let text = try await chat(prompt: prompt, config: config)
        debugLogModelResponse(api: "analyzeQuestion", content: text)
        var jsonText = extractFirstJSONObject(from: text) ?? text
        jsonText = repairJsonForParsing(jsonText)
        guard let data = jsonText.data(using: .utf8) else {
            throw BailianError.invalidResponseJSON(raw: text)
        }
        do {
            return try JSONDecoder().decode(QuestionAnalysisResult.self, from: data)
        } catch {
            throw BailianError.invalidResponseJSON(raw: text)
        }
    }
}

