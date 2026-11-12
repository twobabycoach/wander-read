import Foundation
import PDFKit

// Geometry is used only for horizontally typeset pages with a Chinese text layer.
struct PDFAcademicLayout {
    private static let footerNumber = try! NSRegularExpression(pattern: #"^(?:[·—–－-]\s*)?([0-9]{1,5})(?:\s*[·—–－-])?$"#)
    private static let noteNumber = try! NSRegularExpression(pattern: #"^(?:([①-⑳])|[\[［〔]([0-9]{1,2})[\]］〕]|([0-9]{1,2})(?![0-9])[.．、]?)\s*(?=[\p{L}《〈“「])"#)
    private static let imprintMarker = try! NSRegularExpression(
        pattern: #"^(?:[〔\[【]?\s*(?:收稿日期|基金项目|作者简介)\s*[〕\]】:：]|[＊*]\s*本文(?:系|为))"#
    )

    let lines: [PDFTextLine]
    let notes: Set<Int>
    let footer: (number: Int, offset: Int)?
    let runningHeads: [String: Int]
    let leading: CGFloat?
    private let columns: Columns?
    let repairedLines: Set<Int>
    private let crop: CGRect
    private let bodyHeight: CGFloat
    private let proseFrames: [Int: ProseFrame]

    init?(page: PDFPage, text: String) {
        guard page.rotation == 0, ChineseReading.hasHan(ChineseReading.normalizingGlyphs(text)) else { return nil }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        crop = box
        let measured = PDFTextLine.lines(in: text, on: page).map { line in
            var line = line
            line.bounds = line.bounds ?? page.textSelection(in: line.range)?.bounds(for: page)
            return line
        }
        let positioned = measured.filter { $0.bounds.map { !$0.isEmpty } == true }
        let long = positioned.filter { $0.text.count >= 12 && ($0.bounds?.width ?? 0) >= box.width * 0.22 }
        let heights = long.compactMap { $0.bounds?.height }.sorted()
        let bodyHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
        self.bodyHeight = bodyHeight
        var heads: [String: Int] = [:]
        let headTrim = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "·—–－-"))
        for line in positioned {
            guard let rect = line.bounds, line.text.count >= 7, ChineseReading.hasHan(line.text),
                  rect.midY > box.maxY - box.height * 0.12 else { continue }
            let lower = positioned.compactMap(\.bounds).filter {
                $0.minX < rect.maxX && rect.minX < $0.maxX && rect.midY - $0.midY > bodyHeight * 0.85
            }.map(\.midY).max()
            guard rect.height <= bodyHeight * 0.96 ||
                lower.map({ rect.midY - $0 > bodyHeight * 1.75 }) == true else { continue }
            let compact = ChineseReading.normalizingGlyphs(line.text).filter { !$0.isWhitespace }
            let key = compact.trimmingCharacters(in: headTrim)
            heads[key] = line.range.location
        }
        runningHeads = heads
        footer = Self.footer(in: positioned, box: box)
        notes = Self.notes(in: positioned, box: box, bodyHeight: bodyHeight)
            .union(Self.imprintNotes(in: positioned, box: box, bodyHeight: bodyHeight))
        var grid = positioned.count == measured.count ? Columns(in: long, box: box, bodyHeight: bodyHeight) : nil
        var repaired: [Int: [PDFTextLine]] = [:]
        if let candidate = grid {
            for line in long {
                guard let bounds = line.bounds, candidate.crossesGutter(bounds) else { continue }
                guard let fragments = candidate.separate(line, on: page, source: text as NSString) else {
                    grid = nil
                    repaired.removeAll()
                    break
                }
                repaired[line.range.location] = fragments
            }
        }
        columns = grid
        repairedLines = Set(repaired.values.flatMap { $0.map { $0.range.location } })
        // Retain the PDF's sequence if its geometry is incomplete or a wide block interrupts the columns.
        let ordered: [PDFTextLine]
        if let grid {
            ordered = measured.flatMap { repaired[$0.range.location] ?? [$0] }.sorted { a, b in
                guard let left = a.bounds, let right = b.bounds else { return a.range.location < b.range.location }
                let aBand = grid.band(at: CGPoint(x: left.midX, y: left.midY))
                let bBand = grid.band(at: CGPoint(x: right.midX, y: right.midY))
                if aBand != bBand { return aBand < bBand }
                if left.midY == right.midY {
                    return left.minX == right.minX ? a.range.location < b.range.location : left.minX < right.minX
                }
                return left.midY > right.midY
            }
        } else {
            ordered = measured
        }
        lines = ordered
        // The vertical distance between lines is stable when their glyph bounds vary.
        let noteOffsets = notes
        let headOffsets = Set(heads.values)
        let prose = ordered.filter { line in
            guard let rect = line.bounds else { return false }
            return !noteOffsets.contains(line.range.location) && !headOffsets.contains(line.range.location)
                && rect.width >= box.width * 0.22 && (bodyHeight * 0.82...bodyHeight * 1.2).contains(rect.height)
        }
        let steps = zip(prose, prose.dropFirst()).compactMap { first, second -> CGFloat? in
            guard let upper = first.bounds, let lower = second.bounds,
                  upper.minX < lower.maxX && lower.minX < upper.maxX,
                  abs(upper.minX - lower.minX) <= bodyHeight * 3 else { return nil }
            let step = upper.midY - lower.midY
            return (bodyHeight * 0.55...bodyHeight * 2.45).contains(step) ? step : nil
        }.sorted()
        leading = steps.count >= 3 ? steps[steps.count / 2] : nil
        let byBand = Dictionary(grouping: prose.compactMap(\.bounds)) { rect in
            grid?.band(at: CGPoint(x: rect.midX, y: rect.midY)) ?? 0
        }
        proseFrames = byBand.compactMapValues(ProseFrame.init)
    }

