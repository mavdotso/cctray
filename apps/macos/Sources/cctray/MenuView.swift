import SwiftUI

struct MenuView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var menuWindow: NSWindow?
    @AppStorage(PrefKey.showAccounts) private var showAccounts = true
    @AppStorage(CodingAgent.claude.enabledKey) private var claudeEnabled = true
    @AppStorage(CodingAgent.codex.enabledKey) private var codexEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if claudeEnabled {
                UsagePanel(model: state.usageModel, title: codexEnabled ? "Claude" : nil)
            }
            if codexEnabled { CodexPanel(model: state.codex) }
            AwakeRow(awake: state.awake)
            PreWarmRow(preWarm: state.preWarm)
            AttentionRow(attention: state.attention)
            OrphanRow(sessions: state.sessions)
            if showAccounts {
                GroupDivider()
                if claudeEnabled {
                    AccountRow(accounts: state.accounts, title: codexEnabled ? "Claude account" : "Account")
                }
                if codexEnabled { CodexAccountRow(accounts: state.codexAccounts) }
            }
            SessionsSection(sessions: state.sessions)
            WorktreeRow(worktrees: state.worktrees)
            GroupDivider()
            footer
        }
        .padding(10)
        .frame(width: 312)
        .background(MenuWindowReader { menuWindow = $0 })
        .onAppear { state.menuDidOpen() }
        .onDisappear { state.menuDidClose() }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let launchError = state.launchError {
                Text(launchError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 6)
            }
            HStack {
                Button {
                    menuWindow?.orderOut(nil)
                    state.menuDidClose()
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("Settings…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("Quit")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
    }
}

private struct MenuWindowReader: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: WindowView, context: Context) {}

    final class WindowView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onWindowChange?(window)
            }
        }
    }
}

private struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

struct GroupDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
    }
}

struct Row<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }
}

struct HoverRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: action) {
            Row(title: title, subtitle: subtitle, trailing: trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }
}

struct UsageColumn {
    let label: String
    let pct: Double
    let detail: String
    var available = true
    var help: String?

    static func resetText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return UsageParser.countdown(to: date, from: Date())
    }

    static func pctDetail(_ window: UsageWindow) -> String {
        let pct = "\(Int(window.utilization))%"
        guard let reset = window.resetsAt else { return pct }
        return "\(pct) · \(resetText(reset))"
    }
}

struct UsagePanel: View {
    @ObservedObject var model: UsageModel
    var title: String?

    var body: some View {
        if let usage = model.usage {
            UsageStats(title: title, columns: columns(usage), isStale: model.isStale)
        }
    }

    private func columns(_ usage: Usage) -> [UsageColumn] {
        var columns = [
            UsageColumn(label: "Session", pct: usage.fiveHour.utilization,
                        detail: UsageColumn.resetText(usage.fiveHour.resetsAt)),
            UsageColumn(label: "Week", pct: usage.sevenDay.utilization,
                        detail: UsageColumn.pctDetail(usage.sevenDay))
        ]
        if let (label, window) = usage.modelLimit {
            columns.append(UsageColumn(label: label, pct: window.utilization,
                                       detail: UsageColumn.pctDetail(window)))
        }
        return columns
    }
}

