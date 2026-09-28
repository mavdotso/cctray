import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @State private var pane: SettingsPaneID = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPaneID.allCases, selection: $pane) { id in
                Label { Text(id.title) } icon: { IconBadge(symbol: id.symbol) }
                    .tag(id)
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralSettings()
                case .agents: AgentSettings()
                case .notifications: NotificationSettings()
                case .automation: AutomationSettings()
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 740, height: 540)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            dropInitialFocus()
        }
    }

    /* AppKit focuses the first text field on open; nothing should be focused. */
    private func dropInitialFocus() {
        DispatchQueue.main.async {
            NSApp.windows.first { $0.title.contains("Settings") }?
                .makeFirstResponder(nil)
        }
    }
}

enum SettingsPaneID: CaseIterable, Identifiable {
    case general, agents, notifications, automation
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .notifications: "Notifications"
        case .automation: "Automation"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .agents: "chevron.left.forwardslash.chevron.right"
        case .notifications: "bell.fill"
        case .automation: "clock.arrow.circlepath"
        }
    }
}

struct IconBadge: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Color.gray.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct GeneralSettings: View {
    @AppStorage(PrefKey.terminalApp) private var terminalApp = TerminalApp.detectDefault().rawValue
    @AppStorage(PrefKey.sessionDir) private var sessionDir = ""
    @AppStorage(PrefKey.showSessions) private var showSessions = true
    @AppStorage(PrefKey.showAccounts) private var showAccounts = true
    @AppStorage(PrefKey.autoAwake) private var autoAwake = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register()
                             : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Picker("Terminal app", selection: $terminalApp) {
                    ForEach(TerminalApp.allCases) { app in
                        Text(app.displayName).tag(app.rawValue)
                    }
                }
                LabeledContent {
                    Button("Choose…") { pickFolder() }
                } label: {
                    Text("New sessions open in")
                    Text(folderLabel).truncationMode(.middle)
                }
            }

            Section("Menu bar") {
                Toggle("Show running sessions", isOn: $showSessions)
                Toggle("Show account switcher", isOn: $showAccounts)
            }

            Section {
                Toggle(isOn: $autoAwake) {
                    Text("Keep Mac awake while sessions run")
                    Text("Turns Keep Mac Awake on when a session starts and off when the last one ends.")
                }
            }
        }
    }

    private var folderLabel: String {
        let dir = TerminalLauncher.sessionDirectory ?? NSHomeDirectory()
        return (dir as NSString).abbreviatingWithTildeInPath
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: TerminalLauncher.sessionDirectory ?? NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            sessionDir = url.path
        }
    }
}

private struct AgentSettings: View {
    @EnvironmentObject var state: AppState
    @AppStorage(CodingAgent.claude.enabledKey) private var claudeEnabled = true
    @AppStorage(CodingAgent.codex.enabledKey) private var codexEnabled = true
    @State private var recordingAgent: CodingAgent?

    var body: some View {
        Form {
            agentSection(.claude, isOn: $claudeEnabled)
            agentSection(.codex, isOn: $codexEnabled)
        }
        .onChange(of: claudeEnabled) { _, _ in recordingAgent = nil; state.agentSettingsChanged() }
        .onChange(of: codexEnabled) { _, _ in recordingAgent = nil; state.agentSettingsChanged() }
    }

    private func agentSection(_ agent: CodingAgent, isOn: Binding<Bool>) -> some View {
        Section(agent.name) {
            Toggle(isOn: isOn) {
                Text("Enable \(agent.name)")
                Text("Tracks usage, sessions, and accounts. Sends alerts and pre-warm prompts.")
            }
            LabeledContent {
                AgentHotkeyRecorder(agent: agent, recordingAgent: $recordingAgent)
            } label: {
                Text("New session shortcut")
                Text("Opens \(agent.name) in a new terminal from any app.")
            }
            .disabled(!isOn.wrappedValue)
        }
    }
}

private struct NotificationSettings: View {
    @EnvironmentObject var state: AppState
    @AppStorage(PrefKey.chimeSound) private var chime = CueSynth.defaultName
    @AppStorage(PrefKey.chimeSilent) private var silent = false
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    permissionControl
                } label: {
                    Text("System notifications")
                    Text("cctray tells you when an agent finishes and needs you.")
                }
            }

            Section("Attention chime") {
                AttentionToggle(attention: state.attention)
                Toggle(isOn: $silent) {
                    Text("Silent alerts")
                    Text("Show the notification without a sound.")
                }
                Picker("Sound", selection: $chime) {
                    ForEach(CueSynth.names, id: \.self) { Text($0.capitalized) }
                }
                .onChange(of: chime) { _, s in CueSynth.play(s) }
                .disabled(silent)
            }

            if let error = state.attention.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            if !CueSynth.names.contains(chime) { chime = CueSynth.defaultName }
            refreshNotifStatus()
        }
    }

    @ViewBuilder
    private var permissionControl: some View {
        switch notifStatus {
        case .authorized, .provisional:
            Label("On", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDetermined:
            Button("Turn On") {
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound]) { _, _ in refreshNotifStatus() }
            }
        default:
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func refreshNotifStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { notifStatus = s.authorizationStatus }
        }
    }
}

private struct AttentionToggle: View {
    @ObservedObject var attention: AttentionCenter

    var body: some View {
        Toggle(isOn: $attention.isOn) {
            Text("Alert when an agent finishes")
            Text("Skips the alert when that terminal is in front.")
        }
    }
}

private struct AutomationSettings: View {
    @AppStorage(PrefKey.prewarmStartMin) private var startMin = ActiveHours.default.startMin
    @AppStorage(PrefKey.prewarmEndMin) private var endMin = ActiveHours.default.endMin
    @AppStorage(PrefKey.staleDays) private var staleDays = Worktrees.defaultStaleDays
    @AppStorage(PrefKey.autoClean) private var autoClean = false

    var body: some View {
        Form {
            Section("Pre-warm") {
                LabeledContent {
                    HStack(spacing: 6) {
                        MinutePicker(minutes: $startMin)
                        Text("to").foregroundStyle(.secondary)
                        MinutePicker(minutes: $endMin)
                    }
                } label: {
                    Text("Active hours")
                    Text("Starts a new session window after a reset, only during these hours.")
                }
            }

            Section("Worktrees") {
                LabeledContent("Stale after") {
                    HStack(spacing: 4) {
                        Text(staleDays == 1 ? "1 day" : "\(staleDays) days")
                            .monospacedDigit()
                        Stepper("Stale after", value: $staleDays, in: 1...365)
                            .labelsHidden()
                    }
                }
                Toggle(isOn: $autoClean) {
                    Text("Clean stale worktrees automatically")
                    Text("Removes stale worktrees with no uncommitted changes, and their session data, without asking.")
                }
            }
        }
    }
}

struct MinutePicker: View {
    @Binding var minutes: Int
    var body: some View {
        DatePicker("", selection: Binding(
            get: {
                Calendar.current.date(bySettingHour: minutes / 60,
                                      minute: minutes % 60, second: 0,
                                      of: Date()) ?? Date()
            },
            set: { minutes = PreWarmRule.minutesOfDay($0) }
        ), displayedComponents: .hourAndMinute)
        .labelsHidden()
    }
}
