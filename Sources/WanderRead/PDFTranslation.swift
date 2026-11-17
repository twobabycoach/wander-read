import Combine
import Foundation
import PDFKit

struct PDFComparisonScroll {
    enum Axis { case vertical, horizontal }
    struct Turn: Equatable {
        let step: Int
        let fromBottom: Bool
    }

    private var distance = CGFloat(0)
    private var lastScroll: TimeInterval = -.infinity
    private var lastTurn: TimeInterval = -.infinity
    private var usedGesture = false

    mutating func begin() {
        distance = 0
        usedGesture = false
    }

    mutating func turn(delta: CGFloat, axis: Axis, timestamp: TimeInterval, precise: Bool,
                       atEdge: Bool, canTurn: Bool) -> Turn? {
        if timestamp - lastScroll > 0.28 { distance = 0 }
        lastScroll = timestamp
        guard atEdge, canTurn, delta != 0 else { distance = 0; return nil }
        guard !precise || !usedGesture else { return nil }
        guard timestamp - lastTurn >= 0.35 else { return nil }
        if distance.sign != delta.sign { distance = 0 }
        distance += delta
        let threshold: CGFloat = precise ? (axis == .horizontal ? 44 : 55) : 1
        guard abs(distance) >= threshold else { return nil }
        let step = distance < 0 ? 1 : -1
        distance = 0
        lastTurn = timestamp
        usedGesture = precise
        return Turn(step: step, fromBottom: step < 0 && axis == .vertical)
    }

    var blocksMomentum: Bool { usedGesture }
}

enum PDFTranslationScope: Equatable {
    case document
    case page(Int)

    var description: String {
        switch self {
        case .document: return "整篇"
        case .page(let page): return "第 \(page + 1) 页"
        }
    }

    var key: String {
        switch self {
        case .document: return "whole"
        case .page(let page): return "page-\(page)"
        }
    }

    func indices(pageCount: Int) -> Range<Int> {
        switch self {
        case .document: return 0..<pageCount
        case .page(let page): return (0..<pageCount).contains(page) ? page..<page + 1 : 0..<0
        }
    }
}

struct PDFTranslationSource {
    let document: TranslationDocument
    let url: URL
    let pageCount: Int
}

struct PDFTranslationFile: Identifiable {
    let id: UUID
    let url: URL
    let pages: Range<Int>
    let target: TranslationLanguage?
    let imported: Bool
    var profile: String? = nil

    func translatedPage(for page: Int) -> Int? {
        pages.contains(page) ? page - pages.lowerBound : nil
    }
}

extension ReadingTranslationArchive {
    private struct PDFEntry: Codable {
        let id: UUID
        let target: TranslationLanguage?
        let imported: Bool
    }

    func pdf(_ source: PDFTranslationSource, scope: PDFTranslationScope, profile: String? = nil) -> PDFTranslationFile? {
        let pages = scope.indices(pageCount: source.pageCount)
        guard !pages.isEmpty, let directory = directory(for: source.document),
              let manifest = pdfManifest(in: directory, scope: scope, profile: profile),
              let data = try? Data(contentsOf: manifest),
              let entry = try? JSONDecoder().decode(PDFEntry.self, from: data) else { return nil }
        let url = directory.appendingPathComponent(entry.id.uuidString).appendingPathExtension("pdf")
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return PDFTranslationFile(id: entry.id, url: url, pages: pages, target: entry.target, imported: entry.imported, profile: profile)
    }

    func generatedPDF(_ source: PDFTranslationSource, scope: PDFTranslationScope, settings: ReadingTranslationSettings) -> PDFTranslationFile? {
        guard let profile = settings.pdfProfile else { return nil }
        return pdf(source, scope: scope, profile: profile)
    }

