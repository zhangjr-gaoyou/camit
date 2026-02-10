import Foundation

/// 将田字格、米字格等书写格替换为下划线，确保填空位置正确（存储与展示时均可调用）
func replaceTianziGeWithUnderline(_ content: String) -> String {
    var s = content
    // 1) 田字格、米字格等替换为下划线
    for pattern in ["田字格", "米字格", "九宫格"] {
        s = s.replacingOccurrences(of: pattern, with: "_____")
    }
    // 2) 修复 JSON 解析过程中 \f 被还原为 ASCII 0x0C 导致的 LaTeX 公式损坏：
    //    典型例子：$-\\frac{1}{7}$ 在解码后变成 $-rac{1}{7}$（\f + "rac"）
    //    这里将 0x0C + "rac" 统一还原为 "\\frac"
    s = s.replacingOccurrences(of: "\u{000C}rac", with: "\\frac")
    // 3) 修复 JSON 中 \t 被解析为制表符导致的 LaTeX 损坏：\times -> 制表+imes
    s = s.replacingOccurrences(of: "\u{0009}imes", with: "\\times")
    s = s.replacingOccurrences(of: "\u{0009}an", with: "\\tan")
    s = s.replacingOccurrences(of: "\u{0009}heta", with: "\\theta")
    s = s.replacingOccurrences(of: "\u{0009}ext", with: "\\text")
    s = s.replacingOccurrences(of: "\u{0009}riangle", with: "\\triangle")
    return s
}

