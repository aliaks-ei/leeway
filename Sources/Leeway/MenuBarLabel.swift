import LeewayCore
import SwiftUI

/// Monochrome "✳ 64%  ◎ 91%" rendered as a template image, so the menu bar tints it like system icons.
struct MenuBarLabel: View {
    let items: [UsageStore.MenuBarItem]
    let metric: UsageMetric
    /// The scale of the screen that shows the menu bar, which is not always `NSScreen.main`.
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if items.isEmpty {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .accessibilityLabel("Leeway")
        } else {
            Image(nsImage: rendered)
                .accessibilityLabel(accessibilityText)
        }
    }

    private var accessibilityText: String {
        items.map { item in
            guard let used = item.used else { return String(localized: "\(item.provider.title), no reading") }
            let percent = UsageFormat.percent(metric.value(used: used))
            return metric == .used
                ? String(localized: "\(item.provider.title) \(percent) used")
                : String(localized: "\(item.provider.title) \(percent) left")
        }.joined(separator: ", ")
    }

    private var rendered: NSImage {
        // Fixed sizes: the menu bar has a fixed height.
        let content = HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Spacer().frame(width: 3) }
                LogoShape(provider: item.provider).frame(width: 13, height: 13)
                Text(text(item.used))
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.black)
        .fixedSize()
        .padding(.horizontal, 1)

        let renderer = ImageRenderer(content: content)
        renderer.scale = displayScale
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 1, height: 1))
        image.isTemplate = true
        return image
    }

    private func text(_ used: Double?) -> String {
        guard let used else { return "–" }
        return UsageFormat.percent(metric.value(used: used))
    }
}
