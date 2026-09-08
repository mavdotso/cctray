import SwiftUI

struct MenuView: View {
    @EnvironmentObject var state: AppState
    @AppStorage(PrefKey.showAccounts) private var showAccounts = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            UsagePanel(model: state.usageModel)
            AwakeRow(awake: state.awake)
            PreWarmRow(preWarm: state.preWarm)
            AttentionRow(attention: state.attention)
            OrphanRow(sessions: state.sessions)
            if showAccounts {
                GroupDivider()
                AccountRow(accounts: state.accounts)
            }
            SessionsSection(sessions: state.sessions)
            WorktreeRow(worktrees: state.worktrees)
            GroupDivider()
            footer
        }
        .padding(10)
        .frame(width: 312)
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
                SettingsLink {
                    Text("Settings…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first { $0.title.contains("Settings") }?
                            .makeKeyAndOrderFront(nil)
                    }
                })
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

struct UsagePanel: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        if let u = model.usage { panel(u) }
    }

    private func panel(_ u: Usage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                gaugeColumn(label: "Session",
                            pct: u.fiveHour.utilization,
                            detail: resetText(u.fiveHour.resetsAt))
                Divider()
                gaugeColumn(label: "Week",
                            pct: u.sevenDay.utilization,
                            detail: pctDetail(u.sevenDay))
                if let (label, window) = u.modelLimit {
                    Divider()
                    gaugeColumn(label: label,
                                pct: window.utilization,
                                detail: pctDetail(window))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if model.isStale {
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

    private func gaugeColumn(label: String, pct: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.6))
                    Capsule()
                        .fill(Color(nsColor: .controlAccentColor))
                        .frame(width: max(4, geo.size.width * min(pct, 100) / 100))
                }
            }
            .frame(height: 4)
            Text(detail)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return UsageParser.countdown(to: date, from: Date())
    }

    private func pctDetail(_ w: UsageWindow) -> String {
        let pct = "\(Int(w.utilization))%"
        guard let r = w.resetsAt else { return pct }
        return "\(pct) · \(UsageParser.countdown(to: r, from: Date()))"
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
    @State private var newName = ""
    @State private var editing: Edit?

    enum Edit: Equatable { case save, rename(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Row(title: "Account",
                subtitle: accounts.statusText ?? accounts.mismatch ?? accounts.currentEmail) {
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

    let session: ClaudeSession
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
        session.title ?? (session.cwd as NSString).abbreviatingWithTildeInPath
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
