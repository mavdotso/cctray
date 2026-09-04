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
        .frame(width: 360)
        .background(.regularMaterial, ignoresSafeAreaEdges: .all)
        .onAppear { selected = Set(worktrees.stale.filter(\.isRemovable).map(\.id)) }
    }

    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean Worktrees")
                    .font(.headline)
                Text("No commits for \(Worktrees.staleDays)+ days. Session data goes too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 8)

            if worktrees.stale.isEmpty {
                Text("Nothing stale to clean.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(worktrees.stale) { wt in
                            row(wt)
                        }
                    }
                }
                .frame(height: min(CGFloat(worktrees.stale.count) * 40 + 8, 320))
            }

            GroupDivider()

            HStack {
                Text(footerText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Remove") { run() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || working)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
        }
        .padding(10)
    }

    private func row(_ wt: Worktree) -> some View {
        SelectRow(isOn: selected.contains(wt.id),
                  action: { toggle(wt.id) }) {
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

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private var footerText: String {
        Worktrees.footerText(for: worktrees.stale.filter { selected.contains($0.id) })
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
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

private struct SelectRow<Content: View>: View {
    let isOn: Bool
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                content()
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }
}
