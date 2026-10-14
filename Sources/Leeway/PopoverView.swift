import LeewayCore
import SwiftUI

struct PopoverView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.staticRender) private var staticRender
    @State private var contentHeight: CGFloat = 0
    /// The visible height of the screen that shows the popover.
    @State private var screenHeight: CGFloat = 900

    /// Past this height the cards scroll, so many accounts still fit on the screen.
    private var maxContentHeight: CGFloat { screenHeight * 0.75 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header(now: context.date)
                    .padding([.horizontal, .top], 14)
                if store.accounts.isEmpty {
                    EmptyState()
                        .padding(14)
                } else if contentHeight > maxContentHeight {
                    ScrollView {
                        sections(now: context.date)
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: maxContentHeight)
                } else {
                    sections(now: context.date)
                }
            }
            .frame(width: 340)
        }
        .background {
            // ImageRenderer cannot draw AppKit views, so `--render` keeps the default height.
            if !staticRender {
                ScreenReader { screen in
                    if let height = screen?.visibleFrame.height { screenHeight = height }
                }
            }
        }
        .onAppear { store.refreshIfStale() }
    }

    private func sections(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Provider.allCases) { provider in
                if !store.accounts(for: provider).isEmpty {
                    ProviderSection(provider: provider, now: now)
                        .padding(.top, 14)
                }
            }
        }
        .padding([.horizontal, .bottom], 14)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle(now: now))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !store.accounts.isEmpty {
                MetricToggle()
            }
            HeaderButton(systemImage: "arrow.clockwise", help: "Refresh now", spinning: store.isRefreshing) {
                Task { await store.refreshAll() }
            }
            if staticRender {
                HeaderButton(systemImage: "gearshape", help: "Settings") {}
            } else {
                SettingsMenu()
            }
        }
        .padding(.horizontal, 2)
    }

    private func subtitle(now: Date) -> String {
        if store.isRefreshing { return String(localized: "Updating…") }
        if store.accounts.isEmpty { return String(localized: "No accounts") }
        guard let last = store.lastRefresh else { return String(localized: "\(store.accounts.count) accounts") }
        guard now.timeIntervalSince(last) >= 60 else { return String(localized: "Updated just now") }
        return String(localized: "Updated \(UsageFormat.age(since: last, now: now))")
    }
}

/// Reports the screen of the window that holds this view.
private struct ScreenReader: NSViewRepresentable {
    let onChange: (NSScreen?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((NSScreen?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange?(window?.screen)
        }
    }
}

/// Shown when no account is visible: nothing signed in yet, or everything hidden in Settings.
private struct EmptyState: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let allHidden = !store.allAccounts.isEmpty
        VStack(spacing: 8) {
            Image(systemName: allHidden ? "eye.slash" : "person.crop.circle.badge.questionmark")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
                .accessibilityHidden(true)
            Text(allHidden ? "All accounts are hidden" : "No accounts found")
                .font(.body.weight(.semibold))
            Text(allHidden
                ? "Turn accounts back on in Settings."
                : "Sign in to Claude Code (run claude, then /login) or Codex (run codex login) in Terminal. If your config folder has a custom location, add it in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if !allHidden {
                    Button("Scan Again") { Task { await store.refreshAll() } }
                }
                Button("Open Settings…") { SettingsWindow.show(openWindow) }
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.card)
                .strokeBorder(Palette.cardBorder, lineWidth: 0.5)
        )
    }
}

private struct ProviderSection: View {
    @Environment(UsageStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.staticRender) private var staticRender
    let provider: Provider
    let now: Date

