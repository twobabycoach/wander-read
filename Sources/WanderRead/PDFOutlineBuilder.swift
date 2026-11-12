import Foundation
import PDFKit

struct PDFOutlineCandidate: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var depth = 0
    var location: PDFReadingLocation?
    var needsReview = false
    var printedLabel: String?
    var isPending: Bool { needsReview || location == nil }

    static func sections(from entries: [Self], pageCount: Int) -> [PDFReadingSection]? {
        guard !entries.isEmpty else { return nil }
        var result: [PDFReadingSection] = []
        for entry in entries {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.needsReview, !title.isEmpty, title.count <= 200,
                  let location = entry.location, (0..<pageCount).contains(location.page),
                  location.page >= (result.last?.location.page ?? 0),
                  location.point.map({ $0.x.isFinite && $0.y.isFinite }) ?? true else { return nil }
            let depth = max(0, min(entry.depth, 4, (result.last?.depth ?? -1) + 1))
            result.append(PDFReadingSection(id: result.count, title: title, location: location, depth: depth,
                                            printedLabel: entry.printedLabel))
        }
        return result
    }
}

enum PDFOutlineBuilder {
    static let scanPageLimit = 24
    private static let extraOCRLimit = 40
    private static let contentsNames: Set<String> = ["目录", "目錄", "目次", "contents", "tableofcontents"]
    private static let rowPattern = try! NSRegularExpression(
        pattern: #"^(.+?)(\s*[.·…⋯・_。•]{2,}\s*|\s+)([0-9]{1,5}|[ivxlcdm]{1,8})\s*$"#,
        options: [.caseInsensitive]
    )
    private static let leftPattern = try! NSRegularExpression(
        pattern: #"^([0-9]{1,5}|[ivxlcdm]{1,8})(?:\s+|(?=\p{Han}))(.+)$"#, options: [.caseInsensitive]
    )
    private static let pagePattern = try! NSRegularExpression(
        pattern: #"^[-—–－\s]*([0-9]{1,5}|[ivxlcdm]{1,8})[-—–－\s]*$"#,
        options: [.caseInsensitive]
    )

    private struct Line {
        let text: String
        let bounds: CGRect
    }

    private struct Entry {
        let title: String
        let label: String?
        let x: CGFloat
        let hasLeaders: Bool
    }

    private struct Hit {
        let location: PDFReadingLocation
        let inMargin: Bool
    }

    static func generate(at url: URL, scanRange: Range<Int>? = nil, autoScan: Bool = false) -> [PDFOutlineCandidate] {
        guard let document = PDFDocument(url: url), !document.isLocked else { return [] }
        return generate(in: document, scanRange: scanRange, autoScan: autoScan, cancelled: { Task.isCancelled })
    }

    static func generate(in document: PDFDocument, scanRange: Range<Int>? = nil, autoScan: Bool = false,
                         cancelled: () -> Bool = { false }) -> [PDFOutlineCandidate] {
        let pages = 0..<document.pageCount
        let search = (scanRange ?? 0..<scanPageLimit).clamped(to: pages)
        let useOCR = scanRange != nil || autoScan
        var scanned: [Int: [Line]] = [:]
        var entries: [Entry] = []
        var contents = Set<Int>()
        for index in search.prefix(scanPageLimit) {
            guard !cancelled() else { return [] }
            autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let text = nativeLines(page)
                let scanPage = text.isEmpty && (scanRange != nil || (autoScan && index < 12))
                let lines = scanPage ? ocrLines(page) : text
                if scanPage { scanned[index] = lines }
                let rows = contentsRows(lines)
                let named = lines.prefix(8).contains { contentsNames.contains(key($0.text)) }
                let leaders = rows.filter(\.hasLeaders).count
                let previousPage = entries.compactMap { $0.label.flatMap(Int.init) }.last
                let nextPage = rows.compactMap { $0.label.flatMap(Int.init) }.first
                let continuation = contents.contains(index - 1) && rows.count >= 2 && rows.count * 3 >= lines.count &&
                    nextPage.map { $0 >= (previousPage ?? 0) } == true
                guard !rows.isEmpty, named || continuation || (leaders >= 2 && rows.count * 2 >= lines.count) else { return }
                contents.insert(index)
                entries += rows
            }
        }
        guard let lastContents = contents.max(), !entries.isEmpty else {
            let native = PDFOutlineInference.detect(in: document, cancelled: cancelled).map {
                PDFOutlineCandidate(title: $0.title, depth: $0.depth, location: $0.location)
            }
            return native.isEmpty && useOCR && !cancelled() ? scannedHeadings(scanned) : native
        }

