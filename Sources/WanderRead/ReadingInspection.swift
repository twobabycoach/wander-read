import Foundation
import PDFKit

struct ReadingInspection: Identifiable {
    enum Purpose {
        case candidate
        case pdf(PDFReadingLocation, revision: String, lines: [PDFReadingLine], note: UUID?)
        case text(TextExcerpt)
        case related(RelatedPDFEvidence)
    }

    let id = UUID()
    let item: ReadingItem
    let purpose: Purpose
    var quote = ""
    var knownURL: URL?

    var isCandidate: Bool {
        if case .candidate = purpose { return true }
        return false
    }

    var sourceLabel: String {
        switch purpose {
        case .candidate: return item.source
        case .pdf(let location, _, let lines, _):
            let last = max(location.page, lines.map(\.page).max() ?? location.page)
            return last == location.page ? "PDF 第 \(location.page + 1) 页" : "PDF 第 \(location.page + 1)–\(last + 1) 页"
        case .text(let excerpt): return excerpt.place
        case .related(let evidence): return "PDF 第 \(evidence.page + 1) 页"
        }
    }
}

struct PDFInspectionDestination {
    let location: PDFReadingLocation
    let lines: [PDFReadingLine]
}

enum InspectionContent {
    case link
    case preview(pages: Int?, extract: String?, label: String, headings: [String])
    case pdf(URL, PDFDocument, revision: String, destination: PDFInspectionDestination? = nil)
    case text(URL, TextDocument, offset: Int)

    static func load(_ request: ReadingInspection) async throws -> Self {
        let item = request.item
        if request.isCandidate && !item.canReadInside { return .link }
        let url: URL
        if let known = request.knownURL { url = known }
        else if let reference = item.zotero, let key = reference.pdfKey {
            if let cached = reference.localURL { url = cached }
            else { url = try await ZoteroAPI.pdfURL(key) }
        } else { url = try ReadingFile.localURL(item.target) }
        guard url.isFileURL else { throw InputError.invalid("这里需要一份本地原文。") }
        return try await Task.detached(priority: .userInitiated) {
            switch request.purpose {
            case .candidate:
                if url.pathExtension.lowercased() == "pdf" {
                    let document = try readablePDF(url)
                    let text = (0..<min(document.pageCount, 2)).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
                    let abstract = authorAbstract(in: text)
                    return .preview(pages: document.pageCount, extract: abstract ?? opening(text),
                                    label: abstract == nil ? "开头原文" : "作者摘要", headings: outline(document))
                }
                let document = try TextDocument(url: url)
                let first = document.blocks.first { if case .body = $0.style { return true }; return false }
                return .preview(pages: nil, extract: first.flatMap { opening($0.text) }, label: "开头原文",
                                headings: document.headings.prefix(6).map(\.text))
            case .pdf(let location, let expected, let lines, _):
                let revision = try PDFReader.fingerprint(url)
                guard revision == expected else {
                    throw InputError.invalid("原 PDF 已更换。这段摘录仍在，下方文字是当时保存的版本。")
                }
                let document = try readablePDF(url)
                guard (0..<document.pageCount).contains(location.page) else {
                    throw InputError.invalid("这条摘录的页码在当前文件中找不到。")
                }
                return .pdf(url, document, revision: revision,
                            destination: PDFInspectionDestination(location: location, lines: lines))
            case .related(let evidence):
                let document = try readablePDF(url)
                let selection = try evidence.selection(in: document)
                guard let page = document.page(at: evidence.page) else {
                    throw InputError.invalid("这段原文所在页已变化。")
                }
                let lines = selection.selectionsByLine().map {
                    PDFReadingLine(page: evidence.page, rect: $0.bounds(for: page))
                }.filter { !$0.rect.isEmpty }
                let rect = lines.first?.rect ?? selection.bounds(for: page)
                let location = PDFReadingLocation(page: evidence.page, point: CGPoint(x: rect.minX, y: rect.maxY))
                let revision = try PDFReader.fingerprint(url)
                return .pdf(url, document, revision: revision,
                            destination: PDFInspectionDestination(location: location, lines: lines))
            case .text(let excerpt):
                let document = try TextDocument(url: url)
                guard let offset = document.sourceOffset(excerpt) else {
                    throw InputError.invalid("这条摘录在当前文件里没有唯一位置。")
                }
                return .text(url, document, offset: offset)
            }
        }.value
    }

    private static func readablePDF(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0,
              document.page(at: 0) != nil else { throw InputError.invalid("无法读取这份 PDF。") }
        return document
    }

    private static let abstract = try! NSRegularExpression(
        pattern: #"(?ims)^\h*(?:[【〔［\[]?\h*摘\h*要\h*[】〕］\]]?|abstract)\h*[:：]?\h*(.{24,2400}?)(?=^\h*(?:[【〔［\[]?\h*关\h*键\h*词|key\h*words))"#
    )

