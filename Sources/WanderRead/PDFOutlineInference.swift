import AppKit
import PDFKit

struct PDFOutlineTypography {
    private let attributes: NSAttributedString
    private let bodyFace: String

    init?(page: PDFPage, text: String, lines: [PDFTextLine]) {
        guard let attributes = page.attributedString, attributes.string == text else { return nil }
        let prose = lines.lazy.filter { $0.text.count >= 24 && PDFOutlineHierarchy.marker($0.text) == nil }
            .prefix(16)
        let faces = prose.compactMap { Self.face(in: attributes, range: $0.range) }
        let counts = Dictionary(grouping: faces, by: { $0 }).mapValues(\.count)
        guard let face = Self.dominant(in: counts), (counts[face] ?? 0) >= 2 else { return nil }
        self.attributes = attributes
        bodyFace = face
    }

    func distinguishes(_ range: NSRange) -> Bool {
        Self.face(in: attributes, range: range).map { $0 != bodyFace } ?? false
    }

    private static func face(in attributes: NSAttributedString, range: NSRange) -> String? {
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= attributes.length else { return nil }
        var counts: [String: Int] = [:]
        attributes.enumerateAttribute(.font, in: range) { value, run, _ in
            if let font = value as? NSFont { counts[font.fontName, default: 0] += run.length }
        }
        return dominant(in: counts)
    }

    private static func dominant(in counts: [String: Int]) -> String? {
        guard let best = counts.max(by: { $0.value < $1.value }),
              counts.values.filter({ $0 == best.value }).count == 1 else { return nil }
        return best.key
    }
}

enum PDFOutlineHierarchy {
    static let editableDepth = 7
    static let maximumDepth = 31

    struct Marker {
        let order: Int
        let kind: Int
        var decimal: [Int] = []
    }

    struct Evidence {
        let title: String
        var height: CGFloat?
        var indent: CGFloat?
        var fallback = 0
        var confirmedDepth: Int?
    }

