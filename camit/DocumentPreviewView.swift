import SwiftUI
import UIKit
import ZIPFoundation
import WebKit

/// Word 文档预览（仅支持 .docx）
/// - docx：解压解析 word/document.xml 转为 HTML 展示
/// - doc：不支持，展示提示并提供「用其他应用打开」
struct DocumentPreviewView: View {
    let url: URL
    var onDismiss: (() -> Void)?

    @State private var htmlContent: String?
    @State private var isLoading = true
    @State private var parseError: String?
    @State private var showOpenInMenu = false

    @Environment(\.dismiss) private var dismiss

    private var ext: String { url.pathExtension.lowercased() }

    var body: some View {
        NavigationStack {
            Group {
                if ext == "doc" {
                    fallbackView
                } else if isLoading {
                    ProgressView("正在解析文档...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let html = htmlContent, !html.isEmpty {
                    DocxWebView(html: html)
                } else {
                    fallbackView
                }
            }
            .navigationTitle(url.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("用其他应用打开") {
                        showOpenInMenu = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        close()
                    }
                }
            }
        }
        .task(id: url.path) {
            if ext == "doc" {
                isLoading = false
                parseError = "doc 格式暂不支持，请使用「用其他应用打开」"
            } else {
                await loadContent()
            }
        }
        .background(DocumentInteractionPresenter(
            url: url,
            isPresented: $showOpenInMenu,
            onDismiss: { showOpenInMenu = false; close() }
        ))
    }

    private var fallbackView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("无法在应用内解析此文档")
                .font(.headline)
            if let err = parseError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Button("用其他应用打开") {
                showOpenInMenu = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func close() {
        onDismiss?()
        dismiss()
    }

    private func loadContent() async {
        isLoading = true
        parseError = nil
        htmlContent = nil

        defer { isLoading = false }

        if ext == "docx" {
            if let html = Self.buildDocxHTML(from: url) {
                htmlContent = html
            } else {
                parseError = "docx 解析失败，请使用「用其他应用打开」"
            }
        } else {
            parseError = "不支持的文件格式（仅支持 .docx）"
        }
    }

    private static func buildDocxHTML(from url: URL) -> String? {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        guard let entry = archive["word/document.xml"] else { return nil }

        var data = Data()
        _ = try? archive.extract(entry) { chunk in data.append(chunk) }
        guard !data.isEmpty else { return nil }

        let relationships = loadRelationships(from: archive)
        let media = loadMedia(from: archive)
        return DocxXMLParser.parse(documentXML: data, relationships: relationships, media: media)
    }

    private static func loadRelationships(from archive: Archive) -> [String: String] {
        var map: [String: String] = [:]
        guard let entry = archive["word/_rels/document.xml.rels"] else { return map }
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        guard !data.isEmpty, let xml = String(data: data, encoding: .utf8) else { return map }
        let pattern = "Id=\"([^\"]+)\"[^>]*Target=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return map }
        let range = NSRange(xml.startIndex..., in: xml)
        regex.enumerateMatches(in: xml, range: range) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 3,
                  let idRange = Range(m.range(at: 1), in: xml),
                  let targetRange = Range(m.range(at: 2), in: xml) else { return }
            let id = String(xml[idRange])
            var target = String(xml[targetRange])
            if target.hasPrefix("media/") { target = "word/" + target }
            map[id] = target
        }
        return map
    }

    private static func loadMedia(from archive: Archive) -> [String: (Data, String)] {
        var map: [String: (Data, String)] = [:]
        for entry in archive where entry.path.hasPrefix("word/media/") {
            let name = (entry.path as NSString).lastPathComponent
            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }
            let ext = (name as NSString).pathExtension.lowercased()
            map[name] = (data, ext == "png" ? "image/png" : "image/jpeg")
        }
        return map
    }
}

// MARK: - docx XML 解析器

private final class DocxXMLParser: NSObject, XMLParserDelegate {
    struct RunFormat {
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
        var color: String?
        var fontSize: Double?
    }
    struct Run {
        var text: String
        var format: RunFormat
        var hyperlink: String?
        var drawingRid: String?
    }
    struct Paragraph {
        var runs: [Run]
        var alignment: String?
        var styleId: String?
        var numPr: (ilvl: Int, numId: Int)?
    }
    struct TableCell {
        var paragraphs: [Paragraph]
    }
    struct Table {
        var rows: [[TableCell]]
    }

    private var paragraphs: [Paragraph] = []
    private var tables: [Table] = []
    private var elementStack: [String] = []
    private var currentParagraph: Paragraph?
    private var currentRun: Run?
    private var currentRunFormat: RunFormat?
    private var currentText = ""
    private var inT = false
    private var inDrawing = false
    private var currentDrawingRid: String?
    private var tableStack: [[[TableCell]]] = []
    private var currentRow: [TableCell] = []
    private var currentCellParagraphs: [Paragraph] = []
    private var relationships: [String: String] = [:]
    private var media: [String: (Data, String)] = [:]

