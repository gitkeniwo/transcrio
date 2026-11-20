import AppKit
import SwiftUI

/// Gruvbox accents and tints from gui-design.md, with light and dark variants.
/// Everything else (backgrounds, labels, separators, controls) uses system semantic colors.
enum Palette {
    // Accents
    static let red = Color(light: 0x9d0006, dark: 0xfb4934)
    static let green = Color(light: 0x79740e, dark: 0xb8bb26)
    static let yellow = Color(light: 0xb57614, dark: 0xfabd2f)
    static let blue = Color(light: 0x076678, dark: 0x83a598)
    static let purple = Color(light: 0x8f3f71, dark: 0xd3869b)
    static let aqua = Color(light: 0x427b58, dark: 0x8ec07c)
    static let orange = Color(light: 0xaf3a03, dark: 0xfe8019)
    static let gray = Color(light: 0x7c6f64, dark: 0xa89984)
    /// Text and icons on solid accent fills.
    static let onFill = Color(light: 0xFFFFFF, dark: 0x1d2021)
    /// Selected list row (white text).
    static let selection = Color(light: 0x076678, dark: 0x386669)

    // Tints: pastel backgrounds behind accent-colored text.
    static let redT = Color(light: 0xF6E0DF, dark: 0x3E2523)
    static let greenT = Color(light: 0xEEEEDA, dark: 0x33341E)
    static let yellowT = Color(light: 0xF8EDD8, dark: 0x3C3220)
    static let blueT = Color(light: 0xE0EBED, dark: 0x283437)
    static let purpleT = Color(light: 0xF2E4EB, dark: 0x3A2B33)
    static let aquaT = Color(light: 0xE2EDE5, dark: 0x2B3628)
    static let orangeT = Color(light: 0xF6E5DB, dark: 0x3E2A1C)
    static let grayT = Color(light: 0xECE9E6, dark: 0x363432)

    // File-type icons
    static let audioIcon = Color(hex: 0xd65d0e)
    static let videoIcon = Color(hex: 0xb16286)

    // System semantic roles used across views.
    static let track = Color(nsColor: .quaternaryLabelColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let cardBorder = Color(nsColor: .separatorColor)
    static let control = Color(nsColor: .quaternaryLabelColor).opacity(0.6)
    static let band = Color(nsColor: .quaternaryLabelColor).opacity(0.55)
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let dot = Color(nsColor: .tertiaryLabelColor).opacity(0.45)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    /// A dynamic color that follows the effective appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } ?? false
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// An accent with its tint, for chips, tiles and capsules.
struct Tone: Equatable {
    var fg: Color
    var bg: Color

    static let red = Tone(fg: Palette.red, bg: Palette.redT)
    static let green = Tone(fg: Palette.green, bg: Palette.greenT)
    static let yellow = Tone(fg: Palette.yellow, bg: Palette.yellowT)
    static let blue = Tone(fg: Palette.blue, bg: Palette.blueT)
    static let purple = Tone(fg: Palette.purple, bg: Palette.purpleT)
    static let aqua = Tone(fg: Palette.aqua, bg: Palette.aquaT)
    static let orange = Tone(fg: Palette.orange, bg: Palette.orangeT)
    static let gray = Tone(fg: Palette.gray, bg: Palette.grayT)
}
