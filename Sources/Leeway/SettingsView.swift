import LeewayCore
import SwiftUI

struct SettingsView: View {
    @Environment(UsageStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(LaunchAtLogin.self) private var launchAtLogin
    @Environment(\.staticRender) private var staticRender
    @State private var folderMessage: String?
    @State private var foundCodex: String?
    @State private var lookingForCodex = true
    @State private var foundClaude: String?
    @State private var lookingForClaude = true

    var body: some View {
        Form {
            accountsSection
            menuBarSection
            generalSection
            codexSection
            Section {
                LabeledContent("Version", value: AppInfo.version)
                Button("Open Data Folder") {
                    try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AppPaths.supportDir)
                }
            }
        }
        .formStyle(.grouped)
        // `--render` shows the whole form instead of the scrolled window.
        .frame(width: 500)
        .frame(minHeight: staticRender ? 1120 : 420, idealHeight: staticRender ? 1120 : 680, maxHeight: .infinity)
        .task(id: settings.codexPath) { await findCodex() }
        .task { await findClaude() }
        .onChange(of: settings.codexPath) { Task { await store.refreshAll() } }
        .onChange(of: settings.renewClaudeSignIns) { if settings.renewClaudeSignIns { Task { await store.refreshAll() } } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
        .onAppear { launchAtLogin.refresh() }
        .onDisappear { if !staticRender { SettingsWindow.didClose() } }
    }

    // MARK: Accounts

    private var accountsSection: some View {
        Section {
            if store.allAccounts.isEmpty {
                Text("No signed-in Claude Code or Codex folders found.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.allAccounts) { account in
                AccountRow(account: account, choosesMenuBar: settings.menuBarMode == .chosen)
            }
        } header: {
            Text("Accounts")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Add Folder…", action: addFolder)
                    Button("Scan Again") {
                        folderMessage = nil
                        Task { await store.refreshAll() }
                    }
                }
                if let folderMessage {
                    Text(folderMessage)
                        .foregroundStyle(.secondary)
                }
                Text("Finds ~/.claude and ~/.codex, and folders such as ~/.claude-work that hold a login. Drag cards in the menu bar popover to change their order.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .padding(.top, 4)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose a Claude Code or Codex config folder, such as ~/.claude-work")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let path = PathDisplay.abbreviate(url.path)
            switch await store.addFolder(url) {
            case .added: folderMessage = nil
            case .alreadyListed: folderMessage = String(localized: "\(path) is already in the list.")
            case .unknownFolder: folderMessage = String(localized: "\(path) has no Claude Code or Codex files.")
            }
        }
    }

    // MARK: Menu bar

    private var menuBarSection: some View {
        @Bindable var settings = settings
        return Section {
            Picker("Show", selection: $settings.menuBarMode) {
                ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Limit", selection: $settings.menuBarWindow) {
                ForEach(MenuBarWindow.allCases) { Text($0.title).tag($0) }
            }
            .disabled(settings.menuBarMode == .iconOnly)
            Picker("Percentages", selection: $settings.metric) {
                ForEach(UsageMetric.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Menu Bar")
        } footer: {
            Text(settings.menuBarMode == .chosen
                ? "Turn on the menu bar button next to each account above. Percentages also apply to the popover."
                : "Percentages also apply to the popover.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: General

    private var generalSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin.isOn }, set: { launchAtLogin.set($0) }))
            if launchAtLogin.requiresApproval {
                HStack {
                    Label("Allow Leeway in Login Items to start it at login.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") { launchAtLogin.openSystemSettings() }
                }
                .font(.callout)
            }
            if let error = launchAtLogin.lastError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Picker("Refresh every", selection: $settings.refreshMinutes) {
                ForEach(AppSettings.refreshChoices, id: \.self) { Text("\($0) minutes").tag($0) }
            }
            Toggle("Compact cards", isOn: $settings.compactCards)
            Toggle("Renew expired Claude sign-ins", isOn: $settings.renewClaudeSignIns)
            LabeledContent("Claude CLI") {
                if lookingForClaude {
                    ProgressView().controlSize(.small)
                } else {
                    Text(foundClaude.map { PathDisplay.abbreviate($0) } ?? String(localized: "Not found"))
                        .foregroundStyle(foundClaude == nil ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .disabled(!settings.renewClaudeSignIns)
        } header: {
            Text("General")
        } footer: {
            Text("Claude Code renews its sign-in only while it runs. When an account has been idle for a few hours, Leeway briefly starts claude for that account, in an empty folder, so that it renews the sign-in itself. It sends no message, uses no quota, and runs with the auto-updater off.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func findClaude() async {
        lookingForClaude = true
        foundClaude = await ClaudeCLIRenewer.binary()
        lookingForClaude = false
    }

    // MARK: Codex CLI

    private var codexSection: some View {
        Section {
            LabeledContent("In use") {
                if lookingForCodex {
                    ProgressView().controlSize(.small)
                } else {
                    Text(foundCodex.map { PathDisplay.abbreviate($0) } ?? String(localized: "Not found"))
                        .foregroundStyle(foundCodex == nil ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            HStack {
                Button("Choose…", action: chooseCodex)
                if !settings.codexPath.isEmpty {
                    Button("Find Automatically") { settings.codexPath = "" }
                }
            }
        } header: {
            Text("Codex CLI")
        } footer: {
            Text("The app runs codex app-server to read Codex limits. A Codex home that has its own build in packages/app-server-daemon uses that build.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseCodex() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.prompt = String(localized: "Use")
        panel.message = String(localized: "Choose the codex program")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.codexPath = url.path
    }

    private func findCodex() async {
        lookingForCodex = true
        await CLILocator.shared.reset()
        if let custom = settings.resolvedCodexPath {
            foundCodex = CLILocator.isExecutable(custom) ? custom : nil
        } else {
            foundCodex = await CodexUsageProvider.sharedBinary()
        }
        lookingForCodex = false
    }
}

private struct AccountRow: View {
    @Environment(UsageStore.self) private var store
    @Environment(AppSettings.self) private var settings
    let account: AccountConfig
    let choosesMenuBar: Bool
    @State private var name = ""
    @State private var loadedName = false

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: account.provider, size: 20)
                .opacity(account.isVisible ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name, prompt: Text(AccountArrangement.autoName(account)))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.plain)
                    .fontWeight(.medium)
                    .disabled(account.duplicateOf != nil)
                    .accessibilityLabel("Name of \(account.displayPath)")
                    .onSubmit { store.setName(name, for: account) }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if account.duplicateOf == nil {
                if choosesMenuBar {
                    Toggle(isOn: Binding(
                        get: { store.isChosenForMenuBar(account) },
                        set: { store.setInMenuBar($0, for: account) })
                    ) {
                        Image(systemName: "menubar.rectangle")
                    }
                    .toggleStyle(.button)
                    .disabled(account.isHidden)
                    .help("Show in the menu bar")
                    .accessibilityLabel("Show \(account.name) in the menu bar")
                }
                Toggle("Show", isOn: Binding(
                    get: { !account.isHidden },
                    set: { store.setHidden(!$0, for: account) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Show this account")
                    .accessibilityLabel("Show \(account.name)")
            }
            if account.isCustom {
                Button {
                    store.removeCustomFolder(account)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this folder")
                .accessibilityLabel("Remove \(account.displayPath)")
            }
        }
        .onAppear {
            name = settings.override(for: account.id).name ?? ""
            loadedName = true
        }
        // Save the name after a short pause in typing, not on each key.
        .task(id: name) {
            guard loadedName else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.setName(name, for: account)
        }
    }

    private var detail: String {
        if let duplicate = account.duplicateOf {
            return String(localized: "\(account.displayPath) · same login as \(duplicate)")
        }
        let email = account.email == account.name ? nil : account.email
        return [account.displayPath, email].compactMap { $0 }.joined(separator: " · ")
    }
}
