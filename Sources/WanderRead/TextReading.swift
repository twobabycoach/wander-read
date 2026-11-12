import AppKit
import CryptoKit
import SwiftUI

struct TextExcerpt: Codable, Equatable, Identifiable {
    var id = UUID()
    let revision: String
    let range: NSRange
    let quote: String
    let place: String
    var note = ""
    var createdAt: Date?
}

struct TextReadingState: Codable, Equatable {
    var revision: String?
    var offset: Int?
    var updatedAt: Date?
    var excerpts: [TextExcerpt] = []
}

enum ReadingFile {
    static let textExtensions: Set<String> = ["md", "markdown", "txt", "text", "rtf", "html", "htm"]

    static func textCandidate(_ target: String) -> Bool {
        if target.hasPrefix("/") { return textExtensions.contains(URL(fileURLWithPath: target).pathExtension.lowercased()) }
        guard let url = URL(string: target) else { return false }
        return (url.isFileURL && textExtensions.contains(url.pathExtension.lowercased())) ||
            (url.scheme == "obsidian" && url.host == "open")
    }

    static func localURL(_ target: String) throws -> URL {
        let link = try ObsidianLinks.checkedURL(target)
        if link.isFileURL { return link }
        if link.scheme == "obsidian", let path = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "path" })?.value {
            let file = FileManager.default.fileExists(atPath: path) ? path : String(path.split(separator: "#", maxSplits: 1).first ?? "")
            return URL(fileURLWithPath: file)
        }
        throw InputError.invalid("这个入口没有可在漫读打开的本地原文。")
    }
}

struct TextDocument {
    struct Block: Identifiable {
        enum Style { case body, heading(Int), quote, code }
        let range: NSRange
        let text: String
        let style: Style
        let inline: AttributedString?
        let sourceLine: Int?
        var id: Int { range.location }
    }

    private typealias Part = (text: String, style: Block.Style, markdown: Bool, sourceLine: Int?)

