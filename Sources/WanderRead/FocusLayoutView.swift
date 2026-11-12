import SwiftUI

struct FocusLayoutButton: View {
    @ObservedObject var store: ReadingStore
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: { Label("视野", systemImage: "slider.horizontal.3") }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                FocusLayoutEditor(initial: (store.library.preferences.focusLayout ?? FocusLayout()).normalized()) { layout in
                    if store.commit({ $0.preferences.focusLayout = layout }) { showing = false }
                }
            }
    }
}

struct FocusLayoutEditor: View {
    @State var initial: FocusLayout
    var apply: (FocusLayout) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("专注视野").font(.system(size: 25, weight: .medium, design: .serif))
            Text("收窄正文、拉开笔记，让目光留在你想读的地方。")
                .font(.system(size: 12)).foregroundColor(Palette.muted)
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 5).fill(initial.paper)
                    .frame(width: 72 + (initial.width - 440) / 10)
                    .overlay { VStack(spacing: 5) { ForEach(0..<3) { index in Capsule().fill(Palette.ink.opacity(0.2)).frame(width: index == 2 ? 31 : 48, height: 3) } } }
                RoundedRectangle(cornerRadius: 5).fill(initial.notes)
                    .frame(width: 30 + (initial.notebookWidth - 240) / 5)
                    .overlay { Image(systemName: "pencil.line").foregroundColor(Palette.green) }
            }.frame(maxWidth: .infinity).frame(height: 63).padding(.vertical, 8)
                .background(initial.desk, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            dimension("正文宽度", value: $initial.width, range: 440...1200, step: 20)
            dimension("笔记宽度", value: $initial.notebookWidth, range: 240...420, step: 10)
            dimension("文字大小", value: $initial.textSize, range: 14...26, step: 1)
            HStack {
                tint("留白", selection: $initial.deskTint)
                tint("正文", selection: $initial.paperTint)
                tint("笔记", selection: $initial.noteTint)
            }
            Text("PDF 原页保留纸色，字号用于文本与折叠。")
                .font(.system(size: 11)).foregroundColor(Palette.muted)
            HStack {
                Button("恢复初始值") { initial = FocusLayout() }.buttonStyle(.plain).foregroundColor(Palette.green)
                Spacer()
                Button("应用视野") { apply(initial.normalized()) }.buttonStyle(ActionStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(21).frame(width: 364).background(Palette.paper).foregroundColor(Palette.ink)
    }

    private func dimension(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).frame(width: 62, alignment: .leading)
            Slider(value: value, in: range, step: step).labelsHidden().accessibilityLabel(label).tint(Palette.green)
            Text(Int(value.wrappedValue).formatted()).font(.system(size: 11).monospacedDigit())
                .foregroundColor(Palette.muted).frame(width: 36, alignment: .trailing)
        }
    }

    private func tint(_ label: String, selection: Binding<ReadingTint>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(Palette.muted)
            Picker(label, selection: selection) {
                ForEach(ReadingTint.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().accessibilityLabel(label)
        }
    }
}
