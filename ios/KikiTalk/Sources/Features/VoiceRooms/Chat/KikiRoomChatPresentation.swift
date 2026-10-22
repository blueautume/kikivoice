import SwiftUI

/// Only online listeners appear here; seated speakers belong to the stage above.
struct KikiRoomAudienceStrip<Avatar: View>: View {
    let listeners: [KikiRoomMember]
    let onOpenPerson: (String) -> Void
    @ScaledMetric(relativeTo: .caption2) private var labelHeight: CGFloat = 14
    @ViewBuilder var avatar: (KikiRoomMember) -> Avatar

    private var onlineListeners: [KikiRoomMember] { listeners.filter { $0.online && $0.seatIndex == nil } }

    @ViewBuilder var body: some View {
        if !onlineListeners.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(onlineListeners) { member in
                        Button { onOpenPerson(member.userID) } label: {
                            VStack(spacing: 5) {
                                avatar(member).frame(width: 36, height: 36)
                                Text(member.name).font(.caption2).foregroundStyle(.white.opacity(0.78))
                                    .lineLimit(1).frame(width: 56, height: labelHeight)
                            }
                            .padding(.vertical, 4).frame(minWidth: 56, minHeight: 58).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看\(member.name)的个人主页")
                        .accessibilityIdentifier("livekit.room.listener.\(member.userID)")
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("livekit.room.listeners")
            .frame(maxWidth: .infinity)
            .frame(height: 53 + labelHeight)
        }
    }
}

/// The sender's avatar stays independent from the bubble, including local messages.
struct KikiRoomChatBubbleRow<Avatar: View, BubbleBackground: View>: View {
    let id: String
    let senderName: String
    let text: String
    let isLocal: Bool
    var isGift = false
    let onOpenSender: () -> Void
    @ViewBuilder var avatar: () -> Avatar
    @ViewBuilder var bubbleBackground: () -> BubbleBackground

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button(action: onOpenSender) {
                avatar().frame(width: 32, height: 32).padding(4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看\(senderName)的个人主页")
            .accessibilityIdentifier("livekit.room.messageAvatar.\(id)")
            (Text(senderName + "：").foregroundColor(isLocal ? Color(hex: 0xC6B5FF) : .white.opacity(0.65))
             + Text(isGift ? "🎁 " + text : text).foregroundColor(isGift ? Color(hex: 0xE5D5FF) : .white))
                .font(.subheadline).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background { bubbleBackground() }
                .accessibilityIdentifier("livekit.room.messageBubble.\(id)")
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

struct KikiRoomAnnouncementChatRow: View {
    let text: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color(hex: 0x8B66FF), in: Circle()).padding(4)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("公告").font(.caption2).foregroundStyle(Color(hex: 0xD4C7FF))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color(hex: 0x8B66FF).opacity(0.25), in: Capsule())
                        .fixedSize()
                    Text(text).font(.subheadline).foregroundStyle(.white).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 15))
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("房间公告：" + text)
        .accessibilityIdentifier("livekit.room.announcement")
    }
}

/// The service provides the current announcement, not an announcement event history.
/// Rebuilding this list replaces that one row and never duplicates a polling response.
enum KikiRoomChatEntry: Identifiable, Equatable {
    case message(KikiVoiceMessage)
    case gift(KikiGiftEvent)
    case announcement(KikiRoomAnnouncement)

    var id: String {
        switch self {
        case .message(let value): return value.id
        case .gift(let value): return "gift-" + value.id
        case .announcement(let value): return "announcement-\(value.revision)"
        }
    }

    var createdAt: Int {
        switch self {
        case .message(let value): return value.createdAt
        case .gift(let value): return value.createdAt
        case .announcement(let value): return value.updatedAt
        }
    }

    var sequence: Int {
        switch self {
        case .message(let value): return value.sequence
        case .gift(let value): return value.seq
        case .announcement(let value): return value.revision
        }
    }

    var kindOrder: Int {
        switch self { case .message: return 0; case .gift: return 1; case .announcement: return 2 }
    }

    static func timeline(messages: [KikiVoiceMessage], gifts: [KikiGiftEvent],
                         announcement: KikiRoomAnnouncement, blockedIDs: Set<String>) -> [Self] {
        var entries = messages.filter { !blockedIDs.contains($0.senderID) }.map(Self.message)
        entries += gifts.filter {
            !blockedIDs.contains($0.senderUserID) && !blockedIDs.contains($0.recipientUserID)
        }.map(Self.gift)
        if !announcement.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           announcement.updatedByUserID.map({ !blockedIDs.contains($0) }) ?? true {
            entries.append(.announcement(announcement))
        }
        return entries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            if $0.kindOrder != $1.kindOrder { return $0.kindOrder < $1.kindOrder }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id < $1.id
        }
    }
}
