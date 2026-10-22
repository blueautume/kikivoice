import SwiftUI

/// Shared inbox presentation. Persistence and destructive confirmation belong
/// to the screen so this row can also render local, account-free UI fixtures.
struct KikiInboxConversationRow: View {
    let entry: KikiInboxEntry
    let isWorking: Bool
    var canDelete: Bool = true
    let onOpen: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                avatar
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(entry.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(KikiPalette.text)
                            .lineLimit(1)
                        if entry.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(KikiPalette.purple)
                                .accessibilityLabel("已置顶")
                        }
                        Spacer(minLength: 5)
                        if let time = KikiInboxTime.label(entry.activityAt) {
                            Text(time)
                                .font(.caption)
                                .foregroundStyle(KikiPalette.muted)
                                .fixedSize()
                        }
                    }
                    HStack(spacing: 12) {
                        Text(entry.preview)
                            .font(.subheadline)
                            .foregroundStyle(KikiPalette.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let unread = entry.unreadLabel {
                            Text(unread)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .frame(minWidth: 20, minHeight: 20)
                                .background(KikiPalette.action, in: Capsule())
                                .accessibilityLabel("\(entry.unreadCount) 条未读")
                        }
                    }
                }
            }
            .padding(.vertical, 17)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityIdentifier(entry.id == "notifications" ? "messages.notifications" : "messages." + entry.id)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // The first trailing action sits at the outer edge of the row.
            if canDelete {
                Button(action: onDelete) { Label("删除", systemImage: "trash") }
                    .tint(.red)
                    .disabled(isWorking)
                    .accessibilityIdentifier("messages.delete." + entry.id)
            }

            Button(action: onTogglePin) {
                Label(entry.isPinned ? "取消置顶" : "置顶", systemImage: entry.isPinned ? "pin.slash" : "pin")
            }
            .tint(KikiPalette.action)
            .disabled(isWorking)
            .accessibilityIdentifier("messages.pin." + entry.id)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        switch entry.content {
        case .notifications:
            Image(systemName: "bell.fill")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(KikiPalette.purple)
                .frame(width: 50, height: 50)
                .background(KikiPalette.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 17))
                .accessibilityHidden(true)
        case .direct(let conversation):
            KikiAvatar(index: conversation.person.avatarIndex, size: 50, customURL: conversation.person.avatarURL)
        }
    }
}
