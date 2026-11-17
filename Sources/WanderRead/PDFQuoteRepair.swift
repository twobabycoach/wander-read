import AppKit
import PDFKit

struct PDFQuoteCorrection: Codable, Equatable {
    enum Method: String, Codable { case localOCR, manual }
    let original: String
    var method: Method
    var updatedAt: Date
}

enum PDFQuoteQuality {
    // These are warning signals, never replacement rules. 袁、遥、尧 etc. are also
    // legitimate Chinese characters, so a name or a single occurrence is not an error.
    static func isSuspicious(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let broken = text.unicodeScalars.filter { $0.value == 0xFFFD || (0xE000...0xF8FF).contains($0.value) }.count
        if broken >= 2 { return true }
        let signals = text.filter { "袁遥尧渊冤冶咱暂野院".contains($0) }
        let punctuation = text.filter { "，。；：“”‘’（）【】[]！？、".contains($0) }.count
        let citation = text.range(of: "咱[0-9０-９]{1,3}暂", options: .regularExpression) != nil
        if citation && signals.count >= 3 { return true }
        return signals.count >= 4 && Set(signals).count >= 2 && signals.count > max(3, punctuation * 3)
            && Double(signals.count) / Double(max(1, text.count)) > 0.025
    }
}

struct PDFQuoteImage: Identifiable {
    let id: Int
    let page: Int
    let jpeg: Data
}

enum PDFQuoteRepair {
    struct Proposal {
        let text: String
        let preservesSource: Bool
        let unresolved: String
    }

    static func proposal(original: String, recognized: String) -> Proposal {
        guard PDFQuoteQuality.isSuspicious(original), original.count <= 20_000, recognized.count <= 30_000 else {
            return Proposal(text: recognized, preservesSource: false, unresolved: "")
        }
        let source = Array(original.filter { !$0.isWhitespace })
        let ocr = Array(recognized.filter { !$0.isWhitespace })
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in ocr.difference(from: source) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        let matches = zip(source.indices.filter { !removed.contains($0) }, ocr.indices.filter { !inserted.contains($0) })
        var previous = (-1, -1), replacements: [Int: Character] = [:]
        let signals = "袁遥尧渊冤冶咱暂野院"
        let punctuation = "，。；：“”‘’（）【】[]！？、,.;:\"'()"
        for (left, right) in Array(matches) + [(source.count, ocr.count)] {
            let a = (previous.0 + 1)..<left, b = (previous.1 + 1)..<right
            // Only punctuation substitutions supported at this exact aligned position.
            // Keep source Chinese characters and digits even if OCR misreads them.
            if a.count == b.count && a.count <= 8 {
                for (i, j) in zip(a, b) where signals.contains(source[i]) && punctuation.contains(ocr[j]) {
                    replacements[i] = ocr[j]
                }
            }
            previous = (left, right)
        }
        guard replacements.count >= 2 else {
            return Proposal(text: recognized, preservesSource: false, unresolved: "")
        }
        var index = 0
        let result = original.map { character -> Character in
            guard !character.isWhitespace else { return character }
            defer { index += 1 }
            return replacements[index] ?? character
        }
        let pending = Set(removed.filter { replacements[$0] == nil && signals.contains(source[$0]) }.map { source[$0] })
        return Proposal(text: ChineseReading.compactHanSpacing(String(result)), preservesSource: true,
                        unresolved: pending.sorted().map(String.init).joined(separator: "、"))
    }

    /// Separate pages, columns and disjoint selections. Never OCR an entire page
    /// or an enclosing rectangle that also contains text outside the saved highlight.
    static func groups(_ lines: [PDFReadingLine]) -> [[PDFReadingLine]] {
        var groups: [[PDFReadingLine]] = []
        for line in lines {
            guard line.rect.width > 0, line.rect.height > 0,
                  !line.rect.isInfinite, !line.rect.isNull else { continue }
            if let last = groups.last?.last {
                let overlap = min(last.rect.maxX, line.rect.maxX) - max(last.rect.minX, line.rect.minX)
                let distance = last.rect.midY - line.rect.midY
                if last.page == line.page && overlap > min(last.rect.width, line.rect.width) * 0.2 &&
                    distance > 1 && distance < max(last.rect.height, line.rect.height) * 2.3 {
                    groups[groups.count - 1].append(line)
                    continue
                }
            }
            groups.append([line])
        }
        return groups
    }

