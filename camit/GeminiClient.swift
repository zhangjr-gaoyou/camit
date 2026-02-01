import Foundation

/// Client for Google Gemini API (generateContent)
struct GeminiClient {
    func chat(prompt: String, config: GeminiConfig) async throws -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/models/\(config.model):generateContent?key=\(config.apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.apiKey)"
        guard let url = URL(string: urlString) else { throw BailianError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "temperature": 0.7
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BailianError.httpError(statusCode: -1, body: "无效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BailianError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        if let decoded = try? JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data),
           let text = decoded.candidates?.first?.content?.parts?.first?.text,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        throw BailianError.emptyResponse
    }

    func analyzePaper(imageJPEGData: Data, config: GeminiConfig) async throws -> PaperVisionResult {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/models/\(config.vlModel):generateContent?key=\(config.apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.apiKey)"
        guard let url = URL(string: urlString) else { throw BailianError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = paperAnalysisSystemPrompt()
        let userText = "请分析这张图片。"

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": [
                [
                    "parts": [
                        ["text": userText],
                        [
                            "inline_data": [
                                "mime_type": "image/jpeg",
                                "data": imageJPEGData.base64EncodedString()
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": ["temperature": 0.2]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BailianError.httpError(statusCode: -1, body: "无效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BailianError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let decoded = try? JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data),
              let content = decoded.candidates?.first?.content?.parts?.first?.text else {
            throw BailianError.emptyResponse
        }

        let jsonText = extractFirstJSONObject(from: content) ?? content
        guard let jsonData = jsonText.data(using: .utf8),
              let result = try? JSONDecoder().decode(PaperVisionResult.self, from: jsonData) else {
            throw BailianError.invalidResponseJSON
        }
        return result
    }

    func analyzeQuestion(question: String, subject: Subject, config: GeminiConfig) async throws -> QuestionAnalysisResult {
        let prompt = questionAnalysisPrompt(question: question, subject: subject)
        let text = try await chat(prompt: prompt, config: config)
        let jsonText = extractFirstJSONObject(from: text) ?? text
        guard let data = jsonText.data(using: .utf8) else { throw BailianError.invalidResponseJSON }
        return try JSONDecoder().decode(QuestionAnalysisResult.self, from: data)
    }

    private func paperAnalysisSystemPrompt() -> String {
        paperAnalysisSystemPromptText
    }

    private func questionAnalysisPrompt(question: String, subject: Subject) -> String {
        """
        你是一个 \(subject.rawValue) 老师，请针对下面一道题目给出结构化的解析。

        题目：
        \(question)

        要求：
        1. 判断这道题所属的考查板块/题型，例如："选择题"、"填空题"、"解答题"、"阅读理解" 等。
        2. 给出这道题的标准答案（尽量简洁）。
        3. 给出分步、清晰的解析过程，帮助学生理解解题思路。

        严格只返回 JSON（不要加解释、不要代码块），格式如下：
        {
          "section": "选择题 或 解答题 等，若无法判断则为 null",
          "answer": "标准答案",
          "explanation": "详细解析"
        }
        """
    }
}

private struct GeminiGenerateContentResponse: Codable {
    struct Candidate: Codable {
        struct Content: Codable {
            struct Part: Codable {
                let text: String?
            }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?
}
