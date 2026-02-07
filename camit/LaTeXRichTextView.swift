import SwiftUI
import LaTeXSwiftUI

/// 富文本视图：支持【填空】_____【/填空】的填空标识，以及 $...$ LaTeX 公式渲染
struct LaTeXRichTextView: View {
    let raw: String
    let font: Font
    let weight: Font.Weight
    let isSection: Bool

    init(_ raw: String, isSection: Bool = false) {
        self.raw = raw
        self.isSection = isSection
        self.font = isSection ? .headline : .subheadline
        self.weight = isSection ? .bold : .regular
    }

    var body: some View {
        if raw.contains("$") {
            let preprocessed = fixCasesLineBreaks(raw)
            let useBlockMode = preprocessed.contains("\\begin{cases}")
                || preprocessed.contains("\\begin{matrix}")
                || preprocessed.contains("\\begin{aligned}")
                || preprocessed.contains("\\begin{array}")
            LaTeX(preprocessed)
                .parsingMode(.onlyEquations)
                .font(font)
                .fontWeight(weight)
                .blockMode(useBlockMode ? .blockViews : .alwaysInline)
                .errorMode(.original)
                .imageRenderingMode(.original)
                .renderingStyle(.original)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            fillBlankOnlyView
        }
    }

    private var fillBlankOnlyView: some View {
        let segments = parseFillBlankSegments(raw)
        return ViewThatFits {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    segmentView(seg)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    segmentView(seg)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func segmentView(_ seg: Segment) -> some View {
        switch seg {
        case .plain(let s):
            return AnyView(Text(s).font(font).fontWeight(weight))
        case .fillBlank(let s):
            let content = s.isEmpty ? "_____" : s
            return AnyView(
                Group {
                    if #available(iOS 17.0, *) {
                        Text(content)
                            .font(font).fontWeight(weight)
                            .underline(true, color: .blue)
                            .foregroundStyle(.blue)
                    } else {
                        Text(content)
                            .font(font).fontWeight(weight)
                            .foregroundStyle(.blue)
                    }
                }
            )
        }
    }

    private enum Segment {
        case plain(String)
        case fillBlank(String)
    }

    /// 修复 cases 环境中错误的换行符：LLM 常输出单个 \ 而非 \\，导致 \x、\y 被误解析为 LaTeX 命令。
    /// 将「明显应为换行」的 \x、\y（后接 -、+、=）替换为 \\x、\\y。
    private func fixCasesLineBreaks(_ s: String) -> String {
        let open = "\\begin{cases}"
        let close = "\\end{cases}"
        guard let rOpen = s.range(of: open),
              let rClose = s.range(of: close, range: rOpen.upperBound..<s.endIndex) else {
            return s
        }
        let before = String(s[..<rOpen.upperBound])
        var content = String(s[rOpen.upperBound..<rClose.lowerBound])
        let after = String(s[rClose.lowerBound...])

        // 1) 字面换行符转 LaTeX 换行
        content = content.replacingOccurrences(of: "\r\n", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\\\")
        // 2) 修复 \x、\y 或 \ x、\ y 后接 -、+、= 的情况（JSON 中 \\ 解码为单 \，需补回）
        for (wrong, fixed) in [("\\x-", "\\\\x-"), ("\\x+", "\\\\x+"), ("\\x=", "\\\\x="),
                               ("\\y-", "\\\\y-"), ("\\y+", "\\\\y+"), ("\\y=", "\\\\y="),
                               ("\\ x-", "\\\\ x-"), ("\\ x+", "\\\\ x+"), ("\\ x=", "\\\\ x="),
                               ("\\ y-", "\\\\ y-"), ("\\ y+", "\\\\ y+"), ("\\ y=", "\\\\ y=")] {
            content = content.replacingOccurrences(of: wrong, with: fixed)
        }
        return before + content + fixCasesLineBreaks(after)
    }

    private func parseFillBlankSegments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        let open = "【填空】"
        let close = "【/填空】"
        var remaining = text
        while !remaining.isEmpty {
            if let rStart = remaining.range(of: open) {
                let before = String(remaining[..<rStart.lowerBound])
                if !before.isEmpty { result.append(.plain(before)) }
                remaining = String(remaining[rStart.upperBound...])
                if let rEnd = remaining.range(of: close) {
                    let blank = String(remaining[..<rEnd.lowerBound])
                    result.append(.fillBlank(blank))
                    remaining = String(remaining[rEnd.upperBound...])
                } else {
                    result.append(.plain(remaining))
                    break
                }
            } else {
                if !remaining.isEmpty { result.append(.plain(remaining)) }
                break
            }
        }
        if result.isEmpty && !text.isEmpty { result.append(.plain(text)) }
        return result
    }
}
