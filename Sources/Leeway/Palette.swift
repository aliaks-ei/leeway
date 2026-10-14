import AppKit
import LeewayCore
import SwiftUI

enum Palette {
    static let claude = dynamic(light: 0xD97757, dark: 0xE8896B)
    static let codex = dynamic(light: 0x10A37F, dark: 0x2CC497)
    static let warning = dynamic(light: 0xD9921F, dark: 0xF0B04A)
    static let critical = dynamic(light: 0xE0484D, dark: 0xFF6369)
    static let fresh = dynamic(light: 0x30B05A, dark: 0x3DD06B)

    static let claudeBrand = Color(hex: 0xD97757)
    static let openAITile = dynamic(light: 0x0D0D0D, dark: 0xF5F5F7)
    static let openAIMark = dynamic(light: 0xFFFFFF, dark: 0x0D0D0D)

    static let card = dynamic(light: NSColor(white: 1, alpha: 0.72), dark: NSColor(white: 1, alpha: 0.06))
    static let cardBorder = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
    static let track = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.10))
    static let chip = dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.08))

    static func accent(_ provider: Provider) -> Color {
        provider == .claude ? claude : codex
    }

    /// Provider color below 75 %, amber from 75 %, red from 90 %.
    static func bar(_ provider: Provider, used: Double) -> Color {
        used >= 90 ? critical : used >= 75 ? warning : accent(provider)
    }

    private static func dynamic(light: Int, dark: Int) -> Color {
        dynamic(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

extension Color {
    init(hex: Int) {
        self.init(nsColor: NSColor(hex: hex))
    }
}
