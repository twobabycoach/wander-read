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
            let depth = max(0, min(entry.depth, PDFOutlineHierarchy.maximumDepth, (result.last?.depth ?? -1) + 1))
            result.append(PDFReadingSection(id: result.count, title: title, location: location, depth: depth,
                                            printedLabel: entry.printedLabel))
        }
        return result
    }
}

struct PDFOutlineCalibration {
    struct Option {
        let title: String
        let location: PDFReadingLocation
        var rank = 0
        var wrapped = false
        var relativeHeight: CGFloat?
        var nearTop = false
        var depth: Int?

        var reliableHeading: Bool { rank >= 4 && PDFOutlineHierarchy.marker(title) != nil }
    }

    struct Candidate {
        let id: UUID
        let title: String
        let printedLabel: String?
        let options: [Option]
        var originalPage: Int?
    }

    private struct Reply: Decodable {
        struct Match: Decodable { let entry: Int; let option: Int }
        let matches: [Match]
    }

    struct Inventory {
        let options: [Option]
        let limited: Bool
    }

    static func candidates(in document: PDFDocument, entries: [PDFOutlineCandidate], prioritize: UUID? = nil) throws -> [Candidate] {
        var order = entries.indices.filter { entries[$0].isPending } + entries.indices.filter { !entries[$0].isPending }
        if let prioritize, let offset = order.firstIndex(where: { entries[$0].id == prioritize }) {
            let focused = order.remove(at: offset)
            order.insert(focused, at: 0)
        }
        let count = document.pageCount
        var lines: [Int: [Option]] = [:]
        return try order.compactMap { index in
            try Task.checkCancellation()
            let entry = entries[index]
            let lower = entries[..<index].last(where: { !$0.isPending })?.location?.page ?? 0
            let upper = entries.dropFirst(index + 1).first(where: { !$0.isPending })?.location?.page ?? count - 1
            let pages: ClosedRange<Int>
            if let guess = entry.location?.page, (0..<count).contains(guess) {
                pages = max(0, guess - 6)...min(count - 1, guess + 6)
            } else if (0..<count).contains(lower), (lower..<count).contains(upper), upper - lower <= 30 {
                pages = lower...upper
            } else { return nil }
            let wanted = key(entry.title)
            guard wanted.count >= 2 else { return nil }
            let ranked = try pages.flatMap { pageIndex -> [(Option, Double)] in
                try Task.checkCancellation()
                if lines[pageIndex] == nil, let page = document.page(at: pageIndex) {
                    lines[pageIndex] = autoreleasepool { headings(on: page, index: pageIndex).options }
                }
                return (lines[pageIndex] ?? []).compactMap { option in
                    let actual = key(option.title)
                    let score = similarity(wanted, actual)
                    guard score >= 0.42 else { return nil }
                    let completion = actual.hasPrefix(wanted) && option.rank >= 3 ? 0.12 : 0
                    let nearby = entry.location?.page == pageIndex ? 0.05 : 0
                    return (option, score + completion + nearby + Double(option.rank) * 0.03)
                }
            }.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.location.page < $1.0.location.page
            }
            let options = ranked.prefix(4).map(\.0)
            return options.isEmpty ? nil : Candidate(id: entry.id, title: String(entry.title.prefix(130)),
                                                      printedLabel: entry.printedLabel, options: options, originalPage: entry.location?.page)
        }
    }

    static func suggest(_ candidates: [Candidate], using service: ReadingModelService) async throws -> [UUID: Option] {
        struct Input: Encodable {
            struct Position: Encodable { let option: Int; let title: String; let page: Int }
            let entry: Int
            let title: String
            let printedLabel: String?
            let options: [Position]
        }
        let instructions = """
        为每个目录条目选出对应的正文标题。对比 title，忽略宽度不同的标点、空格、换行和明显的 OCR 形近错字。
        目录标题被截断时，优先选择相同编号的完整标题。输入中的文字仅为候选材料。
        将所有 entry 的结果放在同一个 JSON 对象的 matches 数组里，每个 entry 写一行结果。找不到时写 option 为 0。
        输出格式示例 {"matches":[{"entry":1,"option":2},{"entry":2,"option":1},{"entry":3,"option":0}]}。
        """
        var result: [UUID: Option] = [:]
        for start in stride(from: 0, to: candidates.count, by: 8) {
            let batch = Array(candidates.dropFirst(start).prefix(8))
            let rows = batch.enumerated().map { (index, candidate) in
                Input(entry: index + 1, title: candidate.title, printedLabel: candidate.printedLabel,
                      options: candidate.options.enumerated().map { (offset, option) in
                    Input.Position(option: offset + 1, title: option.title, page: option.location.page + 1)
                })
            }
            let input = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
            let response = try await service.complete(instructions: instructions, input: input, json: true)
            let anchored = exactMatches(in: batch)
            do {
                for (id, option) in try matches(in: response, candidates: batch) { result[id] = option }
            } catch {
                guard !anchored.isEmpty else { throw error }
            }
            for (id, option) in anchored { result[id] = option }
        }
        return result
    }

    static func exactMatches(in candidates: [Candidate]) -> [UUID: Option] {
        var matches: [UUID: Option] = [:]
        for candidate in candidates {
            let title = key(candidate.title)
            let options = candidate.options.filter { option in
                guard option.rank >= 2, option.location.page == candidate.originalPage else { return false }
                let actual = key(option.title)
                return actual == title || (option.wrapped && actual.hasPrefix(title))
            }
            if options.count == 1 { matches[candidate.id] = options[0] }
        }
        return matches
    }

    private static func json(in response: String) -> Data {
        let fence = "\u{0060}\u{0060}\u{0060}"
        let wrapping = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”"))
        var text = response.trimmingCharacters(in: wrapping)
        if text.hasPrefix(fence), text.hasSuffix(fence), let newline = text.firstIndex(of: "\n"),
           text.index(after: newline) <= text.index(text.endIndex, offsetBy: -3) {
            text = String(text[text.index(after: newline)..<text.index(text.endIndex, offsetBy: -3)])
        }
        return Data(text.utf8)
    }

    static func matches(in response: String, candidates: [Candidate]) throws -> [UUID: Option] {
        guard let result = try? JSONDecoder().decode(Reply.self, from: json(in: response)),
              result.matches.count <= candidates.count else {
            throw InputError.invalid("模型没有返回可核对的目录建议，可以重试或在原页确认。")
        }
        var selected: [UUID: Option] = [:]
        var used = Set<Int>()
        for match in result.matches {
            guard match.entry > 0, match.entry <= candidates.count, used.insert(match.entry).inserted else {
                throw InputError.invalid("模型选择了候选范围以外的目录项。")
            }
            let candidate = candidates[match.entry - 1]
            if match.option == 0 { continue }
            guard match.option > 0, match.option <= candidate.options.count else {
                throw InputError.invalid("模型选择了不存在或重复的候选，目录保持待核对。")
            }
            selected[candidate.id] = candidate.options[match.option - 1]
        }
        return selected
    }

    private static func isCorrection(_ option: Option, for entry: PDFOutlineCandidate) -> Bool {
        if option.depth.map({ $0 != entry.depth }) == true { return true }
        if entry.isPending || key(option.title) != key(entry.title) || entry.location?.page != option.location.page { return true }
        guard let before = entry.location?.point, let after = option.location.point else { return option.location.point != nil }
        return hypot(before.x - after.x, before.y - after.y) > 10
    }

    static func corrections(for entries: [PDFOutlineCandidate], matched: [UUID: Option],
                            preserveDepths: Bool, authorOutline: [PDFReadingSection] = []) -> [UUID: Option] {
        let located = entries.filter { !$0.isPending || matched[$0.id] != nil }
        let authored = Dictionary(grouping: authorOutline, by: { key($0.title) })
        let depths = PDFOutlineHierarchy.depths(located.map { entry in
            let source = matched[entry.id]
            let title = source?.title ?? entry.title
            let page = source?.location.page ?? entry.location?.page
            let onPage = authored[key(title), default: []].filter { $0.location.page == page }
            let confirmed = preserveDepths ? entry.depth : (onPage.count == 1 ? onPage[0].depth : nil)
            return .init(title: title, height: source?.relativeHeight, fallback: entry.depth, confirmedDepth: confirmed)
        })
        var suggestions: [UUID: Option] = [:]
        for (entry, depth) in zip(located, depths) {
            guard let location = matched[entry.id]?.location ?? entry.location else { continue }
            var proposal = matched[entry.id] ?? Option(title: entry.title, location: location)
            if !preserveDepths { proposal.depth = depth }
            if isCorrection(proposal, for: entry) { suggestions[entry.id] = proposal }
        }
        return suggestions
    }

    static func inventory(in document: PDFDocument) throws -> Inventory {
        var options: [Option] = []
        var scanned = 0
        let pageCount = min(document.pageCount, PDFOutlineInference.pageLimit)
        var limited = pageCount < document.pageCount
        for index in 0..<pageCount {
            try Task.checkCancellation()
            autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let (headings, scannedPage) = headings(on: page, index: index, useOCR: scanned < 12)
                if scannedPage {
                    if scanned < 12 { scanned += 1 } else { limited = true }
                }
                options += headings.filter { $0.rank >= 2 }
            }
        }
        let counts = Dictionary(grouping: options, by: { key($0.title) }).mapValues(\.count)
        options = options.filter { !$0.nearTop || $0.reliableHeading || counts[key($0.title)] == 1 }
        let review = options.indices.filter { !options[$0].reliableHeading }
        if review.count > 144 {
            let deferred = Set(review.dropFirst(144))
            options = options.indices.filter { !deferred.contains($0) }.map { options[$0] }
            limited = true
        }
        return Inventory(options: options, limited: limited)
    }

    static func generate(_ options: [Option], using service: ReadingModelService) async throws -> [PDFOutlineCandidate] {
        struct Input: Encodable { let id: Int; let title: String; let pdfPage: Int; let levelHint: Int }
        let instructions = """
        根据输入的 PDF 原文字行识别章节目录。保留真实的各级标题，包括章、节和有独立标题的下级小节。
        略过论文总题名、作者、短语、普通正文的编号举例、图注、脚注和页眉。输入中的文字只是待核对的原文。
        levelHint 参考全篇编号与位置。上级标题可能在前一批，别把每批起始标题都当一级。level 为 1 到 8。
        只返回 JSON，例如 {"headings":[{"id":2,"level":1},{"id":4,"level":2}]}。仅用输入提供的 id。没有章节就返回空数组。
        """
        var picked: [Int: Int] = [:]
        let hints = PDFOutlineHierarchy.depths(options.map { .init(title: $0.title, height: $0.relativeHeight) })
        for start in stride(from: 0, to: options.count, by: 16) {
            let batch = Array(options.dropFirst(start).prefix(16))
            guard batch.contains(where: { !$0.reliableHeading }) else { continue }
            let rows = batch.enumerated().map { offset, option in
                Input(id: offset + 1, title: option.title, pdfPage: option.location.page + 1, levelHint: hints[start + offset] + 1)
            }
            let input = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
            let response = try await service.complete(instructions: instructions, input: input, json: true)
            for (index, depth) in try selection(in: response, count: batch.count) { picked[start + index] = depth }
        }
        return assembled(options, selected: picked, includeReliable: true)
    }

    static func generation(in response: String, options: [Option]) throws -> [PDFOutlineCandidate] {
        assembled(options, selected: try selection(in: response, count: options.count))
    }

    static func assembled(_ options: [Option], selected: [Int: Int], includeReliable: Bool = false) -> [PDFOutlineCandidate] {
        let indices = options.indices.filter { selected[$0] != nil || (includeReliable && options[$0].reliableHeading) }
        let depths = PDFOutlineHierarchy.depths(indices.map { index in
            .init(title: options[index].title, height: options[index].relativeHeight, fallback: selected[index] ?? 0)
        })
        return zip(indices, depths).map { index, depth in
            PDFOutlineCandidate(title: options[index].title, depth: depth, location: options[index].location)
        }
    }

    private static func selection(in response: String, count: Int) throws -> [Int: Int] {
        struct Reply: Decodable {
            struct Heading: Decodable { let id: Int; let level: Int }
            let headings: [Heading]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: json(in: response)),
              reply.headings.count <= count else {
            throw InputError.invalid("模型没有返回可用的目录。可重试，或指定 PDF 目录页。")
        }
        var result: [Int: Int] = [:]
        for heading in reply.headings {
            guard heading.id > 0, heading.id <= count, (1...(PDFOutlineHierarchy.editableDepth + 1)).contains(heading.level),
                  result[heading.id - 1] == nil else {
                throw InputError.invalid("模型选了无效或重复的标题，生成结果未采用。")
            }
            result[heading.id - 1] = heading.level - 1
        }
        return result
    }

    private struct Line {
        let title: String
        let bounds: CGRect
        let band: Int
        var distinctFace = false
    }

    private static func headings(on page: PDFPage, index: Int, useOCR: Bool = false) -> (options: [Option], scanned: Bool) {
        let box = page.bounds(for: .cropBox)
        let text = page.string ?? ""
        let scanned = !text.contains(where: \.isLetter)
        let layout = PDFAcademicLayout(page: page, text: text)
        let native = layout?.lines ?? PDFTextLine.lines(in: text, on: page)
        let lines: [Line]
        if scanned && useOCR {
            lines = PDFOutlineBuilder.modelOCRLines(page).map { Line(title: clean($0.text), bounds: $0.bounds, band: 0) }
        } else {
            let typography = PDFOutlineTypography(page: page, text: text, lines: native)
            lines = native.compactMap { line in
                guard layout?.notes.contains(line.range.location) != true,
                      let rect = line.bounds ?? page.textSelection(in: line.range)?.bounds(for: page),
                      !rect.isEmpty else { return nil }
                return Line(title: clean(line.text), bounds: rect, band: layout?.band(at: CGPoint(x: rect.midX, y: rect.midY)) ?? 0,
                            distinctFace: typography?.distinguishes(line.range) == true)
            }
        }
        guard !lines.prefix(8).contains(where: { ["目录", "目錄", "目次", "contents", "tableofcontents"].contains(key($0.title)) }),
              !box.isEmpty else { return ([], scanned) }
        let body = lines.filter { $0.title.count >= 16 && $0.bounds.width > box.width * 0.22 }
            .map(\.bounds.height).sorted()
        let bodyHeight = body.isEmpty ? 0 : body[body.count / 2]
        var usedTail: Int?
        let options: [Option] = lines.enumerated().compactMap { offset, line in
            let rect = line.bounds, label = line.title
            let position = (rect.midY - box.minY) / box.height
            guard offset != usedTail, (0.055...0.95).contains(position), plausible(label),
                  !PDFQuoteQuality.isSuspicious(label) else { return nil }
            let marker = PDFOutlineHierarchy.marker(label)
            let prominent = bodyHeight > 0 && rect.height > bodyHeight * 1.12
            let nearby = lines.dropFirst(offset + 1).prefix(7).prefix { $0.band == line.band }
            let prior = offset > 0 && lines[offset - 1].band == line.band ? lines[offset - 1].bounds : nil
            let separated = prior.map { $0.midY - rect.midY > max(bodyHeight, rect.height) * 1.5 } ?? true
            let isolation = separated && (nearby.first.map { rect.midY - $0.bounds.midY > max(bodyHeight, rect.height) * 1.5 } ?? false)
            let reliable = prominent || ((line.distinctFace || isolation) && label.count <= 70 && rect.width < box.width * 0.85)
            let rank = marker != nil ? (reliable ? 4 : 3) : (prominent && label.count < 100 ? 2 : 0)
            var title = label
            if rank >= 2, let tail = nearby.first, let after = nearby.dropFirst().first,
               plausible(tail.title), PDFOutlineHierarchy.marker(tail.title) == nil, after.title.count >= 14,
               PDFOutlineInference.wrappedTitle(head: rect, tail: tail.bounds, body: after.bounds) {
                title = PDFOutlineInference.joinedTitle(title, tail.title)
                usedTail = offset + 1
            }
            return Option(title: String(title.prefix(160)), location: PDFReadingLocation(page: index, point: CGPoint(x: rect.minX, y: rect.maxY)),
                          rank: rank, wrapped: title != label, relativeHeight: bodyHeight > 0 ? rect.height / bodyHeight : nil,
                          nearTop: position > 0.87)
        }
        return (options, scanned)
    }

    private static func clean(_ title: String) -> String {
        ChineseReading.normalizingGlyphs(title).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plausible(_ title: String) -> Bool {
        (2...130).contains(title.count) && title.contains(where: \.isLetter)
            && !title.contains("……") && !title.contains("....")
            && title.last.map { !"。！？!?；;".contains($0) } == true
    }

    private static func key(_ title: String) -> String {
        ChineseReading.normalizingGlyphs(title).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func similarity(_ wanted: String, _ candidate: String) -> Double {
        if wanted == candidate { return 1 }
        if wanted.count >= 4, candidate.count >= 4,
           wanted.contains(candidate) || candidate.contains(wanted) {
            return Double(min(wanted.count, candidate.count)) / Double(max(wanted.count, candidate.count))
        }
        func pairs(_ value: String) -> Set<String> { Set(zip(value, value.dropFirst()).map { String([$0, $1]) }) }
        let left = pairs(wanted), right = pairs(candidate)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(2 * left.intersection(right).count) / Double(left.count + right.count)
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
                let scanPage = hasNoTextBeyondPageNumbers(text) && (scanRange != nil || (autoScan && index < 12))
                let recognized = scanPage ? ocrLines(page) : []
                let lines = recognized.isEmpty ? text : recognized
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
            if scanRange != nil { return scannedHeadings(scanned) }
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
                      let page = document.page(at: index), hasNoTextBeyondPageNumbers(nativeLines(page)) else { return }
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

    private static func hasNoTextBeyondPageNumbers(_ lines: [Line]) -> Bool {
        lines.allSatisfy { pageNumber($0.text) != nil }
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

    fileprivate static func modelOCRLines(_ page: PDFPage) -> [(text: String, bounds: CGRect)] {
        ocrLines(page).map { ($0.text, $0.bounds) }
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
            let trailing = rowPattern.firstMatch(in: joined, range: range)
            let leading = leftPattern.firstMatch(in: joined, range: range)
            let hasLeaders = trailing.map { source.substring(with: $0.range(at: 2)).contains { !$0.isWhitespace } } ?? false
            var title: String
            let label: String?
            let leaders: Bool
            let mayWrapForward: Bool
            var x = line.bounds.minX
            if let match = leading, !hasLeaders, numberAtRight == nil {
                title = source.substring(with: match.range(at: 2))
                label = pageNumber(source.substring(with: match.range(at: 1)))
                leaders = false
                mayWrapForward = true
            } else if let match = trailing {
                title = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                label = pageNumber(source.substring(with: match.range(at: 3)))
                leaders = hasLeaders
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
        PDFOutlineHierarchy.depths(entries.map { .init(title: $0.title, indent: $0.x) })
    }

    private static func isPart(_ title: String) -> Bool {
        ["上编", "中编", "下编", "上編", "中編", "下編"].contains { title.filter { !$0.isWhitespace }.hasPrefix($0) }
    }

    private static func scannedHeadings(_ scanned: [Int: [Line]]) -> [PDFOutlineCandidate] {
        let entries: [PDFOutlineCandidate] = scanned.keys.sorted().compactMap { index in
            guard let heading = scanned[index]?.prefix(8).first(where: {
                PDFOutlineInference.kind(of: normalized($0.text)).map { $0 <= 2 } ?? false
            }) else { return nil }
            return PDFOutlineCandidate(title: heading.text, location: PDFReadingLocation(page: index,
                point: CGPoint(x: heading.bounds.minX, y: heading.bounds.maxY)), needsReview: true)
        }
        let depths = PDFOutlineHierarchy.depths(entries.map { .init(title: $0.title) })
        return zip(entries, depths).map { entry, depth in
            var entry = entry
            entry.depth = depth
            return entry
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
