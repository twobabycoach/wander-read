import AppKit
import SwiftUI

enum ReadingCommand: Int {
    case excerpt, annotation, highlight, translate
    static let notification = Notification.Name("WanderReadingCommand")
}

struct ReadingExcerptButton: View {
    let capture: () -> Void

    var body: some View {
        Button(action: capture) { Label("摘录", systemImage: "quote.opening") }
            .buttonStyle(ReadingControlStyle(accented: true))
            .help("保存所选原文 · ⇧⌘E")
    }
}

struct ReadingAnnotationButton: View {
    var title = "批注"
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: "square.and.pencil") }
            .buttonStyle(ReadingControlStyle())
            .help("\(title) · ⇧⌘N")
    }
}

struct ReadingSelectionPalette: View {
    let anchor: CGRect
    let appearance: ReadingMarkAppearance
    let excerpt: () -> Void
    let annotate: () -> Void
    let useColor: (ReadingMarkColor) -> Void
    let setStyle: (ReadingMarkStyle) -> Void
    var findRelated: (() -> Void)? = nil
    let copy: () -> Void
    let translate: () -> Void
    var inComparison = false
    var retranslate: (() -> Void)? = nil

    var body: some View {
        SelectionPaletteLayout(anchor: anchor) {
            HStack(spacing: 3) {
                ReadingExcerptButton(capture: excerpt)
                    .keyboardShortcut(inComparison ? KeyboardShortcut("e", modifiers: [.command, .shift]) : nil)
                ReadingAnnotationButton(action: annotate)
                    .keyboardShortcut(inComparison ? KeyboardShortcut("n", modifiers: [.command, .shift]) : nil)
                ReadingIconButton(title: "翻译选区 · ⇧⌘T", systemImage: "character.bubble", action: translate)
                    .keyboardShortcut(inComparison ? KeyboardShortcut("t", modifiers: [.command, .shift]) : nil)
                Divider().frame(height: 17).padding(.horizontal, 3)
                ForEach(ReadingMarkColor.allCases, id: \.self) { color in
                    let title = "用\(color.title)\(appearance.style.title)摘录"
                    Button { useColor(color) } label: {
                        Circle().fill(Color(color.color).opacity(0.87)).frame(width: 12, height: 12)
                            .padding(3).overlay {
                                Circle().strokeBorder(color == appearance.color ? Palette.muted : .clear, lineWidth: 1)
                            }
                    }
                    .buttonStyle(ReadingControlStyle(horizontalPadding: 0))
                    .help(title)
                    .accessibilityLabel(title)
                    .accessibilityValue(color == appearance.color ? "当前颜色" : "")
                }
                Menu {
                    Picker("标记样式", selection: Binding(get: { appearance.style }, set: setStyle)) {
                        ForEach(ReadingMarkStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.inline)
                    Divider()
                    Button("复制所选原文", action: copy)
                    if let retranslate { Button("重译所选原文", action: retranslate) }
                    if let findRelated { Button("查相关原文", action: findRelated) }
                } label: { Image(systemName: "ellipsis").frame(width: 25, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 28)
                .help("标记样式和更多操作")
                .accessibilityLabel("摘录选项")
            }
            .padding(5)
            .foregroundColor(Palette.ink)
            .background(Palette.paper.opacity(0.98), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line.opacity(0.85)) }
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("所选文字")
        }
    }
}

private struct SelectionPaletteLayout: Layout {
    let anchor: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let palette = subviews.first else { return }
        let size = palette.sizeThatFits(.unspecified)
        let gap: CGFloat = 8
        let left = min(max(gap, anchor.midX - size.width / 2), max(gap, bounds.width - size.width - gap))
        let above = anchor.minY - size.height - gap
        let below = anchor.maxY + gap
        let top = above >= gap ? above : min(below, max(gap, bounds.height - size.height - gap))
        palette.place(at: CGPoint(x: bounds.minX + left, y: bounds.minY + top), proposal: ProposedViewSize(size))
    }
}

/// Coalesces selection/layout notifications and waits for the drag to finish.
final class ReadingSelectionTracker {
    let locate: () -> CGRect?
    let show: (CGRect?) -> Void
    private var queued = false

    init(locate: @escaping () -> CGRect?, show: @escaping (CGRect?) -> Void) {
        self.locate = locate
        self.show = show
    }

    func refresh() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in self?.update() }
    }

    private func update() {
        queued = false
        let rect = locate()
        if rect != nil && NSEvent.pressedMouseButtons & 1 != 0 {
            show(nil)
            queued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) { [weak self] in self?.update() }
        } else {
            show(rect)
        }
    }

    static func anchor(_ rect: CGRect, in view: NSView) -> CGRect? {
        let visible = view.bounds.intersection(rect)
        guard !visible.isEmpty, !visible.isInfinite else { return nil }
        let y = view.isFlipped ? visible.minY - view.bounds.minY : view.bounds.maxY - visible.maxY
        return CGRect(x: visible.minX - view.bounds.minX, y: y, width: visible.width, height: visible.height)
    }
}

struct ReadingExcerptNotice: View {
    let reveal: () -> Void

    var body: some View {
        Button(action: reveal) { Label("已摘录 · 查看", systemImage: "checkmark.circle") }
            .buttonStyle(ReadingControlStyle(accented: true))
            .accessibilityLabel("已摘录，打开刚保存的原文")
    }
}
