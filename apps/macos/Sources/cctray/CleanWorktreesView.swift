import SwiftUI

struct CleanWorktreesView: View {
    @ObservedObject var worktrees: WorktreeModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var working = false
    @State private var confirming = false
    @State private var listHeight: CGFloat = 0
    @State private var result: (removed: Int, skipped: Int, freedKB: Int)?

    var body: some View {
        Group {
            if let result {
                successView(result)
            } else {
                pickerView
            }
        }
        .frame(width: 440)
        .modifier(SettingsWindowBackground())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { selected = Set(worktrees.stale.filter(\.isRemovable).map(\.id)) }
    }

    private var selection: [Worktree] {
        worktrees.stale.filter { selected.contains($0.id) }
    }

    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stale worktrees")
                    .font(.headline)
                Text("No commits for \(Worktrees.staleDays)+ days. Removing one also deletes its session data.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Group {
                if worktrees.stale.isEmpty {
                    Text("Nothing stale to clean.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    list
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            .disabled(working)

            HStack {
                Text(footerText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button {
                    if selection.contains(where: \.dirty) { confirming = true } else { run() }
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
        }
        .padding(20)
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button("Remove", role: .destructive) { run() }
        } message: {
            Text("Their uncommitted changes will be lost. You cannot undo this.")
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Toggle(sources: worktrees.stale.map { isSelected($0) }, isOn: \.self) {
                HStack {
                    Text("Select all")
                    Spacer()
                    Text(worktrees.stale.count == 1 ? "1 worktree" : "\(worktrees.stale.count) worktrees")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(worktrees.stale) { wt in
                        if wt.id != worktrees.stale.first?.id { Divider().padding(.leading, 34) }
                        row(wt)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(listHeight, 360))
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func isSelected(_ wt: Worktree) -> Binding<Bool> {
        Binding(
            get: { selected.contains(wt.id) },
            set: { if $0 { selected.insert(wt.id) } else { selected.remove(wt.id) } }
        )
    }

    private func row(_ wt: Worktree) -> some View {
        Toggle(isOn: isSelected(wt)) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(wt.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text("\(wt.repoName) · \(wt.ageDays == 1 ? "1 day" : "\(wt.ageDays) days")")
                            .foregroundStyle(.secondary)
                        if wt.dirty {
                            Label("Uncommitted changes", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        if wt.locked {
                            Label("Locked", systemImage: "lock.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(wt.sizeKB.kbSizeText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var confirmTitle: String {
        let count = selection.filter(\.dirty).count
        return count == 1
            ? "Remove 1 worktree with uncommitted changes?"
            : "Remove \(count) worktrees with uncommitted changes?"
    }

    private var footerText: String {
        if working { return "Removing \(selected.count)…" }
        return Worktrees.footerText(for: selection)
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
