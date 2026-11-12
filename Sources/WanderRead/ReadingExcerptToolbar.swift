import SwiftUI

struct ReadingExcerptButton: View {
    let capture: () -> Void

    var body: some View {
        Button(action: capture) { Label("摘录", systemImage: "quote.opening") }
            .buttonStyle(.borderless).foregroundColor(Palette.green)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("保存所选原文 · ⇧⌘E")
    }
}

struct ReadingExcerptNotice: View {
    let reveal: () -> Void

    var body: some View {
        Button(action: reveal) { Label("已摘录 · 查看", systemImage: "checkmark.circle") }
            .font(.system(size: 12)).buttonStyle(.borderless).foregroundColor(Palette.green)
            .accessibilityLabel("已摘录，打开刚保存的原文")
    }
}
