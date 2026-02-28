import Foundation

/// 单条会话消息（持久化用）
struct ChatMessageRecord: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id: UUID = UUID()
    var role: Role
    var text: String
    var createdAt: Date
    /// 本条消息关联的附件元信息（仅保存必要字段，便于会话历史恢复 UI）
    var attachments: [ChatAttachmentMeta]? = nil
}

/// 附件元信息（持久化用）
struct ChatAttachmentMeta: Codable, Equatable {
    enum Kind: String, Codable {
        case image
        case pdf
        case word
    }

    var kind: Kind
    var title: String
    /// 附件对应的本地文件路径（如 PDF、Word 或 PDF 页图片等），可选
    var filePath: String?
    /// 若为 PDF 文档，对应各页渲染出的图片文件路径列表（用于后续题目抽取等场景）
    var pageImagePaths: [String]? = nil
}

/// 一次完整的学习问答会话
struct ChatSession: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessageRecord]
}

