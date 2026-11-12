import SwiftUI
import AppKit

enum AppTheme:String,CaseIterable,Identifiable {
    case paper, tide, clay, lilac, night
    var id:String {rawValue}
    var title:String {switch self {case .paper:return "纸间";case .tide:return "海盐";case .clay:return "陶土";case .lilac:return "暮紫";case .night:return "深夜"}}
    var detail:String {switch self {case .paper:return "暖纸与森林绿";case .tide:return "雾蓝与海岸线";case .clay:return "奶油与赤陶";case .lilac:return "浅紫与墨色";case .night:return "深蓝与月光"}}
    var isDark:Bool {self == .night}
    var colors:[UInt32] {switch self {
    case .paper:return [0xF7F5F0,0xEDF0E8,0x29362E,0x5C665C,0x335742,0xD1D9CC,0xE6ECDF,0xFFFFFF]
    case .tide:return [0xF1F6F8,0xE2ECF1,0x233D4B,0x526B79,0x28617A,0xC7D7DF,0xDCEAF0,0xFFFFFF]
    case .clay:return [0xFBF3E9,0xF0E3D4,0x49342D,0x786158,0x92482F,0xDFCDBE,0xF1DECE,0xFFFDF9]
    case .lilac:return [0xF5F2FA,0xEAE3F2,0x3C314D,0x6C5E7B,0x70518D,0xD8CCE2,0xE9DFF2,0xFFFFFF]
    case .night:return [0x18232E,0x121C26,0xEEF1E9,0xB1C0C7,0x426E83,0x405363,0x263C4B,0x2A3947]
    }}
    func color(_ index:Int)->Color {let n=colors[index];return Color(red:Double((n>>16)&255)/255,green:Double((n>>8)&255)/255,blue:Double(n&255)/255)}
}
enum Palette {
    static var theme=AppTheme.paper
    static var paper:Color {theme.color(0)}
    static var side:Color {theme.color(1)}
    static var ink:Color {theme.color(2)}
    static var muted:Color {theme.color(3)}
    static var green:Color {theme.isDark ? Color(red:0.64,green:0.82,blue:0.88):theme.color(4)}
    static var accent:Color {theme.color(4)}
    static var line:Color {theme.color(5)}
    static var card:Color {theme.color(6)}
    static var surface:Color {theme.color(7)}
}
extension ReadingStore {
    func selectTheme(_ theme:AppTheme) {
        if commit({$0.preferences.appTheme=theme.rawValue}) {
            Palette.theme=theme
            ThemeAppIcon.apply(theme)
            NSApp?.appearance=NSAppearance(named:theme.isDark ? .darkAqua:.aqua)
            for window in NSApp?.windows ?? [] {window.appearance=NSAppearance(named:theme.isDark ? .darkAqua:.aqua);window.backgroundColor=NSColor(Palette.paper)}
        }
    }
}

struct ThemeAppIcon {
    static func image(_ theme:AppTheme)->NSImage {
        let image=NSImage(size:NSSize(width:256,height:256));image.lockFocus()
        NSColor(theme.color(1)).setFill();NSBezierPath(roundedRect:NSRect(x:12,y:12,width:232,height:232),xRadius:52,yRadius:52).fill()
        NSColor(theme.isDark ? theme.color(2):theme.color(4)).setStroke()
        let ring=NSBezierPath(ovalIn:NSRect(x:55,y:55,width:146,height:146));ring.lineWidth=2.5;ring.stroke()
        NSGraphicsContext.saveGraphicsState();let transform=NSAffineTransform();transform.translateX(by:128,yBy:128);transform.rotate(byDegrees:-36);transform.concat()
        let orbit=NSBezierPath(ovalIn:NSRect(x:-33,y:-73,width:66,height:146));orbit.lineWidth=4;orbit.stroke();NSGraphicsContext.restoreGraphicsState()
        NSColor(theme.isDark ? theme.color(2):theme.color(4)).setFill();NSBezierPath(ovalIn:NSRect(x:169,y:171,width:19,height:19)).fill();image.unlockFocus();return image
    }
    static func apply(_ theme:AppTheme) {guard let app=NSApp else{return};app.applicationIconImage=image(theme)}
}