    static func parse(documentXML: Data, relationships: [String: String], media: [String: (Data, String)]) -> String? {
        let parser = DocxXMLParser(relationships: relationships, media: media)
        let xmlParser = XMLParser(data: documentXML)
        xmlParser.delegate = parser
        guard xmlParser.parse() else { return nil }
        return parser.buildHTML()
    }

    private var currentHyperlink: String?
    private var inBody = false

    init(relationships: [String: String] = [:], media: [String: (Data, String)] = [:]) {
        self.relationships = relationships
        self.media = media
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        elementStack.append(local)

        switch local {
        case "body":
            inBody = true
        case "p":
            guard inBody else { break }
            currentParagraph = Paragraph(runs: [], alignment: nil, styleId: nil, numPr: nil)
            currentRun = nil
            currentRunFormat = nil
        case "pPr":
            break
        case "pStyle":
            if let val = attributeDict["w:val"] ?? attributeDict["val"] {
                currentParagraph?.styleId = val
            }
        case "numPr":
            break
        case "ilvl":
            if let val = attributeDict["w:val"] ?? attributeDict["val"], let ilvl = Int(val) {
                let prev = currentParagraph?.numPr
                currentParagraph?.numPr = (ilvl, prev?.1 ?? 0)
            }
        case "numId":
            if let val = attributeDict["w:val"] ?? attributeDict["val"], let numId = Int(val) {
                let prev = currentParagraph?.numPr
                currentParagraph?.numPr = (prev?.0 ?? 0, numId)
            }
        case "jc":
            if let val = attributeDict["w:val"] ?? attributeDict["val"] {
                currentParagraph?.alignment = val
            }
        case "hyperlink":
            if let rid = attributeDict["r:id"] ?? attributeDict["id"], let target = relationships[rid] {
                currentHyperlink = target
            }
        case "r":
            currentRunFormat = RunFormat()
            currentRun = Run(text: "", format: RunFormat(), hyperlink: currentHyperlink, drawingRid: nil)
        case "rPr":
            break
        case "b":
            currentRunFormat?.bold = true
        case "i":
            currentRunFormat?.italic = true
        case "u":
            currentRunFormat?.underline = true
        case "strike", "dstrike":
            currentRunFormat?.strikethrough = true
        case "sz":
            if let val = attributeDict["w:val"] ?? attributeDict["val"], let n = Int(val) {
                currentRunFormat?.fontSize = Double(n) / 2.0
            }
        case "color":
            if let val = attributeDict["w:val"] ?? attributeDict["val"], !val.hasPrefix("auto") {
                currentRunFormat?.color = val
            }
        case "t":
            inT = true
            currentText = ""
        case "drawing":
            inDrawing = true
        case "blip":
            if let rid = attributeDict["r:embed"] ?? attributeDict["embed"] {
                currentDrawingRid = rid
            }
        case "tbl":
            guard inBody else { break }
            tableStack.append([])  // 新表，rows 数组
        case "tr":
            currentRow = []
        case "tc":
            currentCellParagraphs = []
        case "tblPr", "tblGrid", "tcPr":
            break
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        _ = elementStack.popLast()

        switch local {
        case "body":
            inBody = false
        case "p":
            if var para = currentParagraph {
                if let run = currentRun, !run.text.isEmpty || run.drawingRid != nil {
                    var r = run
                    r.format = currentRunFormat ?? RunFormat()
                    para.runs.append(r)
                }
                if tableStack.isEmpty {
                    paragraphs.append(para)
                } else {
                    currentCellParagraphs.append(para)
                }
            }
            currentParagraph = nil
            currentRun = nil
        case "r":
            if var para = currentParagraph, var run = currentRun {
                run.text = currentText
                run.format = currentRunFormat ?? RunFormat()
                if inDrawing, let rid = currentDrawingRid {
                    run.drawingRid = rid
                }
                if !run.text.isEmpty || run.drawingRid != nil {
                    para.runs.append(run)
                    currentParagraph = para
                }
            }
            currentRun = nil
            currentRunFormat = nil
            currentText = ""
            inT = false
            inDrawing = false
            currentDrawingRid = nil
        case "t":
            inT = false
        case "tc":
            let cell = TableCell(paragraphs: currentCellParagraphs)
            currentRow.append(cell)
        case "tr":
            if !currentRow.isEmpty, !tableStack.isEmpty {
                tableStack[tableStack.count - 1].append(currentRow)
            }
            currentRow = []
        case "tbl":
            if let rows = tableStack.popLast(), !rows.isEmpty {
                tables.append(Table(rows: rows))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT {
            currentText += string
        }
    }

    private func buildHTML() -> String {
        var body = ""
        for para in paragraphs {
            body += paragraphToHTML(para)
        }
        for table in tables {
            body += tableToHTML(table)
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; font-size: 16px; line-height: 1.5; padding: 16px; color: #333; }
        h1 { font-size: 1.5em; margin: 0.67em 0; }
        h2 { font-size: 1.3em; margin: 0.5em 0; }
        h3 { font-size: 1.17em; margin: 0.5em 0; }
        p { margin: 0.5em 0; }
        ul, ol { margin: 0.5em 0; padding-left: 1.5em; }
        table { border-collapse: collapse; width: 100%; margin: 0.5em 0; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; vertical-align: top; }
        th { background: #f5f5f5; font-weight: 600; }
        img { max-width: 100%; height: auto; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private func paragraphToHTML(_ para: Paragraph) -> String {
        let content = runsToHTML(para.runs)
        if content.isEmpty { return "" }
        var style = ""
        if let align = para.alignment {
            style = " style=\"text-align: \(align)\""
        }
        let styleId = para.styleId ?? ""
        let tag: String
        if styleId.hasPrefix("Heading") || styleId.hasPrefix("heading") {
            let level = styleId.replacingOccurrences(of: "Heading", with: "").replacingOccurrences(of: "heading", with: "").trimmingCharacters(in: .whitespaces)
            let n = Int(level) ?? 1
            tag = "h\(min(max(n, 1), 6))"
        } else if para.numPr != nil {
            return "<li\(style)>\(content)</li>\n"
        } else {
            tag = "p"
        }
        return "<\(tag)\(style)>\(content)</\(tag)>\n"
    }

    private func runsToHTML(_ runs: [Run]) -> String {
        runs.map { runToHTML($0) }.joined()
    }

    private func runToHTML(_ run: Run) -> String {
        if let rid = run.drawingRid, let target = relationships[rid] {
            let fileName = (target as NSString).lastPathComponent
            if let (data, mime) = media[fileName] {
                let base64 = data.base64EncodedString()
                return "<img src=\"data:\(mime);base64,\(base64)\" style=\"max-width:100%;\" />"
            }
        }
        let text = escapeHTML(run.text)
        if text.isEmpty { return "" }
        var open: [String] = []
        var close: [String] = []
        let fmt = run.format
        if fmt.bold { open.append("<b>"); close.insert("</b>", at: 0) }
        if fmt.italic { open.append("<i>"); close.insert("</i>", at: 0) }
        if fmt.underline { open.append("<u>"); close.insert("</u>", at: 0) }
        if fmt.strikethrough { open.append("<s>"); close.insert("</s>", at: 0) }
        var spanStyle: [String] = []
        if let color = fmt.color { spanStyle.append("color:#\(color)") }
        if let size = fmt.fontSize { spanStyle.append("font-size:\(Int(size))pt") }
        if !spanStyle.isEmpty {
            open.append("<span style=\"\(spanStyle.joined(separator: "; "))\">")
            close.insert("</span>", at: 0)
        }
        var inner = text
        if let href = run.hyperlink {
            inner = "<a href=\"\(escapeHTML(href))\">\(inner)</a>"
        }
        return open.joined() + inner + close.joined()
    }

    private func tableToHTML(_ table: Table) -> String {
        var html = "<table><tbody>\n"
        for (rowIdx, row) in table.rows.enumerated() {
            html += "<tr>\n"
            for cell in row {
                let tag = rowIdx == 0 ? "th" : "td"
                let cellContent = cell.paragraphs.map { paragraphToHTML($0) }.joined()
                html += "<\(tag)>\(cellContent)</\(tag)>\n"
            }
            html += "</tr>\n"
        }
        html += "</tbody></table>\n"
        return html
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - WKWebView 包装

private struct DocxWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = [.link, .phoneNumber]
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - 用其他应用打开

private struct DocumentInteractionPresenter: UIViewControllerRepresentable {
    let url: URL
    @Binding var isPresented: Bool
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(url: url, isPresented: $isPresented, onDismiss: onDismiss)
    }
    func updateUIViewController(_ vc: Controller, context: Context) {
        vc.url = url
        vc.isPresented = $isPresented
        vc.onDismiss = onDismiss
        if isPresented, !vc.hasPresented {
            vc.presentIfNeeded()
        }
    }

    final class Controller: UIViewController, UIDocumentInteractionControllerDelegate {
        var url: URL
        var isPresented: Binding<Bool>
        var onDismiss: () -> Void
        var hasPresented = false
        var docController: UIDocumentInteractionController?

        init(url: URL, isPresented: Binding<Bool>, onDismiss: @escaping () -> Void) {
            self.url = url
            self.isPresented = isPresented
            self.onDismiss = onDismiss
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError() }

        func presentIfNeeded() {
            guard hasPresented == false else { return }
            hasPresented = true
            let dc = UIDocumentInteractionController(url: url)
            dc.delegate = self
            docController = dc
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })?
                .windows.first(where: { $0.isKeyWindow }),
                  let root = window.rootViewController
            else { isPresented.wrappedValue = false; return }
            let rect = CGRect(x: 0, y: 50, width: 300, height: 100)
            dc.presentOptionsMenu(from: rect, in: root.view, animated: true)
        }

        func documentInteractionControllerDidDismissOptionsMenu(_ controller: UIDocumentInteractionController) {
            isPresented.wrappedValue = false
            onDismiss()
        }
    }
}
