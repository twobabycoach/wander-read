import Foundation
import PDFKit

enum PDFOutlineInference {
    static let pageLimit = 1200

    private static let formal = try! NSRegularExpression(
        pattern: #"^第\s*[0-9〇零一二三四五六七八九十百千万萬两兩壹贰貳叁參肆伍陆陸柒捌玖拾]+\s*([篇部卷编編章回讲講节節])(?:\s*[:、.])?\s*([^。！？!?；;]*)$"#
    )
    private static let numbered = try! NSRegularExpression(
        pattern: #"^([一二三四五六七八九十百]+(?:[、.：:]|\s+)|\([一二三四五六七八九十百]+\)|\d+(?:\.\d+){1,3}\s+|\d+[、.]\s*)\s*[^。！？!?；;]+$"#
    )
    private static let named = try! NSRegularExpression(
        pattern: #"^(前言|序言|绪论|緒論|引言|导言|導言|结语|結語|结论|結論|后记|後記|参考文献|參考文獻|附录|附錄)(?:\s*[：:]\s*[^。！？!?；;]+)?$"#
    )
    private static let leaders = try! NSRegularExpression(pattern: #"[.·…⋯・_。]{2,}\s*(?:[0-9]{1,5}|[ivxlcdmIVXLCDM]+)\s*$"#)
    private static let sequence = try! NSRegularExpression(pattern: #"^([一二三四五六七八九十百]+|[0-9]+)\s*[、.:：]\s*(?![0-9])"#)

    private struct Heading {
        let title: String
        let key: String
        let page: Int
        let band: Int
        let rect: CGRect
        let kind: Int
        let position: CGFloat
        let prominent: Bool
        let wrapped: Bool
        let ordinal: Int?
        var score: Int { (prominent ? 2 : 0) + (wrapped ? 2 : 0) + (position < 0.9 ? 1 : 0) }
    }

    private struct Line {
        let text: String
        let rect: CGRect
        let band: Int
    }

    static func detect(at url: URL) -> [PDFReadingSection] {
        guard let document = PDFDocument(url: url), !document.isLocked else { return [] }
        return detect(in: document, cancelled: { Task.isCancelled })
    }

    static func detect(in document: PDFDocument, cancelled: () -> Bool = { false }) -> [PDFReadingSection] {
        guard (1...pageLimit).contains(document.pageCount) else { return [] }
        var candidates: [Heading] = []
        for index in 0..<document.pageCount {
            guard !cancelled() else { return [] }
            autoreleasepool {
                guard let page = document.page(at: index), page.rotation == 0,
                      let text = page.string, ChineseReading.hasHan(text) else { return }
                let layout = PDFAcademicLayout(page: page, text: text)
                let raw = layout?.lines ?? PDFTextLine.lines(in: text, on: page)
                guard !looksLikeContents(raw) else { return }
                let box = page.bounds(for: .cropBox)
                guard box.width > 0, box.height > 0 else { return }
                let lines = raw.compactMap { line -> Line? in
                    guard layout?.notes.contains(line.range.location) != true,
                          let rect = line.bounds ?? page.textSelection(in: line.range)?.bounds(for: page), !rect.isEmpty else { return nil }
                    let text = ChineseReading.normalizingGlyphs(line.text).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return Line(text: text, rect: rect, band: layout?.band(at: CGPoint(x: rect.midX, y: rect.midY)) ?? 0)
                }
                for (offset, line) in lines.enumerated() {
                    let label = clean(line.text)
                    guard let kind = kind(of: label), !matches(leaders, label) else { continue }
                    let rect = line.rect
                    let position = (rect.midY - box.minY) / box.height
                    guard (0.045...0.97).contains(position), rect.width < box.width * 0.9 else { continue }
                    let nearby = lines.dropFirst(offset + 1).prefix(6).prefix { $0.band == line.band }
                    let tail = continuation(of: line, in: nearby)
                    let bodyRect = nearby.dropFirst(tail == nil ? 0 : 1).first {
                        $0.text.count >= 16 && kindOfBody(clean($0.text)) && $0.rect.midY < rect.midY
                    }?.rect
                    let prominent = bodyRect.map { $0.height > 0 && rect.height >= $0.height * 1.18 } ?? false
                    let ordinal = kind == 3 ? sequenceNumber(label) : nil
                    let short = bodyRect.map { rect.width < $0.width * 0.86 } ?? (label.count <= 16)
                    let separated = bodyRect.map { rect.midY - $0.midY >= (layout?.leading ?? $0.height * 1.3) * 1.23 } ?? false
                    guard prominent || (kind <= 2 && short && position <= 0.92) ||
                          (ordinal != nil && (tail != nil || (short && separated))) else { continue }
                    let title = tail.map { joinedTitle(line.text, $0.text) } ?? line.text
                    candidates.append(Heading(title: title, key: clean(title).filter { !$0.isWhitespace }, page: index,
                                              band: line.band, rect: rect, kind: kind, position: position,
                                              prominent: prominent, wrapped: tail != nil, ordinal: ordinal))
                }
            }
        }
        var unique: [Heading] = []
        for group in Dictionary(grouping: candidates, by: \.key).values {
            guard let first = group.max(by: { $0.score < $1.score }) else { continue }
            // The title repeated in the same high margin is usually a running head.
            if group.count > 1 && group.allSatisfy({ $0.position >= 0.87 && !$0.prominent }) { continue }
            unique.append(first)
        }
        let sorted = unique.sorted { a, b in
            if a.page != b.page { return a.page < b.page }
            if a.band != b.band { return a.band < b.band }
            if a.rect.midY != b.rect.midY { return a.rect.midY > b.rect.midY }
            return a.rect.minX < b.rect.minX
        }
        let supported = supportedSequence(in: sorted)
        let hasFormal = sorted.contains { $0.kind <= 2 }
        let hasChapter = sorted.contains { $0.kind == 1 }
        let hasPart = sorted.contains { $0.kind == 0 }
        let selected = sorted.filter { heading in
            if hasFormal { return heading.kind <= 2 || heading.kind == 5 }
            return heading.kind >= 3 && (heading.prominent || supported.contains(heading.key))
        }
        guard selected.count >= 2 else { return [] }
        return selected.enumerated().map { index, heading in
            let depth: Int
            switch heading.kind {
            case 1: depth = hasPart ? 1 : 0
            case 2: depth = (hasChapter ? 1 : 0) + (hasPart ? 1 : 0)
            case 4: depth = selected.contains(where: { $0.kind == 3 }) ? 1 : 0
            default: depth = 0
            }
            return PDFReadingSection(id: index, title: heading.title,
                                     location: PDFReadingLocation(page: heading.page, point: CGPoint(x: heading.rect.minX, y: heading.rect.maxY)),
                                     depth: depth)
        }
    }

    static func joinedTitle(_ head: String, _ tail: String) -> String {
        if let last = head.last, let first = tail.first,
           last.isASCII, first.isASCII,
           (last.isLetter || last.isNumber), (first.isLetter || first.isNumber) {
            return head + " " + tail
        }
        return head + tail
    }

    private static func continuation(of head: Line, in nearby: ArraySlice<Line>) -> Line? {
        guard let tail = nearby.first, let body = nearby.dropFirst().first,
              ChineseReading.hasHan(tail.text), kindOfBody(clean(tail.text)), kindOfBody(clean(body.text)),
              !tail.text.contains(where: { "。！？!?；;".contains($0) }), body.text.count >= 14 else { return nil }
        let a = head.rect, b = tail.rect, c = body.rect
        let step = a.midY - b.midY
        let height = a.height
        guard (height * 0.65...height * 1.75).contains(step),
              (height * 0.86...height * 1.13).contains(b.height),
              abs(a.minX - b.minX) <= height * 2.7, a.minX < b.maxX, b.minX < a.maxX,
              abs(a.maxX - c.maxX) <= height * 1.25, a.width >= c.width * 0.8,
              b.width < c.width * 0.9, c.midY < b.midY,
              b.midY - c.midY >= step + height * 0.15 else { return nil }
        return tail
    }

    private static func sequenceNumber(_ title: String) -> Int? {
        guard let match = sequence.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) else { return nil }
        let prefix = (title as NSString).substring(with: match.range(at: 1))
        if let number = Int(prefix) { return number }
        let digits = "零一二三四五六七八九"
        func digit(_ text: Substring) -> Int? {
            guard text.count == 1, let first = text.first, let index = digits.firstIndex(of: first) else { return nil }
            return digits.distance(from: digits.startIndex, to: index)
        }
        let parts = prefix.split(separator: "十", omittingEmptySubsequences: false)
        if parts.count == 1 { return digit(parts[0]) }
        guard parts.count == 2, let tens = parts[0].isEmpty ? 1 : digit(parts[0]),
              let ones = parts[1].isEmpty ? 0 : digit(parts[1]) else { return nil }
        return tens * 10 + ones
    }

    private static func supportedSequence(in headings: [Heading]) -> Set<String> {
        var run: [Heading] = []
        var supported = Set<String>()
        func record() {
            // A local numbered list alone is insufficient evidence of chapter structure.
            if run.count >= 3, run.first?.page != run.last?.page { supported.formUnion(run.map(\.key)) }
            run.removeAll(keepingCapacity: true)
        }
        for heading in headings where heading.ordinal != nil {
            if let previous = run.last, let number = previous.ordinal, let current = heading.ordinal,
               current - 1 != number || !(0.79...1.27).contains(heading.rect.height / previous.rect.height) {
                record()
            }
            run.append(heading)
        }
        record()
        return supported
    }

    private static func clean(_ value: String) -> String {
        ChineseReading.normalizingGlyphs(value).precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeContents(_ lines: [PDFTextLine]) -> Bool {
        let top = lines.prefix(8).map { clean($0.text).filter { !$0.isWhitespace }.lowercased() }
        if top.contains(where: { ["目录", "目錄", "目次", "contents", "tableofcontents"].contains($0) }) { return true }
        let leadersCount = lines.reduce(0) { $0 + (matches(leaders, clean($1.text)) ? 1 : 0) }
        return leadersCount >= 2 && leadersCount * 3 >= lines.count
    }

    private static func kindOfBody(_ text: String) -> Bool { kind(of: text) == nil && !matches(leaders, text) }

    static func kind(of text: String) -> Int? {
        guard (2...62).contains(text.count), ChineseReading.hasHan(text) else { return nil }
        let compact = ChineseReading.compactHanSpacing(text)
        if let match = formal.firstMatch(in: compact, range: NSRange(compact.startIndex..., in: compact)) {
            let level = (compact as NSString).substring(with: match.range(at: 1))
            let title = (compact as NSString).substring(with: match.range(at: 2))
            guard title.count <= 52, !title.contains(where: { "，,；;。！？!?".contains($0) }) else { return nil }
            if "篇部卷编編".contains(level) { return 0 }
            return "章回讲講".contains(level) ? 1 : 2
        }
        if matches(numbered, text), !text.contains(where: { "，,。！？!?".contains($0) }) {
            return text.hasPrefix("(") ? 4 : 3
        }
        return matches(named, text) ? 5 : nil
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
