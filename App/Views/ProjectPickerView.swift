// Top bar shows audit scope (latest Claude session vs pinned folder) and lets
// the user switch scope. Refresh is one-shot, not realtime polling.

import SwiftUI
import ClaudeWatchCore
import AppKit

struct ProjectPickerView: View {
    @Environment(SessionWatcher.self) private var watcher
    @Environment(ProjectStore.self) private var projectStore

    var body: some View {
        HStack(spacing: 12) {
            modeIcon
            VStack(alignment: .leading, spacing: 2) {
                modeTitle
                folderSubtitle
            }
            Spacer()
            // Pet ngay bên trái cụm snapshot + "Pin folder".
            HeaderPet()
            if watcher.lastRefreshAt != nil {
                snapshotPill
            }
            if !projectStore.followLatest {
                Button(action: switchToFollow) {
                    pillButton("Latest Claude", tint: Claude.textPrimary, filled: false)
                }
                .buttonStyle(.plain)
            }
            Button(action: pickFolder) {
                pillButton(projectStore.pinnedFolder == nil ? "Pin folder…" : "Change…",
                           tint: .white, filled: true)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Pieces

    private var modeIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Claude.orangeSoft)
                .frame(width: 36, height: 36)
            Image(systemName: projectStore.followLatest
                  ? "dot.radiowaves.left.and.right"
                  : "pin.fill")
                .foregroundStyle(Claude.orange)
        }
    }

    private var modeTitle: some View {
        HStack(spacing: 6) {
            if projectStore.followLatest {
                Text("Latest Claude session")
                    .font(ClaudeFont.heading(14))
                    .foregroundStyle(Claude.textPrimary)
            } else if let folder = projectStore.pinnedFolder {
                Text(folder.lastPathComponent)
                    .font(ClaudeFont.heading(14))
                    .foregroundStyle(Claude.textPrimary)
            } else {
                Text("No project")
                    .font(ClaudeFont.heading(14))
                    .foregroundStyle(Claude.textMuted)
            }
        }
    }

    private var folderSubtitle: some View {
        let path: String? = {
            if projectStore.followLatest {
                return watcher.resolvedFolder?.path ?? "Latest from ~/.claude/projects"
            }
            return projectStore.pinnedFolder?.path
        }()
        return Text(path ?? "Pin a folder or read the latest Claude session")
            .font(ClaudeFont.mono(11))
            .foregroundStyle(Claude.textMuted)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var snapshotPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("snapshot")
                .font(ClaudeFont.label(11))
        }
        .foregroundStyle(Claude.done)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Claude.done.opacity(0.12), in: Capsule())
    }

    private func pillButton(_ title: String, tint: Color, filled: Bool) -> some View {
        Text(title)
            .font(ClaudeFont.body(12))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(filled ? Claude.orange : Claude.surfaceAlt)
            .foregroundStyle(tint)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(filled ? .clear : Claude.border, lineWidth: 1)
            )
    }

    // MARK: - Actions

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Audit"
        panel.message = "Select a project folder to pin. Agent Watch will read the latest session log once when refreshed."
        if panel.runModal() == .OK, let url = panel.url {
            projectStore.pinFolder(url)
            watcher.loadPinned(folder: url)
        }
    }

    private func switchToFollow() {
        projectStore.switchToFollowLatest()
        watcher.loadLatest()
    }
}