    static func regions(_ lines: [PDFReadingLine]) -> [CGRect] {
        lines.enumerated().map { index, line in
            var rect = line.rect
            // Some embedded punctuation fonts have ascenders/descenders extending
            // across adjacent rows. Cap overlapping bands at the row's midpoint.
            let neighbours = [index - 1, index + 1].filter { lines.indices.contains($0) }
            let pitch = neighbours.map { abs(lines[$0].rect.midY - rect.midY) }.filter { $0 > 1 }.min()
            if let pitch, pitch < rect.height, pitch > rect.height * 0.5 {
                rect = CGRect(x: rect.minX, y: rect.midY - pitch / 2, width: rect.width, height: pitch)
            }
            return rect
        }
    }

    static func images(url: URL, revision: String, mark: PDFReadingMark) throws -> [PDFQuoteImage] {
        if let scan = mark.scan { return [PDFQuoteImage(id: 0, page: mark.location.page, jpeg: scan.jpeg)] }
        guard mark.revision == revision, try PDFReader.fingerprint(url) == revision else {
            throw InputError.invalid("PDF 版本已变化。请重新定位这条摘录，再从原页识别；现有文字仍可手动校对。")
        }
        let groups = groups(mark.lines)
        guard !groups.isEmpty, groups.count <= 40, groups.flatMap({ $0 }).count == mark.lines.count,
              let document = PDFDocument(url: url) else {
            throw InputError.invalid("这条摘录没有完整的选区位置。可以在原页重新选中后摘录，或在这里手动校对文字。")
        }
        return try groups.enumerated().map { index, lines in
            try Task.checkCancellation()
            let pageIndex = lines[0].page
            guard let page = document.page(at: pageIndex) else { throw InputError.invalid("找不到摘录所在的原页。") }
            let masks = regions(lines)
            let region = masks.reduce(CGRect.null) { $0.union($1) }
            return PDFQuoteImage(id: index, page: pageIndex,
                                 jpeg: try PDFScan.image(of: page, region: region, masks: masks))
        }
    }

    static func recognize(_ images: [PDFQuoteImage]) throws -> String {
        var parts: [String] = []
        for image in images {
            try Task.checkCancellation()
            let lines = try PDFScan.recognizeLines(image.jpeg).map(\.text)
            let text = joinLines(lines)
            guard !text.isEmpty else { throw InputError.invalid("有一处选区未能识别，请对照原图手动校对。现有文字已保留。") }
            parts.append(text)
        }
        guard !parts.isEmpty else { throw InputError.invalid("没有可以识别的选区。") }
        return parts.joined(separator: "\n\n")
    }

    static func joinLines(_ lines: [String]) -> String {
        var text = ""
        for line in lines {
            let next = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !next.isEmpty else { continue }
            if let last = text.unicodeScalars.last, let first = next.unicodeScalars.first {
                let latin: (Unicode.Scalar) -> Bool = { (0x30...0x39).contains($0.value) || (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
                if latin(last) && latin(first) { text += " " }
            }
            text += next
        }
        return text
    }
}

extension PDFReader {
    @discardableResult func correctQuote(_ id: UUID, text: String, expected: String,
                                         method: PDFQuoteCorrection.Method) throws -> Bool {
        guard var current = marks.first(where: { $0.id == id }), current.quote == expected else {
            throw InputError.invalid("这条摘录已被修改或移除。请关闭校对窗口后重新打开。")
        }
        let replacement = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty, replacement.utf8.count <= 100_000 else {
            throw InputError.invalid("校对文字不能为空，也不能超过 100,000 字节。")
        }
        current.quoteCorrection = PDFQuoteCorrection(original: current.quoteCorrection?.original ?? current.quote,
                                                     method: method, updatedAt: Date())
        current.quote = replacement
        return save(current)
    }

    @discardableResult func restoreOriginalQuote(_ id: UUID) -> Bool {
        guard var mark = marks.first(where: { $0.id == id }), let correction = mark.quoteCorrection else { return false }
        mark.quote = correction.original
        mark.quoteCorrection = nil
        return save(mark)
    }
}
