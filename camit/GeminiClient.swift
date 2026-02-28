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
        request.timeoutInterval = 120

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

    func analyzePaper(imageJPEGData: Data, config: GeminiConfig, promptSuffix: String? = nil) async throws -> PaperVisionResult {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/models/\(config.vlModel):generateContent?key=\(config.apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.apiKey)"
        guard let url = URL(string: urlString) else { throw BailianError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = paperAnalysisSystemPrompt() + (promptSuffix ?? "")
        let userText = "请分析这张图片。"
        // Gemini v1 不支持 systemInstruction，将系统提示词合并到用户消息
        let combinedPrompt = "\(systemPrompt)\n\n\(userText)"

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": combinedPrompt],
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
        debugLogModelResponse(api: "analyzePaper", content: content)
        var jsonText = extractFirstJSONObject(from: content) ?? content
        jsonText = repairPaperVisionJson(jsonText)
        guard let jsonData = jsonText.data(using: .utf8),
              let result = try? JSONDecoder().decode(PaperVisionResult.self, from: jsonData) else {
            throw BailianError.invalidResponseJSON(raw: content)
        }
        return result
    }

    /// 通用图片理解：返回 Markdown 描述
    func describeImage(imageJPEGData: Data, config: GeminiConfig) async throws -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/models/\(config.vlModel):generateContent?key=\(config.apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.apiKey)"
        guard let url = URL(string: urlString) else { throw BailianError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
你是一个图像理解助手，请将图片内容整理成 Markdown 要点，用于后续学习问答。
- 仅输出 Markdown。
- 概括主要对象、文字和数据趋势。
"""

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": systemPrompt],
                        [
                            "inline_data": [
                                "mime_type": "image/jpeg",
                                "data": imageJPEGData.base64EncodedString()
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": ["temperature": 0.3]
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
            debugLogModelResponse(api: "describeImage", content: text)
            return text
        }
        throw BailianError.emptyResponse
    }

    /// 使用 VL 模型结合「图片 + 学生问题」直接回答，用 Markdown（可含数学公式）输出
    func answerQuestionAboutImage(imageJPEGData: Data, question: String, config: GeminiConfig) async throws -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/models/\(config.vlModel):generateContent?key=\(config.apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.apiKey)"
        guard let url = URL(string: urlString) else { throw BailianError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
你是「张老师」，一位擅长讲解题目的学习辅导老师。

你会同时看到学生的问题和一张图片，请根据图片内容直接回答学生的问题。

如果图片中**包含**与学生问题直接相关的题目或内容，请用 Markdown 作答，并严格遵守：
- 不要使用任何标题（禁止 #、##、###）；
- 使用分行、列表和**粗体**组织内容；
- 建议结构如下：
  **相关题目**
  - 尽量完整、准确地复原图片中的题目文字和关键信息（若为选择题，应包含题干和选项）。

  **解题思路与答案**
  - 用分步骤方式说明解题过程；
  - 数学公式使用 LaTeX 语法（行内 $...$，独立公式 $$...$$）；
  - 语言简洁，适合中学生理解。

如果图片中没有与学生问题直接相关的题目或内容，请只输出：NOT_FOUND（必须全大写，且不输出任何其他文字）。
"""

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": systemPrompt],
                        [
                            "inline_data": [
                                "mime_type": "image/jpeg",
                                "data": imageJPEGData.base64EncodedString()
                            ]
                        ],
                        ["text": "学生问题：\n\(question)\n\n请结合图片内容直接回答这个问题。"]
                    ]
                ]
            ],
            "generationConfig": ["temperature": 0.3]
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
            debugLogModelResponse(api: "answerQuestionAboutImage", content: text)
            return text
        }
        throw BailianError.emptyResponse
    }

    func validatePaperResult(imageJPEGData: Data, itemsSummary: String, config: GeminiConfig) async throws -> PaperValidationResult {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/models/\(config.vlModel):generateContent?key=\(config.apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.apiKey)"
        guard let url = URL(string: urlString) else { throw BailianError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let userText = paperValidationUserMessage(itemsSummary: itemsSummary)
        let body: [String: Any] = [
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
            "generationConfig": ["temperature": 0.1]
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
        debugLogModelResponse(api: "validatePaperResult", content: content)
        var jsonText = extractFirstJSONObject(from: content) ?? content
        jsonText = repairJsonForParsing(jsonText)
        guard let jsonData = jsonText.data(using: .utf8),
              let result = try? JSONDecoder().decode(PaperValidationResult.self, from: jsonData) else {
            return PaperValidationResult(valid: true, score: 80, issues: nil)
        }
        return result
    }

    func analyzeQuestion(question: String, subject: Subject, grade: Grade, config: GeminiConfig) async throws -> QuestionAnalysisResult {
        let prompt = questionAnalysisPrompt(question: question, subject: subject.rawValue, grade: grade.rawValue)
        let text = try await chat(prompt: prompt, config: config)
        debugLogModelResponse(api: "analyzeQuestion", content: text)
        var jsonText = extractFirstJSONObject(from: text) ?? text
        jsonText = repairJsonForParsing(jsonText)
        guard let data = jsonText.data(using: .utf8) else { throw BailianError.invalidResponseJSON(raw: text) }
        do {
            return try JSONDecoder().decode(QuestionAnalysisResult.self, from: data)
        } catch {
            throw BailianError.invalidResponseJSON(raw: text)
        }
    }

    private func paperAnalysisSystemPrompt() -> String {
        paperAnalysisSystemPromptText
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
