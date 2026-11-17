import Foundation
import PDFKit

enum PDFFoldUnit: String, Codable, CaseIterable, Identifiable {
    case chapter, page, group
    var id: Self { self }
    var title: String {
        switch self {
        case .chapter: return "目录章节"
        case .page: return "单页"
        case .group: return "连续页段"
        }
    }
}

struct PDFFoldOptions: Codable, Equatable {
    var unit: PDFFoldUnit = .chapter
    var pages = 3
    var fullPassages = false
}

struct PDFChapter: Identifiable {
    static let batchSize = 8
    let id: Int
    let title: String
    let start: PDFReadingLocation
    let end: PDFReadingLocation?
    let depth: Int

    func pages(total: Int) -> Range<Int> {
        let exclusive = end.map { $0.page + ($0.point == nil ? 0 : 1) } ?? total
        return start.page..<min(total, max(start.page + 1, exclusive))
    }

    func initialPages(around page: Int, total: Int) -> Range<Int> {
        let available = pages(total: total)
        let start = available.contains(page) ? max(available.lowerBound, page - 1) : available.lowerBound
        return start..<min(available.upperBound, start + Self.batchSize)
    }

    func pageLabel(total: Int) -> String {
        let range = pages(total: total)
        if range.count == 1 { return "第 \(start.page + 1) 页" }
        if end?.point != nil { return "第 \(start.page + 1) 页起" }
        return "第 \(start.page + 1)–\(range.upperBound) 页"
    }
}

struct PDFFoldedPage: Identifiable {
    var id: Int
    var passages: [FoldedPDFPassage]
    var hasSourceText: Bool
    var footnotes: [FoldedPDFPassage] = []

    var footnotePosition: PDFFoldPosition {
        PDFFoldPosition(page: id, offset: footnotes.first?.id)
    }
}

struct PDFFoldCorrection: Codable, Equatable {
    let boundary: PDFFoldPosition
    // A left-hand anchor joins two adjacent passages. Without one, the boundary splits a passage.
    var joinAfter: PDFFoldPosition?
}

struct PDFSavedFoldCorrections: Codable, Equatable {
    let revision: String
    let edits: [PDFFoldCorrection]
}

struct PDFSplitChoice: Identifiable {
    let id: PDFFoldPosition
    let text: String
}

struct PDFTextLine {
    let range: NSRange
    let text: String
    var bounds: CGRect?

    static func ranges(in source: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var cursor = 0
        while cursor < source.length {
            var end = 0
            var contentEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: cursor, length: 0))
            result.append(NSRange(location: cursor, length: contentEnd - cursor))
            cursor = end
        }
        return result
    }

    static func lines(in text: String, on page: PDFPage? = nil) -> [Self] {
        let source = text as NSString
        if let page, let selection = page.textSelection(in: NSRange(location: 0, length: source.length)) {
            var result: [Self] = []
            var covered = 0
            for line in selection.selectionsByLine() {
                guard line.numberOfTextRanges(on: page) == 1 else { break }
                let range = line.range(at: 0, on: page)
                guard range.location >= covered, range.location < source.length, range.length > 0,
                      range.length <= source.length - range.location,
                      source.substring(with: NSRange(location: covered, length: range.location - covered))
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                result.append(Self(range: range, text: source.substring(with: range), bounds: line.bounds(for: page)))
                covered = NSMaxRange(range)
            }
            if !result.isEmpty, source.substring(from: covered).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return result }
        }
        return ranges(in: source).map { Self(range: $0, text: source.substring(with: $0)) }
    }
}

struct PDFSentenceHit {
    let id = UUID()
    let page: PDFPage
    let text: String
    let selections: [PDFSelection]
    let suspectedEncodingError: Bool
}

extension PDFPage {
    func textSelection(in range: NSRange) -> PDFSelection? {
        let length = numberOfCharacters
        guard range.length > 0, range.location >= 0, range.location < length, range.length <= length - range.location else { return nil }
        return selection(for: range)
    }

    func sentence(at point: CGPoint) -> PDFSentenceHit? {
        textHit(at: point, wholeParagraph: false, nearby: false)
    }

    func paragraph(at point: CGPoint, nearby: Bool = false) -> PDFSentenceHit? {
        textHit(at: point, wholeParagraph: true, nearby: nearby)
    }

