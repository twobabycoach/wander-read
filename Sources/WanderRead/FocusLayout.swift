import SwiftUI

enum ReadingTint: String, Codable, CaseIterable, Identifiable {
    case theme, linen, sage, mist, dusk
    var id: Self { self }
    var title: String {
        switch self {
        case .theme: return "随主题"
        case .linen: return "暖纸"
        case .sage: return "鼠尾草"
        case .mist: return "雾蓝"
        case .dusk: return "暮紫"
        }
    }
    func color(_ fallback: Color) -> Color {
        let value: UInt32
        switch self {
        case .theme: return fallback
        case .linen: value = Palette.theme.isDark ? 0x34302B : 0xFBF5E9
        case .sage: value = Palette.theme.isDark ? 0x273831 : 0xE6EEE4
        case .mist: value = Palette.theme.isDark ? 0x243747 : 0xE5EFF5
        case .dusk: value = Palette.theme.isDark ? 0x362E43 : 0xEFE9F6
        }
        return Color(red: Double(value >> 16) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct FocusLayout: Codable, Equatable {
    var width: Double = 720
    var notebookWidth: Double = 300
    var textSize: Double = 17
    var deskTint: ReadingTint = .sage
    var paperTint: ReadingTint = .linen
    var noteTint: ReadingTint = .mist

    var desk: Color { deskTint.color(Palette.side) }
    var paper: Color { paperTint.color(Palette.paper) }
    var notes: Color { noteTint.color(Palette.side) }

    func normalized() -> Self {
        var result = self
        result.width = width.isFinite ? min(max(width, 440), 1200) : 720
        result.notebookWidth = notebookWidth.isFinite ? min(max(notebookWidth, 240), 420) : 300
        result.textSize = textSize.isFinite ? min(max(textSize, 14), 26) : 17
        return result
    }
}
