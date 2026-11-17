import SwiftUI

struct ReadingNoteFilter: Equatable {
    var query = ""
    var color: ReadingMarkColor?
    var excerptsOnly = false

    var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isFiltering: Bool { !text.isEmpty || color != nil || excerptsOnly }

    func matches(color: ReadingMarkColor?, isExcerpt: Bool = true, text fields: String...) -> Bool {
        if let chosen = self.color, color != chosen { return false }
        if excerptsOnly && !isExcerpt { return false }
        let term = text
        return term.isEmpty || fields.contains { $0.localizedStandardContains(term) }
    }

    func including(color: ReadingMarkColor?, isExcerpt: Bool = true, text fields: [String]) -> Self {
        let term = text
        return ReadingNoteFilter(
            query: term.isEmpty || fields.contains { $0.localizedStandardContains(term) } ? query : "",
            color: self.color == color ? self.color : nil,
            excerptsOnly: excerptsOnly && isExcerpt
        )
    }
}

struct ReadingNotesHeader: View {
    let total: Int
    let visible: Int
    let selecting: Bool
    var canFilterExcerpts = false
    var searchPrompt = "搜原文、想法或页码"
    @Binding var filter: ReadingNoteFilter
    let toggleSelection: () -> Void
    let close: () -> Void
    var undo: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("摘录与批注").font(.system(size: 14, weight: .semibold))
                Text(filter.isFiltering ? "\(visible)/\(total)" : "\(total)")
                    .font(.system(size: 11)).monospacedDigit().foregroundColor(Palette.muted)
                Spacer(minLength: 0)
                if total > 0 {
                    ReadingIconButton(title: selecting ? "完成选择" : "批量选择",
                                      systemImage: selecting ? "checkmark" : "checklist", selected: selecting,
                                      action: toggleSelection)
                }
                if let undo { ReadingIconButton(title: "撤销笔记改动", systemImage: "arrow.uturn.backward", action: undo) }
                ReadingIconButton(title: "关闭摘录侧栏", systemImage: "xmark", action: close)
            }
            if total > 0 {
                HStack(spacing: 5) {
                    ReadingSearchField(prompt: searchPrompt, query: $filter.query)
                    Menu {
                        Picker("颜色", selection: $filter.color) {
                            Text("所有颜色").tag(ReadingMarkColor?.none)
                            ForEach(ReadingMarkColor.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                        }
                        if canFilterExcerpts {
                            Divider()
                            Toggle("只看摘录", isOn: $filter.excerptsOnly)
                        }
                        if filter.isFiltering {
                            Divider()
                            Button("清除筛选") { filter = ReadingNoteFilter() }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .frame(width: 28, height: 28)
                            .foregroundColor(filter.color != nil || filter.excerptsOnly ? Palette.green : Palette.muted)
                            .background(Palette.green.opacity(filter.color != nil || filter.excerptsOnly ? 0.12 : 0),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
                    .help("按颜色和类型筛选")
                    .accessibilityLabel("筛选笔记")
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
    }
}

struct ReadingNoteQuote: View {
    let text: String
    var color: ReadingMarkColor?
    var editing = false
    @State private var expanded = false
    @State private var clipped = false
    @ObservedObject private var appearance = Palette.selection

    private var quote: some View {
        Text(text)
            .font(.system(size: 13)).foregroundColor(appearance.theme.color(2))
            .lineSpacing(3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            quote.lineLimit(expanded ? nil : editing ? 4 : 5)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .background {
                    if !expanded {
                        GeometryReader { displayed in
                            quote.fixedSize(horizontal: false, vertical: true)
                                .frame(width: displayed.size.width, alignment: .leading)
                                .background {
                                    GeometryReader { full in
                                        Color.clear.preference(key: QuoteTruncation.self, value: full.size.height > displayed.size.height + 1)
                                    }
                                }
                                .hidden()
                        }
                    }
                }
                .onPreferenceChange(QuoteTruncation.self) { clipped = $0 }
            if clipped || expanded {
                Button(expanded ? "收起原文" : "展开原文") { expanded.toggle() }
                    .buttonStyle(ReadingControlStyle(horizontalPadding: 4))
                    .foregroundColor(appearance.theme.controlTint).accessibilityLabel(expanded ? "收起摘录原文" : "展开完整摘录原文")
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(color.map { Color($0.color).opacity(0.85) } ?? appearance.theme.color(5))
                .frame(width: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct QuoteTruncation: PreferenceKey {
        static let defaultValue = false
        static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
    }
}

struct ReadingNoteComposer: View {
    var prompt = "写下你的想法…"
    @Binding var text: String
    let cancel: () -> Void
    let save: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField(prompt, text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13))
                .lineLimit(3...7)
                .padding(9).focused($focused)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.green.opacity(focused ? 0.55 : 0.18)) }
                .accessibilityLabel("笔记内容")
                .onAppear { DispatchQueue.main.async { focused = true } }
            HStack(spacing: 5) {
                Button("取消", action: cancel).buttonStyle(ReadingControlStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存", action: save).buttonStyle(ReadingControlStyle(accented: true))
                    .keyboardShortcut(.return, modifiers: .command).help("保存 · ⌘↩")
            }
        }
    }
}

extension View {
    func readingNoteRow(active: Bool) -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(active ? Palette.green.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) {
                if !active { Rectangle().fill(Palette.line.opacity(0.65)).frame(height: 1).padding(.horizontal, 10) }
            }
    }
}

struct ReadingNoteAppearanceMenu: View {
    let appearance: ReadingMarkAppearance
    var styles = true
    let changeColor: (ReadingMarkColor) -> Void
    let changeStyle: (ReadingMarkStyle) -> Void

    var body: some View {
        Picker("颜色", selection: Binding(get: { appearance.color }, set: changeColor)) {
            ForEach(ReadingMarkColor.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        if styles {
            Picker("标记", selection: Binding(get: { appearance.style }, set: changeStyle)) {
                ForEach(ReadingMarkStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }
}
