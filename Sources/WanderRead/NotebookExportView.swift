import SwiftUI
import AppKit

final class NotebookSendState: ObservableObject {
    @Published var configuring = false
    @Published var feedback: String?
    @Published private(set) var failed = false
    var pending = Set<UUID>()

    func send(_ ids: Set<UUID>, from itemID: UUID, store: ReadingStore) {
        guard !ids.isEmpty else { return }
        if store.library.preferences.notebookExport == nil {
            pending = ids
            configuring = true
            return
        }
        do {
            let result = try store.sendNotebookNotes(ids, from: itemID)
            feedback = result.written == 0 ? "这些笔记已经发送过。" : "已送入 Obsidian · \(result.written) 条"
            failed = false
        } catch {
            feedback = error.localizedDescription
            failed = true
        }
    }

    func openSetup() { pending = []; configuring = true }
}

struct NotebookDeliveryStatus: View {
    @ObservedObject var transfer: NotebookSendState
    let open: () -> Void

    var body: some View {
        if let feedback = transfer.feedback {
            VStack(alignment: .leading, spacing: 5) {
                Text(feedback).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Button(transfer.failed ? "检查收件设置" : "打开收件笔记", action: transfer.failed ? transfer.openSetup : open)
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.green)
            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

struct NotebookSendButton: View {
    let sent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: sent ? "checkmark.circle" : "paperplane")
                .frame(width: 24, height: 26)
        }.buttonStyle(.plain)
            .foregroundColor(Palette.green)
            .help(sent ? "已发送 · 打开 Obsidian 收件笔记" : "发送到 Obsidian")
            .accessibilityLabel(sent ? "打开 Obsidian 收件笔记" : "发送到 Obsidian")
    }
}

struct NotebookBatchControls: View {
    let visible: Set<UUID>
    @Binding var selected: Set<UUID>
    let send: (Set<UUID>) -> Void
    let remove: (Set<UUID>) -> Bool
    @State private var confirming = false
    private var selection: Set<UUID> { visible.intersection(selected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(visible == selection ? "取消全选" : "全选当前") {
                    selected = visible == selection ? [] : visible
                }.buttonStyle(.plain).foregroundColor(Palette.green).disabled(visible.isEmpty)
                Spacer()
                Text("选中 \(selection.count) 条").foregroundColor(Palette.muted)
            }
            HStack(spacing: 12) {
                Button { send(selection) } label: { Label("发送", systemImage: "paperplane") }.disabled(selection.isEmpty)
                Spacer()
                Button(role: .destructive) { confirming = true } label: { Label("清除", systemImage: "trash") }
                    .foregroundColor(.red).disabled(selection.isEmpty)
            }.buttonStyle(.plain).foregroundColor(Palette.green)
        }.font(.system(size: 12, weight: .medium))
            .padding(10).background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .alert("从漫读清除 \(selection.count) 条笔记？", isPresented: $confirming) {
                Button("取消", role: .cancel) {}
                Button("清除选中", role: .destructive) { if remove(selection) { selected = [] } }
            } message: {
                Text("高亮也会一并移除。阅读中可以撤销，已经发到 Obsidian 的笔记会保留。")
            }
    }
}

struct NotebookSelectionToggle: View {
    let id: UUID
    @Binding var selected: Set<UUID>
    var body: some View {
        Toggle("选中这条笔记", isOn: Binding(get: { selected.contains(id) }, set: {
            if $0 { selected.insert(id) } else { selected.remove(id) }
        })).toggleStyle(.checkbox).labelsHidden().accessibilityLabel("选中这条笔记")
    }
}

struct NotebookExportEditor: View {
    @ObservedObject var store: ReadingStore
    var pendingCount = 0
    var afterSave: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = NotebookExportSettings()
    @State private var header = false
    @State private var field = "quote"
    @State private var issue: String?
    private let sample = ReaderNote(id: UUID(), kind: "批注", location: "PDF 第 12 页",
                                    quote: "让原文和自己的问题并排。", comment: "回看这里的判断依据。", color: "黄色")
    private let sampleItem = ReadingItem(title: "一篇正在读的文章", target: "https://example.com", tags: ["阅读"])

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 13) {
                Image(systemName: "paperplane").font(.system(size: 17, weight: .medium))
                    .frame(width: 42, height: 42).background(Palette.card, in: RoundedRectangle(cornerRadius: 11)).foregroundColor(Palette.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Obsidian 收件").font(.system(size: 28, weight: .medium, design: .serif))
                    Text("每篇一份 Markdown 笔记，按发送顺序追加。").font(.system(size: 12)).foregroundColor(Palette.muted)
                }
                Spacer()
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.vault.isEmpty ? "还没选择仓库" : URL(fileURLWithPath: draft.vault).lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                    if !draft.vault.isEmpty { Text(draft.vault).font(.system(size: 10)).foregroundColor(Palette.muted).lineLimit(1).truncationMode(.middle) }
                }
                Spacer()
                Button("选择仓库…", action: chooseVault).buttonStyle(ActionStyle())
            }
            HStack {
                Text("收件文件夹").font(.system(size: 13))
                TextField("仓库根目录", text: $draft.folder).textFieldStyle(.roundedBorder)
            }
            Divider()
            HStack(spacing: 12) {
                Picker("编辑模板", selection: $header) {
                    Text("每条笔记").tag(false)
                    Text("新笔记开头").tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 219)
                Spacer()
                Picker("模板字段", selection: $field) {
                    ForEach(NotebookExport.fields, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 129)
                Button("添加字段") {
                    if header { draft.header += "{{\(field)}}" }
                    else { draft.entry += "{{\(field)}}" }
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Palette.green)
            }
            HStack(alignment: .top, spacing: 12) {
                TextEditor(text: header ? $draft.header : $draft.entry)
                    .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                    .padding(7).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(header ? "新笔记模板" : "单条笔记模板")
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("示例预览").font(.system(size: 11, weight: .medium)).foregroundColor(Palette.green)
                        Text(preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
                }.frame(width: 246).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            }.frame(height: 161)
            if let issue { Text(issue).font(.system(size: 12)).foregroundColor(.red) }
            else {
                Text("可以使用 Markdown 和字段。已发送的笔记由你在 Obsidian 编辑。")
                    .font(.system(size: 11)).foregroundColor(Palette.muted)
            }
            HStack {
                Button("恢复默认模板") {
                    draft.header = NotebookExportSettings.defaultHeader
                    draft.entry = NotebookExportSettings.defaultEntry
                }.buttonStyle(.plain).foregroundColor(Palette.green)
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
                Button(pendingCount > 0 ? "保存并发送" : "保存设置", action: save)
                    .buttonStyle(ActionStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 645).background(Palette.paper).foregroundColor(Palette.ink)
            .onAppear { draft = store.library.preferences.notebookExport ?? NotebookExportSettings() }
    }

    private var preview: String {
        do {
            let value = try NotebookExport.render(header ? draft.header : draft.entry, fields: NotebookExport.values(item: sampleItem, note: sample))
            return value.isEmpty ? "留空" : value
        } catch { return error.localizedDescription }
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "选择 Obsidian 仓库根目录"
        if panel.runModal() == .OK, let url = panel.url { draft.vault = url.resolvingSymlinksInPath().path; issue = nil }
    }

    private func save() {
        do {
            try draft.validate()
            guard store.commit({ $0.preferences.notebookExport = draft }) else { return }
            afterSave?()
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