    static func authorAbstract(in text: String) -> String? {
        guard let match = abstract.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return opening(String(text[range]), limit: 640)
    }

    private static func opening(_ value: String, limit: Int = 380) -> String? {
        let text = ChineseReading.reflow(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func outline(_ document: PDFDocument) -> [String] {
        guard let root = document.outlineRoot else { return [] }
        return (0..<min(6, root.numberOfChildren)).compactMap { root.child(at: $0)?.label }
    }
}

extension ReadingStore {
    func inspectRelated(_ result: RelatedReadingResult) {
        guard let evidence = result.pdfEvidence,
              let item = library.items.first(where: { $0.id == result.id && $0.target == result.item.target &&
                  $0.zotero == result.item.zotero && $0.trashedAt == nil }) else {
            error = "这篇收藏的原文入口有变化，请重查。"
            return
        }
        inspection = ReadingInspection(item: item, purpose: .related(evidence), quote: evidence.quote,
                                       knownURL: evidence.url)
    }

    func inspectCandidate(_ item: ReadingItem) {
        guard pdfReader == nil, textReader == nil, activeSession == nil,
              recommendations.contains(where: { $0.id == item.id }) else { return }
        inspection = ReadingInspection(item: item, purpose: .candidate)
    }

    func inspectPDF(_ reader: PDFReader, at location: PDFReadingLocation, lines: [PDFReadingLine] = [],
                    note: UUID? = nil, quote: String = "") {
        guard let item = library.items.first(where: { $0.id == reader.itemID }) else { return }
        inspection = ReadingInspection(item: item, purpose: .pdf(location, revision: reader.revision, lines: lines, note: note),
                                       quote: quote, knownURL: reader.url)
    }

    func inspectText(_ reader: TextReader, excerpt: TextExcerpt) {
        guard let item = library.items.first(where: { $0.id == reader.itemID }) else { return }
        inspection = ReadingInspection(item: item, purpose: .text(excerpt), quote: excerpt.quote, knownURL: reader.url)
    }

    func acceptInspection(_ request: ReadingInspection, content: InspectionContent?) {
        guard inspection?.id == request.id, readerOpening == nil,
              let item = library.items.first(where: { $0.id == request.item.id && $0.target == request.item.target &&
                  $0.zotero?.pdfKey == request.item.zotero?.pdfKey && $0.trashedAt == nil })
        else { return }
        if request.isCandidate {
            inspection = nil
            choose(item)
            return
        }
        guard let content else { return }
        do {
            switch (request.purpose, content) {
            case (.pdf(let location, _, _, let note), .pdf(let url, let document, let revision, _)):
                try acceptPDFInspection(item, url: url, document: document, revision: revision, location: location, note: note)
            case (.related, .pdf(let url, let document, let revision, let destination?)):
                try acceptPDFInspection(item, url: url, document: document, revision: revision, location: destination.location)
            case (.text(let excerpt), .text(let url, let document, let offset)):
                guard (try? ReadingFile.localURL(item.target)) == url else {
                    throw InputError.invalid("原文入口在查阅期间变了，请重新打开出处。")
                }
                if let reader = textReader, reader.itemID == item.id, reader.document.revision == document.revision {
                    guard reader.saveDraft() else { return }
                    inspection = nil
                    reader.revealed = excerpt.id
                    reader.offset = offset
                    reader.move?(offset)
                } else {
                    guard closeReadingForInspection(), startReaderVisit(item.id) else { return }
                    let reader = TextReader(item: item, url: url, document: document, store: self, focused: false)
                    reader.offset = offset
                    reader.revealed = excerpt.id
                    inspection = nil
                    textReader = reader
                }
            default: break
            }
        } catch { self.error = error.localizedDescription }
    }

    private func acceptPDFInspection(_ item: ReadingItem, url: URL, document: PDFDocument, revision: String,
                                     location: PDFReadingLocation, note: UUID? = nil) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              item.zotero?.pdfKey != nil || (try? ObsidianLinks.checkedURL(item.target)) == url else {
            throw InputError.invalid("原文入口在查阅期间变了，请重新打开出处。")
        }
        if let reader = pdfReader, reader.itemID == item.id, reader.revision == revision {
            guard reader.saveDraft() else { return }
            inspection = nil
            if let note { reader.revealedNote = note }
            reader.showSource(at: location)
        } else {
            guard closeReadingForInspection() else { return }
            inspection = nil
            try presentPDF(itemID: item.id, url: url, revision: revision, markID: note,
                           zoteroKey: item.zotero?.pdfKey, prepared: document, location: location)
        }
    }

    private func closeReadingForInspection() -> Bool {
        if pdfReader != nil || textReader != nil {
            leaveReader()
            return pdfReader == nil && textReader == nil
        }
        return activeSession.map { finishReaderVisit($0.itemID) } ?? true
    }
}