    private static let formal = try! NSRegularExpression(
        pattern: #"^第\s*[0-9〇零一二三四五六七八九十百千万萬两兩壹贰貳叁參肆伍陆陸柒捌玖拾\s]+([篇部卷编編章回讲講节節])"#
    )
    private static let english = try! NSRegularExpression(
        pattern: #"^(part|book|volume|chapter|section)\s+(?:[0-9]+|[ivxlcdm]+)(?:\b|[.:])"#, options: .caseInsensitive
    )
    private static let decimal = try! NSRegularExpression(
        pattern: #"^([0-9]{1,3}(?:\.[0-9]{1,3}){0,6})([.、:)]\s*(?!\d)|\s+|(?=\p{Han}))(?=\p{L}|[《〈「“])"#
    )
    private static let hanOrdinal = try! NSRegularExpression(pattern: #"^[一二三四五六七八九十百]+(?:[、.:]\s*|\s+)\S"#)
    private static let hanParenthesis = try! NSRegularExpression(pattern: #"^\(\s*[一二三四五六七八九十百]+\s*\)\s*\S"#)
    private static let digitParenthesis = try! NSRegularExpression(pattern: #"^(?:\((?:[0-9]{1,3}|[a-zA-Z])\)|[a-zA-Z]\))\s*\S"#)
    private static let roman = try! NSRegularExpression(pattern: #"^[IVXLCDM]{1,7}\.\s+(?=\p{L})"#)
    private static let date = try! NSRegularExpression(pattern: #"^[0-9〇○零一二三四五六七八九十]{2,4}年[0-9〇○零一二三四五六七八九十]{1,3}月(?:[0-9〇○零一二三四五六七八九十]{1,3}日)?$"#)
    private static let landmark = try! NSRegularExpression(
        pattern: #"^(?:(?:前言|序言|绪论|緒論|引言|导言|導言|结语|結語|结论|結論|后记|後記|参考文献|參考文獻|附录|附錄)(?:\s*[:]\s*[^。！？!?；;]+)?|上编|中编|下编|上編|中編|下編|abstract|introduction|conclusions?|references|acknowledgments?|appendix(?:\s+[a-z0-9]+)?)$"#,
        options: .caseInsensitive
    )

    static func marker(_ title: String) -> Marker? {
        let text = ChineseReading.normalizingGlyphs(title).precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...120).contains(text.count), !text.contains(where: { "。！？!?；;".contains($0) }) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        if let match = formal.firstMatch(in: text, range: range), let unit = Range(match.range(at: 1), in: text) {
            let value = text[unit]
            let kind = "篇部卷编編".contains(value) ? 0 : "章回讲講".contains(value) ? 1 : 2
            return Marker(order: kind * 10, kind: kind)
        }
        if let match = english.firstMatch(in: text, range: range), let unit = Range(match.range(at: 1), in: text) {
            let value = text[unit].lowercased()
            let kind = value == "chapter" ? 1 : value == "section" ? 2 : 0
            return Marker(order: kind * 10, kind: kind)
        }
        if ["上编", "中编", "下编", "上編", "中編", "下編"].contains(where: { text.hasPrefix($0) }) {
            return Marker(order: 0, kind: 0)
        }
        if landmark.firstMatch(in: text, range: range) != nil {
            let name = text.split(separator: ":", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
            let introductory = ["前言", "序言", "绪论", "緒論", "引言", "导言", "導言", "introduction"].contains { $0 == name }
            return Marker(order: introductory ? 15 : -1, kind: 5)
        }
        if !text.contains(where: { "，,".contains($0) }) {
            if hanOrdinal.firstMatch(in: text, range: range) != nil {
                let compact = text.filter { !$0.isWhitespace }
                let range = NSRange(compact.startIndex..., in: compact)
                if date.firstMatch(in: compact, range: range) == nil { return Marker(order: 30, kind: 3) }
            }
            if hanParenthesis.firstMatch(in: text, range: range) != nil { return Marker(order: 40, kind: 4) }
            if roman.firstMatch(in: text, range: range) != nil { return Marker(order: 45, kind: 3) }
            if let match = decimal.firstMatch(in: text, range: range), let prefix = Range(match.range(at: 1), in: text) {
                let parts = text[prefix].split(separator: ".").compactMap { Int($0) }
                if parts.count > 1 || match.range(at: 2).length > 0 {
                    return Marker(order: 50 + parts.count, kind: 3, decimal: parts)
                }
            }
            if digitParenthesis.firstMatch(in: text, range: range) != nil { return Marker(order: 60, kind: 4) }
        }
        return nil
    }

    static func depths(_ headings: [Evidence]) -> [Int] {
        // The open headings are the ancestors of the last item, in document order.
        var branch: [(evidence: Evidence, marker: Marker?)] = []
        return headings.map { heading in
            let marker = marker(heading.title)
            let guessed: Int
            if let depth = heading.confirmedDepth {
                guessed = depth
            } else if marker?.kind == 5 {
                guessed = 0
            } else if let parent = branch.lastIndex(where: { ancestor in
                if let mark = ancestor.marker, let marker {
                    guard mark.order >= 0, mark.order < marker.order else { return false }
                    return mark.decimal.isEmpty || marker.decimal.isEmpty || marker.decimal.starts(with: mark.decimal)
                }
                if let order = ancestor.marker?.order, order < 0 { return false }
                if let left = ancestor.evidence.indent, let right = heading.indent { return (7...72).contains(right - left) }
                if let large = ancestor.evidence.height, let small = heading.height { return large >= small * 1.14 }
                return false
            }) {
                guessed = parent + 1
            } else {
                guessed = marker == nil ? heading.fallback : 0
            }
            let limit = heading.confirmedDepth == nil ? editableDepth : maximumDepth
            let depth = min(max(0, guessed), branch.count, limit)
            branch.removeLast(branch.count - depth)
            branch.append((heading, marker))
            return depth
        }
    }

    static func visibleSections(_ sections: [PDFReadingSection], collapsed: Set<Int>) -> [PDFReadingSection] {
        var hiddenBelow: Int?
        return sections.filter { section in
            if let hiddenBelow, section.depth > hiddenBelow { return false }
            hiddenBelow = collapsed.contains(section.id) ? section.depth : nil
            return true
        }
    }

    static func ancestors(of id: Int?, in sections: [PDFReadingSection]) -> Set<Int> {
        guard let id else { return [] }
        var branch: [PDFReadingSection] = []
        for section in sections {
            while let previous = branch.last, previous.depth >= section.depth { branch.removeLast() }
            if section.id == id { return Set(branch.map(\.id)) }
            branch.append(section)
        }
        return []
    }
}

enum PDFOutlineInference {
    static let pageLimit = 1200

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
        let isolated: Bool
        let wrapped: Bool
        let ordinal: Int?
    }

    private struct Line {
        let text: String
        let rect: CGRect
        let band: Int
        let distinctFace: Bool
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
                guard let page = document.page(at: index), page.rotation == 0, let text = page.string else { return }
                let layout = PDFAcademicLayout(page: page, text: text)
                let raw = layout?.lines ?? PDFTextLine.lines(in: text, on: page)
                guard !looksLikeContents(raw) else { return }
                let typography = PDFOutlineTypography(page: page, text: text, lines: raw)
                let box = page.bounds(for: .cropBox)
                guard box.width > 0, box.height > 0 else { return }
                let lines = raw.compactMap { line -> Line? in
                    guard layout?.notes.contains(line.range.location) != true,
                          let rect = line.bounds ?? page.textSelection(in: line.range)?.bounds(for: page), !rect.isEmpty else { return nil }
                    let text = ChineseReading.normalizingGlyphs(line.text).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return Line(text: text, rect: rect, band: layout?.band(at: CGPoint(x: rect.midX, y: rect.midY)) ?? 0,
                                distinctFace: typography?.distinguishes(line.range) == true)
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
                    let ordinal = kind == 3 ? sequenceNumber(label) : nil
                    let short = bodyRect.map { rect.width < $0.width * 0.86 } ?? (label.count <= 16)
                    let prominent = (short && line.distinctFace) || (bodyRect.map { rect.height >= $0.height * 1.18 } ?? false)
                    let leading = layout?.leading ?? (bodyRect?.height ?? rect.height) * 1.3
                    let preceding = offset > 0 && lines[offset - 1].band == line.band ? lines[offset - 1].rect : nil
                    let following = nearby.dropFirst(tail == nil ? 0 : 1).first?.rect
                    let isolated = short && (preceding.map { $0.midY - rect.midY > leading * 1.19 } ?? true)
                        && (following.map { (tail?.rect.midY ?? rect.midY) - $0.midY > leading * 1.19 } ?? false)
                    guard prominent || (kind <= 2 && short && position <= 0.92) ||
                          isolated || (ordinal != nil && (tail != nil || short)) else { continue }
                    let title = tail.map { joinedTitle(line.text, $0.text) } ?? line.text
                    candidates.append(Heading(title: title, key: clean(title).filter { !$0.isWhitespace }, page: index,
                                              band: line.band, rect: rect, kind: kind, position: position,
                                              prominent: prominent, isolated: isolated, wrapped: tail != nil, ordinal: ordinal))
                }
            }
        }
        let frequency = Dictionary(grouping: candidates, by: \.key).mapValues(\.count)
        let sorted = candidates.filter { ($0.position < 0.90 || $0.prominent || frequency[$0.key, default: 0] == 1) }.sorted { a, b in
            if a.page != b.page { return a.page < b.page }
            if a.band != b.band { return a.band < b.band }
            if a.rect.midY != b.rect.midY { return a.rect.midY > b.rect.midY }
            return a.rect.minX < b.rect.minX
        }
        let supported = supportedSequence(in: sorted)
        let selected = sorted.filter { heading in
            heading.kind <= 2 || heading.prominent || heading.isolated || heading.wrapped || supported.contains(heading.key)
        }
        guard selected.count >= 2 else { return [] }
        let depths = PDFOutlineHierarchy.depths(selected.map { .init(title: $0.title, height: $0.rect.height) })
        return selected.enumerated().map { index, heading in
            return PDFReadingSection(id: index, title: heading.title,
                                     location: PDFReadingLocation(page: heading.page, point: CGPoint(x: heading.rect.minX, y: heading.rect.maxY)),
                                     depth: depths[index])
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
        return wrappedTitle(head: head.rect, tail: tail.rect, body: body.rect) ? tail : nil
    }

    static func wrappedTitle(head a: CGRect, tail b: CGRect, body c: CGRect) -> Bool {
        let step = a.midY - b.midY
        let height = a.height
        let leftAligned = abs(a.minX - b.minX) <= height * 2.7
        let centered = abs(a.midX - b.midX) <= height * 0.8
        return (height * 0.65...height * 1.75).contains(step)
            && (height * 0.84...height * 1.15).contains(b.height)
            && (leftAligned || centered) && a.minX < b.maxX && b.minX < a.maxX
            && abs(a.maxX - c.maxX) <= height * 2.0 && a.width >= c.width * 0.65
            && b.width < c.width * 0.9 && c.midY < b.midY
            && b.midY - c.midY >= step + height * 0.15
    }

    private static func sequenceNumber(_ title: String) -> Int? {
        guard let match = sequence.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) else { return nil }
        let prefix = (title as NSString).substring(with: match.range(at: 1))
        if let number = Int(prefix) {
            let rest = title.dropFirst(prefix.count).drop(while: \.isWhitespace)
            return rest.first == "、" ? nil : number
        }
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
        PDFOutlineHierarchy.marker(text)?.kind
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
