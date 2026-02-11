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
        debugLogModelResponse(api: "analyzePaper", content: content)
        var jsonText = extractFirstJSONObject(from: content) ?? content
        jsonText = repairPaperVisionJson(jsonText)
        guard let jsonData = jsonText.data(using: .utf8) else {
            throw BailianError.invalidResponseJSON(raw: content)
        }
        do {
            return try JSONDecoder().decode(PaperVisionResult.self, from: jsonData)
        } catch {
            print("[camit:model] analyzePaper decode error: \(error)")
            print("[camit:model] analyzePaper repaired JSON text:\n\(jsonText)")
            let fallbackText = repairJsonForParsing(jsonText)
            if let data2 = fallbackText.data(using: .utf8),
               let result2 = try? JSONDecoder().decode(PaperVisionResult.self, from: data2) {
                return result2
            }
            throw BailianError.invalidResponseJSON(raw: content)
        }
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
        debugLogModelResponse(api: "validatePaperResult", content: content)
        var jsonText = extractFirstJSONObject(from: content) ?? content
        jsonText = repairJsonForParsing(jsonText)
        guard let jsonData = jsonText.data(using: .utf8),
              let result = try? JSONDecoder().decode(PaperValidationResult.self, from: jsonData) else {
            return PaperValidationResult(valid: true, score: 80, issues: nil)
        }
        return result
    }

    func analyzeQuestion(question: String, subject: Subject, grade: Grade, config: OpenAIConfig) async throws -> QuestionAnalysisResult {
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
}
