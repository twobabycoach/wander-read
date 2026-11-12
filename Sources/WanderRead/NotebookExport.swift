import AppKit
import Darwin

struct NotebookExportSettings: Codable, Equatable {
    var vault = ""
    var folder = "漫读收件箱"
    var header = Self.defaultHeader
    var entry = Self.defaultEntry

    static let defaultHeader = "# {{title}}"
    static let defaultEntry = "### {{kind}} · {{location}}\n\n{{image}}\n\n{{blockquote}}\n\n{{comment}}\n\n{{source_link}}"

    func directory() throws -> URL {
        guard vault.hasPrefix("/") else { throw InputError.invalid("请先选择一个 Obsidian 仓库。") }
        let root = URL(fileURLWithPath: vault, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".obsidian").path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw InputError.invalid("找不到这个 Obsidian 仓库。请重新选择仓库根目录。") }
        let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = name.isEmpty ? [] : name.components(separatedBy: "/")
        guard parts.count <= 12, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains(":") &&
            !$0.utf8.contains(0) && $0.utf8.count < 160 }) else {
            throw InputError.invalid("目标请填写仓库内的文件夹，例如「研究/漫读收件箱」。")
        }
        var directory = root
        for part in parts {
            directory.appendPathComponent(part, isDirectory: true)
            let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values?.isSymbolicLink != true, values?.isDirectory != false else {
                throw InputError.invalid("目标包含文件或符号链接，请换一个仓库内的文件夹。")
            }
        }
        let safe = directory.resolvingSymlinksInPath().standardizedFileURL
        guard safe.path == root.path || safe.path.hasPrefix(root.path + "/") else {
            throw InputError.invalid("目标文件夹必须位于选中的仓库内。")
        }
        return safe
    }

    func validate() throws {
        _ = try directory()
        guard !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.utf8.count <= 16_000, header.utf8.count <= 16_000 else {
            throw InputError.invalid("每条笔记模板需有内容，两种模板各最多 16 KB。")
        }
        _ = try NotebookExport.render(header, fields: [:])
        _ = try NotebookExport.render(entry, fields: [:])
    }
}

struct NotebookDelivery: Codable, Equatable {
    var directory: String
    var file: String
    var sent: Set<UUID>
}

struct ReaderNote: Identifiable {
    let id: UUID
    let kind: String
    let location: String
    let quote: String
    let comment: String
    var color = ""
    var date: Date?
    var image: Data?

    init(id: UUID, kind: String, location: String, quote: String, comment: String, color: String = "", date: Date? = nil) {
        self.id = id; self.kind = kind; self.location = location; self.quote = quote; self.comment = comment
        self.color = color; self.date = date
    }

    init(_ mark: PDFReadingMark) {
        let pages = mark.lines.map(\.page) + [mark.location.page]
        let start = (pages.min() ?? mark.location.page) + 1
        let end = (pages.max() ?? mark.location.page) + 1
        let kind = mark.scan != nil ? "图摘" : mark.isExcerpt == true ? "摘录" : mark.kind == .detour ? "暂放" : mark.lines.isEmpty ? "页边记" : mark.note.isEmpty ? "高亮" : "批注"
        let printed = mark.printedPage.map { " · 版面 " + $0 } ?? ""
        let place = start == end ? "PDF 第 \(start) 页" + printed : "PDF 第 \(start)–\(end) 页"
        self.init(id: mark.id, kind: kind, location: place,
                  quote: mark.quote, comment: mark.note, color: mark.lines.isEmpty ? "" : (mark.color ?? .yellow).title, date: mark.createdAt)
        image = mark.scan?.jpeg
    }

    init(_ excerpt: TextExcerpt) {
        self.init(id: excerpt.id, kind: "摘录", location: excerpt.place, quote: excerpt.quote, comment: excerpt.note, date: excerpt.createdAt)
    }
}

