import AppKit
import SwiftUI

/// Foundation supplies the Markdown grammar and stable block identities, including incomplete fences.
struct MarkdownBlock: Identifiable {
    let id: Int
    let kind: PresentationIntent.Kind
    var content = AttributedString()
    var children: [MarkdownBlock] = []

    static func parse(_ text: String) -> [MarkdownBlock] {
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full)) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, content: AttributedString(text))]
        }
        var root = MarkdownBlock(id: 0, kind: .paragraph)
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let path = Array((intent?.components ?? []).reversed())
            let content = AttributedString(parsed[range])
            if path.isEmpty {
                // Foundation leaves raw HTML blocks without a block intent. Keep their literal source in order.
                root.children.append(MarkdownBlock(id: -1 - root.children.count, kind: .paragraph, content: content))
            } else {
                root.append(content, path: path[...])
            }
        }
        return root.children.isEmpty && !text.isEmpty
            ? [MarkdownBlock(id: 0, kind: .paragraph, content: AttributedString(text))] : root.children
    }

    private mutating func append(_ text: AttributedString, path: ArraySlice<PresentationIntent.IntentType>) {
        guard let component = path.first else { content.append(text); return }
        if children.last?.id != component.identity {
            children.append(MarkdownBlock(id: component.identity, kind: component.kind))
        }
        children[children.count - 1].append(text, path: path.dropFirst())
    }
}

struct MarkdownText: View, Equatable {
    let text: String
    let fontSize: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(MarkdownBlock.parse(text)) { MarkdownBlockView(block: $0, fontSize: fontSize) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .tint(Color(red: 0.58, green: 0.76, blue: 0.95))
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let fontSize: CGFloat

    @ViewBuilder var body: some View {
        switch block.kind {
        case .paragraph:
            prose(block.content).frame(maxWidth: 720, alignment: .leading)
        case .header(let level):
            prose(block.content, size: fontSize + (level == 1 ? 10 : level == 2 ? 5 : 2), weight: .semibold)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.top, 6).accessibilityAddTraits(.isHeader)
        case .codeBlock(let language):
            CodeBlockView(code: String(block.content.characters), language: language, fontSize: fontSize)
        case .orderedList, .unorderedList:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(block.children) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(marker(for: item)).monospacedDigit().foregroundStyle(Theme.muted)
                            .frame(minWidth: fontSize, alignment: .trailing)
                        MarkdownBlockView(block: item, fontSize: fontSize)
                    }
                }
            }.font(.system(size: fontSize))
        case .blockQuote:
            children.padding(.leading, 15).foregroundStyle(.white.opacity(0.72))
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.23)).frame(width: 3) }
        case .thematicBreak:
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 6)
        case .table(let columns):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(block.children) { row in
                        GridRow {
                            ForEach(Array(row.children.enumerated()), id: \.element.id) { index, cell in
                                prose(cell.content, weight: row.kind == .tableHeaderRow ? .semibold : .regular)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: columnAlignment(index, columns: columns), vertical: .center))
                                    .gridColumnAlignment(columnAlignment(index, columns: columns))
                                    .background(row.kind == .tableHeaderRow ? Theme.surface : .clear)
                                    .overlay(alignment: .bottom) {
                                        if row.id != block.children.last?.id { Rectangle().fill(Theme.border).frame(height: 1) }
                                    }
                            }
                        }
                    }
                }.fixedSize(horizontal: true, vertical: false)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            }
        default:
            children
        }
    }

    private var children: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(block.children) { MarkdownBlockView(block: $0, fontSize: fontSize) }
        }
    }
    private func prose(_ value: AttributedString, size: CGFloat? = nil, weight: Font.Weight = .regular) -> some View {
        let pointSize = size ?? fontSize
        var styled = value
        for run in value.runs where run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].font = .system(size: pointSize * 0.92, design: .monospaced)
            styled[run.range].foregroundColor = Color(red: 0.74, green: 0.83, blue: 0.94)
            styled[run.range].backgroundColor = .white.opacity(0.07)
        }
        return Text(styled).font(.system(size: pointSize, weight: weight)).lineSpacing(fontSize * 0.3)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    private func marker(for item: MarkdownBlock) -> String {
        if block.kind == .orderedList, case .listItem(let ordinal) = item.kind { return "\(ordinal)." }
        return "•"
    }
    private func columnAlignment(_ index: Int, columns: [PresentationIntent.TableColumn]) -> HorizontalAlignment {
        guard columns.indices.contains(index) else { return .leading }
        switch columns[index].alignment {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?
    let fontSize: CGFloat
    @State private var copied = false
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "Code").fontWeight(.medium)
                if viewportWidth > 0 && contentWidth > viewportWidth + 1 {
                    Label("Scroll", systemImage: "arrow.left.and.right")
                        .help("Scroll horizontally to see the rest of the code")
                        .accessibilityLabel("Code scrolls horizontally")
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.plain).help("Copy code")
                    .task(id: copied) {
                        if copied { try? await Task.sleep(for: .seconds(2)); copied = false }
                    }
            }.font(.system(size: 11)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 14).padding(.vertical, 10).background(.white.opacity(0.025))
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView(.horizontal) {
                Text(CodeHighlighting.highlight(code.hasSuffix("\n") ? String(code.dropLast()) : code, language: language))
                    .font(.system(size: max(12, fontSize * 0.9), design: .monospaced)).lineSpacing(4)
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(14)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        }.background(.black.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }
}

