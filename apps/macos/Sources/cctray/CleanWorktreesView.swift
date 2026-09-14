import SwiftUI

struct CleanWorktreesView: View {
    @ObservedObject var worktrees: WorktreeModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var working = false
    @State private var result: (removed: Int, skipped: Int, freedKB: Int)?

    var body: some View {
        Group {
            if let result {
                successView(result)
            } else {
                pickerView
            }
        }
        .frame(width: 420)
        .modifier(SettingsWindowBackground())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { selected = Set(worktrees.stale.filter(\.isRemovable).map(\.id)) }
    }

    private var pickerView: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if worktrees.stale.isEmpty {
                        Text("Nothing stale to clean.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(worktrees.stale) { wt in
                            row(wt)
                        }
                    }
                } header: {
                    Text("Stale worktrees")
                } footer: {
                    Text("No commits for \(Worktrees.staleDays)+ days. Session data goes too.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(worktrees.stale.count <= 6)
            .frame(height: min(CGFloat(max(worktrees.stale.count, 1)) * 44 + 96, 400))
            .disabled(working)

            HStack {
                Text(footerText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button {
                    run()
                } label: {
                    if working {
                        ProgressView().controlSize(.small).frame(width: 52)
                    } else {
                        Text("Remove").frame(width: 52)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || working)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
    }

    private func row(_ wt: Worktree) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(wt.id) },
            set: { if $0 { selected.insert(wt.id) } else { selected.remove(wt.id) } }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(wt.name)
                    .lineLimit(1)
                Text(subtitle(wt))
                    .font(.caption)
                    .foregroundStyle(wt.dirty || wt.locked
                                     ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
    }

    private func subtitle(_ wt: Worktree) -> String {
        var parts = [wt.repoName, "\(wt.ageDays)d", wt.sizeKB.kbSizeText]
        if wt.dirty { parts.append("uncommitted changes") }
        if wt.locked { parts.append("locked") }
        return parts.joined(separator: " · ")
    }

    private var footerText: String {
        if working { return "Removing \(selected.count)…" }
        return Worktrees.footerText(for: worktrees.stale.filter { selected.contains($0.id) })
    }

    private func run() {
        working = true
        Task {
            result = await worktrees.remove(paths: selected)
            working = false
        }
    }

    private func successView(_ r: (removed: Int, skipped: Int, freedKB: Int)) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.green)
            Text(r.removed == 1 ? "Removed 1 worktree" : "Removed \(r.removed) worktrees")
                .font(.headline)
            Text("\(r.freedKB.kbSizeText) freed")
                .font(.caption)
                .foregroundStyle(.secondary)
            if r.skipped > 0 {
                Text("\(r.skipped) could not be removed")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}
