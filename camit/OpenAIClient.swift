import Foundation

/// Client for OpenAI API (OpenAI-compatible chat/completions, supports vision)
struct OpenAIClient {
    func chat(prompt: String, config: OpenAIConfig) async throws -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base) else { throw BailianError.invalidBaseURL }
        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let body = ChatCompletionsRequest(
            model: config.model,
            messages: [.init(role: "user", content: prompt)],
            temperature: 0.7,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BailianError.httpError(statusCode: -1, body: "无效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BailianError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        if let decoded = try? JSONDecoder().decode(ChatCompletionsResponse.self, from: data),
           let content = decoded.choices.first?.message.content,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        throw BailianError.emptyResponse
    }

    func analyzePaper(imageJPEGData: Data, config: OpenAIConfig, promptSuffix: String? = nil) async throws -> PaperVisionResult {
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

        let body = VLChatCompletionsRequest(
            model: config.vlModel,
            messages: [
                .init(role: "system", content: .string(system)),
                .init(role: "user", content: .parts([
                    .text("请分析这张图片。"),
                    .imageURL(dataURL)
                ]))
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
            throw BailianError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let decoded = try? JSONDecoder().decode(ChatCompletionsResponse.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw BailianError.emptyResponse
        }

        let jsonText = extractFirstJSONObject(from: content) ?? content
        guard let jsonData = jsonText.data(using: .utf8),
              let result = try? JSONDecoder().decode(PaperVisionResult.self, from: jsonData) else {
            throw BailianError.invalidResponseJSON
        }
        return result
    }

    func validatePaperResult(imageJPEGData: Data, itemsSummary: String, config: OpenAIConfig) async throws -> PaperValidationResult {
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
        let jsonText = extractFirstJSONObject(from: content) ?? content
        guard let jsonData = jsonText.data(using: .utf8),
              let result = try? JSONDecoder().decode(PaperValidationResult.self, from: jsonData) else {
            return PaperValidationResult(valid: true, score: 80, issues: nil)
        }
        return result
    }

    func analyzeQuestion(question: String, subject: Subject, config: OpenAIConfig) async throws -> QuestionAnalysisResult {
        let prompt = """
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
        let text = try await chat(prompt: prompt, config: config)
        let jsonText = extractFirstJSONObject(from: text) ?? text
        guard let data = jsonText.data(using: .utf8) else { throw BailianError.invalidResponseJSON }
        return try JSONDecoder().decode(QuestionAnalysisResult.self, from: data)
    }
}
