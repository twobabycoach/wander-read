import SwiftUI
import AppKit

final class NotebookSendState: ObservableObject {
    enum Feedback {
        case sent(Int, citationKey: String?, missingCitation: Bool)
        case failed(String)
    }

    @Published var configuring = false
    @Published var editingCitation = false
    @Published var feedback: Feedback?
    @Published private(set) var sending = false
    private(set) var pending = Set<UUID>()
    private var lastAttempt = Set<UUID>()

    @MainActor
    func send(_ ids: Set<UUID>, from itemID: UUID, store: ReadingStore) {
        guard !ids.isEmpty, !sending else { return }
        if store.library.preferences.notebookExport == nil {
            pending = ids
            configuring = true
            return
        }
        feedback = nil
        lastAttempt = ids
        sending = true
        Task {
            defer { sending = false }
            do {
                let result = try await store.sendNotebookNotes(ids, from: itemID)
                let expected = store.library.items.first { $0.id == itemID }.flatMap(ZoteroAPI.citationLookup) != nil
                feedback = .sent(result.written, citationKey: result.citationKey, missingCitation: expected && result.citationKey == nil)
            } catch {
                feedback = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    func retry(from itemID: UUID, store: ReadingStore) { send(lastAttempt, from: itemID, store: store) }

    func openSetup() { clearPending(); configuring = true }
    func clearPending() { pending.removeAll() }
}

extension View {
    func notebookSheets(_ transfer: NotebookSendState, store: ReadingStore, itemID: UUID) -> some View {
        modifier(NotebookSheets(transfer: transfer, store: store, itemID: itemID))
    }
}

private struct NotebookSheets: ViewModifier {
    @ObservedObject var transfer: NotebookSendState
    @ObservedObject var store: ReadingStore
    let itemID: UUID

    func body(content: Content) -> some View {
        content.sheet(isPresented: $transfer.configuring, onDismiss: transfer.clearPending) {
            NotebookExportEditor(store: store, pendingCount: transfer.pending.count) {
                transfer.send(transfer.pending, from: itemID, store: store)
            }
        }
        .sheet(isPresented: $transfer.editingCitation) {
            if let item = store.library.items.first(where: { $0.id == itemID }) {
                NotebookCitationEditor(store: store, item: item)
            }
        }
    }
}

struct NotebookDeliveryStatus: View {
    @ObservedObject var transfer: NotebookSendState
    @ObservedObject var store: ReadingStore
    let itemID: UUID

    var body: some View {
        if transfer.sending {
            ProgressView("正在发送到 Obsidian…").controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
        } else if let feedback = transfer.feedback {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 6) {
                    switch feedback {
                    case let .sent(count, key, missing):
                        VStack(alignment: .leading, spacing: 4) {
                            Label(count == 0 ? "这些摘录已在 Obsidian" : "已发送 \(count) 条到 Obsidian",
                                  systemImage: "checkmark.circle")
                            if count > 0, let key {
                                Text("@\(key)").font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.muted)
                                    .lineLimit(1).truncationMode(.middle)
                            } else if count > 0 && missing {
                                Text("这次没有读到 Zotero 引文键。").foregroundColor(Palette.muted)
                            }
                        }
                    case let .failed(detail):
                        Label(detail, systemImage: "exclamationmark.circle").fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 3)
                    ReadingIconButton(title: "关闭发送提示", systemImage: "xmark", size: 20) { transfer.feedback = nil }
                }
                HStack(spacing: 3) {
                    switch feedback {
                    case let .sent(_, _, missing):
                        Button("打开笔记") { store.openNotebook(itemID) }.buttonStyle(ReadingControlStyle(accented: true))
                        if missing {
                            Button("设置引文键…") { transfer.editingCitation = true }.buttonStyle(ReadingControlStyle())
                        }
                    case .failed:
                        Button("重试") { transfer.retry(from: itemID, store: store) }.buttonStyle(ReadingControlStyle(accented: true))
                        Button("收件设置…", action: transfer.openSetup).buttonStyle(ReadingControlStyle())
                    }
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface.opacity(0.73), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct NotebookSendButton: View {
    let sent: Bool
    let action: () -> Void

    var body: some View {
        ReadingIconButton(title: sent ? "在 Obsidian 打开已发送的笔记" : "发送这条笔记到 Obsidian",
                          systemImage: sent ? "arrow.up.right.square" : "paperplane", accented: !sent, action: action)
    }
}

struct NotebookBatchControls: View {
    let visible: Set<UUID>
    let sent: Set<UUID>
    let sending: Bool
    @Binding var selected: Set<UUID>
    let send: (Set<UUID>) -> Void
    let remove: (Set<UUID>) -> Bool
    @State private var pendingRemoval = Set<UUID>()
    private var selection: Set<UUID> { visible.intersection(selected) }
    private var waitingToSend: Set<UUID> { selection.subtracting(sent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Button(visible == selection ? "取消全选" : "全选当前结果") {
                    if visible == selection { selected.subtract(visible) }
                    else { selected.formUnion(visible) }
                }.buttonStyle(ReadingControlStyle()).disabled(visible.isEmpty)
                Spacer()
                Text("已选 \(selection.count) 条").monospacedDigit().foregroundColor(Palette.muted)
            }
            HStack(spacing: 4) {
                Button {
                    send(waitingToSend)
                } label: { Label("送到 Obsidian", systemImage: "paperplane") }
                    .buttonStyle(ReadingControlStyle(accented: true)).disabled(sending || waitingToSend.isEmpty)
                    .help("发送尚未送到当前收件位置的笔记")
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    pendingRemoval = selection
                } label: { Label("清除…", systemImage: "trash") }
                    .buttonStyle(ReadingControlStyle()).disabled(sending || selection.isEmpty)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(Palette.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .alert("从漫读清除 \(pendingRemoval.count) 条笔记？", isPresented: Binding(
            get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval.removeAll() } }
        ), presenting: pendingRemoval) { ids in
            Button("取消", role: .cancel) {}
            Button("清除选中", role: .destructive) { if remove(ids) { selected.subtract(ids) } }
        } message: { _ in
            Text("原文上的标记也会移除。本次阅读内可撤销，已发送到 Obsidian 的笔记会保留。")
        }
    }
}

struct NotebookSelectionToggle: View {
    let id: UUID
    @Binding var selected: Set<UUID>
    var body: some View {
        Toggle("选中这条笔记", isOn: Binding(get: { selected.contains(id) }, set: {
            if $0 { selected.insert(id) } else { selected.remove(id) }
        })).toggleStyle(.checkbox).labelsHidden().tint(Palette.accent)
    }
}

struct NotebookCitationEditor: View {
    @ObservedObject var store: ReadingStore
    let item: ReadingItem
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var fetched: String?
    @State private var checking = false
    @State private var issue: String?
    private var entered: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var manual: String? { CitationKey.normalized(entered) }
    private var zoteroKey: String? { fetched ?? CitationKey.normalized(item.zotero?.citationKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("文献引文键").font(.system(size: 24, weight: .medium, design: .serif))
                Text(item.title).font(.system(size: 12)).foregroundColor(Palette.muted).lineLimit(2)
            }
            TextField("手动指定", text: $input, prompt: Text(zoteroKey ?? "例如 oakley2025"))
                .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                .accessibilityLabel("手动指定文献引文键")
            if !entered.isEmpty && manual == nil {
                Text("请输入一个引文键，例如 oakley2025。").foregroundColor(.red)
            } else if let key = manual ?? zoteroKey {
                HStack(spacing: 8) {
                    Text("发送时写入").foregroundColor(Palette.muted)
                    Text(CitationKey.markdown(key)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            } else if checking {
                ProgressView("正在查找 Zotero 引文键…").controlSize(.small)
            } else {
                Text("可填写 Zotero 或文献库中已有的引文键。留空时，发送前会尝试从 Zotero 获取。")
                    .foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let issue { Text(issue).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if !entered.isEmpty, zoteroKey != nil {
                    Button("使用 Zotero 引文键") { input = "" }.buttonStyle(ReadingControlStyle())
                }
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
                Button("保存", action: save).buttonStyle(ActionStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(!entered.isEmpty && manual == nil)
            }
        }
        .font(.system(size: 12)).padding(22).frame(width: 448)
        .background(Palette.paper).foregroundColor(Palette.ink)
        .onAppear { input = item.citationKey ?? "" }
        .task {
            guard !store.isPreview, ZoteroAPI.citationLookup(item) != nil else { return }
            checking = true
            fetched = await ZoteroAPI.citationKey(for: item)
            checking = false
        }
    }

    private func save() {
        guard let current = store.library.items.first(where: { $0.id == item.id && $0.trashedAt == nil }),
              current.target == item.target, current.zotero?.itemKey == item.zotero?.itemKey else {
            issue = "文献入口已变化，请关闭后重新打开。"
            return
        }
        if store.mutate(item.id, {
            $0.citationKey = manual
            if let fetched { $0.zotero?.citationKey = fetched }
        }) { dismiss() }
        else { issue = "暂时无法保存。请重试。" }
    }
}

struct NotebookExportEditor: View {
    @ObservedObject var store: ReadingStore
    var pendingCount = 0
    var afterSave: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = NotebookExportSettings()
    @State private var header = false
    @State private var field = "citation"
    @State private var issue: String?
    @State private var showTemplates = false
    @State private var knownVaults: [URL] = []
    private let sampleID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Obsidian 收件").font(.system(size: 27, weight: .medium, design: .serif))
                Text(pendingCount == 0 ? "同一篇文献的笔记会收在同一个 Markdown 文件。"
                     : "选好位置后，发送已选的 \(pendingCount) 条笔记。")
                    .font(.system(size: 12)).foregroundColor(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    formLabel("目标仓库")
                    Text(draft.vault.isEmpty ? "未选择" : URL(fileURLWithPath: draft.vault).lastPathComponent)
                        .foregroundColor(draft.vault.isEmpty ? Palette.muted : Palette.ink)
                        .lineLimit(1).truncationMode(.middle).help(draft.vault)
                    Spacer(minLength: 8)
                    if knownVaults.isEmpty {
                        Button("选择仓库…", action: chooseVault).buttonStyle(ActionStyle())
                    } else {
                        Menu("选择仓库") {
                            ForEach(knownVaults, id: \.path) { url in
                                Button(url.lastPathComponent) { selectVault(url) }.help(url.path)
                            }
                            Divider()
                            Button("浏览文件夹…", action: chooseVault)
                        }.fixedSize()
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    formLabel("收件文件夹")
                    TextField("仓库根目录", text: $draft.folder).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("收件文件夹").onChange(of: draft.folder) { _ in issue = nil }
                    ReadingIconButton(title: "浏览仓库内的收件文件夹", systemImage: "folder", action: chooseFolder)
                        .disabled(draft.vault.isEmpty)
                }
            }
            .font(.system(size: 13)).padding(12)
            .background(Palette.surface.opacity(0.64), in: RoundedRectangle(cornerRadius: 9))

            DisclosureGroup("笔记模板与引文", isExpanded: $showTemplates) {
                templateEditor.padding(.top, 12)
            }.tint(Palette.green)
            if let issue { Label(issue, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundColor(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
                Button(pendingCount > 0 ? "保存并发送" : "保存设置", action: save)
                    .buttonStyle(ActionStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(draft.vault.isEmpty)
            }
        }
        .padding(23).frame(width: 654).background(Palette.paper).foregroundColor(Palette.ink)
        .onAppear(perform: loadSettings)
    }

    private func formLabel(_ title: String) -> some View {
        Text(title).fontWeight(.medium).frame(width: 75, alignment: .leading)
    }

    private var templateEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ReadingTabs(selection: $header, options: [(false, "每条笔记"), (true, "文件开头")])
                    .accessibilityLabel("模板位置")
                Spacer()
                Picker("模板字段", selection: $field) {
                    ForEach(NotebookExport.fields, id: \.self) { Text(fieldTitle($0)).tag($0) }
                }.labelsHidden().frame(width: 137)
                Button("追加字段") {
                    if header { appendField(to: &draft.header) }
                    else { appendField(to: &draft.entry) }
                }.buttonStyle(ReadingControlStyle(accented: true))
            }
            HStack(alignment: .top, spacing: 8) {
                TextEditor(text: header ? $draft.header : $draft.entry)
                    .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                    .padding(8).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(header ? "文件开头模板" : "每条笔记模板")
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("示例 Markdown").font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.green)
                        Text(preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.frame(width: 265).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            }.frame(height: 174)
            HStack {
                Text("有引文键时，默认随每条笔记写入。").font(.system(size: 11)).foregroundColor(Palette.muted)
                Spacer()
                Button("恢复默认模板") {
                    draft.header = NotebookExportSettings.defaultHeader
                    draft.entry = NotebookExportSettings.defaultEntry
                }.buttonStyle(ReadingControlStyle())
            }
        }
    }

    private func appendField(to template: inout String) {
        if !template.isEmpty && !template.hasSuffix("\n\n") {
            template += template.hasSuffix("\n") ? "\n" : "\n\n"
        }
        template += "{{\(field)}}"
    }

    private func fieldTitle(_ name: String) -> String {
        let names = ["title": "文献标题", "kind": "笔记类型", "location": "原文位置", "quote": "所选原文",
                     "blockquote": "原文引用块", "comment": "批注", "image": "图摘", "color": "标记颜色",
                     "source_link": "回原文链接", "source_url": "文献入口", "tags": "主题",
                     "created_at": "摘录时间", "excerpt_id": "笔记标识", "zotero_item_key": "Zotero 条目标识",
                     "citation": "引文（含页码）", "citekey": "仅引文键"]
        return names[name] ?? name
    }

    private func loadSettings() {
        draft = store.library.preferences.notebookExport ?? NotebookExportSettings()
        if draft.usesDefaultEntry { draft.entry = NotebookExportSettings.defaultEntry }
        guard !store.isPreview else { return }
        let roots = Set(ObsidianLinks.registeredVaults().map { $0.root.resolvingSymlinksInPath().standardizedFileURL })
        knownVaults = roots.filter { root in
            (try? NotebookExportSettings(vault: root.path, folder: "").directory()) != nil
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if draft.vault.isEmpty, knownVaults.count == 1, let root = knownVaults.first { selectVault(root) }
    }

    private func selectVault(_ url: URL) {
        draft.vault = url.resolvingSymlinksInPath().standardizedFileURL.path
        issue = nil
    }

    private var preview: String {
        var note = ReaderNote(id: sampleID, kind: "摘录", location: "PDF 第 5 页 · 版面 42",
                              quote: "理论的解释力要回到证据中检验。", comment: "对照作者的前一个论点。")
        note.citationLocator = "p. 42"
        let item = ReadingItem(title: "学术文献示例", target: "https://example.com", citationKey: "zhang2025")
        let values = NotebookExport.values(item: item, note: note)
        do {
            let value = header ? try NotebookExport.render(draft.header, fields: values) : try NotebookExport.renderEntry(draft, fields: values)
            return value.isEmpty ? "留空" : value
        } catch { return error.localizedDescription }
    }

    private func chooseVault() {
        let panel = directoryPicker(prompt: "选择仓库", message: "选择 Obsidian 仓库或仓库里的一层文件夹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { selectVault(try ObsidianLinks.root(containing: url)) }
        catch { issue = error.localizedDescription }
    }

    private func chooseFolder() {
        let root = URL(fileURLWithPath: draft.vault).resolvingSymlinksInPath().standardizedFileURL
        let panel = directoryPicker(prompt: "选为收件文件夹", message: "选择当前仓库内的收件位置")
        panel.directoryURL = root
        guard panel.runModal() == .OK, let selected = panel.url?.resolvingSymlinksInPath().standardizedFileURL else { return }
        if selected.path == root.path { draft.folder = "" }
        else if selected.path.hasPrefix(root.path + "/") { draft.folder = String(selected.path.dropFirst(root.path.count + 1)) }
        else { issue = "请选择当前 Obsidian 仓库内的文件夹。" }
    }

    private func directoryPicker(prompt: String, message: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = prompt
        panel.message = message
        return panel
    }

    private func save() {
        do {
            try draft.validate()
            guard store.commit({ $0.preferences.notebookExport = draft }) else {
                issue = "暂时无法保存收件设置。请重试。"
                return
            }
            afterSave?()
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
