import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage(CodingAgent.claude.enabledKey) private var claudeEnabled = true
    @AppStorage(CodingAgent.codex.enabledKey) private var codexEnabled = true
    @State private var recordingAgent: CodingAgent?
    @AppStorage(PrefKey.terminalApp) private var terminalApp = TerminalApp.detectDefault().rawValue
    @AppStorage(PrefKey.prewarmStartMin) private var startMin = ActiveHours.default.startMin
    @AppStorage(PrefKey.prewarmEndMin) private var endMin = ActiveHours.default.endMin
    @AppStorage(PrefKey.chimeSound) private var chime = CueSynth.defaultName
    @AppStorage(PrefKey.sessionDir) private var sessionDir = ""
    @AppStorage(PrefKey.showSessions) private var showSessions = true
    @AppStorage(PrefKey.showAccounts) private var showAccounts = true
    @AppStorage(PrefKey.autoAwake) private var autoAwake = false
    @AppStorage(PrefKey.staleDays) private var staleDays = Worktrees.defaultStaleDays
    @AppStorage(PrefKey.autoClean) private var autoClean = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            launchSettings
            automationSettings
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollIndicators(.hidden)
        .frame(width: 800, height: 560)
        .modifier(SettingsWindowBackground())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onChange(of: claudeEnabled) { _, _ in recordingAgent = nil; state.agentSettingsChanged() }
        .onChange(of: codexEnabled) { _, _ in recordingAgent = nil; state.agentSettingsChanged() }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            if !CueSynth.names.contains(chime) { chime = CueSynth.defaultName }
            refreshNotifStatus()
            dropInitialFocus()
        }
    }

    private var launchSettings: some View {
        Form {
            Section("General") {
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
            }

            Section("Agents") {
                Toggle("Enable Claude", isOn: $claudeEnabled)
                LabeledContent("Claude hotkey") { AgentHotkeyRecorder(agent: .claude, recordingAgent: $recordingAgent) }
                    .disabled(!claudeEnabled)
                Toggle("Enable Codex", isOn: $codexEnabled)
                LabeledContent("Codex hotkey") { AgentHotkeyRecorder(agent: .codex, recordingAgent: $recordingAgent) }
                    .disabled(!codexEnabled)
            }

            Section("New sessions") {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(folderLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { pickFolder() }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity)
    }

    private var automationSettings: some View {
        Form {
            Section("Sessions") {
                Toggle("Show running sessions in menu", isOn: $showSessions)
                Toggle("Show account switcher in menu", isOn: $showAccounts)
                Toggle("Keep Mac awake while sessions run", isOn: $autoAwake)
                    .help("Turns Keep Mac Awake on when a session starts and off when the last one ends.")
            }

            Section("Worktrees") {
                LabeledContent("Stale after") {
                    HStack(spacing: 2) {
                        TextField("", value: $staleDays, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .frame(width: 36)
                        Stepper("", value: $staleDays, in: 1...365).labelsHidden()
                        Text("days").foregroundStyle(.secondary).padding(.leading, 4)
                    }
                    .controlSize(.small)
                }
                Toggle("Clean stale worktrees automatically", isOn: $autoClean)
                    .help("Removes stale worktrees that have no uncommitted changes, and their Claude session data, without asking.")
            }

            Section("Pre-warm") {
                LabeledContent("Active hours") {
                    HStack(spacing: 6) {
                        MinutePicker(minutes: $startMin)
                        Text("–").foregroundStyle(.secondary)
                        MinutePicker(minutes: $endMin)
                    }
                }
            }

            Section("Attention chime") {
                Picker("Sound", selection: $chime) {
                    ForEach(CueSynth.names, id: \.self) { Text($0.capitalized) }
                }
                .onChange(of: chime) { _, s in CueSynth.play(s) }

                LabeledContent("Notifications") {
                    switch notifStatus {
                    case .authorized, .provisional:
                        Text("Enabled").foregroundStyle(.secondary)
                    case .notDetermined:
                        Button("Enable") {
                            UNUserNotificationCenter.current()
                                .requestAuthorization(options: [.alert, .sound]) { _, _ in
                                    refreshNotifStatus()
                                }
                        }
                    default:
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsWindowBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.containerBackground(for: .window) {
                Color.clear
                    .glassEffect(.regular, in: Rectangle())
                    .ignoresSafeArea()
            }
        } else if #available(macOS 15.0, *) {
            content.containerBackground(.regularMaterial, for: .window)
        } else {
            content.background(.regularMaterial)
        }
    }
}

extension SettingsView {
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

    /* AppKit focuses the first text field on open; nothing should be focused. */
    private func dropInitialFocus() {
        DispatchQueue.main.async {
            NSApp.windows.first { $0.title.contains("Settings") }?
                .makeFirstResponder(nil)
        }
    }

    private func refreshNotifStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { notifStatus = s.authorizationStatus }
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
