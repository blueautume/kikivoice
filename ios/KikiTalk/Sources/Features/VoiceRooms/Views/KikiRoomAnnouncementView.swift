import SwiftUI

struct KikiRoomAnnouncementView: View {
    @ObservedObject var rtc: KikiRTCService
    @State private var text = ""
    @State private var hasLoaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if rtc.canManageRoom {
                    TextEditor(text: $text).scrollContentBackground(.hidden)
                        .padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("livekit.room.announcement.editor")
                    Text("最多 2000 字节；清空并保存可移除公告。").font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task { if await rtc.saveAnnouncement(text) { dismiss() } }
                    } label: {
                        HStack { Spacer(); if rtc.isSavingAnnouncement { ProgressView() }; Text("保存公告"); Spacer() }
                            .padding(14).background(Color(hex: 0x8B66FF), in: Capsule())
                    }.disabled(!rtc.canUseRoom || rtc.isSavingAnnouncement || text.utf8.count > 2_000)
                        .accessibilityIdentifier("livekit.room.announcement.save")
                } else {
                    ScrollView { Text(rtc.announcement.text.isEmpty ? "暂无公告" : rtc.announcement.text).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.padding(20).background(Color(hex: 0x241747))
                .navigationTitle("房间公告").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .onAppear { if !hasLoaded { text = rtc.announcement.text; hasLoaded = true } }
        }.preferredColorScheme(.dark).tint(Color(hex: 0xB69AFF))
    }
}