    // Drag-to-reorder state. A SwiftUI gesture instead of onDrag/onDrop, which never starts inside
    // the menu bar panel. `consumed` is the drag distance already turned into moves.
    @State private var draggingID: String?
    @State private var dragOffset: CGFloat = 0
    @State private var consumed: CGFloat = 0
    @State private var heights: [String: CGFloat] = [:]
    private static let spacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            HStack(spacing: 8) {
                ProviderBadge(provider: provider)
                Text(provider.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                // Column caption over the card percentages.
                Text(settings.metric == .used ? "% used" : "% left")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 9)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 2)
            let accounts = store.accounts(for: provider)
            ForEach(accounts) { account in
                let isDragging = draggingID == account.id
                AccountCard(account: account, state: store.state(account), now: now,
                            inMenuBar: store.showsMenuBarMarker(account))
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { heights[account.id] = $0 }
                    .scaleEffect(isDragging ? 1.015 : 1)
                    .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: 8, y: 3)
                    .offset(y: isDragging ? dragOffset : 0)
                    .zIndex(isDragging ? 1 : 0)
                    .gesture(reorderGesture(account), including: accounts.count > 1 && !staticRender ? .all : .subviews)
                    .reorderable(enabled: !staticRender) { card in
                        card.contextMenu { menu(for: account, siblings: accounts) }
                    }
                    // VoiceOver users cannot drag, so offer the moves as actions.
                    .accessibilityActions {
                        if accounts.count > 1 {
                            if account.id != accounts.first?.id {
                                Button("Move up") { store.move(account, by: -1) }
                            }
                            if account.id != accounts.last?.id {
                                Button("Move down") { store.move(account, by: 1) }
                            }
                        }
                        Button("Hide") { store.setHidden(true, for: account) }
                    }
            }
        }
    }

    @ViewBuilder
    private func menu(for account: AccountConfig, siblings: [AccountConfig]) -> some View {
        switch settings.menuBarMode {
        case .firstPerProvider:
            Button("Show in menu bar") { withAnimation { store.move(account, by: -siblings.count) } }
                .disabled(account.id == siblings.first?.id)
        case .chosen:
            Toggle("Show in menu bar", isOn: Binding(
                get: { store.isChosenForMenuBar(account) },
                set: { store.setInMenuBar($0, for: account) }))
        case .closest, .iconOnly:
            EmptyView()
        }
        if siblings.count > 1 {
            Button("Move up") { withAnimation { store.move(account, by: -1) } }
                .disabled(account.id == siblings.first?.id)
            Button("Move down") { withAnimation { store.move(account, by: 1) } }
                .disabled(account.id == siblings.last?.id)
        }
        Divider()
        Button("Hide") { withAnimation { store.setHidden(true, for: account) } }
    }

    private func reorderGesture(_ account: AccountConfig) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if draggingID == nil {
                    withAnimation(.snappy(duration: 0.15)) { draggingID = account.id }
                }
                dragOffset = value.translation.height - consumed
                swapWithNeighborIfNeeded(account)
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.25)) {
                    draggingID = nil
                    dragOffset = 0
                }
                consumed = 0
            }
    }

    /// Swaps with the card above or below once the dragged card covers half of it.
    private func swapWithNeighborIfNeeded(_ account: AccountConfig) {
        let accounts = store.accounts(for: provider)
        guard let index = accounts.firstIndex(of: account) else { return }
        if dragOffset > 0, index + 1 < accounts.count {
            let neighbor = accounts[index + 1]
            let step = (heights[neighbor.id] ?? 0) + Self.spacing
            if dragOffset > step / 2 {
                withAnimation(.snappy(duration: 0.25)) { store.move(account.id, to: neighbor.id) }
                consumed += step
                dragOffset -= step
            }
        } else if dragOffset < 0, index > 0 {
            let neighbor = accounts[index - 1]
            let step = (heights[neighbor.id] ?? 0) + Self.spacing
            if -dragOffset > step / 2 {
                withAnimation(.snappy(duration: 0.25)) { store.move(account.id, to: neighbor.id) }
                consumed -= step
                dragOffset += step
            }
        }
    }
}

/// True in `--render` snapshots, where ImageRenderer cannot draw AppKit-backed modifiers.
extension EnvironmentValues {
    @Entry var staticRender = false
}

private extension View {
    @ViewBuilder
    func reorderable(enabled: Bool, _ apply: (Self) -> some View) -> some View {
        if enabled { apply(self) } else { self }
    }
}

private struct AccountCard: View {
    @Environment(AppSettings.self) private var settings
    let account: AccountConfig
    let state: AccountState
    let now: Date
    var inMenuBar = false

    private var compact: Bool { settings.compactCards }

