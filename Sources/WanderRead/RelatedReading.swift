import Foundation
import PDFKit

struct RelatedReadingResult: Identifiable {
    let item: ReadingItem
    let similarity: Double
    let excerpt: String?
    let sampledPages: [Int]
    let pdfEvidence: RelatedPDFEvidence?
    var id: UUID { item.id }
}

struct RelatedPDFEvidence {
    let url: URL
    let page: Int
    let range: NSRange
    let quote: String

    func selection(in document: PDFDocument) throws -> PDFSelection {
        guard let page = document.page(at: page), let text = page.string as NSString?,
              range.location >= 0, range.length > 0, range.location <= text.length,
              range.length <= text.length - range.location, text.substring(with: range) == quote,
              let selection = page.textSelection(in: range), !selection.bounds(for: page).isEmpty else {
            throw InputError.invalid("这段原文的位置已有变化，请重新查相关文献。")
        }
        return selection
    }
}

struct RelatedReadingReport {
    var results: [RelatedReadingResult] = []
    var compared = 0
    var sampled = 0
    var available = 0
    var needsAnchor = false
}

enum RelatedReading {
    private struct Sample {
        var parts: [Part]
        var url: URL?
        var text: String { parts.map(\.text).joined(separator: "\n") }
        var pages: [Int] { parts.compactMap { $0.page.map { $0 + 1 } } }
    }

    private struct Part {
        let text: String
        var page: Int?
        var offset = 0
    }

