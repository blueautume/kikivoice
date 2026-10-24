import SwiftUI

/// The profile keeps this action separate from the room's invitation lifecycle.
struct KikiProfileSeatInviteButton: View {
    let title: String
    let isBusy: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            guard isEnabled, !isBusy else { return }
            action()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                if isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "mic.fill")
                        .accessibilityHidden(true)
                }
            }
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .frame(minHeight: 36)
            .background(KikiPalette.action, in: Capsule())
            .opacity(isEnabled || isBusy ? 1 : 0.5)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel("邀请上麦")
        .accessibilityValue(isBusy ? "正在发送" : title)
        .accessibilityIdentifier("social.profile.inviteSeat")
    }
}

/// Consent stays explicit: receiving an invitation never opens the microphone.
struct KikiIncomingSeatInvitationCard: View {
    let isBusy: Bool
    let isEnabled: Bool
    let isRoomFull: Bool
    let onAccept: () -> Void
    let onDecline: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("收到上麦邀请", systemImage: "mic.fill")
                .font(.headline)
                .foregroundStyle(KikiPalette.text)
                .accessibilityAddTraits(.isHeader)
            Text(isRoomFull
                 ? "麦位已满，接受后将等待空位；上麦后麦克风默认关闭。"
                 : "接受后将加入麦位，麦克风默认关闭。")
                .font(.subheadline)
                .foregroundStyle(KikiPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            invitationActions
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(KikiPalette.elevated, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("livekit.room.incomingSeatInvitation")
    }

    private var invitationActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Button {
                guard isEnabled, !isBusy else { return }
                onDecline()
            } label: {
                Text("暂不")
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 24)
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .foregroundStyle(KikiPalette.text)
                    .background(KikiPalette.elevated, in: Capsule())
            }
            .accessibilityLabel("暂不上麦")
            .accessibilityIdentifier("livekit.room.declineSeatInvitation")
            Button {
                guard isEnabled, !isBusy else { return }
                onAccept()
            } label: {
                HStack(spacing: 7) {
                    if isBusy {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text(isBusy ? "处理中" : "接受")
                }
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 24)
                .padding(.horizontal, 15).padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(KikiPalette.action, in: Capsule())
            }
            .accessibilityLabel("接受上麦邀请")
            .accessibilityIdentifier("livekit.room.acceptSeatInvitation")
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .opacity(isEnabled || isBusy ? 1 : 0.5)
    }
}

/// A moderation-only sheet. The room owns request submission and all mutations.
@MainActor
struct KikiSeatRequestSheet: View {
    let roomState: KikiRoomState?
    let isWorking: Bool
    let isAvailable: Bool
    let errorMessage: String?
    let onApprove: (String) -> Void
    let onReject: (String) -> Void
    let onOpenPerson: (String) -> Void
    let onDismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let accent = KikiPalette.purple
    private let background = KikiPalette.background

    init(roomState: KikiRoomState?, isWorking: Bool, isAvailable: Bool,
         errorMessage: String?, onApprove: @escaping (String) -> Void, onReject: @escaping (String) -> Void,
         onOpenPerson: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self.roomState = roomState
        self.isWorking = isWorking
        self.isAvailable = isAvailable
        self.errorMessage = errorMessage
        self.onApprove = onApprove
        self.onReject = onReject
        self.onOpenPerson = onOpenPerson
        self.onDismiss = onDismiss
    }

    var body: some View {
        content
    }

    private var pending: [KikiSeatRequest] { requests(with: "pending") }
    private var approved: [KikiSeatRequest] { requests(with: "approved") }
    private func requests(with status: String) -> [KikiSeatRequest] {
        (roomState?.queue ?? []).filter { $0.status == status }
            .sorted { $0.position == $1.position ? $0.requestedAt < $1.requestedAt : $0.position < $1.position }
    }

