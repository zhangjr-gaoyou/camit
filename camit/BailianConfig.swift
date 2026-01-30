import Foundation

struct BailianConfig: Codable, Equatable {
    var apiKey: String = ""
    var model: String = "qwen-plus"
    /// Vision-language model (e.g. qwen-vl-plus).
    var vlModel: String = "qwen-vl-plus"
    /// DashScope OpenAI-compatible base URL by default.
    var baseURL: String = "https://dashscope.aliyuncs.com/compatible-mode/v1"

    enum CodingKeys: String, CodingKey {
        case apiKey
        case model
        case vlModel
        case baseURL
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "qwen-plus"
        vlModel = try container.decodeIfPresent(String.self, forKey: .vlModel) ?? "qwen-vl-plus"
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://dashscope.aliyuncs.com/compatible-mode/v1"
    }

    static func configFileURL() throws -> URL {
        let fm = FileManager.default

        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let dir = appSupport.appendingPathComponent("camit", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return dir.appendingPathComponent("bailian_config.json", isDirectory: false)
    }

    static func load() throws -> BailianConfig {
        let url = try configFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return BailianConfig()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BailianConfig.self, from: data)
    }

    func save() throws {
        let url = try Self.configFileURL()
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: [.atomic])
    }
}

