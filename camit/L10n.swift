import Foundation
import SwiftUI

/// Localized strings (zh-Hans / en), follows system language
enum L10n {
    private static var isChinese: Bool {
        let preferred = Locale.preferredLanguages.first ?? ""
        return preferred.hasPrefix("zh")
    }

    // MARK: - Settings
    static var settingsTitle: String { isChinese ? "设置" : "Settings" }
    static var settingsClose: String { isChinese ? "关闭" : "Close" }
    static var settingsSave: String { isChinese ? "保存" : "Save" }
    static var settingsApiKeyRequired: String { isChinese ? "请先在设置里填写 API Key。" : "Please configure API Key in Settings first." }
    static var settingsVLModelRequired: String { isChinese ? "请先在设置里填写 VL 模型名称。" : "Please configure VL model name in Settings first." }
    static var settingsConfigRequiredForCamera: String { isChinese ? "请先在设置中配置当前服务的 API Key 及 VL 模型后再拍照。" : "Please configure API Key and VL model for the current provider in Settings before taking a photo." }
    static var settingsConfigFooter: String { isChinese ? "配置会保存到应用支持目录下。" : "Config is saved to application support directory." }

    static var settingsProviderLabel: String { isChinese ? "大模型服务" : "LLM Provider" }
    static var settingsProviderPicker: String { isChinese ? "选择服务" : "Select provider" }
    static var settingsBailianSection: String { isChinese ? "百炼 / Qwen" : "Bailian / Qwen" }
    static var settingsOpenAISection: String { isChinese ? "OpenAI" : "OpenAI" }
    static var settingsGeminiSection: String { isChinese ? "Google Gemini" : "Google Gemini" }
    static var settingsLabelApiKey: String { isChinese ? "API Key" : "API Key" }
    static var settingsLabelModel: String { isChinese ? "文本模型（例如：qwen-plus）" : "Text model (e.g. qwen-plus)" }
    static var settingsLabelVLModel: String { isChinese ? "VL 模型（例如：qwen-vl-plus）" : "VL model (e.g. qwen-vl-plus)" }
    static var settingsLabelBaseURL: String { isChinese ? "Base URL" : "Base URL" }
    static var settingsLabelOpenAIModel: String { isChinese ? "模型（例如：gpt-4o-mini）" : "Model (e.g. gpt-4o-mini)" }
    static var settingsLabelGeminiModel: String { isChinese ? "模型（例如：gemini-2.5-flash）" : "Model (e.g. gemini-2.5-flash)" }

    // MARK: - Help / Registration
    static var settingsHelpTitle: String { isChinese ? "API Key 注册申请说明" : "API Key Registration" }
    static var settingsHelpBailianTitle: String { isChinese ? "阿里云百炼" : "Bailian (Alibaba)" }
    static var settingsHelpOpenAITitle: String { "OpenAI" }
    static var settingsHelpGeminiTitle: String { "Google Gemini" }

    // MARK: - Main Tab
    static var tabPapers: String { isChinese ? "试卷" : "Papers" }
    static var tabWrong: String { isChinese ? "错题" : "Wrong" }
    static var tabCamera: String { isChinese ? "拍照" : "Photo" }
    static var analyzing: String { isChinese ? "识别中…" : "Analyzing…" }
    /// 拍照解析：准备阶段
    static var analyzeStagePreparing: String {
        isChinese ? "正在准备解析试卷…" : "Preparing to analyze paper…"
    }
    /// 拍照解析：结构识别阶段（第 current 次 / 共 total 次）
    static func analyzeStageVisionAttempt(current: Int, total: Int) -> String {
        if isChinese {
            return "第 \(current)/\(total) 次：识别试卷结构与题目…"
        } else {
            return "Attempt \(current)/\(total): analyzing paper layout and questions…"
        }
    }
    /// 拍照解析：质量校验阶段
    static func analyzeStageValidating(current: Int, total: Int) -> String {
        if isChinese {
            return "第 \(current)/\(total) 次：校验题干、题目与切图质量…"
        } else {
            return "Attempt \(current)/\(total): validating stems, items and crops…"
        }
    }
    /// 拍照解析：切图阶段
    static var analyzeStageCropping: String {
        isChinese ? "正在为每道题生成切图…" : "Generating crops for each question…"
    }
    static var alertTitle: String { isChinese ? "提示" : "Notice" }
    static var alertOK: String { isChinese ? "确定" : "OK" }
    static var cancel: String { isChinese ? "取消" : "Cancel" }
    static var notificationTitle: String { isChinese ? "通知" : "Notifications" }
    static var noNotifications: String { isChinese ? "暂无新通知。" : "No new notifications." }
    static var notPaperMessage: String { isChinese ? "识别结果：该图片不是作业/试卷，未保存。" : "Not a paper/homework, not saved." }