struct ReaderNoteLink {
    let itemID: UUID
    let noteID: UUID

    var url: String { "wanderread://read?item=\(itemID.uuidString)&note=\(noteID.uuidString)" }

    init(itemID: UUID, noteID: UUID) { self.itemID = itemID; self.noteID = noteID }

    init(_ url: URL) throws {
        let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard url.scheme == "wanderread", url.host == "read",
              let item = fields.first(where: { $0.name == "item" })?.value.flatMap(UUID.init(uuidString:)),
              let note = fields.first(where: { $0.name == "note" })?.value.flatMap(UUID.init(uuidString:)) else {
            throw InputError.invalid("这条漫读笔记链接不完整。")
        }
        self.init(itemID: item, noteID: note)
    }
}

enum NotebookExport {
    struct Result {
        let delivery: NotebookDelivery
        let written: Int
    }

    static let fields = ["title", "kind", "location", "quote", "blockquote", "comment", "image", "color", "source_link", "source_url",
                         "tags", "created_at", "excerpt_id", "zotero_item_key"]
    private static let variable = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z_][A-Za-z_0-9]*)\s*\}\}"#)
    private static let maxBytes = 12_000_000

    static func render(_ template: String, fields values: [String: String]) throws -> String {
        let text = template as NSString
        var cursor = 0
        var output = ""
        for match in variable.matches(in: template, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1))
            guard fields.contains(name) else { throw InputError.invalid("模板字段「\(name)」无法识别。") }
            output += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += values[name] ?? ""
            cursor = NSMaxRange(match.range)
        }
        output += text.substring(from: cursor)
        return output
    }

    static func values(item: ReadingItem, note: ReaderNote) -> [String: String] {
        let link = ReaderNoteLink(itemID: item.id, noteID: note.id).url
        let quoted = note.quote.isEmpty ? "" : note.quote.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        let date = note.date.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        return ["title": item.title, "kind": note.kind, "location": note.location, "quote": note.quote,
                "image": note.image == nil ? "" : "![框选原图](<附件/\(imageName(note.id))>)",
                "blockquote": quoted, "comment": note.comment, "color": note.color, "source_link": "[在漫读中回到原文](\(link))",
                "source_url": item.target, "tags": item.tags.joined(separator: "、"), "created_at": date,
                "excerpt_id": note.id.uuidString.lowercased(), "zotero_item_key": item.zotero?.itemKey ?? ""]
    }

    static func deliver(_ notes: [ReaderNote], from item: ReadingItem, using settings: NotebookExportSettings) throws -> Result {
        try settings.validate()
        let directory = try settings.directory()
        guard let first = notes.first else { throw InputError.invalid("请先选择要发送的笔记。") }
        let previous = item.notebookDeliveries?.first { $0.directory == directory.path }
        let id = item.id.uuidString.lowercased()
        var safeTitle = String(item.title.prefix(38)).components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"><|")
            .union(.controlCharacters)).joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while safeTitle.utf8.count > 140 { safeTitle.removeLast() }
        let initial = (safeTitle.isEmpty ? "阅读笔记" : safeTitle) + " · " + id.prefix(12) + ".md"
        let storedFile = previous?.file ?? initial
        let file = storedFile == URL(fileURLWithPath: storedFile).lastPathComponent && storedFile.hasSuffix(".md") && !storedFile.hasPrefix(".") ? storedFile : initial
        var delivery = NotebookDelivery(directory: directory.path, file: file, sent: previous?.sent ?? [])
        guard notes.contains(where: { !delivery.sent.contains($0.id) }) else { return Result(delivery: delivery, written: 0) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = "<!-- wanderread-document:\(id) -->"
        let header = try render(settings.header, fields: values(item: item, note: first))
        let target = directory.appendingPathComponent(file)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Swift.Result<Result, Error>?
        coordinator.coordinate(writingItemAt: target, options: [], error: &coordinationError) { url in
            outcome = Swift.Result {
                guard try settings.directory().path == directory.path,
                      url.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.path,
                      url.lastPathComponent == target.lastPathComponent else {
                    throw InputError.invalid("目标路径刚刚发生了变化，请检查 Obsidian 仓库后重试。")
                }
                var original: Data?
                var body = ""
                let attributes = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                if let attributes {
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                          (attributes.fileSize ?? 0) <= maxBytes else {
                        throw InputError.invalid("同名目标不是可写的 Markdown 笔记，或文件已超过 12 MB。")
                    }
                    let bytes = try Data(contentsOf: url)
                    guard let text = String(data: bytes, encoding: .utf8),
                          text.components(separatedBy: .newlines).contains(marker) else {
                        throw InputError.invalid("发现同名文件。为保留你的笔记，请换一个收件文件夹后重试。")
                    }
                    original = bytes
                    body = text
                } else if FileManager.default.fileExists(atPath: url.path) {
                    throw InputError.invalid("目标文件暂时无法读取，请稍后重试。")
                }
                let lines = Set(body.components(separatedBy: .newlines))
                var additions: [String] = []
                var assets: [(UUID, Data)] = []
                for note in notes where !delivery.sent.contains(note.id) {
                    let noteMarker = "<!-- wanderread-note:\(note.id.uuidString.lowercased()) -->"
                    if !lines.contains(noteMarker) {
                        let fields = values(item: item, note: note)
                        let text = try render(settings.entry, fields: fields)
                        if let image = note.image, let link = fields["image"], text.contains(link) {
                            assets.append((note.id, image))
                        }
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw InputError.invalid("模板在部分笔记上生成了空内容。请加入原文、想法或出处字段后再发送。")
                        }
                        additions.append(text + "\n\n" + noteMarker)
                    }
                    delivery.sent.insert(note.id)
                }
                if !additions.isEmpty {
                    var data = original ?? Data((header.isEmpty ? marker : header + "\n\n" + marker).utf8)
                    data.append(contentsOf: ("\n\n" + additions.joined(separator: "\n\n") + "\n").utf8)
                    guard data.count <= maxBytes else { throw InputError.invalid("本次发送会使收件笔记超过 12 MB，请分到另一个收件文件夹。") }
                    var created: [URL] = []
                    do {
                        if !assets.isEmpty {
                            let folder = directory.appendingPathComponent("附件", isDirectory: true)
                            if let info = try? folder.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                               info.isSymbolicLink == true || info.isDirectory == false {
                                throw InputError.invalid("收件文件夹中的「附件」位置不可写。")
                            }
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            for (id, bytes) in assets {
                                let file = folder.appendingPathComponent(imageName(id))
                                if let info = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) {
                                    guard info.isSymbolicLink != true, info.isRegularFile == true, info.fileSize == bytes.count,
                                          try Data(contentsOf: file) == bytes else {
                                        throw InputError.invalid("发现同名图摘附件。请换一个收件文件夹。")
                                    }
                                } else {
                                    try writeNew(bytes, to: file)
                                    created.append(file)
                                }
                            }
                        }
                        if let original {
                            guard try Data(contentsOf: url) == original else { throw InputError.invalid("Obsidian 正在编辑这份笔记，请保存后重试。") }
                            try data.write(to: url, options: .atomic)
                        } else {
                            try writeNew(data, to: url)
                        }
                    } catch {
                        for file in created { try? FileManager.default.removeItem(at: file) }
                        throw error
                    }
                }
                return Result(delivery: delivery, written: additions.count)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw InputError.invalid("暂时无法访问 Obsidian 收件文件夹。") }
        return try outcome.get()
    }

    private static func imageName(_ id: UUID) -> String { "漫读-\(id.uuidString.lowercased()).jpg" }

    private static func writeNew(_ data: Data, to destination: URL) throws {
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".wanderread-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: stage) }
        try data.write(to: stage, options: .atomic)
        let status = stage.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                renamex_np(source, target, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

extension ReadingStore {
    func deliveredNotes(for id: UUID) -> Set<UUID> {
        guard let settings = library.preferences.notebookExport else { return [] }
        // Resolve the selected folder only when sending/opening. Drawing cards needs no disk access.
        let folder = settings.folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = URL(fileURLWithPath: settings.vault, isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true).standardizedFileURL.path
        return library.items.first { $0.id == id }?.notebookDeliveries?.first { $0.directory == directory }?.sent ?? []
    }

    func sendNotebookNotes(_ ids: Set<UUID>, from itemID: UUID) throws -> NotebookExport.Result {
        guard !recoveryRequired, let item = library.items.first(where: { $0.id == itemID && $0.trashedAt == nil }),
              let settings = library.preferences.notebookExport else { throw InputError.invalid("请先设置 Obsidian 收件位置。") }
        let notes = (item.pdfReading?.marks.map(ReaderNote.init) ?? []) + (item.textReading?.excerpts.map(ReaderNote.init) ?? [])
        let result = try NotebookExport.deliver(notes.filter { ids.contains($0.id) }, from: item, using: settings)
        let delivery = result.delivery
        let old = item.notebookDeliveries ?? []
        if !old.contains(delivery) {
            guard mutate(itemID, { $0.notebookDeliveries = old.filter { $0.directory != delivery.directory } + [delivery] }) else {
                throw InputError.invalid("笔记已写入 Obsidian，漫读暂时无法保存发送回执。重试会核对笔记里的记录。")
            }
        }
        return result
    }

    func openNotebook(_ itemID: UUID, noteID: UUID? = nil) {
        guard let settings = library.preferences.notebookExport,
              let directory = try? settings.directory(),
              let delivery = library.items.first(where: { $0.id == itemID })?.notebookDeliveries?.first(where: { $0.directory == directory.path }),
              delivery.file == URL(fileURLWithPath: delivery.file).lastPathComponent else {
            error = "这篇文献还没有发送到当前收件位置。"; return
        }
        let url = directory.appendingPathComponent(delivery.file)
        let marker = noteID.map { "<!-- wanderread-note:\($0.uuidString.lowercased()) -->" }
            ?? "<!-- wanderread-document:\(itemID.uuidString.lowercased()) -->"
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 12_000_000,
              let text = try? String(contentsOf: url, encoding: .utf8),
              text.components(separatedBy: .newlines).contains(marker) else {
            error = "收件笔记可能已在 Obsidian 移动或改名。已发送的内容仍可在仓库中搜索。"; return
        }
        if let link = URL(string: ObsidianLinks.uri(file: url)), !NSWorkspace.shared.open(link) {
            error = "请先在 Obsidian 打开这个仓库。"
        }
    }
}

extension ReadingStore {
    func revealReaderNote(_ link: ReaderNoteLink) {
        guard let item = library.items.first(where: { $0.id == link.itemID && $0.trashedAt == nil }) else {
            error = "这篇材料已不在漫读收藏里。Obsidian 里保存的笔记仍可阅读。"; return
        }
        if let mark = item.pdfReading?.marks.first(where: { $0.id == link.noteID }) {
            inspection = ReadingInspection(item: item, purpose: .pdf(mark.location, revision: mark.revision,
                                           lines: mark.lines, note: mark.id), quote: mark.quote,
                                           knownURL: pdfReader?.itemID == item.id ? pdfReader?.url : nil)
        } else if let note = item.textReading?.excerpts.first(where: { $0.id == link.noteID }) {
            inspection = ReadingInspection(item: item, purpose: .text(note), quote: note.quote,
                                           knownURL: textReader?.itemID == item.id ? textReader?.url : nil)
        } else {
            error = "这条批注已从漫读移除。可从收藏打开文档，参照 Obsidian 里保存的出处。"
        }
    }
}