    func importPDF(_ url: URL, for source: PDFTranslationSource, scope: PDFTranslationScope,
                   target: TranslationLanguage? = nil, profile: String? = nil) throws -> PDFTranslationFile {
        let files = FileManager.default
        guard let directory = directory(for: source.document), let manifest = pdfManifest(in: directory, scope: scope, profile: profile) else {
            throw InputError.invalid("无法记录这份原文的版本。请重新打开原文。")
        }
        guard try PDFReader.fingerprint(source.url) == source.document.revision else {
            throw InputError.invalid("原文文件已经变化。请重新打开原文，再关联译文。")
        }
        let pages = scope.indices(pageCount: source.pageCount)
        let id = UUID()
        let destination = directory.appendingPathComponent(id.uuidString).appendingPathExtension("pdf")
        let previous = pdf(source, scope: scope, profile: profile)
        let localFile = url.resolvingSymlinksInPath()
        guard try localFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw InputError.invalid("请选择一个本地译文 PDF 文件。")
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.copyItem(at: localFile, to: destination)
        do {
            try Task.checkCancellation()
            try validatePDF(destination, source: source, pages: pages, generated: target != nil)
            try Task.checkCancellation()
            let entry = PDFEntry(id: id, target: target, imported: target == nil)
            try JSONEncoder().encode(entry).write(to: manifest, options: .atomic)
        } catch {
            try? files.removeItem(at: destination)
            throw error
        }
        if let previous { try? files.removeItem(at: previous.url) }
        return PDFTranslationFile(id: id, url: destination, pages: pages, target: target, imported: target == nil, profile: profile)
    }

    func removePDF(_ source: PDFTranslationSource, scope: PDFTranslationScope, profile: String? = nil) throws {
        guard let directory = directory(for: source.document), let manifest = pdfManifest(in: directory, scope: scope, profile: profile),
              let previous = pdf(source, scope: scope, profile: profile) else { return }
        try FileManager.default.removeItem(at: manifest)
        try? FileManager.default.removeItem(at: previous.url)
    }

    private func pdfManifest(in directory: URL, scope: PDFTranslationScope, profile: String?) -> URL? {
        if let profile {
            guard profile.utf8.count == 64, profile.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        }
        return directory.appendingPathComponent(scope.key + (profile.map { "-" + $0 } ?? "") + ".json")
    }

    private func validatePDF(_ url: URL, source: PDFTranslationSource, pages: Range<Int>, generated: Bool) throws {
        guard let original = PDFDocument(url: source.url), original.pageCount == source.pageCount,
              let translated = PDFDocument(url: url), !translated.isLocked, !pages.isEmpty,
              translated.pageCount == pages.count else {
            throw InputError.invalid("译文页数与原文对应范围不同。请选与原文逐页对应的纯译文 PDF。")
        }
        guard try PDFReader.fingerprint(url) != source.document.revision else {
            throw InputError.invalid("选中了原 PDF。请另选生成的译文。")
        }
        var changed = !generated
        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            guard let before = original.page(at: page), let after = translated.page(at: index) else {
                throw InputError.invalid("无法读出译文页面。")
            }
            let a = before.bounds(for: .cropBox), b = after.bounds(for: .cropBox)
            guard a.width > 0, a.height > 0, abs(a.width - b.width) <= 3, abs(a.height - b.height) <= 3 else {
                throw InputError.invalid("原文第 \(page + 1) 页与译文的版面大小不同。请选纯译文 PDF，双语并排文件不能用于页码对照。")
            }
            if !changed {
                let from = (before.string ?? "").filter { !$0.isWhitespace }
                let to = (after.string ?? "").filter { !$0.isWhitespace }
                changed = !from.isEmpty && !to.isEmpty && from != to
            }
        }
        if !changed { throw InputError.invalid("生成的 PDF 没有检测到译文。请检查本地服务，或先用一页试译。") }
    }
}