        let titles = Set(entries.map { key($0.title) })
        var hits: [String: [Hit]] = [:]
        var footers: [Int: String] = [:]
        var embedded: [String: [Int]] = [:]
        func indexLines(_ lines: [Line], at index: Int, on page: PDFPage) {
            let crop = page.bounds(for: .cropBox)
            if let label = page.label, label != String(index + 1), let number = pageNumber(label) {
                embedded[number, default: []].append(index)
            }
            let bottom = lines.filter { $0.bounds.midY < crop.minY + crop.height * 0.10 }.compactMap { pageNumber($0.text) }
            if bottom.count == 1 { footers[index] = bottom[0] }
            for (offset, line) in lines.enumerated() {
                let position = (line.bounds.midY - crop.minY) / crop.height
                guard position >= 0.10, position <= 0.98 else { continue }
                var title = key(line.text)
                var previous = line.bounds
                if !titles.contains(title) {
                    for next in lines.dropFirst(offset + 1).prefix(2) {
                        let rect = next.bounds
                        let step = previous.midY - rect.midY
                        guard step > 2, step <= max(previous.height, rect.height) * 2.5,
                              abs(previous.minX - rect.minX) <= crop.width * 0.12,
                              previous.minX < rect.maxX, rect.minX < previous.maxX else { break }
                        title += key(next.text)
                        if titles.contains(title) { break }
                        previous = rect
                    }
                }
                guard titles.contains(title) else { continue }
                let origin = CGPoint(x: line.bounds.minX, y: line.bounds.maxY)
                hits[title, default: []].append(Hit(location: PDFReadingLocation(page: index, point: origin),
                                                    inMargin: position >= 0.90))
            }
        }

