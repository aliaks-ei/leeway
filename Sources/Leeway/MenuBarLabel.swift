import LeewayCore
import SwiftUI

/// Monochrome "✳ 64%  ◎ 91%" rendered as a template image, so the menu bar tints it like system icons.
struct MenuBarLabel: View {
    let items: [UsageStore.MenuBarItem]
    let metric: UsageMetric
    var now: Date = .now
    /// The scale of the screen that shows the menu bar, which is not always `NSScreen.main`.
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if items.isEmpty {
                Image(systemName: "gauge.with.dots.needle.33percent")
            } else {
                Image(nsImage: rendered)
            }
        }
        .accessibilityLabel(description(now: now))
        .help(description(now: now))
    }

    private func description(now: Date) -> String {
        guard !items.isEmpty else { return "Leeway" }
        return items.map { item in
            let identity = [item.provider.title, item.accountName, item.windowName].compactMap { $0 }.joined(separator: " · ")
            let reading: String
            if item.awaitingReset {
                reading = String(localized: "Reset expected, awaiting update")
            } else if let used = item.used {
                let percent = UsageFormat.percent(metric.value(used: used))
                reading = metric == .used ? String(localized: "\(percent) used") : String(localized: "\(percent) left")
            } else {
                reading = String(localized: "No reading")
            }
            let age = item.measuredAt.map { String(localized: "Last reading \(UsageFormat.age(since: $0, now: now))") }
            return [identity, reading, item.isStale ? String(localized: "Not current") : nil, age].compactMap { $0 }.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    private var rendered: NSImage {
        // Fixed sizes: the menu bar has a fixed height.
        let content = HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Spacer().frame(width: 3) }
                LogoShape(provider: item.provider).frame(width: 13, height: 13)
                Text(text(item.used))
                if item.isStale {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 9, weight: .medium))
                }
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
