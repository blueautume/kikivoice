import SwiftUI

struct KikiRoomAnnouncementView: View {
    @ObservedObject var rtc: KikiRTCService
    @State private var text = ""
    @State private var hasLoaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        KikiRoomAnnouncementContent(text: $text, canManageRoom: rtc.canManageRoom,
                                    canUseRoom: rtc.canUseRoom, isSaving: rtc.isSavingAnnouncement,
                                    announcement: rtc.announcement.text,
                                    onSave: { Task { if await rtc.saveAnnouncement(text) { dismiss() } } },
                                    onClose: { dismiss() })
            .onAppear { if !hasLoaded { text = rtc.announcement.text; hasLoaded = true } }
    }
}

struct KikiRoomAnnouncementContent: View {
    @Binding var text: String
    let canManageRoom: Bool
    let canUseRoom: Bool
    let isSaving: Bool
    let announcement: String
    let onSave: () -> Void
    let onClose: () -> Void
    private var canSave: Bool { canUseRoom && !isSaving && text.utf8.count <= 2_000 }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if canManageRoom {
                    TextEditor(text: $text).scrollContentBackground(.hidden)
                        .foregroundStyle(KikiPalette.text)
                        .padding(10).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("livekit.room.announcement.editor")
                    Text("最多 2000 字节；清空并保存可移除公告。").font(.caption).foregroundStyle(.secondary)
                    Button(action: onSave) {
                        HStack {
                            Spacer()
                            if isSaving { ProgressView().tint(.white) }
                            Text(isSaving ? "正在保存…" : "保存公告")
                            Spacer()
                        }
                        .foregroundStyle(canSave || isSaving ? Color.white : KikiPalette.muted)
                        .padding(14)
                        .background(canSave || isSaving ? KikiPalette.action : KikiPalette.elevated, in: Capsule())
                    }.buttonStyle(.plain).disabled(!canSave)
                        .accessibilityIdentifier("livekit.room.announcement.save")
                } else {
                    ScrollView { Text(announcement.isEmpty ? "暂无公告" : announcement).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(KikiPalette.text).background(KikiPalette.background)
                .navigationTitle("房间公告").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭", action: onClose) } }
        }.tint(KikiPalette.purple)
    }
}
