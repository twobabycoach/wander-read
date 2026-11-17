import SwiftUI

struct FocusLayoutButton: View {
    @ObservedObject var store: ReadingStore
    var originalPDF = false
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { Label("版式", systemImage: "slider.horizontal.3") }
            .buttonStyle(ReadingControlStyle(selected: showing))
            .help("调整专注阅读版式")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                FocusLayoutEditor(initial: (store.library.preferences.focusLayout ?? FocusLayout()).normalized(),
                                  originalPDF: originalPDF) { layout in
                    if store.commit({ $0.preferences.focusLayout = layout }) { showing = false }
                }
            }
    }
}

struct FocusLayoutEditor: View {
    @State var initial: FocusLayout
    let originalPDF: Bool
    var apply: (FocusLayout) -> Void
    @State private var custom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("专注版式").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 6) {
                preset("适中", icon: "text.justify") {
                    initial.width = 720
                    if !originalPDF { initial.textSize = 18; initial.lineSpacing = 9 }
                }
                preset("窄栏", icon: "rectangle.center.inset.filled") {
                    initial.width = 560
                    if !originalPDF { initial.textSize = 19; initial.lineSpacing = 10 }
                }
                if !originalPDF {
                    preset("大字", icon: "textformat.size") {
                        initial.width = 720
                        initial.textSize = 22
                        initial.lineSpacing = 12
                    }
                }
                Spacer(minLength: 0)
            }
            sample
            if !originalPDF {
                HStack {
                    Text("正文纸色").font(.system(size: 12))
                    Spacer()
                    tint("正文纸色", selection: $initial.paperTint)
                }
            }
            Divider()
            DisclosureGroup("细调", isExpanded: $custom) {
                VStack(alignment: .leading, spacing: 10) {
                    dimension(originalPDF ? "页面宽度" : "正文宽度", value: $initial.width, range: 440...1200, step: 20)
                    if !originalPDF {
                        dimension("文字大小", value: $initial.textSize, range: 14...26, step: 1)
                        dimension("行距", value: Binding(get: { initial.paragraphLineSpacing }, set: { initial.lineSpacing = $0 }),
                                  range: 5...16, step: 1)
                    }
                    dimension("笔记宽度", value: $initial.notebookWidth, range: 240...420, step: 10)
                    HStack(spacing: 8) {
                        Text("留白").font(.system(size: 12))
                        tint("留白", selection: $initial.deskTint)
                        Spacer(minLength: 2)
                        Text("笔记").font(.system(size: 12))
                        tint("笔记", selection: $initial.noteTint)
                    }
                }.padding(.top, 8)
            }.font(.system(size: 12)).tint(Palette.green)
            if originalPDF {
                Text("原页保留 PDF 的排版。切到折叠视图即可调整字号和行距。")
                    .font(.system(size: 11)).foregroundColor(Palette.muted)
            }
            HStack {
                Button("恢复默认") { initial = FocusLayout() }.buttonStyle(ReadingControlStyle())
                Spacer()
                Button("应用") { apply(initial.normalized()) }.buttonStyle(ReadingControlStyle(accented: true))
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(15).frame(width: 344).background(Palette.paper).foregroundColor(Palette.ink)
    }

    private var sample: some View {
        HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 3) {
                if originalPDF {
                    Text("PDF 原页").font(.system(size: 13, weight: .semibold))
                    Text("目录　正文　页注").font(.system(size: 10))
                } else {
                    Text("把一段话读完整").font(.system(size: initial.textSize * 0.72, weight: .semibold))
                    Text("从问题出发。\n回到原文。")
                        .font(.system(size: initial.textSize * 0.64))
                        .lineSpacing(initial.paragraphLineSpacing * 0.4)
                }
            }.padding(8)
                .frame(width: 106 + (initial.width - 440) / 8, height: 77, alignment: .leading)
                .foregroundColor(originalPDF ? Color(white: 0.17) : Palette.ink)
                .background(originalPDF ? .white : initial.paper, in: RoundedRectangle(cornerRadius: 6))
            RoundedRectangle(cornerRadius: 6).fill(initial.notes)
                .frame(width: 29 + (initial.notebookWidth - 240) / 6, height: 77)
                .overlay { Image(systemName: "pencil.line").font(.system(size: 12)).foregroundColor(Palette.muted) }
        }.frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(initial.desk, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    private func preset(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            apply(initial.normalized())
        } label: {
            Label(label, systemImage: icon)
        }.buttonStyle(ReadingControlStyle()).help("立即应用" + label + "版式")
    }

    private func dimension(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).frame(width: 59, alignment: .leading)
            Slider(value: value, in: range, step: step).labelsHidden().accessibilityLabel(label).tint(Palette.green)
            Text(Int(value.wrappedValue).formatted()).font(.system(size: 11)).monospacedDigit()
                .foregroundColor(Palette.muted).frame(width: 32, alignment: .trailing)
        }
    }

    private func tint(_ label: String, selection: Binding<ReadingTint>) -> some View {
        Menu {
            Picker(label, selection: selection) {
                ForEach(ReadingTint.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Circle().fill(selection.wrappedValue.color(Palette.paper)).frame(width: 9, height: 9)
                    .overlay { Circle().strokeBorder(Palette.line) }
                Text(selection.wrappedValue.title)
            }
        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(label)
    }
}
