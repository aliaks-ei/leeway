import LeewayCore
import SwiftUI

/// Provider mark drawn from SVG path data, so it stays sharp at any size and takes any color.
struct LogoShape: Shape {
    let provider: Provider

    func path(in rect: CGRect) -> Path {
        let source = provider == .claude ? Self.claude : Self.openAI
        let scale = min(rect.width, rect.height) / 100
        let transform = CGAffineTransform(translationX: rect.midX - 50 * scale, y: rect.midY - 50 * scale)
            .scaledBy(x: scale, y: scale)
        return source.applying(transform)
    }

    private static let claude = SVGPath.parse(LogoPaths.claude)
    private static let openAI = SVGPath.parse(LogoPaths.openAI)
}

/// Parser for the absolute `M L H V C Z` commands the two logos use.
enum SVGPath {
    static func parse(_ data: String) -> Path {
        var path = Path()
        var tokens = tokenize(data)[...]
        var command: Character = "M"
        var current = CGPoint.zero

        func next() -> CGFloat { CGFloat(Double(tokens.popFirst().map(String.init) ?? "") ?? 0) }

        while let token = tokens.first {
            if let letter = token.first, letter.isLetter {
                command = letter
                tokens.removeFirst()
                if command == "Z" || command == "z" {
                    path.closeSubpath()
                    continue
                }
            }
            switch command {
            case "M":
                current = CGPoint(x: next(), y: next())
                path.move(to: current)
                command = "L" // further pairs after M are line-tos
            case "L":
                current = CGPoint(x: next(), y: next())
                path.addLine(to: current)
            case "H":
                current.x = next()
                path.addLine(to: current)
            case "V":
                current.y = next()
                path.addLine(to: current)
            case "C":
                let c1 = CGPoint(x: next(), y: next())
                let c2 = CGPoint(x: next(), y: next())
                current = CGPoint(x: next(), y: next())
                path.addCurve(to: current, control1: c1, control2: c2)
            default:
                tokens.removeFirst()
            }
        }
        return path
    }

    private static func tokenize(_ data: String) -> [Substring] {
        var tokens: [Substring] = []
        var start: String.Index?
        var index = data.startIndex
        func flush() {
            if let s = start { tokens.append(data[s ..< index]) }
            start = nil
        }
        while index < data.endIndex {
            let char = data[index]
            if char.isLetter, char != "e" {
                flush()
                tokens.append(data[index ... index])
            } else if char == "-", let s = start, data[data.index(before: index)] != "e", s < index {
                flush()
                start = index
            } else if char == " " || char == "," || char == "\n" {
                flush()
            } else if char == ".", let s = start, data[s ..< index].contains(".") {
                flush()
                start = index
            } else if start == nil {
                start = index
            }
            index = data.index(after: index)
        }
        flush()
        return tokens
    }
}

/// Rounded tile with the provider mark, like an app icon: Claude in clay, ChatGPT in black or white.
struct ProviderBadge: View {
    let provider: Provider
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(provider == .claude ? Palette.claudeBrand : Palette.openAITile)
            .overlay(
                LogoShape(provider: provider)
                    .fill(provider == .claude ? Color.white : Palette.openAIMark)
                    .padding(size * (provider == .claude ? 0.14 : 0.16))
            )
            .frame(width: size, height: size)
            .accessibilityLabel(provider == .claude ? "Claude" : "Codex")
    }
}