        for index in pages.prefix(PDFOutlineInference.pageLimit) where !contents.contains(index) {
            guard !cancelled() else { return [] }
            autoreleasepool {
                guard let page = document.page(at: index) else { return }
                indexLines(scanned[index] ?? nativeLines(page), at: index, on: page)
            }
        }
        if useOCR {
            var budget = extraOCRLimit
            func inspect(_ index: Int) {
                guard budget > 0, !cancelled(), pages.contains(index), index > lastContents, scanned[index] == nil,
                      let page = document.page(at: index), nativeLines(page).isEmpty else { return }
                budget -= 1
                autoreleasepool {
                    let lines = ocrLines(page)
                    scanned[index] = lines
                    indexLines(lines, at: index, on: page)
                }
            }
            // Establish the first printed-to-file-page anchor even after front matter.
            for index in (lastContents + 1)..<min(pages.upperBound, lastContents + 10) {
                inspect(index)
                if entries.contains(where: { $0.label.flatMap(Int.init) != nil && preferredHit(hits[key($0.title)] ?? []) != nil }) { break }
            }
            var anchor = entries.compactMap { entry -> (Int, Int)? in
                guard let number = entry.label.flatMap(Int.init), let hit = preferredHit(hits[key(entry.title)] ?? []) else { return nil }
                return (number, hit.page)
            }.first
            if anchor == nil {
                anchor = footers.keys.sorted().first { $0 > lastContents && verifiedFooter(at: $0, in: footers) }
                    .flatMap { index in footers[index].flatMap(Int.init).map { ($0, index) } }
            }
            if let initial = anchor {
                var estimates: [(Entry, Int)] = []
                for entry in entries {
                    guard !cancelled() else { return [] }
                    guard let number = entry.label.flatMap(Int.init), budget > 0 else { continue }
                    let known = anchor ?? initial
                    let guess = known.1 + (number - known.0)
                    estimates.append((entry, guess))
                    inspect(guess)
                    if let hit = preferredHit(hits[key(entry.title)] ?? []),
                       (hit.page == guess || (footers[hit.page] == entry.label && verifiedFooter(at: hit.page, in: footers))),
                       !conflictsWithFooter(number, at: hit.page, in: footers) { anchor = (number, hit.page) }
                    else if footers[guess] == entry.label, verifiedFooter(at: guess, in: footers) { anchor = (number, guess) }
                }
                // Check the likely chapter page for every entry before spending the remaining budget nearby.
                for (entry, guess) in estimates {
                    for delta in [-1, 1] where preferredHit(hits[key(entry.title)] ?? []) == nil {
                        inspect(guess + delta)
                    }
                }
            }
        }
        guard !cancelled() else { return [] }
        let verifiedFooters = footers.keys.filter { verifiedFooter(at: $0, in: footers) }.sorted()
        let footersByLabel = Dictionary(grouping: verifiedFooters, by: { footers[$0] ?? "" })
        let verifiedPages = entries.map { entry in
            Set((embedded[entry.label ?? ""] ?? []) + (footersByLabel[entry.label ?? ""] ?? []))
        }
        let matches = entries.enumerated().map { index, entry in
            let exact = hits[key(entry.title)] ?? []
            let verified = exact.filter { verifiedPages[index].contains($0.location.page) }
            return preferredHit(verified) ?? preferredHit(exact)
        }
        let conflicts = entries.indices.map { index in
            guard let number = entries[index].label.flatMap(Int.init), let page = matches[index]?.page,
                  !verifiedPages[index].contains(page) else { return false }
            return conflictsWithFooter(number, at: page, in: footers)
        }
        let anchors = entries.indices.compactMap { index -> (Int, Int, Int)? in
            guard !conflicts[index], let number = entries[index].label.flatMap(Int.init),
                  let page = matches[index]?.page else { return nil }
            return (index, number, page)
        }
        let depths = entryDepths(entries)
        var previous = -1
        return entries.enumerated().map { index, entry in
            let exact = matches[index].flatMap { $0.page >= previous ? $0 : nil }
            let byLabel = verifiedPages[index]
                .filter { $0 >= previous && !contents.contains($0) }
            let anchor = anchors.min { abs($0.0 - index) < abs($1.0 - index) }
            let estimate = entry.label.flatMap(Int.init).flatMap { number -> Int? in
                if let anchor { return anchor.2 + number - anchor.1 }
                let offsets = Set(verifiedFooters.compactMap { page in footers[page].flatMap(Int.init).map { page - $0 } })
                return offsets.count == 1 ? offsets.first.map { $0 + number } : nil
            }
                ?? (entry.label == nil ? matches.dropFirst(index + 1).compactMap { $0?.page }.first : nil)
            let guess = (byLabel.count == 1 ? byLabel.first : estimate).flatMap { page in
                pages.contains(page) && page >= previous && !contents.contains(page) ? PDFReadingLocation(page: page) : nil
            }
            if let exact, !conflicts[index] { previous = exact.page }
            return PDFOutlineCandidate(title: entry.title, depth: depths[index], location: exact ?? guess,
                                       needsReview: exact == nil || conflicts[index], printedLabel: entry.label)
        }
    }

    private static func preferredHit(_ hits: [Hit]) -> PDFReadingLocation? {
        let body = hits.filter { !$0.inMargin }
        let possible = body.isEmpty ? hits : body
        return possible.count == 1 ? possible[0].location : nil
    }

    private static func verifiedFooter(at index: Int, in labels: [Int: String]) -> Bool {
        guard let number = labels[index].flatMap(Int.init) else { return false }
        return [-1, 1].contains { labels[index + $0] == String(number + $0) }
    }

    private static func conflictsWithFooter(_ number: Int, at index: Int, in labels: [Int: String]) -> Bool {
        let nearby = Set((-2...2).compactMap { delta -> Int? in
            let page = index + delta
            guard verifiedFooter(at: page, in: labels), let value = labels[page].flatMap(Int.init) else { return nil }
            return value - delta
        })
        return nearby.count == 1 && !nearby.contains(number)
    }

    private static func nativeLines(_ page: PDFPage) -> [Line] {
        guard page.rotation == 0, let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return PDFTextLine.lines(in: text, on: page).compactMap { line in
            guard let rect = line.bounds ?? page.textSelection(in: line.range)?.bounds(for: page), !rect.isEmpty else { return nil }
            return Line(text: line.text, bounds: rect)
        }
    }

    private static func ocrLines(_ page: PDFPage) -> [Line] {
        guard page.rotation == 0 else { return [] }
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 0, crop.height > 0 else { return [] }
        let scale = 2350 / max(crop.width, crop.height)
        let size = CGSize(width: crop.width * scale, height: crop.height * scale)
        // Small print is easier to read from the lossless page image.
        guard let image = page.thumbnail(of: size, for: .cropBox).tiffRepresentation,
              let observations = try? PDFScan.recognizeLines(image) else { return [] }
        return observations.map { line in
            let rect = line.bounds
            return Line(text: line.text, bounds: CGRect(x: crop.minX + rect.minX * crop.width, y: crop.minY + rect.minY * crop.height,
                                                        width: rect.width * crop.width, height: rect.height * crop.height))
        }.sorted { $0.bounds.midY > $1.bounds.midY }
    }

    private static func contentsRows(_ lines: [Line]) -> [Entry] {
        var rows: [Entry] = []
        var previousRow = -1
        var consumed = Set<Int>()
        for (index, line) in lines.enumerated() {
            guard !consumed.contains(index) else { continue }
            let text = normalized(line.text)
            let numberAtLeft = lines.last {
                abs($0.bounds.midY - line.bounds.midY) <= max(2, line.bounds.height * 0.46) &&
                    $0.bounds.maxX < line.bounds.minX && pageNumber($0.text) != nil
            }
            let numberAtRight = lines.first {
                abs($0.bounds.midY - line.bounds.midY) <= max(2, line.bounds.height * 0.46) &&
                    $0.bounds.minX > line.bounds.maxX && pageNumber($0.text) != nil
            }
            let joined = numberAtLeft.map { normalized($0.text) + "  " + text }
                ?? numberAtRight.map { text + "  " + normalized($0.text) } ?? text
            let source = joined as NSString
            let range = NSRange(joined.startIndex..., in: joined)
            var title: String
            let label: String?
            let leaders: Bool
            let mayWrapForward: Bool
            var x = line.bounds.minX
            if let match = leftPattern.firstMatch(in: joined, range: range) {
                title = source.substring(with: match.range(at: 2))
                label = pageNumber(source.substring(with: match.range(at: 1)))
                leaders = false
                mayWrapForward = true
            } else if let match = rowPattern.firstMatch(in: joined, range: range) {
                title = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                label = pageNumber(source.substring(with: match.range(at: 3)))
                leaders = source.substring(with: match.range(at: 2)).contains { !$0.isWhitespace }
                mayWrapForward = false
                if index > previousRow + 1, PDFOutlineInference.kind(of: title) == nil {
                    let prior = lines[index - 1]
                    let head = normalized(prior.text)
                    let step = prior.bounds.midY - line.bounds.midY
                    let height = prior.bounds.height
                    if PDFOutlineInference.kind(of: head).map({ $0 < 5 }) == true,
                       (height * 0.65...height * 1.65).contains(step),
                       (height * 0.82...height * 1.2).contains(line.bounds.height),
                       abs(prior.bounds.minX - x) <= height * 2.5 {
                        title = PDFOutlineInference.joinedTitle(head, title)
                        x = prior.bounds.minX
                    }
                }
            } else if isPart(text) {
                title = text
                label = nil
                leaders = false
                mayWrapForward = true
            } else {
                continue
            }
            if mayWrapForward, ChineseReading.hasHan(title),
               let nextIndex = (index + 1..<min(index + 4, lines.count)).first(where: { pageNumber(lines[$0].text) == nil }),
               let tail = contentsContinuation(lines[nextIndex], after: line, in: lines) {
                title = PDFOutlineInference.joinedTitle(title, tail)
                consumed.insert(nextIndex)
            }
            guard (2...160).contains(title.count), !contentsNames.contains(key(title)), title.contains(where: \.isLetter) else { continue }
            rows.append(Entry(title: title, label: label, x: x, hasLeaders: leaders))
            previousRow = index
        }
        return rows
    }

    private static func contentsContinuation(_ line: Line, after head: Line, in lines: [Line]) -> String? {
        let tail = normalized(line.text)
        let range = NSRange(tail.startIndex..., in: tail)
        let step = head.bounds.midY - line.bounds.midY
        let height = head.bounds.height
        guard (height * 0.65...height * 1.85).contains(step),
              (height * 0.7...height * 1.3).contains(line.bounds.height),
              abs(line.bounds.minX - head.bounds.minX) <= height * 2.7,
              line.bounds.width < head.bounds.width * 0.9, ChineseReading.hasHan(tail),
              PDFOutlineInference.kind(of: tail) == nil, !isPart(tail),
              leftPattern.firstMatch(in: tail, range: range) == nil, rowPattern.firstMatch(in: tail, range: range) == nil,
              !lines.contains(where: {
                  abs($0.bounds.midY - line.bounds.midY) <= max(2, line.bounds.height * 0.46) &&
                  ($0.bounds.maxX < line.bounds.minX || $0.bounds.minX > line.bounds.maxX) && pageNumber($0.text) != nil
              }) else { return nil }
        return tail
    }

    private static func entryDepths(_ entries: [Entry]) -> [Int] {
        let kinds = entries.map { isPart($0.title) ? 0 : PDFOutlineInference.kind(of: $0.title) }
        let hasPart = kinds.contains(0)
        let hasChapter = kinds.contains(1)
        let baseline = entries.map(\.x).min() ?? 0
        var previous = -1
        return entries.enumerated().map { index, entry in
            let level: Int
            switch kinds[index] {
            case 0: level = 0
            case 1: level = hasPart ? 1 : 0
            case 2: level = (hasPart ? 1 : 0) + (hasChapter ? 1 : 0)
            case 3: level = hasPart ? 1 : 0
            case 4: level = kinds.contains(3) ? 1 : 0
            case 5: level = 0
            default: level = hasPart && kinds.contains(3) ? 2 : Int(max(0, entry.x - baseline) / 13)
            }
            previous = min(level, previous + 1, 4)
            return previous
        }
    }

    private static func isPart(_ title: String) -> Bool {
        ["上编", "中编", "下编", "上編", "中編", "下編"].contains { title.filter { !$0.isWhitespace }.hasPrefix($0) }
    }

    private static func scannedHeadings(_ scanned: [Int: [Line]]) -> [PDFOutlineCandidate] {
        scanned.keys.sorted().compactMap { index in
            guard let heading = scanned[index]?.prefix(8).first(where: {
                PDFOutlineInference.kind(of: normalized($0.text)).map { $0 <= 2 } ?? false
            }) else { return nil }
            return PDFOutlineCandidate(title: heading.text, location: PDFReadingLocation(page: index,
                point: CGPoint(x: heading.bounds.minX, y: heading.bounds.maxY)), needsReview: true)
        }
    }

    private static func pageNumber(_ value: String) -> String? {
        let text = normalized(value)
        guard let match = pagePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let number = (text as NSString).substring(with: match.range(at: 1))
        return Int(number).map(String.init) ?? number.lowercased()
    }

    private static func normalized(_ text: String) -> String {
        ChineseReading.normalizingGlyphs(text).precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func key(_ text: String) -> String {
        normalized(text.trimmingCharacters(in: CharacterSet(charactersIn: "①②③④⑤⑥⑦⑧⑨⑩＊*").union(.whitespacesAndNewlines)))
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