/// Small lexical highlighter; unknown languages stay plain text. It never changes copied source.
enum CodeHighlighting {
    private static let keywords = "as async await break case catch class const continue def defer do else enum except export extends false False finally fn for from func function guard if impl import in interface let match mut new nil None null package private public raise return self Self static struct super switch throw throws trait true True try type typeof use var void when where while with yield"
    private static let languages: Set<String> = ["python", "py", "javascript", "js", "jsx", "typescript", "ts", "tsx", "swift", "rust", "rs", "go", "java", "kotlin", "c", "cpp", "c++", "csharp", "cs", "bash", "sh", "shell", "zsh", "ruby", "rb", "json", "yaml", "yml", "sql"]
    private static let hashComments: Set<String> = ["python", "py", "bash", "sh", "shell", "zsh", "ruby", "rb", "yaml", "yml"]
    private static let rules: [String: NSRegularExpression] = {
        let strings = #"(?:\"\"\"[\s\S]*?(?:\"\"\"|\z)|'''[\s\S]*?(?:'''|\z)|\"(?:\\.|[^\"\\])*(?:\"|\z)|'(?:\\.|[^'\\])*(?:'|\z)|`(?:\\.|[^`\\])*(?:`|\z))"#
        let words = #"\b(?:"# + keywords.split(separator: " ").joined(separator: "|") + #")\b"#
        let numbers = #"\b(?:0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
        return Dictionary(uniqueKeysWithValues: ["hash", "slash", "sql", "none"].compactMap { style in
            let comment = style == "hash" ? #"#[^\n]*"# : style == "sql" ? #"--[^\n]*|/\*[\s\S]*?(?:\*/|\z)"# : style == "slash" ? #"//[^\n]*|/\*[\s\S]*?(?:\*/|\z)"# : #"(?!)"#
            guard let regex = try? NSRegularExpression(pattern: "(\(strings))|(\(comment))|(\(words))|(\(numbers))") else { return nil }
            return (style, regex)
        })
    }()

    static func highlight(_ code: String, language: String?) -> AttributedString {
        let language = language?.lowercased() ?? ""
        guard languages.contains(language), code.utf16.count <= 100_000,
              let rule = rules[hashComments.contains(language) ? "hash" : language == "sql" ? "sql" : language == "json" ? "none" : "slash"] else { return AttributedString(code) }
        let source = code as NSString
        let colors = [Color(red: 0.69, green: 0.83, blue: 0.65), Color(red: 0.53, green: 0.58, blue: 0.62), Color(red: 0.78, green: 0.69, blue: 0.94), Color(red: 0.91, green: 0.74, blue: 0.53)]
        var result = AttributedString()
        var offset = 0
        for match in rule.matches(in: code, range: NSRange(location: 0, length: source.length)) {
            result.append(AttributedString(source.substring(with: NSRange(location: offset, length: match.range.location - offset))))
            var token = AttributedString(source.substring(with: match.range))
            if let group = (1...4).first(where: { match.range(at: $0).location != NSNotFound }) { token.foregroundColor = colors[group - 1] }
            result.append(token); offset = NSMaxRange(match.range)
        }
        result.append(AttributedString(source.substring(from: offset)))
        return result
    }
}
