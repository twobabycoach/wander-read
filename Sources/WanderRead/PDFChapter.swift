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

struct PDFChapter: Identifiable {
    let id: Int
    let title: String
    let start: PDFReadingLocation
    let end: PDFReadingLocation?
    let depth: Int

    func pages(total: Int) -> Range<Int> {
        let exclusive = end.map { $0.page + ($0.point == nil ? 0 : 1) } ?? total
        return start.page..<min(total, max(start.page + 1, exclusive))
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

extension PDFPage {
    func textSelection(in range: NSRange) -> PDFSelection? {
        let length = numberOfCharacters
        guard range.length > 0, range.location >= 0, range.location < length, range.length <= length - range.location else { return nil }
        return selection(for: range)
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
        if let cached = printedPageLabels[index] { return cached.isEmpty ? nil : cached }
        let filePage = String(index + 1)
        let embedded = sourcePage(at: index)?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label: String?
        if let embedded, !embedded.isEmpty, embedded != filePage {
            label = embedded
        } else if let footer = academicLayout(at: index)?.footer,
                  [-1, 1].contains(where: { academicLayout(at: index + $0)?.footer?.number == footer.number + $0 }),
                  String(footer.number) != filePage {
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
        let outline = hasAuthorOutline ? sections : (savedOutline.isEmpty ? inferred : savedOutline)
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
        let locations = hasAuthorOutline ? outline.map(headingLocation) : outline.map(\.location)
        var result = outline.enumerated().map { index, section in
            let start = locations[index]
            let next = outline.indices.dropFirst(index + 1).first {
                outline[$0].depth <= section.depth && isBefore(start, locations[$0])
            }
            return PDFChapter(id: section.id, title: section.title, start: start, end: next.map { locations[$0] }, depth: section.depth)
        }
        if let first = result.first, first.start.page > 0 || (!hasAuthorOutline && hasOpeningText(before: first.start)) {
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
        guard next.id == previous.id + 1, let tail = previous.passages.last, let head = next.passages.first,
              let from = academicLayout(at: previous.id), let to = academicLayout(at: next.id),
              let tailRange = tail.sources(startingOn: previous.id).last?.range,
              let end = from.lines.last(where: { NSLocationInRange($0.range.location, tailRange) }),
              let start = to.lines.first(where: { $0.range.location == head.id }),
              PDFOutlineInference.kind(of: start.text.precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)) == nil,
              from.continuesOnto(to, after: end, before: start) else { return }
        previous.passages[previous.passages.count - 1] = tail.appending(head, on: next.id)
        next.passages.removeFirst()
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

    private func headingLocation(_ section: PDFReadingSection) -> PDFReadingLocation {
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
