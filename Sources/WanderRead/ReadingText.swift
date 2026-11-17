import Foundation
import NaturalLanguage

enum ReadingSentence {
    struct VisibleRange {
        let visible: NSRange
        let source: NSRange
    }

    private static let lineBreaks = try! NSRegularExpression(pattern: #"(?:\r\n|\r|\n)(?:[ \t　]*(?:\r\n|\r|\n))*"#)
    private static let citations = try! NSRegularExpression(pattern: #"(?<=[。！？.!?])[”’」』）》】]*((?:[ \t　]*(?:[〔［\[]\s*[0-9０-９,，、–—-]+\s*[〕］\]]|[（(][PpＰｐ][.．]?\s*[0-9０-９]+[）)]|[①-⑳]))+)|(?<=[。！？!?])([0-9]{1,3})(?=\s|$)"#)
    private static let numberedAbbreviation = try! NSRegularExpression(
        pattern: #"(?i)\b(?:figs?|eqs?|refs?|secs?|chs?|pp?|nos?|vols?|tabs?|art|chap|tbl)(\.)(?=[ \t]*[(\[]?[A-Z]?\d)"#
    )
    private static let hyphenatedWrap = try! NSRegularExpression(pattern: #"(?<=[A-Za-z])([-‐]|\u00AD)[ \t]*\r?\n[ \t]*(?=[a-z])"#)

    static func ranges(in text: String) -> [NSRange] {
        let original = text as NSString
        let entire = NSRange(location: 0, length: original.length)
        let mask = NSMutableString(string: text)
        for match in lineBreaks.matches(in: text, range: entire) {
            let value = original.substring(with: match.range)
            if value == "\n" || value == "\r" || value == "\r\n" {
                mask.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
            }
        }
        // Give trailing scholarly citations to the preceding sentence without changing its source offsets.
        let joined = mask as String
        for match in citations.matches(in: joined, range: entire) {
            let range = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
            mask.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }
        for match in numberedAbbreviation.matches(in: joined, range: entire) {
            mask.replaceCharacters(in: match.range(at: 1), with: "·")
        }
        let normalized = mask as String
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = normalized
        let starts = tokenizer.tokens(for: normalized.startIndex..<normalized.endIndex).compactMap { token -> Int? in
            guard let start = normalized[token].firstIndex(where: { !$0.isWhitespace }) else { return nil }
            return start.utf16Offset(in: normalized)
        }
        return zip(starts, Array(starts.dropFirst()) + [original.length]).compactMap { start, end in
            guard let range = Range(NSRange(location: start, length: end - start), in: text),
                  let last = text[range].lastIndex(where: { !$0.isWhitespace }) else { return nil }
            return NSRange(range.lowerBound..<text.index(after: last), in: text)
        }
    }

    static func visibleRanges(in preview: String, from fullText: String) -> [VisibleRange] {
        // A folded preview may be an interior sentence with an ellipsis added at the end.
        let full = fullText as NSString
        var displayed = full.range(of: preview, options: .literal)
        if displayed.location == NSNotFound, preview.hasSuffix("…") {
            displayed = full.range(of: String(preview.dropLast()), options: .literal)
        }
        guard displayed.location != NSNotFound, displayed.length > 0 else { return [] }
        return ranges(in: fullText).compactMap { sentence in
            let intersection = NSIntersectionRange(sentence, displayed)
            guard intersection.length > 0 else { return nil }
            return VisibleRange(visible: NSRange(location: intersection.location - displayed.location,
                                                 length: intersection.length), source: sentence)
        }
    }

    static func translationText(_ text: String) -> String {
        let joined = hyphenatedWrap.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
            .replacingOccurrences(of: "\u{00AD}", with: "")
        return ChineseReading.reflow(joined).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }
}

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

enum ReadingAidMode: String, Codable, CaseIterable {
    case off, adaptive, english

    var title: String {
        switch self {
        case .off: return "关闭"
        case .adaptive: return "中英自适应"
        case .english: return "仅英文"
        }
    }
}

enum ReadingWordEmphasis {
    private static let latinWord = try! NSRegularExpression(
        pattern: #"(?<![\p{Latin}\p{M}\p{N}_])\p{Latin}[\p{Latin}\p{M}]{3,}(?![\p{Latin}\p{M}\p{N}_])"#
    )
    private static let hanRun = try! NSRegularExpression(pattern: #"\p{Han}{2,}"#)
    private static let protectedText = try! NSRegularExpression(
        pattern: #"(?i)(?:https?://|www\.|doi\s*[:：]\s*|\b10\.\d{4,9}/)[^\s，。；、！？”》）\]<>]+|《[^》\r\n]+》|\x60[^\x60\r\n]+\x60|\$[^$\r\n]+\$|\[(?:\^|@)[^\]\r\n]+\]|[（(](?:pp?\.?\s*)?[0-9０-９][0-9０-９\s–—,.，:-]*[）)]"#
    )
    private static let shortConnectors: Set<String> = [
        "一个", "一种", "一些", "一方面", "另一方面", "这个", "这些", "那个", "那些", "什么", "怎样", "如何", "哪个", "哪些",
        "可以", "能够", "应当", "应该", "需要", "必须", "已经", "正在", "还有", "没有", "不同", "相同",
        "不仅", "而且", "但是", "然而", "因此", "于是", "以及", "或者", "并且", "如果", "因为", "由于",
        "对于", "关于", "其中", "通过", "按照", "作为", "所以", "然后", "同时", "本文", "我们", "他们",
        "自己", "这样", "那样", "是否", "就是", "不是", "只是", "再看", "首先", "其次", "最后", "下次",
        "重要", "主要", "相关", "相应", "一般", "具体", "一定", "进一步", "更为", "非常",
        "讨论", "说明", "认为", "出发", "保留", "原来", "根据", "包括", "因而", "由于", "第一", "第二", "第三", "第四",
        "這個", "這些", "這樣", "什麼", "哪個",
        "怎樣", "應當", "需要", "已經", "沒有", "我們", "他們", "討論", "認為", "出發", "相關", "進一步"
    ]
    private static let englishConnectors: Set<String> = [
        "this", "that", "with", "from", "have", "were", "they", "them", "their", "there", "which", "when", "then"
    ]
    private final class CachedAnchors: NSObject {
        let anchors: [NSRange]
        init(_ anchors: [NSRange]) { self.anchors = anchors }
    }

    private static let formattedPassages: NSCache<NSString, CachedAnchors> = {
        let cache = NSCache<NSString, CachedAnchors>()
        cache.countLimit = 480
        cache.totalCostLimit = 512_000
        return cache
    }()

    static func ranges(in text: String, mode: ReadingAidMode, excluding extra: [NSRange] = []) -> [NSRange] {
        guard mode != .off, !text.isEmpty, !ChineseReading.isBibliographyItem(text), !text.contains("\t"),
              !text.contains("="), !text.contains("＝") else { return [] }
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        let excluded = (extra + protectedText.matches(in: text, range: full).map(\.range)).sorted { $0.location < $1.location }
        var excludedIndex = 0
        func blocked(_ range: NSRange) -> Bool {
            while excludedIndex < excluded.count && NSMaxRange(excluded[excludedIndex]) <= range.location { excludedIndex += 1 }
            return excludedIndex < excluded.count && NSIntersectionRange(excluded[excludedIndex], range).length > 0
        }

        var result: [NSRange] = []
        for match in latinWord.matches(in: text, range: full) {
            let range = match.range
            guard !blocked(range), let swiftRange = Range(range, in: text) else { continue }
            let word = text[swiftRange]
            guard !word.allSatisfy(\.isUppercase), !englishConnectors.contains(word.lowercased()) else { continue }
            let end = text.index(swiftRange.lowerBound, offsetBy: max(1, word.count * 2 / 5))
            result.append(NSRange(swiftRange.lowerBound..<end, in: text))
        }
        if mode == .adaptive, ChineseReading.hasHan(text) {
            excludedIndex = 0
            let tokenizer = NLTokenizer(unit: .word)
            let sample = String(text.lazy.filter(ChineseReading.isHan).prefix(160))
            tokenizer.setLanguage(NLLanguageRecognizer.dominantLanguage(for: sample) == .traditionalChinese ? .traditionalChinese : .simplifiedChinese)
            var nextAnchor = 0
            var recent: [String: Int] = [:]
            for match in hanRun.matches(in: text, range: full) {
                let run = source.substring(with: match.range)
                tokenizer.string = run
                var candidates: [(range: NSRange, word: String)] = []
                tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { token, _ in
                    let word = String(run[token])
                    guard (2...7).contains(word.count), !shortConnectors.contains(word) else { return true }
                    var range = NSRange(token, in: run)
                    range.location += match.range.location
                    if !blocked(range) { candidates.append((range, word)) }
                    return true
                }
                var index = 0
                func eligible(_ candidate: (range: NSRange, word: String)) -> Bool {
                    candidate.range.location >= nextAnchor && candidate.range.location - (recent[candidate.word] ?? -60) >= 60
                }
                while index < candidates.count {
                    let first = candidates[index]
                    if !eligible(first) { index += 1; continue }
                    let preferred = candidates[index...].prefix { $0.range.location <= first.range.location + 5 }
                        .first { $0.word.count > first.word.count && eligible($0) } ?? first
                    result.append(preferred.range)
                    nextAnchor = NSMaxRange(preferred.range) + 13
                    recent[preferred.word] = preferred.range.location
                    index += 1
                }
            }
        }
        return result.sorted { $0.location < $1.location }
    }

    static func format(_ text: String, mode: ReadingAidMode = .adaptive) -> AttributedString {
        guard mode != .off else { return AttributedString(text) }
        let key = (mode.rawValue + "\u{0}" + text) as NSString
        let anchors: [NSRange]
        if let cached = formattedPassages.object(forKey: key) {
            anchors = cached.anchors
        } else {
            anchors = ranges(in: text, mode: mode)
            formattedPassages.setObject(CachedAnchors(anchors), forKey: key, cost: key.length * 2 + anchors.count * 16)
        }
        var output = AttributedString()
        var start = text.startIndex
        for anchor in anchors {
            guard let range = Range(anchor, in: text) else { continue }
            output.append(AttributedString(String(text[start..<range.lowerBound])))
            var emphasis = AttributedString(String(text[range]))
            emphasis.inlinePresentationIntent = .stronglyEmphasized
            output.append(emphasis)
            start = range.upperBound
        }
        output.append(AttributedString(String(text[start...])))
        return output
    }
}