enum PDFTranslationTool {
    static func executable(_ custom: String?) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL]
        if let custom {
            guard custom.hasPrefix("/") else { return nil }
            candidates = [URL(fileURLWithPath: custom)]
        } else {
            candidates = [
                home.appendingPathComponent(".local/bin/pdf2zh_next"),
                URL(fileURLWithPath: "/opt/homebrew/bin/pdf2zh_next"),
                URL(fileURLWithPath: "/usr/local/bin/pdf2zh_next")
            ]
        }
        return candidates.first {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory) &&
                !directory.boolValue && FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    static func generate(_ source: PDFTranslationSource, scope: PDFTranslationScope, settings: ReadingTranslationSettings,
                         archive: ReadingTranslationArchive) async throws -> PDFTranslationFile {
        guard let service = settings.service, let profile = settings.pdfProfile, let binary = executable(settings.pdfTool) else {
            throw InputError.invalid("请先连接翻译模型，并选好 PDFMathTranslate-next。")
        }
        guard settings.pdfSource != settings.target else {
            throw InputError.invalid("请为原文和译文选择不同的语言。")
        }

        let workspace = archive.root.appendingPathComponent("Work", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let input = workspace.appendingPathComponent("source.pdf")
        let output = workspace.appendingPathComponent("output", isDirectory: true)
        let config = workspace.appendingPathComponent("settings.toml")
        let files = FileManager.default
        try files.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: workspace) }
        try files.createDirectory(at: output, withIntermediateDirectories: false)
        try files.copyItem(at: source.url, to: input)
        try prepare(input, source: source, scope: scope)
        try await service.prepareForPDF()
        try Task.checkCancellation()
        try Data("# Translation settings are passed to this job only.\n".utf8).write(to: config, options: .atomic)

        let trace = workspace.appendingPathComponent("worker.log")
        guard files.createFile(atPath: trace.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw InputError.invalid("无法准备文档翻译。请检查磁盘可用空间。")
        }
        let log = try FileHandle(forWritingTo: trace)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = workspace
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            let name = key.uppercased()
            return !name.hasPrefix("PDF2ZH_") && !name.hasPrefix("OPENAI_") && !name.hasSuffix("_PROXY")
                && name != "PYTHONPATH" && name != "PYTHONHOME"
        }
        environment["PDF2ZH_OPENAI_API_KEY"] = try service.requestKey()
        environment["PDF2ZH_OPENAI_SEND_TEMPRATURE"] = settings.isRemote ? "false" : "true"
        if !settings.isRemote { environment["PDF2ZH_OPENAI_TEMPERATURE"] = "0" }
        environment["PDF2ZH_OPENAI_TIMEOUT"] = "110"
        environment["PDF2ZH_DEBUG"] = "false"
        environment["PDF2ZH_CUSTOM_SYSTEM_PROMPT"] = [
            "You translate academic PDF text. Retain the original section numbering, symbols, references, and placeholder tokens.",
            TranslationGuidance.fidelity, settings.rules.additions, settings.target.scriptInstruction
        ].joined(separator: "\n")
        if settings.target == .chinese {
            try Data(simplifyWorkerOutput.utf8).write(to: workspace.appendingPathComponent("sitecustomize.py"), options: .atomic)
            environment["PYTHONPATH"] = workspace.path
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
        }
        process.environment = environment
        var args = [
            input.path, "--config-file", config.path, "--output", output.path,
            "--openai", "--openai-base-url", service.base.absoluteString, "--openai-model=\(service.model)",
            "--lang-in", settings.pdfSource.rawValue, "--lang-out", settings.target.rawValue,
            "--no-dual", "--no-auto-extract-glossary", "--ignore-cache",
            "--watermark-output-mode", "no_watermark", "--pool-max-workers", "1", "--qps", "2"
        ]
        // Let BabelDOC select the page so PDFKit doesn't rewrite its embedded fonts or character maps.
        if case .page(let index) = scope {
            args += ["--pages", String(index + 1), "--only-include-translated-page"]
        }
        let terms = try settings.rules.terms()
        if !terms.isEmpty {
            let glossary = workspace.appendingPathComponent("glossary.csv")
            func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            let rows = terms.map { quoted($0.source) + "," + quoted($0.target) }
            try Data((["source,target"] + rows).joined(separator: "\n").utf8).write(to: glossary, options: .atomic)
            args += ["--glossaries", glossary.lastPathComponent]
        }
        process.arguments = args
        let status = try await TranslationProcess().wait(for: process)
        try Task.checkCancellation()
        let candidates = try files.contentsOfDirectory(at: output, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.lastPathComponent.hasSuffix(".mono.pdf") || $0.lastPathComponent.hasSuffix("-mono.pdf") }
        guard status == 0, candidates.count == 1, let translated = candidates.first else {
            throw InputError.invalid("未生成译文 PDF。请检查 PDFMathTranslate-next 2.x、所选模型和服务连接，再试一页。")
        }
        return try archive.importPDF(translated, for: source, scope: scope, target: settings.target, profile: profile)
    }

    // Apply the macOS transform before BabelDOC lays out the translated glyphs.
    // The hook lives only in this job's private directory.
    static let simplifyWorkerOutput = #"""
    import ctypes as c
    import functools
    import importlib.abc
    import importlib.machinery
    import json
    import re
    import sys

    _cf = c.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    _pointer = c.c_void_p
    _utf8 = 0x08000100
    _cf.CFStringCreateWithCString.argtypes = [_pointer, c.c_char_p, c.c_uint32]
    _cf.CFStringCreateWithCString.restype = _pointer
    _transform = _cf.CFStringCreateWithCString(None, b"Traditional-Simplified", _utf8)
    _cf.CFStringCreateMutableCopy.argtypes = [_pointer, c.c_long, _pointer]
    _cf.CFStringCreateMutableCopy.restype = _pointer
    _cf.CFStringGetLength.argtypes = [_pointer]
    _cf.CFStringGetLength.restype = c.c_long
    _cf.CFStringTransform.argtypes = [_pointer, _pointer, _pointer, c.c_bool]
    _cf.CFStringTransform.restype = c.c_bool
    _cf.CFStringGetCString.argtypes = [_pointer, _pointer, c.c_long, c.c_uint32]
    _cf.CFStringGetCString.restype = c.c_bool
    _cf.CFRelease.argtypes = [_pointer]
    _cf.CFRelease.restype = None
    _han = re.compile(r"[\u3400-\u9fff\uf900-\ufaff\U00020000-\U000323af]")

    def _simplify(text):
        if not _han.search(text) or "\0" in text:
            return text
        source = _cf.CFStringCreateWithCString(None, text.encode("utf-8"), _utf8)
        if not source:
            return text
        try:
            value = _cf.CFStringCreateMutableCopy(None, 0, source)
            if not value:
                return text
            try:
                if _transform and _cf.CFStringTransform(value, None, _transform, False):
                    buffer = c.create_string_buffer(_cf.CFStringGetLength(value) * 4 + 1)
                    if _cf.CFStringGetCString(value, buffer, len(buffer), _utf8):
                        return buffer.value.decode("utf-8")
                return text
            finally:
                _cf.CFRelease(value)
        finally:
            _cf.CFRelease(source)

    def _values(value):
        if isinstance(value, list):
            return [_values(item) for item in value]
        if isinstance(value, dict):
            return {key: _values(item) for key, item in value.items()}
        return _simplify(value) if isinstance(value, str) else value

    def _reply(text):
        if not isinstance(text, str):
            return text
        # Batches can escape Han characters in JSON strings.
        if "\\u" in text:
            content = text.strip()
            before = after = ""
            fence = chr(96) * 3
            if content.startswith(fence) and content.endswith(fence):
                before, _, content = content.partition("\n")
                before += "\n"
                content, after = content[:-3], content[-3:]
            if content.lstrip().startswith(("[", "{")):
                try:
                    return before + json.dumps(_values(json.loads(content)), ensure_ascii=False) + "\n" + after
                except (ValueError, UnicodeError, RecursionError):
                    pass
        return _simplify(text)

    def _wrapped(method):
        @functools.wraps(method)
        def call(*args, **kwargs):
            return _reply(method(*args, **kwargs))
        return call

    class _OutputLoader(importlib.abc.Loader):
        def __init__(self, loader):
            self.loader = loader

        def create_module(self, spec):
            return self.loader.create_module(spec)

        def exec_module(self, module):
            self.loader.exec_module(module)
            translator = getattr(module, "OpenAITranslator", None)
            for name in ("do_translate", "do_llm_translate"):
                method = getattr(translator, name, None)
                if method:
                    setattr(translator, name, _wrapped(method))

    class _FindOpenAITranslator(importlib.abc.MetaPathFinder):
        def find_spec(self, name, path, target=None):
            if name != "pdf2zh_next.translator.translator_impl.openai":
                return None
            spec = importlib.machinery.PathFinder.find_spec(name, path, target)
            if spec and spec.loader:
                spec.loader = _OutputLoader(spec.loader)
            return spec

    sys.meta_path.insert(0, _FindOpenAITranslator())
    """#

    private static func prepare(_ input: URL, source: PDFTranslationSource, scope: PDFTranslationScope) throws {
        try Task.checkCancellation()
        guard try PDFReader.fingerprint(input) == source.document.revision,
              let document = PDFDocument(url: input), !document.isLocked, document.pageCount == source.pageCount else {
            throw InputError.invalid("原文已更改。请重新打开后再生成。")
        }
        let pages = scope.indices(pageCount: source.pageCount)
        var readablePage = false
        for index in pages {
            try Task.checkCancellation()
            let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if PDFQuoteQuality.isSuspicious(text) {
                throw InputError.invalid("原文第 \(index + 1) 页的文字层可能有错码。请在原页校对文字，也可以关联已校对的译文 PDF。")
            }
            if text.count >= 10 { readablePage = true }
        }
        if !readablePage {
            throw InputError.invalid("所选 PDF 页没有可用文字。扫描件可先识别文字，再翻译选区。")
        }
    }
}

private final class TranslationProcess {
    private let lock = NSLock()
    private var cancelled = false
    private var running: Process?

    func wait(for process: Process) async throws -> Int32 {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do {
                    try process.run()
                    running = process
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: InputError.invalid("无法启动所选 PDF 翻译工具。请重新选择可运行的程序。"))
                }
            }
        }, onCancel: { self.stop() })
    }

    private func stop() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let running, running.isRunning { running.terminate() }
    }
}

final class PDFTranslationJobs: ObservableObject {
    struct Activity: Equatable {
        let document: TranslationDocument
        let scope: PDFTranslationScope
        let profile: String?
        let owner: UUID?
        var cancelling = false
    }

    struct Outcome {
        let document: TranslationDocument
        let scope: PDFTranslationScope
        let profile: String?
        let owner: UUID?
        let file: PDFTranslationFile?
        let message: String?
        var cancelled = false
    }

    @Published private(set) var activity: Activity?
    @Published private(set) var outcome: Outcome?
    private let archive: ReadingTranslationArchive
    private var task: Task<Void, Never>?

    init(archive: ReadingTranslationArchive) { self.archive = archive }

    func start(_ source: PDFTranslationSource, scope: PDFTranslationScope, settings: ReadingTranslationSettings, owner: UUID? = nil) {
        guard activity == nil else { return }
        let profile = settings.pdfProfile
        activity = Activity(document: source.document, scope: scope, profile: profile, owner: owner)
        outcome = nil
        let archive = archive
        let worker = Task.detached(priority: .userInitiated) {
            try await PDFTranslationTool.generate(source, scope: scope, settings: settings, archive: archive)
        }
        task = Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler(operation: { await worker.result }, onCancel: { worker.cancel() })
            guard let self else { return }
            self.activity = nil
            self.task = nil
            switch result {
            case .success(let file):
                self.outcome = Outcome(document: source.document, scope: scope, profile: profile, owner: owner, file: file, message: nil)
            case .failure(let error):
                let cancelled = error is CancellationError
                self.outcome = Outcome(document: source.document, scope: scope, profile: profile, owner: owner, file: nil,
                                       message: cancelled ? "已停止翻译。" : error.localizedDescription, cancelled: cancelled)
            }
        }
    }

    func cancel() {
        guard let activity, !activity.cancelling else { return }
        self.activity?.cancelling = true
        task?.cancel()
    }

    func clearOutcome(for document: TranslationDocument) {
        if outcome?.document == document { outcome = nil }
    }
}

struct PDFTranslationFollow {
    let page: Int
    let pageCount: Int
    let automatic: Bool
    let manual: Bool

    var pages: [Int] {
        guard (0..<pageCount).contains(page), automatic || manual else { return [] }
        return automatic && page + 1 < pageCount ? [page, page + 1] : [page]
    }

    func next(available: (Int) -> Bool, failed: Set<Int>) -> Int? {
        // When the current page failed, leave reading available and wait for a retry or a new page.
        guard let needed = pages.first(where: { !available($0) }), !failed.contains(needed) else { return nil }
        return needed
    }
}

enum PDFTranslationHeadings {
    private static let headings = try! NSRegularExpression(
        pattern: #"(?mi)^[ \t]*(\d{1,3}(?:\.\d{1,3})*)(?:[.．、][ \t]*|[ \t]+)(?!https?://|www\.)(?=\p{L})"#
    )

    static func changed(source: String?, translation: String?) -> Bool {
        guard let source, let translation, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let original = numbers(in: source)
        return !original.isEmpty && original != numbers(in: translation)
    }

    static func changed(on source: PDFPage?, comparedWith translation: PDFPage?) -> Bool {
        guard let source, let translation, let originalText = source.string, let translatedText = translation.string,
              !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let original = numbers(in: originalText, on: source)
        return !original.isEmpty && original != numbers(in: translatedText, on: translation)
    }

    private static func numbers(in text: String, on page: PDFPage? = nil) -> [String] {
        // This normalization has the same UTF-16 length for the full-width digits and punctuation.
        // Use the original string for PDFKit ranges whenever other glyphs changed the length.
        let folded = text.folding(options: .widthInsensitive, locale: nil)
        let value = folded.utf16.count == text.utf16.count ? folded : text
        let source = value as NSString
        let range = NSRange(location: 0, length: source.length)
        let matches = headings.matches(in: value, range: range)
        guard let page, !matches.isEmpty else { return matches.map { source.substring(with: $0.range(at: 1)) }.sorted() }

        let crop = page.bounds(for: .cropBox)
        let noteBand = crop.minY + crop.height * 0.23
        let bodyHeights = PDFTextLine.lines(in: text, on: page).compactMap { line -> CGFloat? in
            guard let bounds = line.bounds ?? page.textSelection(in: line.range)?.bounds(for: page),
                  bounds.midY > noteBand, bounds.width >= crop.width * 0.25, !bounds.isEmpty else { return nil }
            return bounds.height
        }.sorted()
        let bodyHeight = bodyHeights.isEmpty ? 0 : bodyHeights[bodyHeights.count / 2]
        return matches.compactMap { match in
            if let rect = page.textSelection(in: match.range(at: 1))?.bounds(for: page),
               rect.midY < noteBand, rect.height < max(7, bodyHeight * 0.85) { return nil }
            return source.substring(with: match.range(at: 1))
        }.sorted()
    }
}
