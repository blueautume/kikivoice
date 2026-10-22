import SwiftUI

/// A moderation-only sheet. The room owns request submission and all mutations.
@MainActor
struct KikiSeatRequestSheet: View {
    let roomState: KikiRoomState?
    @ObservedObject var gifts: KikiGiftStore
    let isWorking: Bool
    let isAvailable: Bool
    let errorMessage: String?
    let onApprove: (String) -> Void
    let onReject: (String) -> Void
    let onOpenPerson: (String) -> Void
    let onDismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let accent = Color(hex: 0x8B66FF)
    private let background = Color(hex: 0x17151E)

    init(roomState: KikiRoomState?, gifts: KikiGiftStore, isWorking: Bool, isAvailable: Bool,
         errorMessage: String?, onApprove: @escaping (String) -> Void, onReject: @escaping (String) -> Void,
         onOpenPerson: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self.roomState = roomState
        self.gifts = gifts
        self.isWorking = isWorking
        self.isAvailable = isAvailable
        self.errorMessage = errorMessage
        self.onApprove = onApprove
        self.onReject = onReject
        self.onOpenPerson = onOpenPerson
        self.onDismiss = onDismiss
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(.form)
        } else { content }
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
                        .font(.subheadline).foregroundStyle(Color(hex: 0xEAC6A3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .accessibilityIdentifier("livekit.room.seatRequestError")
                }
                if roomState == nil {
                    ProgressView("正在同步上麦申请")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if pending.isEmpty && approved.isEmpty {
                    VStack(spacing: 15) {
                        Image(systemName: "figure.wave")
                            .font(.system(size: 38, weight: .light)).foregroundStyle(.white.opacity(0.32))
                            .accessibilityHidden(true)
                        Text("暂无上麦申请").font(.headline).foregroundStyle(.white.opacity(0.62))
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
                    .listRowSeparatorTint(.white.opacity(0.10))
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
        .tint(accent).preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(background)
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
                    KikiDecoratedAvatar(gifts: gifts, userID: request.userID, index: member?.avatarIndex ?? 0,
                                        size: 44, customURL: member?.avatarURL)
                        .saturation(online ? 1 : 0).opacity(online ? 1 : 0.42)
                }
                .buttonStyle(.plain).accessibilityLabel("查看\(request.name)的个人主页")
                .accessibilityIdentifier("livekit.room.seatRequestPerson.\(request.userID)")
                VStack(alignment: .leading, spacing: 5) {
                    Text(request.name).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(request.status == "approved" ? "已同意，等待自动上麦" : "申请上麦")
                        .font(.caption).foregroundStyle(.white.opacity(0.52))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if canReview(request) {
                approvalButtons(request)
            } else if request.status == "approved" {
                Label("已同意", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Color(hex: 0xB9F2D1))
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
            .buttonStyle(.bordered).tint(.white.opacity(0.76))
            .accessibilityLabel("拒绝\(request.name)的上麦申请")
            .accessibilityIdentifier("livekit.room.rejectSeatRequest.\(request.userID)")
            Button {
                guard canReview(request), isAvailable, !isWorking else { return }
                onApprove(request.userID)
            } label: {
                Text("同意").font(.subheadline.weight(.semibold))
                    .frame(minWidth: 32, maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
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
