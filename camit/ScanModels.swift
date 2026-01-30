import Foundation

enum Subject: String, CaseIterable, Codable, Equatable {
    case chinese = "语文"
    case math = "数学"
    case english = "英语"
    case geography = "地理"
    case physics = "物理"
    case chemistry = "化学"
    case other = "其他"

    var badgeColorHex: String {
        switch self {
        case .chinese: return "#0984E3"
        case .math: return "#2F6BFF"
        case .english: return "#E17055"
        case .geography: return "#00CEC9"
        case .physics: return "#6C5CE7"
        case .chemistry: return "#00B894"
        case .other: return "#636E72"
        }
    }
}

enum Grade: String, CaseIterable, Codable, Equatable {
    case primary1 = "小一"
    case primary2 = "小二"
    case primary3 = "小三"
    case primary4 = "小四"
    case primary5 = "小五"
    case primary6 = "小六"
    case junior1 = "初一"
    case junior2 = "初二"
    case junior3 = "初三"
    case other = "其他"
}

enum ScoreFilter: String, CaseIterable, Codable, Equatable {
    case all = "分数"
    case lt60 = "< 60"
    case from60to80 = "60-80"
    case from80to90 = "80-90"
    case gte90 = "≥ 90"
}

struct ScanItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date
    var grade: Grade
    var subject: Subject
    /// Local file name in Documents/camit_scans/
    var imageFileName: String?

    /// Extracted questions from the paper/homework image.
    var questions: [PaperQuestion] = []

    /// Whether the image is recognized as homework/exam paper.
    var isHomeworkOrExam: Bool = true

    /// Whether this paper is archived (hidden from main lists).
    var isArchived: Bool = false

    /// Score of this paper, if known.
    var score: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, grade, subject, imageFileName
        case questions, isHomeworkOrExam, score
    }

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date,
        grade: Grade,
        subject: Subject,
        imageFileName: String?,
        questions: [PaperQuestion] = [],
        isHomeworkOrExam: Bool = true,
        isArchived: Bool = false,
        score: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.grade = grade
        self.subject = subject
        self.imageFileName = imageFileName
        self.questions = questions
        self.isHomeworkOrExam = isHomeworkOrExam
        self.isArchived = isArchived
        self.score = score
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        grade = try c.decode(Grade.self, forKey: .grade)
        subject = try c.decode(Subject.self, forKey: .subject)
        imageFileName = try c.decodeIfPresent(String.self, forKey: .imageFileName)
        questions = try c.decodeIfPresent([PaperQuestion].self, forKey: .questions) ?? []
        isHomeworkOrExam = try c.decodeIfPresent(Bool.self, forKey: .isHomeworkOrExam) ?? true
        isArchived = false
        score = try c.decodeIfPresent(Int.self, forKey: .score)
    }
}

/// 识别出的单项类型：板块分类、题干、题目（仅「题目」可生成答案与解析）
struct PaperQuestion: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var index: Int?
    /// 板块分类 / 题干 / 题目
    var kind: String?
    var section: String?
    var text: String
    var answer: String?
    var explanation: String?
    var isWrong: Bool = false

    /// 是否为可作答的「题目」（仅此类显示「生成答案与解析」）
    var isQuestionItem: Bool {
        let k = kind ?? "题目"
        return k == "题目"
    }
}

