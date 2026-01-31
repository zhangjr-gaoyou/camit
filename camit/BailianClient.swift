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

        let system = """
        你是一个 OCR + 文档理解助手。你的任务：
        1) 判断图片是否为“作业/试卷”（包含题目、题干、编号等）。
        2) 如果是，按顺序抽取内容，并对每一项标注类型：
           - "板块分类"：如“一、选择题”“二、填空题”、大题板块名等；
           - "题干"：阅读材料、共用题干、不包含选项的提问句等。例如选择题中“下列……一项是（ ）”“下列……最恰当的一项是（ ）”这类只有问句、没有 A/B/C/D 选项的部分，必须标为题干；
           - "题目"：需要单独作答的一道小题，包含选项时则整道题（含 A/B/C/D 选项）为一条题目。
        3) 填空题中的下划线“_”或“____”表示需要填空的位置，必须在 content 中明确保留并标识。做法：原样保留下划线，或在填空处用【填空】_____【/填空】标出，以便前端明显区分填空位。
        4) 如果图片中能看出总分或得分，请给出 0-100 的整数分数；无法确定则 null。

        题干与题目的正确示例（必须按此规则识别）：
        - 题干：下列词语中加点字的读音，字形完全正确的一项是（ ）
        - 题目：A. 倒闭（tuì） 嘲言（bō） 悄然（qiǎo） 前仆后继（pū）\\nB. 阎阿（xiā） 誓约（shà） 欣慰（wèi） 潜滋暗长（qián）\\nC. 忌讳（huì） 云霄（xiāo） 推崇（cóng） 无精打采（cǎi）\\nD. 惨境（cháng） 优哉（qí） 显印（kēn） 闭户拒盗（sù）
        即：问句单独一条 type=题干；A/B/C/D 选项整体为一条 type=题目。

        你必须只返回 JSON（不要 Markdown、不要代码块），格式严格如下：
        {
          "is_homework_or_exam": true/false,
          "title": "试卷或作业标题（若无法判断可为空字符串）",
          "subject": "科目（如 语文/数学/英语/地理/物理/化学/其他）",
          "grade": "年级（如 小一/小二/小三/小四/小五/小六/初一/初二/初三/其他）",
          "items": [ 
            {"type": "板块分类", "content": "一、选择题", "bbox": {"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.05}},
            {"type": "题干", "content": "下列...一项是（ ）", "bbox": {"x": 0.1, "y": 0.25, "width": 0.8, "height": 0.08}},
            {"type": "题目", "content": "A. ...\\\\nB. ...\\\\nC. ...\\\\nD. ...", "bbox": {"x": 0.1, "y": 0.33, "width": 0.8, "height": 0.15}}
          ],
          "score": 86 或 null
        }
        type 只能是 "板块分类"、"题干"、"题目" 之一。
        bbox 为该项在图片中的边界框，坐标为归一化值（0-1）：x/y 为左上角相对位置，width/height 为相对宽高。如果无法确定位置可省略 bbox。
        """

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

private struct ChatCompletionsRequest: Codable {
    struct Message: Codable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double?
    let stream: Bool?
}

private struct ChatCompletionsResponse: Codable {
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

private struct VLChatCompletionsRequest: Codable {
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

private func extractFirstJSONObject(from text: String) -> String? {
    // Remove common code fences
    let cleaned = text
        .replacingOccurrences(of: "```json", with: "```")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let start = cleaned.firstIndex(of: "{") else { return nil }
    var depth = 0
    var inString = false
    var prev: Character? = nil

    for i in cleaned.indices[start...] {
        let ch = cleaned[i]
        if ch == "\"" && prev != "\\" {
            inString.toggle()
        }
        if !inString {
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(cleaned[start...i])
                }
            }
        }
        prev = ch
    }
    return nil
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