struct UsageStats: View {
    var title: String?
    let columns: [UsageColumn]
    var isStale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(columns.indices, id: \.self) { index in
                    if index > 0 { Divider() }
                    let column = columns[index]
                    gaugeColumn(label: column.label, pct: column.pct, detail: column.detail,
                                available: column.available)
                        .help(column.help ?? column.label)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if isStale {
                Text("May be out of date — retrying")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .padding(.bottom, 6)
    }

    private func gaugeColumn(label: String, pct: Double, detail: String, available: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.6))
                    if available {
                        Capsule()
                            .fill(Color(nsColor: .controlAccentColor))
                            .frame(width: max(4, geo.size.width * min(pct, 100) / 100))
                    }
                }
            }
            .frame(height: 4)
            Text(detail)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Row(title: title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

struct AwakeRow: View {
    @ObservedObject var awake: AwakeController
    var body: some View { ToggleRow(title: "Keep Mac Awake", isOn: $awake.isOn) }
}

struct PreWarmRow: View {
    @ObservedObject var preWarm: PreWarmController
    var body: some View {
        ToggleRow(title: "Pre-warm", subtitle: preWarm.lastError, isOn: $preWarm.isOn)
    }
}

struct AttentionRow: View {
    @ObservedObject var attention: AttentionCenter
    var body: some View {
        ToggleRow(title: "Attention chime", subtitle: attention.lastError, isOn: $attention.isOn)
    }
}

struct AccountRow: View {
    @ObservedObject var accounts: AccountStore
    var title = "Account"
    @State private var newName = ""
    @State private var editing: Edit?

    enum Edit: Equatable { case save, rename(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Row(title: title,
                subtitle: accounts.statusText ?? accounts.mismatch) {
                Menu(accounts.active ?? "Choose…") {
                    ForEach(accounts.profiles, id: \.self) { name in
                        Button(AccountStore.menuLabel(name, summary: accounts.usageByProfile[name])) {
                            accounts.activate(name)
                        }
                    }
                    Divider()
                    if accounts.isAddingAccount {
                        Button("Cancel login") { accounts.cancelAdd() }
                    } else {
                        Button("Add account…") { accounts.addAccount() }
                    }
                    if let unsaved = accounts.unsavedLogin {
                        Button("Save current login as…") { newName = unsaved; editing = .save }
                    }
                    if let active = accounts.active {
                        Button("Rename \(active)…") { newName = active; editing = .rename(active) }
                        Button("Delete \(active)", role: .destructive) { accounts.delete(active) }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
            .help("Applies to new sessions. Running sessions keep the current account.")
            if let editing {
                HStack(spacing: 6) {
                    TextField(editing == .save ? "Profile name" : "New name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { commit() }
                    Button(editing == .save ? "Save" : "Rename") { commit() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
        }
    }

    private func commit() {
        switch editing {
        case .save: accounts.saveCurrent(as: newName)
        case .rename(let old): accounts.rename(old, to: newName)
        case nil: break
        }
        newName = ""
        editing = nil
    }
}

struct WorktreeRow: View {
    @ObservedObject var worktrees: WorktreeModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !worktrees.stale.isEmpty {
            GroupDivider()
            HoverRow(title: "Clean stale worktrees",
                     action: {
                         openWindow(id: "cleanWorktrees")
                         NSApp.activate(ignoringOtherApps: true)
                     }) {
                Text("\(worktrees.stale.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SessionsSection: View {
    @ObservedObject var sessions: SessionModel
    @AppStorage(PrefKey.showSessions) private var show = true

    private static let visibleRows = 5

    var body: some View {
        if show && !sessions.sessions.isEmpty {
            GroupDivider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sessions.sessions) { SessionRow(session: $0) }
                }
            }
            .frame(height: SessionRow.height * min(CGFloat(sessions.sessions.count),
                                                   CGFloat(Self.visibleRows)))
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

struct SessionRow: View {
    static let height: CGFloat = 34

    let session: AgentSession
    @EnvironmentObject var state: AppState

    var body: some View {
        Button {
            state.launchError = TerminalLauncher.focusSession(tty: session.tty,
                                                              cwd: session.cwd)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Circle()
                    .fill(session.isWorking ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(session.isWorking ? "Working" : "Idle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(height: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }

    private var title: String {
        let dir = (session.cwd as NSString).lastPathComponent
        return dir.isEmpty ? session.tty : dir
    }

    private var detail: String {
        session.agent.name + " · " + (session.title ?? (session.cwd as NSString).abbreviatingWithTildeInPath)
    }
}

struct CodexPanel: View {
    @ObservedObject var model: CodexModel

    var body: some View {
        if let limits = model.limits {
            UsageStats(title: "Codex", columns: columns(limits), isStale: model.error != nil)
        }
    }

    private func columns(_ limits: CodexLimits) -> [UsageColumn] {
        var spark = column("Spark", limits.sparkWindow)
        spark.help = limits.sparkWindows.map {
            "\($0.label): \(Int($0.usedPercent))% · \(UsageColumn.resetText($0.reset))"
        }.joined(separator: "\n")
        var result: [UsageColumn] = []
        if let session = limits.sessionWindow {
            result.append(column("Session", session, countdownOnly: true))
        }
        return result + [column("Week", limits.weeklyWindow), spark]
    }

    private func column(_ label: String, _ window: CodexLimits.Window?, countdownOnly: Bool = false) -> UsageColumn {
        guard let window else {
            return UsageColumn(label: label, pct: 0, detail: "—", available: false,
                               help: "Codex has not reported this limit")
        }
        let usage = UsageWindow(utilization: window.usedPercent, resetsAt: window.reset)
        return UsageColumn(label: label, pct: window.usedPercent,
                           detail: countdownOnly ? UsageColumn.resetText(window.reset) : UsageColumn.pctDetail(usage))
    }
}

struct CodexAccountRow: View {
    @ObservedObject var accounts: CodexAccounts
    @ObservedObject private var model: CodexModel
    @State private var editing = false
    @State private var renaming = false
    @State private var name = ""

    init(accounts: CodexAccounts) {
        self.accounts = accounts
        self.model = accounts.model
    }

    private var profile: CodexProfile? { accounts.profiles.first { $0.id == accounts.selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Row(title: "Codex account", subtitle: accounts.error ?? model.error) {
                Menu(profile?.name ?? "Choose…") {
                    ForEach(accounts.profiles) { profile in
                        Button(AccountStore.menuLabel(profile.name, summary: accounts.usageByProfile[profile.id])) {
                            accounts.selected = profile.id
                        }
                    }
                    Divider()
                    Button("Add account…") { renaming = false; name = ""; editing = true }
                    if let profile {
                        Button("Rename \(profile.name)…") { renaming = true; name = profile.name; editing = true }
                        Button("Delete \(profile.name)", role: .destructive) { accounts.delete(profile.id) }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
            .help("Applies to new sessions. Running sessions keep the current account.")
            if editing {
                HStack(spacing: 6) {
                    TextField("Account name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { save() }
                    Button(renaming ? "Rename" : "Add") { save() }.controlSize(.small)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
        }
    }

    private func save() {
        if renaming { accounts.rename(accounts.selected, to: name) }
        else { accounts.add(name: name) }
        if accounts.error == nil { editing = false }
    }
}

struct OrphanRow: View {
    @ObservedObject var sessions: SessionModel

    var body: some View {
        if !sessions.orphanPids.isEmpty {
            HoverRow(title: "Kill orphaned sessions",
                     action: { sessions.killOrphans() }) {
                Text("\(sessions.orphanPids.count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.red))
            }
        }
    }
}