    static func rank(items: [ReadingItem], preferences: Preferences, question: String,
                     anchorID: UUID?, limit: Int, now: Date = Date(), inlineEvidence: Bool = false) -> RelatedReadingReport {
        let scoped = items.filter {
            PriorityEngine.inScope($0, preferences: preferences) && $0.state != .archived
        }
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchorIDs = query.isEmpty ? (anchorID.map { [$0] } ?? SemanticIndex.anchors(in: scoped)) : []
        let anchorSet = Set(anchorIDs)
        let anchors = items.filter { $0.trashedAt == nil && anchorSet.contains($0.id) }
        guard !query.isEmpty || !anchors.isEmpty else { return RelatedReadingReport(needsAnchor: true) }
        let eligible = scoped.filter {
            $0.id != anchorID && !anchorSet.contains($0.id) && AttentionEngine.eligible($0, now: now)
                && (!inlineEvidence || $0.canSendToResearch || $0.zotero?.localURL != nil)
        }
        let vaults = ObsidianLinks.registeredVaults()
        var pool: [ReadingItem] = []
        for item in eligible {
            if Task.isCancelled { return RelatedReadingReport() }
            if (try? ObsidianLinks.checkedURL(item.target, vaults: vaults)) != nil { pool.append(item) }
        }
        let metadata = SemanticIndex.similarities(items: pool + anchors, question: query, anchorIDs: anchorIDs)
        pool.sort {
            let left = metadata[$0.id] ?? 0
            let right = metadata[$1.id] ?? 0
            if left != right { return left > right }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let candidates = Array(pool.prefix(max(1, min(limit, 500))))
        var samples: [UUID: Sample] = [:]
        for item in candidates + anchors {
            if Task.isCancelled { return RelatedReadingReport() }
            samples[item.id] = sample(item.zotero?.localURL?.path ?? item.target, vaults: vaults)
        }
        let scores = SemanticIndex.similarities(items: candidates + anchors, question: query,
                                                body: samples.mapValues(\.text), anchorIDs: anchorIDs)
        let anchorTerms = Set(SemanticIndex.tokens(query + " " + anchors.map { anchor in
            anchor.title + " " + anchor.note + " " + (samples[anchor.id]?.text ?? "")
        }.joined(separator: " ")))
        let ranked = candidates.compactMap { item -> RelatedReadingResult? in
            guard let score = scores[item.id], score > 0 else { return nil }
            let sample = samples[item.id]
            let match = sample.flatMap { bestExcerpt(in: $0.parts, matching: anchorTerms,
                                                    excludingTitle: inlineEvidence ? item.title : nil) }
            let evidence: RelatedPDFEvidence?
            if let match, let page = match.part.page, let url = sample?.url {
                evidence = RelatedPDFEvidence(url: url, page: page,
                    range: NSRange(location: match.range.location + match.part.offset, length: match.range.length),
                    quote: match.quote)
            } else { evidence = nil }
            if inlineEvidence && (evidence == nil || (match?.overlap ?? 0) < min(2, max(1, anchorTerms.count))) {
                return nil
            }
            return RelatedReadingResult(item: item, similarity: min(1, score), excerpt: match?.quote,
                                        sampledPages: sample?.pages ?? [], pdfEvidence: evidence)
        }.sorted {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            return $0.id.uuidString < $1.id.uuidString
        }
        let results = inlineEvidence ? Array(ranked.lazy.filter { result in
            guard !Task.isCancelled, let evidence = result.pdfEvidence,
                  let document = PDFDocument(url: evidence.url) else { return false }
            return (try? evidence.selection(in: document)) != nil
        }.prefix(2)) : Array(ranked.prefix(40))
        return RelatedReadingReport(results: results, compared: candidates.count,
                                    sampled: candidates.filter { samples[$0.id] != nil }.count, available: pool.count)
    }

    private static func sample(_ target: String, vaults: [RegisteredVault]) -> Sample? {
        guard let link = try? ObsidianLinks.checkedURL(target, vaults: vaults) else { return nil }
        let file: URL
        if link.isFileURL {
            file = link
        } else if link.scheme == "obsidian",
                  let path = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "path" })?.value {
            let exact = URL(fileURLWithPath: path)
            file = FileManager.default.fileExists(atPath: exact.path)
                ? exact : URL(fileURLWithPath: path.components(separatedBy: "#").first ?? path)
        } else {
            return nil
        }
        switch file.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: file), !document.isLocked, document.pageCount > 0 else { return nil }
            let pages = Set([0, document.pageCount / 2, document.pageCount - 1]).sorted()
            var parts: [Part] = []
            for page in pages {
                guard let text = document.page(at: page)?.string else { continue }
                let slice = page == pages.last && page > 0 ? text.suffix(1500) : text.prefix(1500)
                guard !slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                parts.append(Part(text: String(slice), page: page, offset: NSRange(slice.startIndex..<slice.endIndex, in: text).location))
            }
            return parts.isEmpty ? nil : Sample(parts: parts, url: file)
        case "md", "markdown", "txt", "text":
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            do {
                let size = try handle.seekToEnd()
                let width: UInt64 = 4096
                let offsets: [UInt64] = size <= width * 3 ? [0] : [0, size / 2, size - width]
                let parts = try offsets.map { offset in
                    try handle.seek(toOffset: offset)
                    let data = try handle.read(upToCount: offsets.count == 1 ? Int(width * 3) : Int(width)) ?? Data()
                    return String(decoding: data, as: UTF8.self)
                }
                let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : Sample(parts: [Part(text: text)])
            } catch { return nil }
        default:
            return nil
        }
    }

    private static let sourcePhrases = try! NSRegularExpression(pattern: #"[^\r\n。！？!?]+(?:[。！？!?]+[”’」』）》】]*)?"#)
    private static let metadataPrefixes = ["关键词", "中图分类号", "文献标识码", "文章编号", "基金项目",
                                           "收稿日期", "作者简介", "doi", "keywords"]

    private static func comparisonKey(_ text: String) -> String {
        ChineseReading.normalizingGlyphs(text).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func bestExcerpt(in parts: [Part], matching terms: Set<String>, excludingTitle: String?)
        -> (part: Part, range: NSRange, quote: String, overlap: Int)? {
        var best: (Part, NSRange, String, Int)?
        var matches = 0
        var endsSentence = false
        let title = excludingTitle.map(comparisonKey)
        for part in parts {
            let text = part.text
            for phrase in sourcePhrases.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(phrase.range, in: text),
                      let start = text[range].firstIndex(where: { !$0.isWhitespace }) else { continue }
                let excerpt = text[start..<range.upperBound].prefix(150)
                let quote = String(excerpt)
                let terminal = quote.last.map { "。！？.!?」』”".contains($0) } == true
                if let title {
                    let key = comparisonKey(quote)
                    guard key.count >= 14, quote.contains(where: { "。！？!?；;，,.".contains($0) }),
                          !Self.metadataPrefixes.contains(where: { key.hasPrefix($0) }),
                          !title.contains(key), (title.count < 8 || !key.hasPrefix(title)) else { continue }
                }
                let overlap = Set(SemanticIndex.tokens(ChineseReading.reflow(quote))).intersection(terms).count
                if overlap > matches || (title != nil && overlap == matches && matches > 0 && terminal && !endsSentence) {
                    best = (part, NSRange(excerpt.startIndex..<excerpt.endIndex, in: text), quote, overlap)
                    matches = overlap
                    endsSentence = terminal
                }
            }
        }
        return best
    }
}