    // MARK: - Home
    static var appTitle: String { isChinese ? "试卷管家" : "Exam Manager" }
    static var searchPlaceholder: String { isChinese ? "搜索试卷、科目、年级…" : "Search papers, subject, grade…" }
    static var filterGrade: String { isChinese ? "年级" : "Grade" }
    /// 英文用缩写避免换行
    static var filterSubject: String { isChinese ? "科目" : "Subj" }
    static var paperActions: String { isChinese ? "试卷操作" : "Paper actions" }
    static var archiveAction: String { isChinese ? "归档" : "Archive" }
    static var deleteAction: String { isChinese ? "删除" : "Delete" }
    static var noImage: String { isChinese ? "无图片" : "No image" }
    static var homeFilterAll: String { isChinese ? "全部" : "All" }
    static var homeRecent: String { isChinese ? "最近添加" : "Recent" }
    static var homeLastWeek: String { isChinese ? "上周" : "Last Week" }
    static var parsing: String { isChinese ? "解析中…" : "Parsing…" }

    // MARK: - Wrong Questions
    static var wrongEmptyTitle: String { isChinese ? "暂无题目" : "No Questions" }
    static var wrongEmptyHint: String { isChinese ? "拍照识别作业/试卷后，会在这里按试卷展示题目。\n默认只显示你标记为错题的题目，可通过开关查看全部。" : "Questions will appear here after scanning papers.\nBy default only wrong questions are shown; use the toggle to view all." }
    static var wrongFilterAll: String { isChinese ? "全部" : "All" }
    static var wrongFilterWrong: String { isChinese ? "错题" : "Wrong" }
    static var wrongGenerateAnswer: String { isChinese ? "生成答案与解析" : "Generate Answer" }
    static var wrongRegenerate: String { isChinese ? "重新生成解析" : "Regenerate" }
    static var wrongParsing: String { isChinese ? "解析生成中…" : "Generating…" }
    static var wrongCorrectAnswer: String { isChinese ? "正确答案：" : "Answer: " }
    static var wrongExplanation: String { isChinese ? "解析：" : "Explanation: " }
    static var wrongShowCrop: String { isChinese ? "显示题目切图" : "Show crop" }
    static var wrongMarkWrong: String { isChinese ? "标记为错题" : "Mark wrong" }
    static var wrongUnmarkWrong: String { isChinese ? "取消错题" : "Unmark wrong" }
    static var wrongNoCrop: String { isChinese ? "暂无错题" : "No wrong questions" }
    static var wrongShowAll: String { isChinese ? "显示全部题目" : "Show all questions" }
    static var wrongLoadCropFailed: String { isChinese ? "无法加载切图" : "Cannot load crop" }
    static var wrongNavigateTo: String { isChinese ? "转向错题" : "Go to Wrong" }
    static var wrongShowAllPapers: String { isChinese ? "显示全部试卷" : "Show all papers" }

    // MARK: - Camera
    static var cameraCancel: String { isChinese ? "取消" : "Cancel" }
    static var cameraGuide: String { isChinese ? "将试卷对准框内" : "Align paper in frame" }
    static var cameraFromAlbum: String { isChinese ? "从相册选择" : "From album" }

    // MARK: - Subject
    static func subject(_ subject: Subject) -> String {
        if isChinese {
            return subject.rawValue
        }
        switch subject {
        case .chinese: return "Chinese"
        case .math: return "Math"
        case .english: return "English"
        case .geography: return "Geography"
        case .physics: return "Physics"
        case .chemistry: return "Chemistry"
        case .other: return "Other"
        }
    }

    // MARK: - Grade
    static func grade(_ grade: Grade) -> String {
        if isChinese {
            return grade.rawValue
        }
        switch grade {
        case .primary1: return "Grade 1"
        case .primary2: return "Grade 2"
        case .primary3: return "Grade 3"
        case .primary4: return "Grade 4"
        case .primary5: return "Grade 5"
        case .primary6: return "Grade 6"
        case .junior1: return "Grade 7"
        case .junior2: return "Grade 8"
        case .junior3: return "Grade 9"
        case .other: return "Other"
        }
    }

    // MARK: - Score Filter
    static func scoreFilter(_ filter: ScoreFilter) -> String {
        if isChinese {
            return filter.rawValue
        }
        switch filter {
        case .all: return "Score"
        case .lt60: return "< 60"
        case .from60to80: return "60-80"
        case .from80to90: return "80-90"
        case .gte90: return "≥ 90"
        }
    }

    // MARK: - Paper Meta Editor
    static var paperMetaTitle: String { isChinese ? "试卷设置" : "Paper Settings" }
    static var paperMetaSection: String { isChinese ? "试卷信息" : "Paper Info" }
    static var paperMetaName: String { isChinese ? "试卷名称" : "Paper Name" }
    static var paperMetaGrade: String { isChinese ? "年级" : "Grade" }
    static var paperMetaSubject: String { isChinese ? "科目" : "Subject" }
    static var paperMetaScore: String { isChinese ? "分数（可选）" : "Score (optional)" }
    static var paperMetaSave: String { isChinese ? "保存" : "Save" }
}
