import SwiftUI

/// Few colors, two typefaces. Warm grays like an old Braun case, one orange signal like a Teenage Engineering key.
struct Tone: ShapeStyle {
    let light: Color
    let dark: Color

    init(_ light: UInt32, _ dark: UInt32, opacity: Double = 1) {
        self.light = Color(hex: light).opacity(opacity)
        self.dark = Color(hex: dark).opacity(opacity)
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .dark ? dark : light
    }
}

extension ShapeStyle where Self == Tone {
    static var panel: Tone { Tone(0xECEBE7, 0x1D1D1C) }
    static var key: Tone { Tone(0xDEDDD8, 0x2B2B29) }
    static var keyHover: Tone { Tone(0xD5D4CE, 0x333331) }
    static var keyDown: Tone { Tone(0xC9C8C2, 0x3C3C39) }
    static var ink: Tone { Tone(0x1F1F1D, 0xE9E8E3) }
    static var faint: Tone { Tone(0x8C8B86, 0x8A8984) }
    static var unlit: Tone { Tone(0x1F1F1D, 0xE9E8E3, opacity: 0.13) }
    static var screen: Tone { Tone(0x161615, 0x0E0E0D) }
    static var screenInk: Tone { Tone(0xF1EFE9, 0xF1EFE9) }
    static var screenFaint: Tone { Tone(0x8F8D87, 0x8F8D87) }
    static var screenUnlit: Tone { Tone(0xF1EFE9, 0xF1EFE9, opacity: 0.22) }
    static var signal: Tone { Tone(0xFF5B1A, 0xFF6A2B) }
}

extension Font {
    static let title = Font.system(size: 24, weight: .medium)
    static let detail = Font.system(size: 12)
    static let label = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let readout = Font.system(size: 13, weight: .medium, design: .monospaced)
}

extension View {
    /// Small caps label, as printed on a front panel.
    func panelLabel() -> some View {
        font(.label).textCase(.uppercase).tracking(0.7)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
