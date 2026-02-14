import SwiftUI
import LaTeXSwiftUI

/// 报告内容视图：支持 Markdown（标题、加粗、列表）、LaTeX 公式、图片（含 base64）
struct MarkdownReportView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                let isSubjectHeader = block.hasPrefix("## ") && !block.hasPrefix("### ")
                blockView(block, isSubjectHeader: isSubjectHeader, isFirstBlock: idx == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 规范化报告 Markdown：将误用的 **标题**（整行）转为 ## / ### 格式
    private var normalizedContent: String {
        let subjects = ["语文", "数学", "英语", "物理", "化学", "地理", "生物", "其他"]
        let sections = ["一、知识薄弱点分析", "二、学习建议", "三、针对性练习题"]
        let lines = content.components(separatedBy: .newlines)
        var result: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("**") && t.hasSuffix("**") && t.count > 4 {
                let inner = String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                if subjects.contains(inner) {
                    result.append("## \(inner)")
                } else if sections.contains(inner) {
                    result.append("### \(inner)")
                } else {
                    result.append(line)
                }
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    private var blocks: [String] {
        normalizedContent.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func blockView(_ block: String, isSubjectHeader: Bool = false, isFirstBlock: Bool = true) -> some View {
        if block.range(of: #"^!\[[^\]]*\]\([^)]+\)\s*$"#, options: .regularExpression) != nil,
           let (alt, url) = parseImage(block), !url.isEmpty {
            imageView(alt: alt, url: url)
        } else if block.hasPrefix("### ") {
            Text(String(block.dropFirst(4)))
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
        } else if block.hasPrefix("## ") {
            let title = String(block.dropFirst(3))
            VStack(alignment: .leading, spacing: 0) {
                if isSubjectHeader && !isFirstBlock {
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(height: 1)
                        .padding(.bottom, 12)
                }
                Text(title)
                    .font(isSubjectHeader ? .title2.weight(.bold) : .title3.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        } else if block.contains("$") {
            LaTeXRichTextView(block, isSection: false)
        } else {
            markdownTextView(block)
        }
    }

    private func parseImage(_ block: String) -> (alt: String, url: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#),
              let m = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              m.numberOfRanges >= 3,
              let altRange = Range(m.range(at: 1), in: block),
              let urlRange = Range(m.range(at: 2), in: block) else { return nil }
        return (String(block[altRange]), String(block[urlRange]))
    }

    @ViewBuilder
    private func imageView(alt: String, url: String) -> some View {
        if url.hasPrefix("data:image") {
            if let commaIdx = url.firstIndex(of: ","),
               let data = Data(base64Encoded: String(url[url.index(after: commaIdx)...])),
               let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                placeholderImage(alt: alt)
            }
        } else {
            placeholderImage(alt: alt)
        }
    }

    private func placeholderImage(alt: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(AppTheme.secondaryText)
            if !alt.isEmpty {
                Text(alt)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func markdownTextView(_ text: String) -> some View {
        if #available(iOS 15.0, *) {
            Group {
                if let attr = try? AttributedString(markdown: text) {
                    Text(attr)
                } else {
                    Text(text)
                }
            }
            .font(.body)
        } else {
            Text(text)
                .font(.body)
        }
    }
}
