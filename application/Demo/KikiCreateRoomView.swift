import SwiftUI

@available(iOS 16.0, *)
struct KikiCreateRoomView: View {
    @EnvironmentObject private var store: KikiDemoStore
    @Environment(\.dismiss) private var dismiss
    var onCreate: (DemoRoom) -> Void

    @State private var title = ""
    @State private var isLive = false
    @State private var category = "随心聊"
    @State private var theme = 0
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    init(initialIsLive: Bool = false, onCreate: @escaping (DemoRoom) -> Void) {
        self.onCreate = onCreate
        _isLive = State(initialValue: initialIsLive)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !trimmedTitle.isEmpty && trimmedTitle.count <= 36 && trimmedTitle.utf8.count <= 100 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("你的声音，值得一个房间。")
                            .font(.system(size: 23, weight: .bold))
                        Text("选个话题，邀请同频的人一起聊聊")
                            .font(.system(size: 13))
                            .foregroundStyle(KikiPalette.secondary)
                    }
                    .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 12) {
                        fieldTitle("房间类型")
                        HStack(spacing: 12) {
                            typeOption("语聊房", detail: "用声音，拉近一点", symbol: "waveform", live: false)
                            typeOption("直播间", detail: "分享你的此刻", symbol: "video", live: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            fieldTitle("房间名称")
                            Spacer()
                            Text("\(title.count)/36")
                                .font(.system(size: 11))
                                .foregroundStyle(KikiPalette.muted)
                        }
                        TextField("例如：今晚聊聊你的小确幸", text: $title)
                            .font(.system(size: 14))
                            .padding(16)
                            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 13))
                            .focused($titleFocused)
                            .submitLabel(.done)
                            .onSubmit { titleFocused = false }
                            .onChange(of: title) { value in
                                if value.count > 36 { title = String(value.prefix(36)) }
                            }
                            .accessibilityIdentifier("newRoomTitle")
                        if trimmedTitle.utf8.count > 100 {
                            Text("名称过长，请减少文字或表情。")
                                .font(.system(size: 12)).foregroundStyle(Color.red.opacity(0.9))
                        }
                    }

                    topicPicker

                    VStack(alignment: .leading, spacing: 12) {
                        fieldTitle("房间氛围")
                        HStack(spacing: 10) {
                            ForEach(0..<5) { index in
                                Button { theme = index } label: {
                                    KikiCover(theme: index)
                                        .frame(height: 58)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(theme == index ? KikiPalette.lavender : .clear, lineWidth: 2)
                                        }
                                        .overlay {
                                            if theme == index {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(.white)
                                                    .font(.system(size: 18))
                                            }
                                        }
                                }
                                .accessibilityLabel("氛围\(index + 1)")
                                .accessibilityAddTraits(theme == index ? .isSelected : [])
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Label(isLive ? "开播需要使用摄像头和麦克风，请在系统提示中允许访问。" : "语聊需要使用麦克风，请在系统提示中允许访问。", systemImage: isLive ? "video" : "mic")
                        .font(.system(size: 12))
                        .lineSpacing(4)
                        .foregroundStyle(KikiPalette.muted)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12))
                            .lineSpacing(4)
                            .foregroundStyle(Color.red.opacity(0.9))
                    }

                    Button(action: createRoom) {
                        HStack(spacing: 10) {
                            if isCreating { ProgressView().tint(.white) }
                            else { Image(systemName: isLive ? "video.fill" : "mic.fill") }
                            Text(isCreating ? "正在创建…" : (isLive ? "创建并开启直播" : "创建并进入语聊房"))
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(18)
                        .background(valid ? KikiPalette.purple : KikiPalette.elevated, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(valid ? .white : KikiPalette.muted)
                    }
                    .disabled(!valid || isCreating)
                    .accessibilityIdentifier("confirmCreateRoom")
                }
                .padding(24)
                .disabled(isCreating)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(KikiPalette.background)
            .foregroundStyle(KikiPalette.text)
            .navigationTitle("创建房间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(KikiPalette.secondary)
                        .disabled(isCreating)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(KikiPalette.lavender)
        .interactiveDismissDisabled(isCreating)
    }

    private func createRoom() {
        guard valid, !isCreating else { return }
        titleFocused = false
        errorMessage = nil
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                let room = try await store.reserveRoom(title: trimmedTitle, category: category, isLive: isLive, theme: theme)
                onCreate(room)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var topicPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldTitle("房间话题")
            Menu {
                Picker("房间话题", selection: $category) {
                    ForEach(["随心聊", "音乐", "生活", "游戏", "情感"], id: \.self) { Text($0) }
                }
            } label: {
                HStack {
                    Text(category)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 10))
                }
                .font(.system(size: 14))
                .foregroundStyle(KikiPalette.text)
                .padding(16)
                .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 13))
            }
        }
    }

    private func fieldTitle(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(KikiPalette.secondary)
    }

    private func typeOption(_ value: String, detail: String, symbol: String, live: Bool) -> some View {
        Button { isLive = live } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 21))
                    Spacer()
                    if isLive == live {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 16))
                    }
                }
                Text(value).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(KikiPalette.secondary)
            }
            .foregroundStyle(isLive == live ? KikiPalette.lavender : KikiPalette.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isLive == live ? KikiPalette.purple.opacity(0.1) : KikiPalette.surface, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(isLive == live ? KikiPalette.purple.opacity(0.6) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isLive == live ? .isSelected : [])
        .accessibilityIdentifier(live ? "createLiveType" : "createVoiceType")
    }
}