    func band(at point: CGPoint) -> Int { columns?.band(at: point) ?? 0 }

    func continuesAcrossColumns(after previous: PDFTextLine, before next: PDFTextLine) -> Bool {
        guard let columns, let left = previous.bounds, let right = next.bounds,
              band(at: CGPoint(x: left.midX, y: left.midY)) == 1,
              band(at: CGPoint(x: right.midX, y: right.midY)) == 2,
              columns.hasContinuation(from: left, to: right) else { return false }
        return ChineseReading.canContinueParagraph(after: previous.text, before: next.text)
    }

    func fitsBodyRhythm(after previous: CGRect, before next: CGRect) -> Bool {
        let column = band(at: CGPoint(x: next.midX, y: next.midY))
        guard column == band(at: CGPoint(x: previous.midX, y: previous.midY)),
              let frame = proseFrames[column], let leading else { return false }
        return (leading * 0.72...leading * 1.25).contains(previous.midY - next.midY)
            && previous.maxX >= frame.right - leading * 0.7 && abs(next.minX - frame.left) <= leading * 0.45
    }

    func continuesOnto(_ next: Self, after last: PDFTextLine, before first: PDFTextLine) -> Bool {
        guard (columns == nil) == (next.columns == nil),
              let fromStep = leading, let toStep = next.leading, (0.8...1.25).contains(fromStep / toStep),
              let from = proseFrames[columns == nil ? 0 : 2], let to = next.proseFrames[next.columns == nil ? 0 : 1],
              let end = last.bounds, let start = first.bounds,
              band(at: CGPoint(x: end.midX, y: end.midY)) == (columns == nil ? 0 : 2),
              next.band(at: CGPoint(x: start.midX, y: start.midY)) == (next.columns == nil ? 0 : 1),
              (bodyHeight * 0.8...bodyHeight * 1.28).contains(end.height),
              (next.bodyHeight * 0.8...next.bodyHeight * 1.28).contains(start.height),
              end.midY <= from.bottom + fromStep * 1.3, isPageTail(end),
              start.midY >= max(to.top - toStep * 1.2, next.crop.maxY - next.crop.height * 0.2),
              start.midY <= to.top + toStep * 2.2,
              end.maxX >= from.right - fromStep * 0.7,
              abs(start.minX - to.left) <= toStep * 0.62 else { return false }
        return ChineseReading.canContinueParagraph(after: last.text, before: first.text)
    }

    private func isPageTail(_ rect: CGRect) -> Bool {
        if rect.midY <= crop.minY + crop.height * 0.38 { return true }
        // On a footnote-heavy page, the body can stop well above the page margin.
        return rect.midY <= crop.minY + crop.height * 0.55 && lines.contains {
            guard notes.contains($0.range.location), let note = $0.bounds else { return false }
            return note.midY < rect.minY && note.minX < rect.maxX && rect.minX < note.maxX
        }
    }

    private struct ProseFrame {
        let left: CGFloat
        let right: CGFloat
        let top: CGFloat
        let bottom: CGFloat

        init?(_ lines: [CGRect]) {
            guard lines.count >= 3, let top = lines.map(\.midY).max(), let bottom = lines.map(\.midY).min() else { return nil }
            left = lines.map(\.minX).sorted()[lines.count / 5]
            right = lines.map(\.maxX).sorted()[lines.count * 4 / 5]
            self.top = top
            self.bottom = bottom
        }
    }

