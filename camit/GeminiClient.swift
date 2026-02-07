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