    private var content: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorMessage, !errorMessage.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .accessibilityIdentifier("livekit.room.seatRequestError")
                }
                if roomState == nil {
                    ProgressView("正在同步上麦申请")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if pending.isEmpty && approved.isEmpty {
                    VStack(spacing: 15) {
                        Image("RaiseHand").renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 42, height: 42).foregroundStyle(KikiPalette.muted)
                            .accessibilityHidden(true)
                        Text("暂无上麦申请").font(.headline).foregroundStyle(KikiPalette.secondary)
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("livekit.room.emptySeatRequests")
                } else {
                    List {
                        ForEach(pending) { request in requestRow(request) }
                        if !approved.isEmpty {
                            Section("已同意，等待上麦") {
                                ForEach(approved) { request in requestRow(request) }
                            }
                        }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    .listRowSeparatorTint(KikiPalette.muted.opacity(0.18))
                }
            }
            .background(background)
            .navigationTitle("上麦申请").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onDismiss).accessibilityIdentifier("livekit.room.dismissSeatRequests")
                }
            }
        }
        .tint(accent).foregroundStyle(KikiPalette.text)
        .accessibilityIdentifier("livekit.room.seatRequestPanel")
    }

    private func requestRow(_ request: KikiSeatRequest) -> some View {
        let member = roomState?.members.first { $0.userID == request.userID }
        let online = request.online && member?.online != false
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 13))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            HStack(spacing: 11) {
                Button { onOpenPerson(request.userID) } label: {
                    KikiAvatar(index: member?.avatarIndex ?? 0,
                                        size: 44, customURL: member?.avatarURL)
                        .saturation(online ? 1 : 0).opacity(online ? 1 : 0.42)
                }
                .buttonStyle(.plain).accessibilityLabel("查看\(request.name)的个人主页")
                .accessibilityIdentifier("livekit.room.seatRequestPerson.\(request.userID)")
                VStack(alignment: .leading, spacing: 5) {
                    Text(request.name).font(.subheadline.weight(.medium)).foregroundStyle(KikiPalette.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(request.status == "approved" ? "已同意，等待自动上麦" : "申请上麦")
                        .font(.caption).foregroundStyle(KikiPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if canReview(request) {
                approvalButtons(request)
            } else if request.status == "approved" {
                Label("已同意", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(KikiPalette.mint)
            }
        }
        .padding(.vertical, 9).listRowBackground(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityValue(online ? "在线" : "连接中断，申请已保留")
        .accessibilityIdentifier("livekit.room.seatRequestRow.\(request.userID)")
    }

    private func approvalButtons(_ request: KikiSeatRequest) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 9)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Button {
                guard canReview(request), isAvailable, !isWorking else { return }
                onReject(request.userID)
            } label: {
                Text("拒绝").font(.subheadline.weight(.medium))
                    .frame(minWidth: 32, maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 30)
            }
            .buttonStyle(.bordered).tint(KikiPalette.secondary)
            .accessibilityLabel("拒绝\(request.name)的上麦申请")
            .accessibilityIdentifier("livekit.room.rejectSeatRequest.\(request.userID)")
            Button {
                guard canReview(request), isAvailable, !isWorking else { return }
                onApprove(request.userID)
            } label: {
                Text("同意").font(.subheadline.weight(.semibold))
                    .frame(minWidth: 32, maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 30)
            }
            .buttonStyle(.borderedProminent).tint(KikiPalette.action)
            .accessibilityLabel("同意\(request.name)的上麦申请")
            .accessibilityIdentifier("livekit.room.approveSeatRequest.\(request.userID)")
        }
        .disabled(!isAvailable || isWorking)
    }

    private func canReview(_ request: KikiSeatRequest) -> Bool {
        guard let state = roomState, state.me.isModerator,
              let current = state.queue.first(where: { $0.userID == request.userID }), current.status == "pending",
              let target = state.members.first(where: { $0.userID == request.userID }) else { return false }
        return state.me.canModerate(target)
    }
}
