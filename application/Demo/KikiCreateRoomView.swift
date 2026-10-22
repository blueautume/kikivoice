import SwiftUI

@available(iOS 16.0, *)
struct KikiCreateRoomView: View {
    @EnvironmentObject private var store: KikiDemoStore
    @Environment(\.dismiss) private var dismiss
    private let isLive: Bool
    private let onCreate: (DemoRoom) -> Void

    @State private var title = ""
    @State private var theme = 0
    @State private var hasLoadedTitle = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    init(isLive: Bool, onCreate: @escaping (DemoRoom) -> Void) {
        self.isLive = isLive
        self.onCreate = onCreate
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { trimmedTitle.count <= 36 && trimmedTitle.utf8.count <= 100 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            fieldTitle("房间名称")
                            Spacer()
                            Text("\(title.count)/36")
                                .font(.system(size: 11))
                                .foregroundStyle(KikiPalette.muted)
                        }
                        TextField(store.defaultRoomTitle, text: $title)
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

                    VStack(alignment: .leading, spacing: 12) {
                        fieldTitle("背景")
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
                                .accessibilityLabel("背景\(index + 1)")
                                .accessibilityAddTraits(theme == index ? .isSelected : [])
                                .buttonStyle(.plain)
                            }
                        }
                    }

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
                        .background(valid ? KikiPalette.action : KikiPalette.elevated, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(valid ? .white : KikiPalette.muted)
                    }
                    .disabled(!valid || isCreating)
                    .accessibilityIdentifier("confirmCreateRoom")
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .disabled(isCreating)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(KikiPalette.background)
            .foregroundStyle(KikiPalette.text)
            .navigationTitle(isLive ? "创建直播间" : "创建语聊房")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(KikiPalette.secondary)
                        .disabled(isCreating)
                }
            }
            .onAppear {
                guard !hasLoadedTitle else { return }
                hasLoadedTitle = true
                title = store.suggestedRoomTitle
            }
        }

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
                let room = try await store.reserveRoom(title: trimmedTitle, category: "随心聊", isLive: isLive, theme: theme)
                onCreate(room)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func fieldTitle(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(KikiPalette.secondary)
    }
}