    func correspondingPoint(_ point: CGPoint, from other: PDFPage) -> CGPoint? {
        guard rotation == other.rotation else { return nil }
        let frame = bounds(for: .cropBox), origin = other.bounds(for: .cropBox)
        guard !origin.isEmpty, !frame.isEmpty, origin.contains(point) else { return nil }
        return CGPoint(x: frame.minX + (point.x - origin.minX) * frame.width / origin.width,
                       y: frame.minY + (point.y - origin.minY) * frame.height / origin.height)
    }

    private func textHit(at point: CGPoint, wholeParagraph: Bool, nearby allowNearby: Bool) -> PDFSentenceHit? {
        guard let value = string, !annotations.contains(where: { $0.type == "Link" && $0.bounds.contains(point) }) else { return nil }
        let source = value as NSString
        let charIndex = characterIndex(at: point)
        let offset = charIndex >= 0 && charIndex < source.length && charIndex < numberOfCharacters
            && characterBounds(at: charIndex).contains(point) ? charIndex : nil
        guard offset != nil || allowNearby,
              let allText = textSelection(in: NSRange(location: 0, length: min(source.length, numberOfCharacters))) else { return nil }

        let pageWidth = bounds(for: .cropBox).width
        let lines: [PDFTextLine] = allText.selectionsByLine().flatMap { line in
            let bounds = line.bounds(for: self)
            return (0..<line.numberOfTextRanges(on: self)).flatMap { index -> [PDFTextLine] in
                let range = line.range(at: index, on: self)
                guard range.location < source.length, range.length > 0, range.length <= source.length - range.location else { return [] }
                let parts = bounds.width > pageWidth * 0.53
                    ? splitSentenceLine(range, in: source, gap: max(bounds.height * 1.8, pageWidth * 0.035)) : [range]
                return parts.compactMap { part in
                    let rect = part == range && line.numberOfTextRanges(on: self) == 1 ? bounds : textSelection(in: part)?.bounds(for: self)
                    guard let rect, !rect.isEmpty else { return nil }
                    return PDFTextLine(range: part, text: source.substring(with: part), bounds: rect)
                }
            }
        }
        let hit = offset.flatMap { offset in lines.first { NSLocationInRange(offset, $0.range) } }
            ?? (allowNearby ? nearestTextLine(to: point, in: lines) : nil)
        guard let hit, let column = hit.bounds else { return nil }
        let nearby = lines.filter { line in
            guard let rect = line.bounds else { return false }
            let overlap = min(rect.maxX, column.maxX) - max(rect.minX, column.minX)
            return overlap > min(rect.width, column.width) * 0.5 && abs(rect.minX - column.minX) <= column.height * 3
                && (0.65...1.55).contains(rect.height / column.height)
        }.sorted { ($0.bounds?.midY ?? 0) > ($1.bounds?.midY ?? 0) }
        guard let index = nearby.firstIndex(where: { $0.range == hit.range }) else { return nil }

        func consecutive(_ upper: PDFTextLine, _ lower: PDFTextLine) -> Bool {
            guard let first = upper.bounds, let second = lower.bounds else { return false }
            let height = max(first.height, second.height)
            let step = (first.midY - second.midY) / height
            guard (0.54...1.88).contains(step), min(first.height, second.height) >= height * 0.72 else { return false }
            if first.width < second.width * 0.7 && first.height > second.height * 1.12 { return false }
            if lower.text.hasPrefix("  ") || lower.text.hasPrefix("　") { return false }
            if wholeParagraph {
                if Self.startsBlock(lower.text) { return false }
                if let last = upper.text.trimmingCharacters(in: .whitespacesAndNewlines).last,
                   ".。!?！？”.）»".contains(last),
                   first.maxX + height * 2.6 < second.maxX || abs(second.minX - first.minX) > height * 0.8 { return false }
            }
            let gapStart = NSMaxRange(upper.range)
            if lower.range.location > gapStart {
                let gap = source.substring(with: NSRange(location: gapStart, length: lower.range.location - gapStart))
                if gap.allSatisfy(\.isWhitespace) && gap.filter(\.isNewline).count > 1 { return false }
            }
            return true
        }

        var start = index
        var end = index
        while start > 0, consecutive(nearby[start - 1], nearby[start]) { start -= 1 }
        while end + 1 < nearby.count, consecutive(nearby[end], nearby[end + 1]) { end += 1 }
        var text = ""
        var spans: [(local: NSRange, original: NSRange)] = []
        var position = 0
        for line in nearby[start...end] {
            if !text.isEmpty { text += "\n" }
            let local = NSRange(location: text.utf16.count, length: line.range.length)
            if line.range == hit.range, let offset { position = local.location + offset - hit.range.location }
            spans.append((local: local, original: line.range))
            text += line.text
        }
        let range = wholeParagraph ? NSRange(location: 0, length: text.utf16.count) :
            ReadingSentence.ranges(in: text).first(where: { NSLocationInRange(position, $0) })
        guard let range else { return nil }
        let raw = (text as NSString).substring(with: range)
        guard raw.contains(where: \.isLetter) else { return nil }
        let selections = spans.compactMap { span -> PDFSelection? in
            let part = NSIntersectionRange(span.local, range)
            guard part.length > 0 else { return nil }
            return textSelection(in: NSRange(location: span.original.location + part.location - span.local.location, length: part.length))
        }
        guard !selections.isEmpty else { return nil }
        return PDFSentenceHit(page: self, text: ReadingSentence.translationText(raw), selections: selections,
                              suspectedEncodingError: PDFQuoteQuality.isSuspicious(raw))
    }

