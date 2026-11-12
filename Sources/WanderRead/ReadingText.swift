import Foundation
import NaturalLanguage

struct FoldedPDFPassage: Identifiable {
    struct Source {
        let page: Int
        let range: NSRange
    }

    let range: NSRange
    let text: String
    private(set) var continuations: [Source] = []
    var id: Int { range.location }

    var displayText: String { ChineseReading.reflow(text) }

    func sources(startingOn page: Int) -> [Source] {
        [Source(page: page, range: range)] + continuations
    }

    func appending(_ next: Self, on page: Int) -> Self {
        Self(range: range, text: text + "\n" + next.text,
             continuations: continuations + next.sources(startingOn: page))
    }

    var scanExcerpt: String {
        let text = displayText
        guard ChineseReading.hasHan(text) else { return firstLine }
        guard !text.contains("\n"), text.count > 70 else { return text }
        let sentences = ChineseReading.sourceSentences(in: text)
        let picked = sentences.first {
            (18...160).contains($0.count) && ChineseReading.hasArgumentCue($0)
        } ?? sentences.first ?? text
        return picked.count > 160 ? String(picked.prefix(160)) + "…" : picked
    }

    var firstLine: String {
        let text = displayText
        guard !text.isEmpty else { return "" }
        if ChineseReading.hasHan(text),
           let stop = text.firstIndex(where: { "。！？!?".contains($0) }) {
            let end = text[text.index(after: stop)...].prefix(while: { "”’」』）》】".contains($0) }).endIndex
            return String(text[..<end].prefix(140))
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let first = tokenizer.tokenRange(at: text.startIndex)
        let sentence = first.isEmpty ? text : String(text[first])
        return String(sentence.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
    }

    static func split(_ text: String, lines: [NSRange]? = nil, starts: Set<Int> = [],
                      omitting: Set<Int> = [], layoutAware: Bool = false) -> [FoldedPDFPassage] {
        let source = text as NSString
        var passages: [FoldedPDFPassage] = []
        var pending: NSRange?
        var lineCount = 0
        var endsSentence = false
        for line in lines ?? PDFTextLine.ranges(in: source) {
            let value = source.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || omitting.contains(line.location) {
                if let range = pending { passages.append(FoldedPDFPassage(range: range, text: source.substring(with: range))) }
                pending = nil
                lineCount = 0
                continue
            }
            if let range = pending, !starts.contains(line.location),
               canJoin(in: source, after: range, before: line),
               layoutAware || (NSMaxRange(line) - range.location <= 440 &&
                               lineCount < 6 && !(lineCount >= 3 && endsSentence)) {
                pending = NSUnionRange(range, line)
                lineCount += 1
            } else {
                if let range = pending { passages.append(FoldedPDFPassage(range: range, text: source.substring(with: range))) }
                pending = line
                lineCount = 1
            }
            endsSentence = value.last.map { "。！？.!?；;".contains($0) } ?? false
        }
        if let range = pending { passages.append(FoldedPDFPassage(range: range, text: source.substring(with: range))) }
        return passages
    }

    private static func canJoin(in source: NSString, after: NSRange, before: NSRange) -> Bool {
        let end = NSMaxRange(after)
        guard before.location >= end else { return false }
        let gap = source.substring(with: NSRange(location: end, length: before.location - end))
        return gap.allSatisfy(\.isWhitespace)
            && gap.replacingOccurrences(of: "\r\n", with: "\n").filter(\.isNewline).count <= 1
    }
}

enum ChineseReading {
    static func isHan(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x3400...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value) || (0x20000...0x323AF).contains(value)
    }

    static func hasHan(_ text: String) -> Bool { text.contains(where: isHan) }

    private static let hanSpaces = try! NSRegularExpression(pattern: #"(?<=\p{Han})[ \t]+(?=\p{Han})"#)
    private static let listMarker = try! NSRegularExpression(pattern: #"^\s*(?:[一二三四五六七八九十]+[、．.]|[（(][一二三四五六七八九十]+[）)])"#)
    private static let bibliographyMarker = try! NSRegularExpression(pattern: #"^\s*(?:\[[0-9]{1,3}\]|［[0-9０-９]{1,3}］|〔[0-9]{1,3}〕)\s*\S"#)
    private static let sentenceEnd = try! NSRegularExpression(
        pattern: #"[。！？.!?；;][”’」』）》】]*\s*(?:[〔［\[]\s*[0-9０-９,，、–—-]+\s*[〕］\]]\s*)*(?:[（(]\s*[PpＰｐ]?[.．]?\s*[0-9０-９][0-9０-９ –—-]*[）)]\s*)?[①-⑳]*$"#
    )
    private static let pageJump = try! NSRegularExpression(pattern: #"(?:上接|下接|下转|续见|转至)\s*第?\s*[0-9０-９〇零一二三四五六七八九十百]+\s*页"#)
    private static let argumentCues = ["本文认为", "由此可见", "这表明", "这意味着", "可以看出", "可以推知",
                                       "在于", "关键是", "因此", "或者说", "归根到底", "综上"]
    // These encoded radicals occur as complete characters in some PDF text layers.
    private static let radicalLetters: [Unicode.Scalar: String] = [
        "⺰": "纟", "⻅": "见", "⻈": "讠", "⻉": "贝", "⻋": "车", "⻐": "钅",
        "⻓": "长", "⻔": "门", "⻙": "韦", "⻚": "页", "⻛": "风", "⻜": "飞",
        "⻠": "饣", "⻢": "马", "⻥": "鱼", "⻦": "鸟", "⻧": "卤", "⻨": "麦",
        "⻩": "黄", "⻪": "黾", "⻫": "斉", "⻬": "齐", "⻭": "歯", "⻮": "齿",
        "⻯": "竜", "⻰": "龙", "⻲": "亀", "⻳": "龟"
    ]
    private static let cjkPunctuation = "，。、；：！？（）《》【】「」『』“”‘’—…"

    static func normalizingGlyphs(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x2E80...0x2FD5).contains($0.value) }) else { return text }
        return text.unicodeScalars.map { scalar in
            if (0x2F00...0x2FD5).contains(scalar.value) { return String(scalar).precomposedStringWithCompatibilityMapping }
            return radicalLetters[scalar] ?? String(scalar)
        }.joined()
    }

    static func isListItem(_ text: String) -> Bool {
        listMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isBibliographyItem(_ text: String) -> Bool {
        bibliographyMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func canContinueParagraph(after previous: String, before next: String) -> Bool {
        let tail = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = next.trimmingCharacters(in: .whitespacesAndNewlines)
        let adjacent = normalizingGlyphs(tail + "\n" + head)
        return hasHan(tail) && hasHan(head)
            && !next.hasPrefix("  ") && !next.hasPrefix("　")
            && !isListItem(compactHanSpacing(head).replacingOccurrences(of: " ", with: ""))
            && !isBibliographyItem(head)
            && pageJump.firstMatch(in: adjacent, range: NSRange(adjacent.startIndex..., in: adjacent)) == nil
            && sentenceEnd.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) == nil
    }

    static func hasArgumentCue(_ text: String) -> Bool {
        guard let first = text.first, !"“‘「『".contains(first) else { return false }
        return argumentCues.contains { text.contains($0) }
    }

    static func sourceSentences(in text: String) -> [String] {
        let delimiters: [Character: Character] = ["“": "”", "‘": "’", "「": "」", "『": "』",
                                                  "（": "）", "(": ")", "《": "》", "〔": "〕",
                                                  "【": "】", "[": "]", "［": "］"]
        var sentences: [String] = []
        var closers: [Character] = []
        var start = text.startIndex
        for index in text.indices {
            let character = text[index]
            if character == closers.last { closers.removeLast() }
            else if let closer = delimiters[character] { closers.append(closer) }
            guard closers.isEmpty, "。！？!?".contains(character) else { continue }
            let end = text.index(after: index)
            let next = text[end...].drop(while: \.isWhitespace)
            if let first = next.first, "〔［[（(".contains(first) { continue }
            sentences.append(String(text[start..<end]).trimmingCharacters(in: .whitespaces))
            start = end
        }
        if start < text.endIndex { sentences.append(String(text[start...]).trimmingCharacters(in: .whitespaces)) }
        return sentences.filter { !$0.isEmpty }
    }

    static func compactHanSpacing(_ text: String) -> String {
        hanSpaces.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    static func reflow(_ raw: String) -> String {
        let text = normalizingGlyphs(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasHan(text) else { return text }
        let lines = text.split(whereSeparator: \.isNewline)
        // Short stacked lines can be verse, a table, or an index; keep their structure.
        guard !text.contains("\t"), !lines.contains(where: { isListItem(String($0)) }),
              lines.count <= 1 || lines.dropLast().contains(where: { $0.count >= 12 }) else { return text }
        var result = ""
        for line in lines {
            let part = line.trimmingCharacters(in: .whitespaces)
            if let last = result.last, let first = part.first,
               !isHan(last), !isHan(first), !cjkPunctuation.contains(last), !cjkPunctuation.contains(first) {
                result += " "
            }
            result += part
        }
        return compactHanSpacing(result)
    }
}

enum ReadingWordEmphasis {
    static func format(_ text: String) -> AttributedString {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var output = AttributedString()
        var start = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = text[range]
            guard word.count >= 2, word.first?.isLetter == true else { return true }
            let prefixCount = max(1, word.count * 2 / 5)
            let end = text.index(range.lowerBound, offsetBy: prefixCount)
            output.append(AttributedString(String(text[start..<range.lowerBound])))
            var emphasis = AttributedString(String(text[range.lowerBound..<end]))
            emphasis.inlinePresentationIntent = .stronglyEmphasized
            output.append(emphasis)
            start = end
            return true
        }
        output.append(AttributedString(String(text[start...])))
        return output
    }
}