/// 修复模型返回的 JSON 中常见错误，提高解析成功率
func repairPaperVisionJson(_ json: String) -> String {
    var s = json
    // 1) 去掉 BOM
    if s.hasPrefix("\u{FEFF}") {
        s = String(s.dropFirst())
    }
    // 2) bbox 数值后多余引号，如 "height": 0.05" -> "height": 0.05
    if let regex = try? NSRegularExpression(pattern: #"(\d+\.?\d*)"(\s*[,}\]\n])"#) {
        let range = NSRange(s.startIndex..., in: s)
        s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "$1$2")
    }
    // 2b) 兼容部分模型返回的特例：仅在 bbox 键 (x/y/width/height) 后出现数字+" 的情况
    if let r2b = try? NSRegularExpression(pattern: #"(\"(?:x|y|width|height)\"\s*:\s*\d+\.?\d*)\""#) {
        let range = NSRange(s.startIndex..., in: s)
        s = r2b.stringByReplacingMatches(in: s, range: range, withTemplate: "$1")
    }
    // 2c) 某些题目选项行末尾缺失 content 字符串的结束引号，具体表现为：
    // "D. ...4:1,\n      "bbox": {...}
    // 或 "D. -3＜a＜5,\n      "bbox": {...}
    // 此处应为 D. ...4:1",\n      "bbox"...，故将 D. 行末的逗号移到字符串外并补上结束引号
    // 仅匹配以 D. 开头且逗号后直接接 "bbox" 的行，避免误伤其它内容
    if let r2c = try? NSRegularExpression(pattern: #"(D\.[^"\n]*?),(\s*)\"bbox"#) {
        let range = NSRange(s.startIndex..., in: s)
        s = r2c.stringByReplacingMatches(in: s, range: range, withTemplate: #"${1}"$2"bbox"#)
    }
    // 2d) 更常见的变体：选项行正常结束在 "4:1"，但 content 字符串末尾缺逗号，直接接上了 "bbox"：
    // ... D. 4:1"\n      "bbox": { ... }
    // 修复方式：在字符串结束引号与后面的 "bbox" 之间插入逗号。
    // 使用 (?!,) 确保该引号后没有逗号，避免误伤已正确的 "...30",\n      "bbox"。
    if let r2d = try? NSRegularExpression(pattern: #"\"(?!,)(\s*)\"bbox\""#) {
        let range = NSRange(s.startIndex..., in: s)
        s = r2d.stringByReplacingMatches(in: s, range: range, withTemplate: #""$1,"bbox""#)
    }
    // 2e) content 未闭合：模型在 content 值中换行后直接写 "bbox"（缺结束引号）。
    //     仅当逗号前为「未闭合 content 的结尾字符」（数字/字母/括号）时插入 "，避免误伤已闭合的 "...30",\n      "bbox"。
    if let r2e = try? NSRegularExpression(pattern: #"(?<=[0-9a-zA-Z\)）]),(\s*\n\s*)\"bbox\""#) {
        let range = NSRange(s.startIndex..., in: s)
        s = r2e.stringByReplacingMatches(in: s, range: range, withTemplate: #"\"",$1\"bbox\""#)
    }
    // 3) 尾逗号：,} -> } 或 ,] -> ]
    if let r1 = try? NSRegularExpression(pattern: #",(\s*})"#) {
        s = r1.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
    }
    if let r2 = try? NSRegularExpression(pattern: #",(\s*])"#) {
        s = r2.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
    }
    // 4) LaTeX \begin 被 JSON 的 \b 误解析为退格：$\begin -> $egin，必须最先修复
    s = fixLatexBackslashInJson(s)
    // 5) 无效转义序列（如 \350、\247）须在换行修复前处理，避免字符串边界被误判
    s = fixInvalidJsonEscapes(s)
    // 6) 字符串内的未转义换行：JSON 不允许字符串中有字面换行，需替换为 \n
    s = escapeNewlinesInJsonStrings(s)
    // 7) 重复键：如 "subtype":"选题目","subtype":"选择题" 只保留最后一个
    s = deduplicateJsonKeys(s)
    return s
}

/// 修复 LaTeX 中 \begin、\times 等被 JSON 误解析为控制字符（\b 退格、\t 制表等）
/// \begin -> $egin；\times -> 制表符+imes。将未转义的 LaTeX 反斜杠命令转为 \\ 以保留字面量。
private func fixLatexBackslashInJson(_ json: String) -> String {
    var s = json
    // 1) \b 在 JSON 中是退格：$\begin{cases} -> $egin{cases}
    let beginPatterns = ["$\\begin{", "\n\\begin{", " \\begin{"]
    for pattern in beginPatterns {
        let prefix = String(pattern.prefix(1))
        s = s.replacingOccurrences(of: pattern, with: prefix + "\\\\begin{")
    }
    // 2) \t 在 JSON 中是制表符：\times -> 制表+imes。仅当出现在 LaTeX 公式内（前有 $ 或空白）时转为 \\t。
    //    正则中匹配字面 \ + t 需 \\t，Swift raw 中 #"\\\\t"# 输出两反斜杠+t。
    if let r = try? NSRegularExpression(pattern: #"(?<=[\$\s])\\\\t([a-zA-Z]+)"#) {
        let range = NSRange(s.startIndex..., in: s)
        s = r.stringByReplacingMatches(in: s, range: range, withTemplate: #"\\\\t$1"#)
    }
    return s
}

/// 修复无效的 JSON 转义序列。JSON 仅允许 \" \\ \/ \b \f \n \r \t \uXXXX。
/// 模型可能输出 \350、\247 等非法转义（如误把 Unicode 当八进制），将 \ 转为 \\ 使后续字符按字面解析。
private func fixInvalidJsonEscapes(_ json: String) -> String {
    var result = ""
    var i = json.startIndex
    while i < json.endIndex {
        let ch = json[i]
        if ch == "\\" && json.index(after: i) < json.endIndex {
            let nextIndex = json.index(after: i)
            let next = json[nextIndex]
            let validEscapes = CharacterSet(charactersIn: "\"\\/bfnrtu")
            let nextScalar = next.unicodeScalars.first!
            if validEscapes.contains(nextScalar) {
                if next == "u" {
                    let uStart = json.index(i, offsetBy: 2)
                    let hexCount = min(4, json.distance(from: uStart, to: json.endIndex))
                    let uEnd = json.index(uStart, offsetBy: hexCount)
                    if hexCount == 4, uEnd <= json.endIndex {
                        let hex = String(json[uStart..<uEnd])
                        if hex.allSatisfy({ $0.isHexDigit }) {
                            result.append(ch)
                            result.append(next)
                            result.append(hex)
                            i = json.index(uEnd, offsetBy: -1)
                        } else {
                            result.append("\\\\")
                        }
                    } else {
                        result.append("\\\\")
                    }
                } else {
                    result.append(ch)
                    result.append(next)
                    i = nextIndex
                }
            } else {
                // \ 后跟非法字符（如数字 \350、\247 或其它）：双写反斜杠，后续字符按字面保留
                result.append("\\\\")
            }
        } else {
            result.append(ch)
        }
        i = json.index(after: i)
    }
    return result
}

/// 去除重复的 subtype 键：如 "subtype":"选题目","subtype":"选择题" 保留后者
private func deduplicateJsonKeys(_ json: String) -> String {
    var s = json
    if let r = try? NSRegularExpression(pattern: #""subtype"\s*:\s*"[^"]*"\s*,\s*"subtype"\s*:"#) {
        let range = NSRange(s.startIndex..., in: s)
        s = r.stringByReplacingMatches(in: s, range: range, withTemplate: "\"subtype\":")
    }
    return s
}

/// 将 JSON 字符串值中的字面换行替换为 \\n（仅处理双引号内的内容）
private func escapeNewlinesInJsonStrings(_ json: String) -> String {
    var result = ""
    var inString = false
    var i = json.startIndex
    var prev: Character? = nil
    while i < json.endIndex {
        let ch = json[i]
        if ch == "\"" && prev != "\\" {
            inString.toggle()
            result.append(ch)
        } else if inString && (ch == "\n" || ch == "\r") {
            result.append("\\n")
            if ch == "\r" && json.index(after: i) < json.endIndex && json[json.index(after: i)] == "\n" {
                i = json.index(after: i)
            }
        } else {
            result.append(ch)
        }
        prev = ch
        i = json.index(after: i)
    }
    return result
}

/// 通用 JSON 修复（用于 PaperValidationResult、QuestionAnalysisResult 等）
func repairJsonForParsing(_ json: String) -> String {
    var s = json
    if s.hasPrefix("\u{FEFF}") { s = String(s.dropFirst()) }
    s = fixLatexBackslashInJson(s)
    if let r1 = try? NSRegularExpression(pattern: #"(\d+\.?\d*)"(\s*[,}\]\n])"#) {
        s = r1.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1$2")
    }
    if let r2e = try? NSRegularExpression(pattern: #"(?<=[0-9a-zA-Z\)）]),(\s*\n\s*)\"bbox\""#) {
        s = r2e.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: #"\"",$1\"bbox\""#)
    }
    if let r2 = try? NSRegularExpression(pattern: #",(\s*})"#) {
        s = r2.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
    }
    if let r3 = try? NSRegularExpression(pattern: #",(\s*])"#) {
        s = r3.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
    }
    s = fixInvalidJsonEscapes(s)
    s = escapeNewlinesInJsonStrings(s)
    s = deduplicateJsonKeys(s)
    return s
}

/// 打印模型返回的原始内容到 console，便于排查 JSON 解析等问题。在 Xcode Console 中搜索 [camit:model] 过滤。
func debugLogModelResponse(api: String, content: String) {
    let prefix = "[camit:model] "
    print("\(prefix)===== \(api) 模型返回 (length: \(content.count)) =====")
    print(content)
    print("\(prefix)===== End \(api) =====")
}

func extractFirstJSONObject(from text: String) -> String? {
    var cleaned = text
        .replacingOccurrences(of: "```json", with: "```", options: .caseInsensitive)
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
1) 判断图片是否为「作业/试卷」（包含题目、题干、编号等），一份试卷可能由 1 张或多张图片组成。
2) 如果是，按在整份试卷中的阅读顺序抽取内容，并对每一项标注类型：
   - "板块分类"：如「一、选择题」「二、填空题」等大题板块名；
   - "答题说明"：紧跟在某个板块标题之后，或者与板块标题在同一行括号中的整段说明文字，例如「(本题共 12 小题，每小题 2 分……)」；
   - "题干"：阅读材料、共用题干、不包含选项的提问句等。例如选择题中「下列……一项是（ ）」「下列……最恰当的一项是（ ）」这类只有问句、没有 A/B/C/D 选项的部分，必须标为题干；
   - "题目"：需要单独作答的一道小题。**每道小题单独一条 items，不可将不同题号合并为一条。** 例外：**填空题**若为「一题干 + 多个填空小题项」（如题 3 题干「在（）里填上">"、"<"或"="。」下面有 4 个比较式：80毫升（＜）8升、10升（＞）9000毫升、32×5×6（=）32×30、6升（=）6000毫升），则只输出**一条** type=题目、subtype=填空题，content 中先写题干，再用换行逐条列出各填空小题，不要拆成多条题目。若连续出现「1.」「2.」「3.」等不同题号且非上述填空小题项，应拆分为多条题目。无论题型如何，都统一标为 type=题目，同时必须对 type=题目 的项标注 subtype（题型），取值为：选择题、填空题、判断题、简答题、计算题、匹配题、论述题、阅读理解、其他（无法判断时用「其他」）。
3) **数学公式与化学方程式**：题目内容中涉及的所有数学公式、化学方程式、物理公式等，必须用 LaTeX 格式包裹。示例：质量能量公式 $E=mc^2$，分数 $\\frac{1}{2}$，根号 $\\sqrt{x}$，化学式 $H_2O$、$2H_2+O_2\\rightarrow 2H_2O$，下标 $x_1$、上标 $x^2$。不可用纯文字描述公式，必须用 $...$ 包裹。
4) 填空题中的下划线「_」「____」表示需要填空的位置，必须在 content 中明确保留并标识。做法：原样保留下划线，或在填空处用【填空】_____【/填空】标出，以便前端明显区分填空位。当填空区域为田字格、米字格等书写格时，在 content 中一律用下划线 _____ 或【填空】_____【/填空】表示，不要保留「田字格」「米字格」等描述，等同于下划线填空。
5) 如果图片中能看出总分或得分，请给出 0-100 的整数分数；无法确定则 null。
6) 当选择题的选项为图形（如图片、示意图）而非文字时，content 中用 [图片A]、[图片B]、[图片C]、[图片D] 等占位符表示各选项，且该题目的 bbox 必须完整覆盖题干及所有选项图片在试卷中的实际区域，确保切图能完整展示题目内容，前端将直接显示切图而非占位符。
7) 请根据常见题型，对 type=题目 的 content 做结构化组织（仅在 content 内体现题型含义，不改变 type 字段）：
   - 选择题：先给出题干句子，再按行列出选项，格式必须为「A. ……」「B. ……」「C. ……」「D. ……」（若有更多选项继续用 E./F.）；题干中不要包含答案。
   - 填空题：若为「一题干 + 多个填空小题项」（如「在（）里填上">"、"<"或"="。」下列若干比较式），content 格式为：第一行写题干，随后每行一条填空小题（如 80毫升（＜）8升、10升（＞）9000毫升），用换行分隔。其他填空题：题干中所有需要填写的空位用下划线或【填空】_____【/填空】标出，不要给出正确答案。
   - 判断题：content 中给出需要判断对/错的完整陈述句，不要直接透露「正确/错误」答案。
   - 简答题：content 中给出完整的提问句或要求（例如「简要说明……」「为什么……」），不包含参考答案，只保留题目本身。
   - 匹配题：在一条题目中同时给出「前提列」和「反应列」以及匹配指令，例如：
     前提列：1. ……\\n2. ……\\n3. ……
     反应列：A. ……\\nB. ……\\nC. ……
     匹配指令：请将前提与反应正确连线。
   - 论述题 / 解答题：content 中给出题干、作答要求等文字（如「请结合材料……写一篇不少于 600 字的文章」），不要给出评分标准或参考答案。
   - 计算题：content 中给出完整的题干和计算要求，涉及数字、公式、方程时一律用 LaTeX 表示，如 $x^2+2x+1=0$。