    private struct Columns {
        let split: CGFloat
        let top: CGFloat
        let bottom: CGFloat
        let leftEnd: CGFloat
        let rightStart: CGFloat
        let leftBottom: CGFloat
        let rightTop: CGFloat
        let bodyHeight: CGFloat

        init?(in lines: [PDFTextLine], box: CGRect, bodyHeight: CGFloat) {
            let body = lines.compactMap(\.bounds).filter { $0.height >= bodyHeight * 0.89 && $0.height <= bodyHeight * 1.35 }
            let left = body.filter { $0.maxX <= box.midX && $0.maxX > box.midX - box.width * 0.08 }
            let right = body.filter { $0.minX >= box.midX && $0.minX < box.midX + box.width * 0.08 }
            guard left.count >= 4, right.count >= 3,
                  let leftTop = left.map(\.midY).max(), let rightTop = right.map(\.midY).max(),
                  let leftBottom = left.map(\.midY).min(), let rightBottom = right.map(\.midY).min(),
                  min(leftTop, rightTop) - max(leftBottom, rightBottom) >= bodyHeight * 2.25 else { return nil }
            top = max(leftTop, rightTop) + bodyHeight * 0.8
            bottom = min(leftBottom, rightBottom) - bodyHeight * 0.8
            self.leftBottom = leftBottom
            self.rightTop = rightTop
            split = box.midX
            let leftEdges = left.map(\.maxX).sorted()
            let rightEdges = right.map(\.minX).sorted()
            leftEnd = leftEdges[leftEdges.count * 3 / 4]
            rightStart = rightEdges[rightEdges.count / 4]
            self.bodyHeight = bodyHeight
        }

        func crossesGutter(_ bounds: CGRect) -> Bool {
            bounds.minX < split - bodyHeight && bounds.maxX > split + bodyHeight
                && (bottom...top).contains(bounds.midY)
                && (bodyHeight * 0.89...bodyHeight * 1.35).contains(bounds.height)
        }

        func separate(_ line: PDFTextLine, on page: PDFPage, source: NSString) -> [PDFTextLine]? {
            // PDFKit can return one range for two unrelated lines sharing a baseline.
            var runs: [(range: NSRange, bounds: CGRect, left: Bool)] = []
            for offset in line.range.location..<NSMaxRange(line.range) {
                let glyph = NSRange(location: offset, length: 1)
                guard !source.substring(with: glyph).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let bounds = page.characterBounds(at: offset)
                guard !bounds.isEmpty else { return nil }
                let left = bounds.midX < split
                if let last = runs.last, last.left == left {
                    runs[runs.count - 1] = (NSUnionRange(last.range, glyph), last.bounds.union(bounds), left)
                } else {
                    runs.append((glyph, bounds, left))
                }
            }
            guard runs.count == 2, let left = runs.first(where: { $0.left }), let right = runs.first(where: { !$0.left }),
                  left.bounds.width >= bodyHeight * 8, right.bounds.width >= bodyHeight * 8,
                  right.bounds.minX - left.bounds.maxX >= bodyHeight * 0.42,
                  abs(left.bounds.maxX - leftEnd) <= bodyHeight,
                  abs(right.bounds.minX - rightStart) <= bodyHeight else { return nil }
            return runs.map { PDFTextLine(range: $0.range, text: source.substring(with: $0.range), bounds: $0.bounds) }
        }

        func band(at point: CGPoint) -> Int {
            if point.y > top { return 0 }
            if point.y < bottom { return 3 }
            return point.x < split ? 1 : 2
        }

        func hasContinuation(from left: CGRect, to right: CGRect) -> Bool {
            left.midY <= leftBottom + bodyHeight * 1.8 && right.midY >= rightTop - bodyHeight * 1.8
                && left.maxX >= leftEnd - bodyHeight * 1.1
                && (rightStart - bodyHeight...rightStart + bodyHeight * 0.8).contains(right.minX)
                && [left, right].allSatisfy { (bodyHeight * 0.8...bodyHeight * 1.3).contains($0.height) }
        }
    }