    let revision: String
    let content: String
    let blocks: [Block]
    var headings: [Block] { blocks.filter { if case .heading = $0.style { return true }; return false } }

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 4_000_000 else {
            throw InputError.invalid("内置阅读支持 4 MB 以内的文本文件。可从收藏菜单用原应用打开。")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 4_000_000 else { throw InputError.invalid("文本超过 4 MB，可用原应用打开。") }
        revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let suffix = url.pathExtension.lowercased()
        let parts: [Part]
        if suffix == "rtf" {
            let text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
            parts = Self.lines(text, markdown: false)
        } else if ["html", "htm"].contains(suffix) {
            parts = try Self.html(data)
        } else {
            let bom = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
            guard let text = bom ? String(data: data, encoding: .utf16) : String(data: data, encoding: .utf8) else {
                throw InputError.invalid("漫读未识别这份文本的编码。请保存为 UTF-8 或使用原应用打开。")
            }
            parts = Self.lines(text, markdown: suffix == "md" || suffix == "markdown")
        }
        var rendered = ""
        var entries: [Block] = []
        var offset = 0
        for (raw, style, markdown, line) in parts {
            let inline = markdown ? try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) : nil
            let text = inline.map { String($0.characters) } ?? raw
            let length = text.utf16.count
            if length > 0 { entries.append(Block(range: NSRange(location: offset, length: length), text: text, style: style, inline: inline, sourceLine: line)) }
            rendered += text + "\n"
            offset += length + 1
        }
        guard !entries.isEmpty else { throw InputError.invalid("这份文件没有可阅读的文字。") }
        content = rendered
        blocks = entries
    }

    func place(at offset: Int) -> String {
        let index = blocks.lastIndex { $0.id <= offset } ?? 0
        let place = blocks[index].sourceLine.map { "第 \($0) 行" } ?? "第 \(index + 1) 段"
        return headings.last(where: { $0.id <= offset }).map { String($0.text.prefix(72)) + " · " + place } ?? place
    }

    func quote(_ range: NSRange) -> String? {
        guard range.location >= 0, range.length > 0, range.length <= 20_000,
              let swiftRange = Range(range, in: content) else { return nil }
        let quote = String(content[swiftRange])
        return quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : quote
    }

    func sourceOffset(_ excerpt: TextExcerpt) -> Int? {
        if excerpt.revision == revision, quote(excerpt.range) == excerpt.quote { return excerpt.range.location }
        guard !excerpt.quote.isEmpty else { return nil }
        let text = content as NSString
        let first = text.range(of: excerpt.quote, options: .literal)
        guard first.location != NSNotFound else { return nil }
        let end = NSMaxRange(first)
        return text.range(of: excerpt.quote, options: .literal, range: NSRange(location: end, length: text.length - end)).location == NSNotFound ? first.location : nil
    }

    private static func lines(_ source: String, markdown: Bool) -> [Part] {
        let source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = source.components(separatedBy: "\n")
        var fence: Character?
        var fenceCount = 0
        return lines.enumerated().compactMap { index, line in
            let lineNumber = index + 1
            guard markdown else { return (line, .body, false, lineNumber) }
            let leading = line.trimmingCharacters(in: .whitespaces)
            let run = leading.prefix(while: { $0 == leading.first }).count
            if let delimiter = fence {
                if leading.first == delimiter, run >= fenceCount, leading.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                    fenceCount = 0
                    return nil
                }
                return (line, .code, false, lineNumber)
            }
            if run >= 3 && (leading.first == "`" || leading.first == "~") {
                fence = leading.first
                fenceCount = run
                return nil
            }
            if (1...6).contains(run), leading.first == "#", leading.dropFirst(run).first == " " {
                return (String(leading.dropFirst(run + 1)), .heading(run), true, lineNumber)
            }
            if leading.hasPrefix("> ") { return (String(leading.dropFirst(2)), .quote, true, lineNumber) }
            if leading.hasPrefix("- ") || leading.hasPrefix("* ") || leading.hasPrefix("+ ") {
                return ("• " + leading.dropFirst(2), .body, true, lineNumber)
            }
            return (line, .body, true, lineNumber)
        }
    }

    private static func html(_ data: Data) throws -> [Part] {
        // The system HTML tidy parser predates HTML5's short charset declaration.
        let bytes: Data
        if var html = String(data: data, encoding: .utf8) {
            let encoding = "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">"
            if let head = html.range(of: #"<head\b[^>]*>"#, options: [.caseInsensitive, .regularExpression]) {
                html.insert(contentsOf: encoding, at: head.upperBound)
            } else if let root = html.range(of: #"<html\b[^>]*>"#, options: [.caseInsensitive, .regularExpression]) {
                html.insert(contentsOf: "<head>" + encoding + "</head>", at: root.upperBound)
            } else {
                html = "<html><head>" + encoding + "</head><body>" + html + "</body></html>"
            }
            bytes = Data(html.utf8)
        } else {
            bytes = data
        }
        let doc = try XMLDocument(data: bytes, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement() else { return [] }
        let skipped: Set<String> = ["head", "script", "style", "template", "iframe", "svg", "noscript"]
        var result: [Part] = []
        var buffer = ""
        func emit(_ style: Block.Style = .body) {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append((text, style, false, nil)) }
            buffer = ""
        }
        func walk(_ node: XMLNode) {
            if node.kind == .text { buffer += node.stringValue ?? ""; return }
            guard node.kind == .element else { return }
            let name = node.name?.lowercased() ?? ""
            guard !skipped.contains(name) else { return }
            if name == "br" { buffer += "\n"; return }
            let level = name.first == "h" && name.count == 2 ? Int(name.suffix(1)) : nil
            let isBlock = level != nil || ["article", "section", "div", "p", "li", "pre", "blockquote", "tr"].contains(name)
            if isBlock { emit() }
            if name == "li" { buffer = "• " }
            for child in node.children ?? [] { walk(child) }
            if isBlock { emit(level.map { .heading($0) } ?? (name == "pre" ? .code : name == "blockquote" ? .quote : .body)) }
        }
        walk(root)
        emit()
        return result
    }
}

final class TextReader: ObservableObject {
    let itemID: UUID
    let title: String
    let url: URL
    let document: TextDocument
    @Published var isFocused = false
    @Published private(set) var excerpts: [TextExcerpt]
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var revealed: UUID?
    @Published var editing: UUID?
    @Published var draft = ""
    var offset: Int
    var move: ((Int) -> Void)?
    private var previous: [[TextExcerpt]] = []
    weak var store: ReadingStore?

    init(item: ReadingItem, url: URL, document: TextDocument, store: ReadingStore, focused: Bool) {
        itemID = item.id
        title = item.title
        self.url = url
        self.document = document
        self.store = store
        excerpts = item.textReading?.excerpts ?? []
        offset = item.textReading?.revision == document.revision ? min(max(0, item.textReading?.offset ?? 0), document.content.utf16.count) : 0
        isFocused = focused
    }

    var canUndo: Bool { !previous.isEmpty }
    var selectedQuote: String? { document.quote(selection) }