    private var isFresh: Bool {
        guard let usage = state.usage else { return false }
        return state.error == nil && now.timeIntervalSince(usage.measuredAt) < 15 * 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            HStack(spacing: 6) {
                Text(account.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help([account.email, account.displayPath].compactMap { $0 }.joined(separator: " · "))
                    .accessibilityAddTraits(.isHeader)
                if inMenuBar {
                    Image(systemName: "menubar.rectangle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Shown in the menu bar")
                        .accessibilityLabel("Shown in the menu bar")
                }
                if let plan = state.usage?.plan {
                    Text(plan)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .accessibilityLabel("\(plan) plan")
                }
                Spacer()
                freshness
            }

            if let usage = state.usage {
                // Show only the windows the plan has; some Codex plans have a weekly window only.
                // Per-model weekly windows, such as Fable, follow under the model's name.
                let windows = ([(String(localized: "Session"), usage.session), (String(localized: "Weekly"), usage.weekly)]
                    + (usage.scoped ?? []).map { ($0.name, Optional($0.window)) }).filter { $0.1 != nil }
                VStack(spacing: compact ? 5 : 8) {
                    ForEach(windows, id: \.0) { label, window in
                        WindowRow(label: label, window: window, provider: account.provider, metric: settings.metric,
                                  now: now, compact: compact)
                    }
                    if windows.isEmpty {
                        Text("No limits reported")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .opacity(isFresh ? 1 : 0.6)
            } else if state.error == nil {
                Text("Loading…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let error = state.error {
                Label(error.message, systemImage: error.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, compact ? 8 : 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.card)
                .strokeBorder(Palette.cardBorder, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(account.name)
    }

    @ViewBuilder private var freshness: some View {
        if state.isRefreshing && state.usage == nil {
            ProgressView().controlSize(.mini)
                .accessibilityLabel("Loading")
        } else if let usage = state.usage {
            let age = UsageFormat.age(since: usage.measuredAt, now: now)
            HStack(spacing: 5) {
                Circle()
                    .fill(isFresh ? Palette.fresh : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(age)
            }
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            // The dot shows freshness by color only; say it in words.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isFresh ? String(localized: "Updated \(age)") : String(localized: "Not current, updated \(age)"))
        }
    }
}

private struct WindowRow: View {
    let label: String
    let window: UsageWindow?
    let provider: Provider
    let metric: UsageMetric
    let now: Date
    var compact = false

    var body: some View {
        let used = window?.effectiveUsed(now: now)
        // In "left" mode the bar shows what remains; the color still follows how much is used.
        let shown = used.map { metric.value(used: $0) }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(label)
                    .frame(width: 50, alignment: .leading)
                UsageBar(fraction: (shown ?? 0) / 100, color: Palette.bar(provider, used: used ?? 0))
                Text(shown.map(UsageFormat.percent) ?? "–")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle((used ?? 0) >= 75 ? Palette.bar(provider, used: used ?? 0) : .primary)
                    .frame(width: 36, alignment: .trailing)
                if compact {
                    // One line per window: the reset time moves next to the percentage.
                    Text(shortResetText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
            }
            .font(.callout)
            if !compact {
                Text(resetText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 58)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue(shown: shown))
    }

    private var shortResetText: String {
        guard let window, !window.hasReset(now: now), let resetsAt = window.resetsAt else { return "" }
        return UsageFormat.duration(from: now, to: resetsAt)
    }

    private var resetText: String {
        guard let window else { return String(localized: "No data yet") }
        if window.hasReset(now: now) { return String(localized: "Window reset since last reading") }
        guard let resetsAt = window.resetsAt else { return String(localized: "Reset time unknown") }
        return String(localized: "Resets in \(UsageFormat.duration(from: now, to: resetsAt))")
    }

    /// "64% used, resets in 2 hours, 10 minutes".
    private func spokenValue(shown: Double?) -> String {
        guard let shown else { return String(localized: "No data yet") }
        let percent = UsageFormat.percent(shown)
        let amount = metric == .used ? String(localized: "\(percent) used") : String(localized: "\(percent) left")
        guard let window else { return amount }
        if window.hasReset(now: now) { return String(localized: "\(amount), window reset since last reading") }
        guard let resetsAt = window.resetsAt else { return amount }
        return String(localized: "\(amount), resets in \(UsageFormat.spokenDuration(from: now, to: resetsAt))")
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(color)
                    .frame(width: fraction > 0 ? max(proxy.size.width * min(fraction, 1), 4) : 0)
            }
        }
        .frame(height: 6)
        .animation(.smooth(duration: 0.35), value: fraction)
        .accessibilityElement()
        .accessibilityValue(UsageFormat.percent(min(max(fraction, 0), 1) * 100))
    }
}

/// Compact two-segment switch between "Used" and "Left", styled like the header buttons.
private struct MetricToggle: View {
    @Environment(AppSettings.self) private var settings
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsageMetric.allCases) { option in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { settings.metric = option }
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(settings.metric == option ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background {
                            if settings.metric == option {
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .fill(Palette.card)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(settings.metric == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("Show quota used or quota left")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Percentages")
    }
}

private struct HeaderButton: View {
    let systemImage: String
    let help: String
    var spinning = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .symbolEffect(.rotate, isActive: spinning)
                .frame(width: 26, height: 26)
                .background(hovering ? Palette.track : Palette.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct SettingsMenu: View {
    @Environment(Updater.self) private var updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Button("Settings…") { SettingsWindow.show(openWindow) }
                .keyboardShortcut(",")
            if updater.isAvailable {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            Divider()
            Button("Quit Leeway") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Palette.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}