    private static func footer(in lines: [PDFTextLine], box: CGRect) -> (Int, Int)? {
        let candidates = lines.compactMap { line -> (Int, Int)? in
            guard let rect = line.bounds, rect.midY < box.minY + box.height * 0.09, rect.width < box.width * 0.17 else { return nil }
            let text = line.text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = footerNumber.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let number = Int((text as NSString).substring(with: match.range(at: 1))) else { return nil }
            return (number, line.range.location)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func notes(in lines: [PDFTextLine], box: CGRect, bodyHeight: CGFloat) -> Set<Int> {
        guard bodyHeight > 0 else { return [] }
        let low = lines.filter { line in
            guard let rect = line.bounds else { return false }
            return rect.midY < box.minY + box.height * 0.39 && rect.midY > box.minY + box.height * 0.06
        }
        let noteHeight = bodyHeight * 0.92
        let first = low.filter { ($0.bounds?.height ?? 0) <= noteHeight }
        let markers = low.compactMap { line -> (PDFTextLine, Int)? in
            guard let number = marker(in: line.text), let rect = line.bounds else { return nil }
            // A superscript can inflate the glyph box of the first line of a footnote.
            let compactContinuation = first.contains {
                guard let b = $0.bounds else { return false }
                return rect.midY > b.midY && rect.midY - b.midY <= bodyHeight * 1.4
                    && b.minX >= rect.minX && b.minX <= rect.minX + bodyHeight * 1.4
            }
            guard rect.height <= noteHeight || (rect.height <= bodyHeight * 1.1 && compactContinuation) else { return nil }
            return (line, number)
        }
        let markerOffsets = Set(markers.map { $0.0.range.location })
        var result = Set<Int>()
        for (line, number) in markers {
            guard let rect = line.bounds else { continue }
            let pair = markers.contains { candidate, next in
                guard let bounds = candidate.bounds else { return false }
                return next == number + 1 && abs(bounds.minX - rect.minX) <= bodyHeight * 0.8 &&
                    rect.midY > bounds.midY && rect.midY - bounds.midY < bodyHeight * 4
            }
            let single = line.text.trimmingCharacters(in: .whitespacesAndNewlines).first.map { "①②③④⑤⑥⑦⑧⑨⑩".contains($0) } == true
                && line.text.contains("《") && line.text.count >= 12
            guard pair || single else { continue }
            let columnEnd = rect.maxX > box.midX && rect.minX < box.midX ? box.maxX : rect.midX < box.midX ? box.midX : box.maxX
            let tail = low.filter { candidate in
                guard let b = candidate.bounds else { return false }
                let sameIndent = abs(b.minX - rect.minX) < bodyHeight
                return b.midY <= rect.midY && b.minX >= rect.minX - bodyHeight * 2 &&
                    (b.maxX <= columnEnd + 2 || (sameIndent && hasBrokenGlyph(candidate.text)))
            }.sorted { ($0.bounds?.midY ?? 0) > ($1.bounds?.midY ?? 0) }
            var previous = rect.midY
            for candidate in tail {
                guard let b = candidate.bounds, previous - b.midY <= bodyHeight * 1.6 else { break }
                guard b.height <= noteHeight || markerOffsets.contains(candidate.range.location)
                        || hasBrokenGlyph(candidate.text) else { break }
                result.insert(candidate.range.location)
                previous = b.midY
            }
        }
        return result
    }

    private static func hasBrokenGlyph(_ text: String) -> Bool { text.unicodeScalars.contains { $0.value == 0 } }

    private static func imprintNotes(in lines: [PDFTextLine], box: CGRect, bodyHeight: CGFloat) -> Set<Int> {
        guard bodyHeight > 0 else { return [] }
        let lower = lines.filter {
            guard let rect = $0.bounds else { return false }
            return rect.midY <= box.minY + box.height * 0.42 && rect.midY > box.minY + box.height * 0.06
                && rect.height <= bodyHeight * 0.92
        }
        var offsets = Set<Int>()
        for line in lower {
            let label = line.text.trimmingCharacters(in: .whitespaces)
            guard let bounds = line.bounds,
                  imprintMarker.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil else { continue }
            let follow = lower.filter {
                guard let candidate = $0.bounds else { return false }
                return candidate.midY <= bounds.midY && candidate.minX >= bounds.minX - bodyHeight * 2
                    && (bounds.minX < box.midX || candidate.minX >= box.midX)
            }.sorted { ($0.bounds?.midY ?? 0) > ($1.bounds?.midY ?? 0) }
            var last = bounds.midY
            for candidate in follow {
                guard let next = candidate.bounds?.midY, last - next <= bodyHeight * 1.65 else { break }
                offsets.insert(candidate.range.location)
                last = next
            }
        }
        return offsets
    }

    static func marker(in value: String) -> Int? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = noteNumber.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let source = text as NSString
        if match.range(at: 1).location != NSNotFound, let scalar = text.unicodeScalars.first {
            return Int(scalar.value - 0x2460 + 1)
        }
        let number = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
        return Int(source.substring(with: number))
    }
}
