import Foundation

func extractFirstJSONObject(from text: String) -> String? {
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
        if ch == "\"" && prev != "\\" { inString.toggle() }
        if !inString {
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return String(cleaned[start...i]) }
            }
        }
        prev = ch
    }
    return nil
}

let paperAnalysisSystemPromptText = """
你是一个 OCR + 文档理解助手。你的任务：
1) 判断图片是否为"作业/试卷"（包含题目、题干、编号等）。
2) 如果是，按顺序抽取内容，并对每一项标注类型：
   - "板块分类"：如"一、选择题""二、填空题"、大题板块名等；
   - "题干"：阅读材料、共用题干、不包含选项的提问句等。例如选择题中"下列……一项是（ ）""下列……最恰当的一项是（ ）"这类只有问句、没有 A/B/C/D 选项的部分，必须标为题干；
   - "题目"：需要单独作答的一道小题，包含选项时则整道题（含 A/B/C/D 选项）为一条题目。
3) 填空题中的下划线"_"或"____"表示需要填空的位置，必须在 content 中明确保留并标识。做法：原样保留下划线，或在填空处用【填空】_____【/填空】标出，以便前端明显区分填空位。
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