8) 对于每个大题板块（如「选择题」「填空题」）的答题说明文字（例如「本题共 12 小题，每小题 2 分，计 24 分。每小题只有一个选项符合题意。」），无论它是写在板块标题同一行的括号中，还是单独写在下一行，都请**单独作为一条 items 输出**，type 必须为 "答题说明"，content 为该说明文字，并放在对应的板块分类之后（紧邻该板块，且在该板块下第一道小题之前）。

题干与题目的正确示例（必须按此规则识别）：
- 题干：下列词语中加点字的读音，字形完全正确的一项是（ ）
- 题目：A. 倒闭（tuì） 嘲言（bō） 悄然（qiǎo） 前仆后继（pū）\\nB. 阎阿（xiā） 誓约（shà） 欣慰（wèi） 潜滋暗长（qián）\\nC. 忌讳（huì） 云霄（xiāo） 推崇（cóng） 无精打采（cǎi）\\nD. 惨境（cháng） 优哉（qí） 显印（kēn） 闭户拒盗（sù）
即：问句单独一条 type=题干；A/B/C/D 选项整体为一条 type=题目。
- 填空题「一题干+多填空小题」示例：题干「3. 在（）里填上">"、"<"或"="。」下列 4 个比较式，只输出**一条**题目，content 为：「3. 在（）里填上">"、"<"或"="。\\n80毫升（＜）8升\\n10升（＞）9000毫升\\n32×5×6（=）32×30\\n6升（=）6000毫升」

