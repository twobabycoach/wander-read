import SwiftUI

struct ReadingControlStyle: ButtonStyle {
    var selected = false
    var accented = false
    var horizontalPadding: CGFloat = 7
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        Control(label: configuration.label, selected: selected, accented: accented, pressed: configuration.isPressed,
                padding: horizontalPadding, tint: tint)
    }

    private struct Control<Label: View>: View {
        let label: Label
        let selected: Bool
        let accented: Bool
        let pressed: Bool
        let padding: CGFloat
        let tint: Color?
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorScheme) private var colorScheme
        @ObservedObject private var appearance = Palette.selection
        @State private var hovered = false
        private var accent: Color {
            if let tint { return tint }
            let theme = appearance.theme
            if colorScheme == .dark && !theme.isDark { return .primary }
            return theme.controlTint
        }

        var body: some View {
            let outline = RoundedRectangle(cornerRadius: 6)
            coloredLabel
                .font(.system(size: 12, weight: selected || accented ? .semibold : .medium))
                .padding(.horizontal, padding)
                .frame(minWidth: 28, minHeight: 28)
                .background(accent.opacity(backgroundOpacity), in: outline)
                .overlay { outline.strokeBorder(selected ? accent.opacity(0.25) : .clear).allowsHitTesting(false) }
                .contentShape(outline)
                .onHover { hovered = $0 }
                .opacity(enabled ? 1 : 0.42)
                .accessibilityAddTraits(selected ? .isSelected : [])
        }

        private var backgroundOpacity: Double {
            if !enabled { return selected ? 0.10 : 0 }
            if pressed { return 0.21 }
            if selected { return hovered ? 0.17 : 0.12 }
            if accented { return hovered ? 0.14 : 0.08 }
            return hovered ? 0.08 : 0
        }

        @ViewBuilder private var coloredLabel: some View {
            if selected || accented { label.foregroundColor(accent) }
            else { label }
        }
    }
}

struct ReadingTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var tint: Color? = nil
    @ObservedObject private var appearance = Palette.selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button(option.title) { selection = option.value }
                    .buttonStyle(ReadingControlStyle(selected: selection == option.value, horizontalPadding: 9, tint: tint))
            }
        }
        .padding(2)
        .background(appearance.theme.color(7).opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(appearance.theme.color(5).opacity(0.5)).allowsHitTesting(false) }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct ReadingFocusButton: View {
    let focused: Bool
    let toggle: () -> Void

    var body: some View {
        let title = focused ? "退出专注" : "专注"
        Button(action: toggle) { Label(title, systemImage: "viewfinder") }
            .buttonStyle(ReadingControlStyle(selected: focused))
            .help(focused ? "退出专注 · Esc / ⇧⌘F" : "进入专注阅读 · ⇧⌘F")
            .accessibilityLabel(focused ? "退出专注" : "进入专注阅读")
    }
}

struct ReadingAidButton: View {
    @ObservedObject var store: ReadingStore
    var inOriginalPDF = false
    var canReflow: () -> Bool = { true }
    var reflow: () -> Void = {}
    @State private var showing = false

    var body: some View {
        let mode = store.library.preferences.readingAid
        Button { showing.toggle() } label: { Label("仿生", systemImage: "textformat") }
            .buttonStyle(ReadingControlStyle(selected: showing || (!inOriginalPDF && mode != .off)))
            .help("仿生阅读 · " + (inOriginalPDF && mode != .off ? "在折叠视图生效" : mode.title))
            .accessibilityLabel("仿生阅读")
            .accessibilityValue(inOriginalPDF && mode != .off ? "在折叠视图生效" : mode.title)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                let available = !inOriginalPDF || canReflow()
                VStack(alignment: .leading, spacing: 11) {
                    Text("仿生阅读").font(.system(size: 15, weight: .semibold))
                    ForEach(ReadingAidMode.allCases, id: \.self) { option in
                        Button {
                            if store.commit({ $0.preferences.readingAidMode = option }) {
                                if inOriginalPDF && available && option != .off { showing = false; reflow() }
                            }
                        } label: {
                            HStack {
                                Text(option.title)
                                Spacer()
                                if option == mode { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                            }
                        }.buttonStyle(ReadingControlStyle(selected: option == mode))
                            .disabled(!available && option != .off)
                            .help(option == .adaptive ? "中文整词、英文词首" : option == .english ? "只强调英文词首" : "使用原来的字重")
                    }
                    Divider()
                    if !available {
                        Text("当前页没有可重排的文字。可以翻到有文字的页再开启。")
                            .font(.system(size: 12)).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    } else if inOriginalPDF {
                        Text("开启后会从当前阅读位置切到折叠视图，可随时返回原页。")
                            .font(.system(size: 12)).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(ReadingWordEmphasis.format("从问题出发，回到材料中寻找证据。\nComparing sources helps us understand the evidence.", mode: mode))
                            .font(.system(size: 13)).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(13).frame(width: 246, alignment: .leading)
                .background(Palette.paper).foregroundColor(Palette.ink)
            }
    }
}

struct ReadingSearchField: View {
    let prompt: String
    @Binding var query: String
    var focusOnAppear = false
    var identifier: String? = nil
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    @ObservedObject private var appearance = Palette.selection

    var body: some View {
        let theme = appearance.theme
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundColor(theme.color(3)).accessibilityHidden(true)
            TextField("", text: $query, prompt: Text(prompt).foregroundColor(theme.color(3)))
                .textFieldStyle(.plain).foregroundColor(theme.color(2)).focused($focused)
                .accessibilityLabel(prompt)
                .accessibilityIdentifier(identifier ?? prompt)
                .onSubmit(onSubmit)
                .onAppear {
                    if focusOnAppear { DispatchQueue.main.async { focused = true } }
                }
            if !query.isEmpty {
                ReadingIconButton(title: "清除搜索", systemImage: "xmark.circle.fill", size: 22) {
                    query = ""
                    focused = true
                }.foregroundColor(theme.color(3))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .frame(minHeight: 30)
        .background(theme.color(7).opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? theme.controlTint.opacity(0.55) : theme.color(5).opacity(0.6)) }
    }
}