    private func nearestTextLine(to point: CGPoint, in lines: [PDFTextLine]) -> PDFTextLine? {
        lines.compactMap { line -> (PDFTextLine, CGFloat)? in
            guard let rect = line.bounds, rect.insetBy(dx: -min(25, rect.height * 1.8), dy: -rect.height * 0.65).contains(point),
                  line.text.contains(where: \.isLetter) else { return nil }
            let dx = max(rect.minX - point.x, point.x - rect.maxX, 0)
            return (line, abs(rect.midY - point.y) + dx)
        }.min { $0.1 < $1.1 }?.0
    }

    private static let blockStart = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:Figure|Fig\.?|Table|图|表)\s*\d{1,4}[:：.\s]|\d{1,3}(?:\.\d{1,3}){1,4}\.?\s+(?=\p{L})|(?:[A-Z][A-Za-z-]*\s*){1,5}[:：])"#
    )

    private static func startsBlock(_ text: String) -> Bool {
        blockStart.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            || PDFOutlineInference.kind(of: text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private func splitSentenceLine(_ range: NSRange, in source: NSString, gap: CGFloat) -> [NSRange] {
        var parts: [NSRange] = []
        var start = range.location
        var previous: (offset: Int, rect: CGRect)?
        for index in range.location..<NSMaxRange(range) {
            if let character = Unicode.Scalar(source.character(at: index)), CharacterSet.whitespacesAndNewlines.contains(character) { continue }
            let rect = characterBounds(at: index)
            guard !rect.isEmpty else { continue }
            if let previous, rect.minX - previous.rect.maxX > gap {
                parts.append(NSRange(location: start, length: previous.offset + 1 - start))
                start = index
            }
            previous = (index, rect)
        }
        parts.append(NSRange(location: start, length: NSMaxRange(range) - start))
        return parts
    }
}

extension PDFReader {
    func academicLayout(at index: Int) -> PDFAcademicLayout? {
        if let cached = academicLayouts[index] { return cached }
        guard let page = sourcePage(at: index), let text = page.string,
              let layout = PDFAcademicLayout(page: page, text: text) else { return nil }
        // The reader may stay open across a long book.
        if academicLayouts.count >= 24 { academicLayouts.removeAll(keepingCapacity: true) }
        academicLayouts[index] = layout
        return layout
    }

    func printedPageLabel(at index: Int) -> String? {
        guard let label = publicationPageLabel(at: index), label != String(index + 1) else { return nil }
        return label
    }

    func publicationPageLabel(at index: Int) -> String? {
        if let cached = printedPageLabels[index] { return cached.isEmpty ? nil : cached }
        let filePage = String(index + 1)
        let embedded = sourcePage(at: index)?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label: String?
        if let embedded, !embedded.isEmpty, embedded != filePage {
            label = embedded
        } else if let footer = academicLayout(at: index)?.footer,
                  [-1, 1].contains(where: { academicLayout(at: index + $0)?.footer?.number == footer.number + $0 }) {
            label = String(footer.number)
        } else {
            label = nil
        }
        printedPageLabels[index] = label ?? ""
        return label
    }

    func pageReference(_ index: Int) -> String {
        let filePage = "PDF 第 \(index + 1) 页"
        return printedPageLabel(at: index).map { filePage + " · 版面 \($0)" } ?? filePage
    }

    func chapters(unit: PDFFoldUnit, groupSize: Int, inferred: [PDFReadingSection] = []) -> [PDFChapter] {
        let total = document.pageCount
        guard total > 0 else { return [] }
        let outline = (navigationSections.isEmpty ? inferred : navigationSections)
            .filter { (0..<total).contains($0.location.page) }
        if unit != .chapter || outline.isEmpty {
            let step = unit == .page ? 1 : max(2, min(groupSize, 20))
            return stride(from: 0, to: total, by: step).map { page in
                let end = min(total, page + step)
                let title = page + 1 == end ? "PDF 第 \(end) 页" : "PDF 第 \(page + 1)–\(end) 页"
                return PDFChapter(id: page, title: title, start: PDFReadingLocation(page: page),
                                  end: PDFReadingLocation(page: end), depth: 0)
            }
        }
        let locations = outline.map(sectionLocation)
        var result = outline.enumerated().map { index, section in
            let start = locations[index]
            let next = outline.indices.dropFirst(index + 1).first {
                outline[$0].depth <= section.depth && isBefore(start, locations[$0])
            }
            return PDFChapter(id: section.id, title: section.title, start: start, end: next.map { locations[$0] }, depth: section.depth)
        }
        if let first = result.first, first.start.page > 0 || hasOpeningText(before: first.start) {
            result.insert(PDFChapter(id: -1, title: "卷首", start: PDFReadingLocation(page: 0), end: first.start, depth: 0), at: 0)
        }
        return result
    }

    private func hasOpeningText(before location: PDFReadingLocation) -> Bool {
        guard let point = location.point, let page = sourcePage(at: location.page), let text = page.string else { return false }
        let layout = academicLayout(at: location.page)
        let lines = layout?.lines ?? PDFTextLine.lines(in: text, on: page)
        return lines.contains { line in
            guard line.text.filter({ $0.isLetter }).count >= 15,
                  layout?.notes.contains(line.range.location) != true,
                  let rect = line.bounds ?? page.textSelection(in: line.range)?.bounds(for: page), !rect.isEmpty else { return false }
            return Self.isAbove(CGPoint(x: rect.minX, y: rect.midY), point, in: layout)
        }
    }

    func chapterAt(_ location: PDFReadingLocation, in chapters: [PDFChapter]) -> PDFChapter? {
        chapters.last { !isBefore(location, $0.start) }
            ?? chapters.first { $0.start.page == location.page } ?? chapters.first
    }

    func currentSectionID(in sections: [PDFReadingSection]) -> Int? {
        sections.last(where: { !isBefore(location, $0.location) })?.id
    }

    func foldPosition(at location: PDFReadingLocation) -> PDFFoldPosition {
        guard let point = location.point, let page = sourcePage(at: location.page),
              let text = page.string else { return PDFFoldPosition(page: location.page) }
        let layout = academicLayout(at: location.page)
        let band = layout?.band(at: point)
        let lines = layout?.lines ?? PDFTextLine.lines(in: text, on: page)
        var best: (offset: Int, distance: CGFloat)?
        for line in lines where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard layout?.notes.contains(line.range.location) != true,
                  let rect = line.bounds ?? page.textSelection(in: line.range)?.bounds(for: page), !rect.isEmpty,
                  layout?.band(at: CGPoint(x: rect.midX, y: rect.midY)) == band else { continue }
            let distance = abs(rect.maxY - point.y)
            if best.map({ distance < $0.distance }) ?? true { best = (line.range.location, distance) }
        }
        return PDFFoldPosition(page: location.page, offset: best?.offset)
    }

    func foldedPage(_ index: Int, in chapter: PDFChapter) -> PDFFoldedPage {
        guard let page = sourcePage(at: index), let text = page.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PDFFoldedPage(id: index, passages: [], hasSourceText: false)
        }
        let from = index == chapter.start.page ? chapter.start.point : nil
        let until = index == chapter.end?.page ? chapter.end?.point : nil
        let chinese = ChineseReading.hasHan(ChineseReading.normalizingGlyphs(text))
        let layout = chinese ? academicLayout(at: index) : nil
        let printedPage = printedPageLabel(at: index)
        guard from != nil || until != nil || chinese else {
            return PDFFoldedPage(id: index, passages: FoldedPDFPassage.split(text), hasSourceText: true)
        }
        var starts = Set<Int>()
        var omitting = Set<Int>()
        var previous: PDFTextLine?
        var continuations = Set<Int>()
        var previousWasList = false
        let crop = page.bounds(for: .cropBox)
        let title = Self.headingKey(chapter.title)
        let lines = layout?.lines ?? PDFTextLine.lines(in: text, on: chinese ? page : nil)
        var noteLines: [NSRange] = []
        var noteStarts = Set<Int>()
        var repeatedHeads = Set<Int>()
        if let layout, !layout.runningHeads.isEmpty {
            for delta in [-2, -1, 1, 2] {
                guard let neighbor = academicLayout(at: index + delta) else { continue }
                for (title, offset) in layout.runningHeads where neighbor.runningHeads[title] != nil {
                    repeatedHeads.insert(offset)
                }
            }
        }
        let confirmedFooter = layout?.footer.flatMap { footer in
            printedPage == String(footer.number) || [-1, 1].contains(where: { academicLayout(at: index + $0)?.footer?.number == footer.number + $0 })
                ? footer.offset : nil
        }
        if let from, !title.isEmpty {
            var prefix = ""
            var headingOffsets: [Int] = []
            let opening = lines.lazy.filter { line in
                guard let rect = line.bounds ?? page.textSelection(in: line.range)?.bounds(for: page), !rect.isEmpty else { return false }
                let point = CGPoint(x: rect.minX, y: rect.midY)
                return !Self.isAbove(point, from, in: layout) && (until.map { Self.isAbove(point, $0, in: layout) } ?? true)
            }
            for line in opening.prefix(3) {
                prefix += Self.headingKey(line.text)
                guard title.hasPrefix(prefix) else { break }
                headingOffsets.append(line.range.location)
                if prefix == title {
                    if headingOffsets.count > 1 { omitting.formUnion(headingOffsets) }
                    break
                }
            }
        }
        for line in lines where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if omitting.contains(line.range.location) { continue }
            guard let rect = line.bounds ?? page.textSelection(in: line.range)?.bounds(for: page), !rect.isEmpty else {
                if from != nil || until != nil { omitting.insert(line.range.location) }
                previous = nil
                continue
            }
            if layout?.notes.contains(line.range.location) == true {
                omitting.insert(line.range.location)
                noteLines.append(line.range)
                if PDFAcademicLayout.marker(in: line.text) != nil { noteStarts.insert(line.range.location) }
                previous = nil
                continue
            }
            let point = CGPoint(x: rect.minX, y: rect.midY)
            guard line.range.location != confirmedFooter, !repeatedHeads.contains(line.range.location),
                  from.map({ !Self.isAbove(point, $0, in: layout) }) ?? true,
                  until.map({ Self.isAbove(point, $0, in: layout) }) ?? true else {
                omitting.insert(line.range.location)
                previous = nil
                continue
            }
            if chinese, index > chapter.start.page, rect.midY >= crop.maxY - crop.height * 0.08,
               Self.headingKey(line.text) == title {
                omitting.insert(line.range.location)
                previous = nil
                continue
            }
            let list = chinese && ChineseReading.isListItem(line.text)
            let reference = chinese && ChineseReading.isBibliographyItem(line.text)
            var measured = line
            measured.bounds = rect
            if let previous, let last = previous.bounds {
                let height = max(last.height, rect.height)
                let gap = last.minY - rect.maxY
                let indent = rect.minX - last.minX
                let changedBand = layout?.band(at: point) != layout?.band(at: CGPoint(x: last.minX, y: last.midY))
                let step = last.midY - rect.midY
                let paragraphGap = layout?.leading.map { step > max($0 * 1.28, $0 + 3) }
                    ?? (gap > max(8, height * 0.65))
                let indented = line.text.hasPrefix("  ") || line.text.hasPrefix("　")
                    || (gap >= -height * 0.5 && indent >= height * 0.8 && indent <= height * 4)
                let changedType = min(last.height, rect.height) < height * 0.82 && (
                    layout?.fitsBodyRhythm(after: last, before: rect) != true
                    || PDFOutlineInference.kind(of: line.text) != nil || PDFOutlineInference.kind(of: previous.text) != nil
                )
                if !previousWasList, layout?.continuesAcrossColumns(after: previous, before: measured) == true {
                    continuations.insert(line.range.location)
                    starts.insert(line.range.location)
                } else if changedBand || paragraphGap || rect.midY > last.midY + height ||
                    (chinese && (indented || list || reference || previousWasList || changedType)) {
                    starts.insert(line.range.location)
                } else if let layout, let leading = layout.leading, step > leading * 0.7,
                          layout.repairedLines.contains(previous.range.location) || layout.repairedLines.contains(line.range.location) {
                    continuations.insert(line.range.location)
                }
            }
            previous = measured
            previousWasList = list
        }
        let blocks = FoldedPDFPassage.split(text, lines: lines.map(\.range), starts: starts, omitting: omitting,
                                            layoutAware: layout?.leading != nil || (chinese && !starts.isEmpty))
        var passages: [FoldedPDFPassage] = []
        for block in blocks {
            if continuations.contains(block.id), let previous = passages.popLast() {
                passages.append(previous.appending(block, on: index))
            } else {
                passages.append(block)
            }
        }
        let footnotes = FoldedPDFPassage.split(text, lines: noteLines, starts: noteStarts, layoutAware: true)
        return PDFFoldedPage(id: index, passages: passages, hasSourceText: true, footnotes: footnotes)
    }

    func stitchFoldedPages(_ previous: inout PDFFoldedPage, _ next: inout PDFFoldedPage) {
        guard let tail = previous.passages.last, let head = next.passages.first,
              let tailSource = tail.sources(startingOn: previous.id).last, tailSource.page + 1 == next.id,
              let from = academicLayout(at: tailSource.page), let to = academicLayout(at: next.id),
              let end = from.lines.last(where: { NSLocationInRange($0.range.location, tailSource.range) }),
              let start = to.lines.first(where: { $0.range.location == head.id }),
              PDFOutlineInference.kind(of: start.text.precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)) == nil,
              from.continuesOnto(to, after: end, before: start) else { return }
        previous.passages[previous.passages.count - 1] = tail.appending(head, on: next.id)
        next.passages.removeFirst()
    }

    func stitchedFoldPages(_ pages: [PDFFoldedPage]) -> [PDFFoldedPage] {
        var result = pages
        var lastText: Int?
        for index in result.indices {
            if let lastText {
                var previous = result[lastText]
                stitchFoldedPages(&previous, &result[index])
                result[lastText] = previous
            }
            if !result[index].passages.isEmpty { lastText = index }
        }
        return result
    }

    func splitChoices(for passage: FoldedPDFPassage, page: Int) -> [PDFSplitChoice] {
        passage.sources(startingOn: page).flatMap { source -> [PDFSplitChoice] in
            guard let original = sourcePage(at: source.page), let text = original.string else { return [] }
            let lines = academicLayout(at: source.page)?.lines ?? PDFTextLine.lines(in: text, on: original)
            return lines.compactMap { line in
                guard NSLocationInRange(line.range.location, source.range),
                      source.page != page || line.range.location != passage.id,
                      !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return PDFSplitChoice(id: PDFFoldPosition(page: source.page, offset: line.range.location),
                                      text: ChineseReading.reflow(line.text))
            }
        }
    }

    func correctedFoldPages(_ input: [PDFFoldedPage]) -> [PDFFoldedPage] {
        guard !foldCorrections.isEmpty, !input.isEmpty else { return input }
        var pages = input
        for correction in foldCorrections {
            let boundary = correction.boundary
            guard let offset = boundary.offset, let end = pages.firstIndex(where: { $0.id == boundary.page }) else { continue }
            if let after = correction.joinAfter {
                guard let start = pages.firstIndex(where: { $0.id == after.page }), start <= end,
                      let left = pages[start].passages.firstIndex(where: { $0.id == after.offset }),
                      let right = pages[end].passages.firstIndex(where: { $0.id == offset }) else { continue }
                let adjacent = start == end ? left + 1 == right :
                    left == pages[start].passages.count - 1 && right == 0 &&
                    pages[(start + 1)..<end].allSatisfy { $0.passages.isEmpty && $0.hasSourceText }
                guard adjacent else { continue }
                let tail = pages[end].passages.remove(at: right)
                pages[start].passages[left] = pages[start].passages[left].appending(tail, on: boundary.page)
            } else {
                // An automatic continuation may own the beginning of the following page.
                for start in pages.indices.reversed() where start <= end {
                    guard let index = pages[start].passages.firstIndex(where: { passage in
                        passage.sources(startingOn: pages[start].id).contains {
                            $0.page == boundary.page && NSLocationInRange(offset, $0.range)
                        }
                    }) else { continue }
                    if let (before, after) = split(pages[start].passages[index], on: pages[start].id, at: boundary) {
                        pages[start].passages[index] = before
                        pages[end].passages.insert(after, at: start == end ? index + 1 : 0)
                    }
                    break
                }
            }
        }
        return pages
    }

    private func split(_ passage: FoldedPDFPassage, on page: Int,
                       at boundary: PDFFoldPosition) -> (FoldedPDFPassage, FoldedPDFPassage)? {
        let ranges = passage.sources(startingOn: page)
        guard let offset = boundary.offset, let index = ranges.firstIndex(where: {
            $0.page == boundary.page && NSLocationInRange(offset, $0.range)
        }) else { return nil }
        let current = ranges[index].range
        var leading = Array(ranges[..<index])
        if offset > current.location {
            leading.append(.init(page: boundary.page, range: NSRange(location: current.location, length: offset - current.location)))
        }
        let trailing = [FoldedPDFPassage.Source(page: boundary.page, range: NSRange(location: offset, length: NSMaxRange(current) - offset))]
            + ranges.dropFirst(index + 1)
        guard let left = passageFromSources(leading), let right = passageFromSources(trailing) else { return nil }
        return (left, right)
    }

    private func passageFromSources(_ sources: [FoldedPDFPassage.Source]) -> FoldedPDFPassage? {
        var result: FoldedPDFPassage?
        for source in sources {
            guard let text = sourcePage(at: source.page)?.string as NSString?,
                  source.range.length > 0, NSMaxRange(source.range) <= text.length else { return nil }
            let part = FoldedPDFPassage(range: source.range, text: text.substring(with: source.range))
            result = result?.appending(part, on: source.page) ?? part
        }
        return result
    }

    func sectionLocation(_ section: PDFReadingSection) -> PDFReadingLocation {
        guard (hasAuthorOutline && savedOutline.isEmpty) || section.location.point == nil else { return section.location }
        guard let page = sourcePage(at: section.location.page), let text = page.string else { return section.location }
        let ns = text as NSString
        let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2 else { return section.location }
        let key = Self.headingKey(title)
        let matches = PDFTextLine.lines(in: text, on: page).filter { Self.headingKey($0.text) == key }.compactMap { line in
            line.bounds ?? page.textSelection(in: line.range)?.bounds(for: page)
        }.filter { !$0.isEmpty }
        let box = page.bounds(for: .cropBox)
        let targetY = section.location.point?.y ?? box.maxY
        let exact = matches.count > 1 && targetY >= box.maxY - 8
            ? matches.first(where: { $0.midY < box.maxY - box.height * 0.08 })
            : matches.min(by: { abs($0.maxY - targetY) < abs($1.maxY - targetY) })
        let range = ns.range(of: title, options: [.caseInsensitive, .diacriticInsensitive])
        if let bounds = exact ?? page.textSelection(in: range)?.bounds(for: page), !bounds.isEmpty,
           section.location.point.map({ abs($0.y - bounds.maxY) < 100 || $0.y >= box.maxY - 8 }) ?? true {
            return PDFReadingLocation(page: section.location.page, point: CGPoint(x: bounds.minX, y: bounds.maxY))
        }
        return section.location
    }

    static func headingKey(_ value: String) -> String {
        ChineseReading.normalizingGlyphs(value).precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }.lowercased()
    }

    private static func isAbove(_ first: CGPoint, _ second: CGPoint, in layout: PDFAcademicLayout?, tolerance: CGFloat = 2) -> Bool {
        if let layout {
            let left = layout.band(at: first)
            let right = layout.band(at: second)
            if left != right { return left < right }
        }
        return first.y >= second.y + tolerance
    }

    private func isBefore(_ first: PDFReadingLocation, _ second: PDFReadingLocation) -> Bool {
        if first.page != second.page { return first.page < second.page }
        if first.point == nil { return second.point != nil }
        guard let left = first.point, let right = second.point else { return false }
        return Self.isAbove(left, right, in: academicLayout(at: first.page), tolerance: 1.01)
    }
}