    @discardableResult func capture(at range: NSRange? = nil, addingNote note: String = "") -> TextExcerpt? {
        let range = range ?? selection
        guard let quote = document.quote(range) else { return nil }
        if let existing = excerpts.last(where: { $0.revision == document.revision && $0.range == range }) {
            guard !note.isEmpty, !existing.note.contains(note) else { return existing }
            let combined = [existing.note, note].filter { !$0.isEmpty }.joined(separator: "\n\n")
            guard annotate(existing.id, note: combined) else { return nil }
            return excerpts.first { $0.id == existing.id }
        }
        let excerpt = TextExcerpt(revision: document.revision, range: range, quote: quote,
                                  place: document.place(at: range.location), note: note, createdAt: Date())
        return save(excerpts + [excerpt]) ? excerpt : nil
    }

    @discardableResult func annotate(_ id: UUID, note: String) -> Bool {
        var updated = excerpts
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return false }
        updated[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return save(updated)
    }

    @discardableResult func saveDraft() -> Bool {
        if let editing {
            guard annotate(editing, note: draft) else { return false }
            self.editing = nil
        }
        return true
    }

    func remove(_ id: UUID) { _ = remove([id]) }

    @discardableResult func remove(_ ids: Set<UUID>) -> Bool {
        let remaining = excerpts.filter { !ids.contains($0.id) }
        return remaining == excerpts || save(remaining)
    }

    func undo() {
        guard let step = previous.last, persist(step) else { return }
        excerpts = step
        previous.removeLast()
    }

    private func save(_ next: [TextExcerpt]) -> Bool {
        guard persist(next) else { return false }
        previous.append(excerpts)
        if previous.count > 12 { previous.removeFirst() }
        excerpts = next
        return true
    }

    @discardableResult func persist(_ next: [TextExcerpt]? = nil) -> Bool {
        let state = TextReadingState(revision: document.revision, offset: offset, updatedAt: Date(), excerpts: next ?? excerpts)
        return store?.mutate(itemID) { $0.textReading = state } ?? false
    }

    func sourceOffset(_ excerpt: TextExcerpt) -> Int? {
        document.sourceOffset(excerpt)
    }
}

extension ReadingStore {
    func openText(_ item: ReadingItem, focused: Bool = false, noteID: UUID? = nil) {
        guard readerOpening == nil, pdfReader == nil, textReader == nil else { return }
        guard activeSession == nil || activeSession?.itemID == item.id else {
            page = "发现"; message = "先收好正在读的那一篇，再打开这份原文。"; return
        }
        do {
            let url = try ReadingFile.localURL(item.target)
            guard ReadingFile.textExtensions.contains(url.pathExtension.lowercased()) else {
                throw InputError.invalid("这个文件可用原应用打开。")
            }
            readerOpening = item.id
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try TextDocument(url: url) }
                DispatchQueue.main.async {
                    guard let self, self.readerOpening == item.id else { return }
                    self.readerOpening = nil
                    do {
                        let document = try result.get()
                        guard let live = self.library.items.first(where: { $0.id == item.id && $0.trashedAt == nil && $0.target == item.target }),
                              self.startReaderVisit(live.id) else { return }
                        self.message = nil
                        let reader = TextReader(item: live, url: url, document: document, store: self, focused: focused)
                        if let noteID, let note = reader.excerpts.first(where: { $0.id == noteID }) {
                            if let offset = reader.sourceOffset(note) { reader.offset = offset }
                            else { self.error = "原文件已有改动，这条摘录在当前版本里没有唯一位置。" }
                            reader.revealed = noteID
                        }
                        self.textReader = reader
                    } catch { self.error = error.localizedDescription }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func leaveReader() {
        if pdfReader != nil { leavePDF(); return }
        guard let reader = textReader, reader.saveDraft(), reader.persist(), finishReaderVisit(reader.itemID) else { return }
        textReader = nil
        fillQueueIfNeeded()
    }

    var latestReadingToResume: ReadingItem? {
        let pdf = latestPDFToResume
        let text = latestTextToResume
        return (pdf?.pdfReading?.cursor?.updatedAt ?? .distantPast) > (text?.textReading?.updatedAt ?? .distantPast) ? pdf : text ?? pdf
    }

    private var latestTextToResume: ReadingItem? {
        library.items.filter { $0.trashedAt == nil && $0.state != .archived && ReadingFile.textCandidate($0.target) && $0.textReading?.updatedAt != nil }
            .max { ($0.textReading?.updatedAt ?? .distantPast) < ($1.textReading?.updatedAt ?? .distantPast) }
    }
}