你必须只返回 JSON（不要 Markdown、不要代码块），格式严格如下：
{
  "is_homework_or_exam": true/false,
  "title": "试卷或作业标题（若无法判断可为空字符串）",
  "subject": "科目（如 语文/数学/英语/地理/物理/化学/其他）",
  "grade": "年级（如 小一/小二/小三/小四/小五/小六/初一/初二/初三/其他）",
  "items": [ 
    {"type": "板块分类", "content": "一、选择题", "bbox": {"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.05}},
    {"type": "题干", "content": "下列...一项是（ ）", "bbox": {"x": 0.1, "y": 0.25, "width": 0.8, "height": 0.08}},
    {"type": "题目", "subtype": "选择题", "content": "A. ...\\\\nB. ...\\\\nC. ...\\\\nD. ...", "bbox": {"x": 0.1, "y": 0.33, "width": 0.8, "height": 0.15}}
  ],
  "score": 86 或 null
}
type 只能是 "板块分类"、"答题说明"、"题干"、"题目" 之一。当 type=题目 时，必须包含 subtype 字段，取值为：选择题、填空题、判断题、简答题、计算题、匹配题、论述题、阅读理解、其他。
bbox 为该项在图片中的边界框，坐标为归一化值（0-1）：x/y 为左上角相对位置，width/height 为相对宽高。如果无法确定位置可省略 bbox。当题目选项为图形（如 [图片A] 等）时，bbox 必须覆盖题干+所有选项图片的完整区域。
"""

/// 重试时追加到解析提示词后的强调说明
let paperAnalysisPromptSuffixForRetry = """

【重要】请特别注意：1) 题干与题目必须严格区分——问句单独标为题干，含 A/B/C/D 选项的整体标为题目；2) 每道小题单独一条 items，不可合并不同题号；**填空题若为一题干+多个填空小题项（如「在（）里填上">"、"<"或"="。」下列 4 个比较式），只输出一条题目，content 中题干+换行+各小题；** 3) type=题目 时必须标注 subtype（选择题/填空题/简答题/计算题/匹配题等）；4) 数学公式、化学方程式必须用 LaTeX 格式 $...$ 包裹；5) 田字格、米字格等填空格一律用下划线或【填空】_____【/填空】表示；6) 每项的 bbox 须完整覆盖该内容在图片中的区域；7) 当题目选项为图形（[图片A] 等）时，bbox 必须覆盖题干及所有选项图片的完整区域。
"""

/// 题目解析提示词：要求生成结构化解析（知识点 + 详细解析）
func questionAnalysisPrompt(question: String, subject: String, grade: String) -> String {
    """
    你是一个 \(subject) 老师，面向 \(grade) 学生。请针对下面一道题目给出结构化的解析。

    题目：
    \(question)

    要求：
    1. 判断这道题所属的考查板块/题型，例如："选择题"、"填空题"、"解答题"、"阅读理解" 等。
    2. 给出这道题的标准答案（尽量简洁）。
    3. 给出结构化的解析，必须包含以下部分：
       - 【知识点】：结合试卷科目（\(subject)）和年级（\(grade)），用 2～4 个简短词语或短语（每项 4 字以内），用顿号或中文逗号分隔，如：声学、温度计、蒸发、比热容
       - 【详细解析】：分三步呈现
         1) 题干理解：简要说明题目在问什么。
         2) 选项分析：若为选择题，逐条分析各选项（A/B/C/D），每项一行，以 • 或 - 开头；非选择题则分析解题要点。
         3) 结论：给出最终答案或解题结论，如：故选D。

    严格只返回 JSON（不要加解释、不要代码块），格式如下：
    {
      "section": "选择题 或 解答题 等，若无法判断则为 null",
      "answer": "标准答案",
      "explanation": "【知识点】声学、温度计、蒸发\\n\\n【详细解析】\\n1) 题干理解：...\\n2) 选项分析：\\n• A. ...\\n• B. ...\\n3) 结论：故选D。"
    }
    explanation 必须包含【知识点】和【详细解析】两个部分，格式如上。【知识点】不超过 4 个，用简短语句。
    """
}

/// 校验解析结果时的用户消息前缀，后面拼接 itemsSummary
func paperValidationUserMessage(itemsSummary: String) -> String {
    """
    以下是对该试卷图片的解析结果（仅 type 与 content）：
    \(itemsSummary)

    请结合图片检查：1) 题干与题目是否正确区分；2) 各题内容是否完整、边界是否合理。
    只返回 JSON，不要 Markdown：{"valid": true/false, "score": 0-100, "issues": "问题描述或空字符串"}
    """
}
