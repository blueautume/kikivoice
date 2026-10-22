import LiveKit
import SwiftUI

/// Eight server-owned seats and an independent audience; LiveKit supplies live speaking state.
struct KikiLiveKitRoomView: View {
    @ObservedObject var rtc: KikiRTCService
    @ObservedObject private var gifts: KikiGiftStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsGifts = false
    @State private var showsExperience = false
    @State private var confirmsExit = false
    @State private var showsParticipants = false
    @State private var showsSeatRequests = false
    @State private var showsAnnouncement = false
    @State private var showsTitleEditor = false
    @State private var roomTitleDraft = ""
    @State private var roomTitleError: String?
    @State private var reportTarget: KikiReportTarget?
    @State private var queuedReportTarget: KikiReportTarget?
    @State private var pendingBlock: KikiBlockedUser?
    @State private var pendingModeration: KikiPendingModeration?
    @State private var showsSafety = false
    @State private var selectedPerson: KikiPersonDestination?
    @State private var queuedPerson: KikiPersonDestination?
    @State private var isComposing = false
    @State private var headerHeight: CGFloat = 44
    @State private var stageContentHeight: CGFloat = 0
    @State private var roomNotice: String?
    @State private var roomNoticeID = UUID()
    @State private var hasPositionedChat = false
    @State private var chatTracking = KikiRoomChatTracking()
    @GestureState private var isDraggingChat = false
    private let accent = KikiPalette.purple
    private let secondary = KikiPalette.secondary

    init(rtc: KikiRTCService) {
        self.rtc = rtc
        self._gifts = ObservedObject(wrappedValue: rtc.gifts)
    }

    private var experienceVisibilityKey: String {
        "\(rtc.currentRoomID ?? "")-\(scenePhase)-\(rtc.isVoiceRoomMinimized)-\(rtc.canUseRoom)-\(rtc.safetyState.blockedIDs.sorted().joined(separator: ","))"
    }

    private var observesRoomExperience: Bool {
        rtc.currentRoomID != nil && scenePhase == .active && !rtc.isVoiceRoomMinimized && rtc.canUseRoom
    }

    private var observesRoomTaps: Bool {
        isComposing && scenePhase == .active && !rtc.isVoiceRoomMinimized && rtc.canUseRoom
            && !showsGifts && !showsExperience && !showsParticipants && !showsSeatRequests
            && !showsAnnouncement && !showsTitleEditor && !showsSafety && !confirmsExit
            && reportTarget == nil && selectedPerson == nil && pendingBlock == nil && pendingModeration == nil
    }

    var body: some View {
        GeometryReader { _ in
            let horizontalPadding: CGFloat = 18
            ZStack {
                KikiRoomDecorationBackground(decorationID: gifts.appearance(for: rtc.roomInfo?.hostID ?? "").roomBackground)
                    .ignoresSafeArea()
                VStack(spacing: 14) {
                    header
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: KikiRoomHeaderHeightKey.self, value: geometry.size.height)
                            }
                        }
                        .onPreferenceChange(KikiRoomHeaderHeightKey.self) { headerHeight = $0 }
                    KikiRoomContentLayout(hasChatContent: !chatScrollIdentity.isEmpty || rtc.chatSyncNotice != nil,
                                          onStageHeightChange: { stageContentHeight = $0 }) { width, columns in
                        roomStage(width: width, avatarSize: columns ? 68 : 55)
                    } chat: {
                        chat
                    }
                }
                .padding(.horizontal, horizontalPadding).padding(.top, 10).padding(.bottom, 2)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(KikiPalette.text)
                if let reason = rtc.disconnectionReason { endedRoom(reason) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 8)
                .frame(maxWidth: 1180).frame(maxWidth: .infinity)
        }
        .overlay {
            if rtc.disconnectionReason == nil {
                KikiRoomActionRail(hasChatContent: !chatScrollIdentity.isEmpty || rtc.chatSyncNotice != nil,
                                   stageContentHeight: stageContentHeight, contentTopInset: headerHeight + 24) {
                    roomActions
                }
                .foregroundStyle(KikiPalette.text)
            }
        }
        .background(KikiRoomKeyboardDismissal(isEnabled: observesRoomTaps, onDismiss: endComposing))
        .overlay(alignment: .top) {
            if let roomNotice {
                Text(roomNotice).font(.subheadline).foregroundStyle(KikiPalette.text)
                    .multilineTextAlignment(.center).padding(.horizontal, 18).padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.horizontal, 24).padding(.top, 68)
                    .allowsHitTesting(false).accessibilityIdentifier("livekit.room.notice")
            }
        }
        .tint(KikiPalette.purple)
        .interactiveDismissDisabled()
        .overlay { KikiGiftPresentationOverlay(gifts: gifts).allowsHitTesting(false) }
        .sheet(isPresented: $showsGifts) {
            if let roomID = rtc.currentRoomID {
                KikiGiftPanel(gifts: gifts, roomID: roomID,
                              members: rtc.roomState?.members.filter { $0.online && !rtc.safetyState.blockedIDs.contains($0.userID) } ?? [],
                              hostID: rtc.roomInfo?.hostID).kikiRoomSheet()
            }
        }
        .sheet(isPresented: $showsExperience) { KikiExperienceCenterView(gifts: gifts).kikiRoomSheet() }
        .task(id: experienceVisibilityKey) {
            // RTC owns the single refresh driver. A visibility/safety boundary
            // rebuilds the gift cursor without replaying past room events.
            rtc.setRoomExperienceVisible(false)
            rtc.setRoomExperienceVisible(observesRoomExperience)
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { endComposing(); rtc.setRoomExperienceVisible(false) } }
        .onChange(of: rtc.isVoiceRoomMinimized) { _, minimized in if minimized { endComposing(); rtc.setRoomExperienceVisible(false) } }
        .onDisappear { endComposing(); rtc.setRoomExperienceVisible(false) }
        .onChange(of: rtc.canManageRoom) { _, canManage in if !canManage { showsSeatRequests = false } }
        .onChange(of: mySeatRequestStatus) { previous, current in
            if previous != "loading", !rtc.isRoomOwner, ["approved", "rejected", "seated"].contains(current) {
                showRoomNotice(mySeatStatusTitle)
            }
        }
        .confirmationDialog(rtc.isRoomOwner ? "结束本次语聊？房间将关闭，所有成员都会离开。" : "确定离开本次语聊？",
                            isPresented: $confirmsExit, titleVisibility: .visible) {
            if rtc.isRoomOwner {
                Button("结束房间并离开", role: .destructive) {
                    isComposing = false
                    Task { await rtc.leaveRoom(endRoom: true) }
                }
            } else {
                Button("离开房间", role: .destructive) {
                    isComposing = false
                    Task { await rtc.leaveRoom() }
                }
            }
            Button("取消", role: .cancel) { }
        }
        .alert("语聊提示", isPresented: Binding(get: { rtc.roomError != nil && !showsParticipants && !showsSeatRequests }, set: { if !$0 { rtc.roomError = nil } })) {
            Button("知道了") { rtc.roomError = nil }
        } message: { Text(rtc.roomError ?? "") }
        .sheet(isPresented: $showsParticipants, onDismiss: presentQueuedDestination) { participantList.kikiRoomSheet() }
        .sheet(isPresented: $showsSeatRequests, onDismiss: { rtc.roomError = nil; presentQueuedDestination() }) { seatRequestPanel.kikiRoomSheet() }
        .sheet(item: $reportTarget) { target in KikiSafetyReportForm(rtc: rtc, target: target).kikiRoomSheet() }
        .sheet(item: $selectedPerson) { person in
            if let store = rtc.socialStore { KikiPublicProfileView(userID: person.id, store: store).kikiRoomSheet() }
        }
        .sheet(isPresented: $showsSafety) { KikiSafetyCenter(rtc: rtc).kikiRoomSheet() }
        .confirmationDialog("拉黑后，你将不再听到对方的声音或看到对方的房间文字。对方仍可能在公开房间听到你；可在设置解除。", isPresented: blockConfirmation(inParticipants: false), titleVisibility: .visible) {
            blockConfirmationButtons
        }
        .alert(pendingModeration?.title ?? "确认管理操作", isPresented: moderationConfirmation(inParticipants: false)) {
            moderationConfirmationButtons
        } message: { Text(pendingModeration?.message ?? "") }
        .sheet(isPresented: $showsAnnouncement) { KikiRoomAnnouncementView(rtc: rtc).kikiRoomSheet() }
        .sheet(isPresented: $showsTitleEditor) { titleEditor.kikiRoomSheet() }
    }

    private func roomStage(width: CGFloat, avatarSize: CGFloat) -> some View {
        VStack(spacing: 14) {
            connectionBanner
            seats(width: width, avatarSize: avatarSize)
            audienceStrip
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        KikiRoomHeader(title: rtc.roomInfo?.title ?? "语聊房", host: rtc.roomInfo?.host ?? "",
                       onEditTitle: rtc.isRoomOwner ? editRoomTitle : nil,
                       isTitleEditingEnabled: rtc.canUseRoom) {
            Button { if let id = rtc.roomInfo?.hostID { openPerson(id) } } label: {
                if let info = rtc.roomInfo {
                    let online = rtc.roomState?.members.first { $0.userID == info.hostID }?.online ?? true
                    KikiDecoratedAvatar(gifts: gifts, userID: info.hostID, index: info.hostAvatarIndex, size: 36, customURL: info.hostAvatarURL)
                        .saturation(online ? 1 : 0).opacity(online ? 1 : 0.45)
                } else { initials("", size: 36) }
            }.buttonStyle(.plain).accessibilityLabel("查看房主主页")
        } controls: {
            HStack(spacing: 4) {
                Menu {
                    if rtc.canManageRoom || !rtc.announcement.text.isEmpty {
                        Button(rtc.canManageRoom ? (rtc.announcement.text.isEmpty ? "发布房间公告" : "编辑房间公告") : "查看房间公告", systemImage: "megaphone") {
                            endComposing()
                            showsAnnouncement = true
                        }
                        .accessibilityIdentifier("livekit.room.announcement.manage")
                    }
                    if !rtc.isRoomOwner {
                        if rtc.roomState?.me.seatIndex != nil {
                            Button("主动下麦", systemImage: "arrow.down.circle", role: .destructive) { action(.leaveSeat) }
                        } else if ["pending", "approved"].contains(mySeatRequestStatus) {
                            Button("取消上麦申请", systemImage: "xmark.circle") { action(.cancelRequest) }
                        } else if rtc.canManageRoom {
                            Button(action: submitSeatRequest) { Label("申请上麦", image: "RaiseHand") }
                        }
                    }
                    Button("举报房间", systemImage: "exclamationmark.bubble") {
                        if let roomID = rtc.currentRoomID { openReport(.init(targetType: .room, roomID: roomID, targetUserID: nil, messageID: nil, name: rtc.roomInfo?.title ?? "当前房间")) }
                    }
                } label: { roomControlIcon("ellipsis", size: 36) }
                .buttonStyle(.plain)
                .accessibilityLabel("房间工具与举报").accessibilityIdentifier("livekit.room.tools")
                Button { showsParticipants = true } label: { roomControlIcon("person.2", size: 36) }
                    .buttonStyle(.plain).accessibilityLabel("房间成员")
                Button {
                    isComposing = false
                    Task { await rtc.minimizeRoom() }
                } label: { roomControlIcon("arrow.down.right.and.arrow.up.left", size: 36) }
                .buttonStyle(.plain).disabled(rtc.isLeavingRoom || rtc.isTransitioningRoom)
                .accessibilityLabel("最小化语聊房").accessibilityIdentifier("livekit.room.minimize")
                Button { confirmsExit = true } label: { roomControlIcon("xmark", size: 36) }
                    .buttonStyle(.plain).disabled(rtc.isLeavingRoom)
                    .accessibilityLabel(rtc.isRoomOwner ? "结束房间" : "离开房间")
                    .accessibilityIdentifier("livekit.room.leave")
            }
        }
    }

    private func editRoomTitle() {
        endComposing()
        roomTitleDraft = rtc.roomInfo?.title ?? ""
        roomTitleError = nil
        showsTitleEditor = true
    }

    private func roomControlIcon(_ symbol: String, size: CGFloat, active: Bool = false, loading: Bool = false) -> some View {
        roomControl(Image(systemName: symbol).font(.system(size: size == 36 ? 15 : 17, weight: .medium)),
                    size: size, active: active, loading: loading)
    }

    private func roomControl<Icon: View>(_ icon: Icon, size: CGFloat, active: Bool = false, loading: Bool = false) -> some View {
        Group {
            if loading { ProgressView().tint(accent).controlSize(.small) }
            else { icon }
        }
        .foregroundStyle(active ? accent : KikiPalette.text).frame(width: size, height: size)
        .background(active ? accent.opacity(0.20) : KikiPalette.elevated.opacity(0.85), in: Circle())
        .frame(width: max(44, size), height: max(44, size))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var connectionBanner: some View {
        if let notice = rtc.safetyState.notices.first {
            Button { showsSafety = true } label: {
                Label("社区通知：" + notice.message, systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 11)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            }.accessibilityLabel("查看运营通知：" + notice.message)
        }
        if rtc.isLeavingRoom {
            HStack(spacing: 8) {
                ProgressView().tint(accent).scaleEffect(0.7)
                Text("正在离开房间…").font(.system(size: 11))
                Spacer()
            }.padding(8).background(accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        } else if !rtc.isRecovering, rtc.connectionState == .connected, let notice = rtc.audioState.notice {
            Text(notice).font(.system(size: 11)).foregroundStyle(KikiPalette.warning)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func seats(width: CGFloat, avatarSize: CGFloat) -> some View {
        let columns = max(2, min(4, Int((width + 8) / (avatarSize + 14))))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 14) {
            ForEach(1...8, id: \.self) { number in
                if let slot = rtc.roomState?.seats.first(where: { $0.index == number }) {
                    if let member = rtc.roomState?.member(on: slot) {
                        Button { openPerson(member.userID) } label: { seat(slot, avatarSize: avatarSize) }
                            .buttonStyle(.plain).accessibilityLabel("查看\(member.name)的个人主页")
                    } else {
                        Button { handleSeatRequest() } label: { seat(slot, avatarSize: avatarSize) }
                            .buttonStyle(.plain)
                            .disabled(slot.locked || !rtc.canUseRoom || rtc.isPerformingRoomAction)
                            .accessibilityLabel(rtc.canManageRoom ? "查看上麦申请" : "申请上麦")
                            .accessibilityHint("获准后由系统按顺序安排麦位")
                            .accessibilityIdentifier("livekit.room.emptySeat.\(number)")
                    }
                } else {
                    seatPlaceholder(number: number, avatarSize: avatarSize)
                }
            }
        }.padding(.top, 4).padding(.bottom, 2)
    }

    private func seat(_ slot: KikiRoomSeat, avatarSize: CGFloat) -> some View {
        let member = rtc.roomState?.member(on: slot)
        return KikiRoomSeatTile(slot: slot, member: member,
                               participant: rtc.participants.first { $0.id == member?.userID },
                               localUserID: rtc.roomState?.me.userID, avatarSize: avatarSize, gifts: gifts)
    }

    private func seatPlaceholder(number: Int, avatarSize: CGFloat) -> some View {
        VStack(spacing: 9) {
            Circle().fill(KikiPalette.elevated).frame(width: avatarSize + 6, height: avatarSize + 6)
                .overlay(Image(systemName: "mic").foregroundStyle(secondary))
            Text("\(number)").font(.system(size: 10)).foregroundStyle(secondary)
                .accessibilityLabel("\(number)号麦位")
        }.frame(maxWidth: .infinity)
    }

    private var audienceStrip: some View {
        KikiRoomAudienceStrip(listeners: rtc.roomState?.listeners ?? [],
                              onOpenPerson: openPerson) { member in
            KikiDecoratedAvatar(gifts: gifts, userID: member.userID, index: member.avatarIndex,
                                size: 36, customURL: member.avatarURL)
        }
    }

    private var pendingSeatRequests: [KikiSeatRequest] {
        (rtc.roomState?.queue ?? []).filter { $0.status == "pending" }.sorted { $0.position < $1.position }
    }

    private var mySeatRequestStatus: String {
        guard let state = rtc.roomState else { return "loading" }
        if state.me.seatIndex != nil { return "seated" }
        if state.me.seatRequestStatus != "none" { return state.me.seatRequestStatus }
        return state.myRequest?.status ?? "none"
    }

    private var mySeatStatusTitle: String {
        switch mySeatRequestStatus {
        case "pending": return "申请已提交，等待同意"
        case "approved": return "申请已同意，等待空位"
        case "rejected": return "上麦申请已被拒绝"
        case "seated":
            if rtc.isRoomOwner { return "当前在房主麦位" }
            return "已上麦 · \(rtc.roomState?.me.seatIndex ?? 0) 号麦"
        case "loading": return "正在同步上麦状态"
        default: return "当前为听众"
        }
    }

    private var seatRequestPanel: some View {
        KikiSeatRequestSheet(roomState: rtc.roomState, gifts: gifts,
                             isWorking: rtc.isPerformingRoomAction, isAvailable: rtc.canUseRoom,
                             errorMessage: rtc.roomError,
                             onApprove: { action(.approveRequest, target: $0) },
                             onReject: { action(.rejectRequest, target: $0) },
                             onOpenPerson: openPerson,
                             onDismiss: { showsSeatRequests = false; rtc.roomError = nil })
    }

    private var chat: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if let notice = rtc.chatSyncNotice {
                            Text(notice).font(.caption).foregroundStyle(secondary)
                        }
                        ForEach(chatTimeline) { entry in
                            switch entry {
                            case .message(let message):
                                messageRow(message).id(entry.id)
                            case .gift(let event):
                                giftRow(event).id(entry.id)
                            case .announcement(let announcement):
                                KikiRoomAnnouncementChatRow(text: announcement.text) {
                                    endComposing()
                                    showsAnnouncement = true
                                }.id(entry.id)
                            }
                        }
                        if let pending = rtc.pendingMessage {
                            pendingMessageRow(pending).id("pending-" + pending.clientMessageID)
                        }
                        Color.clear.frame(height: 1)
                            .id("livekit.room.chat.bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: KikiRoomChatViewportKey.self,
                                                   value: KikiRoomChatViewport(
                                                    bottom: content.frame(in: .named("livekit.room.chat")).maxY,
                                                    height: geometry.size.height, width: geometry.size.width))
                        }
                    }
                }
                .coordinateSpace(name: "livekit.room.chat")
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture(minimumDistance: 1).updating($isDraggingChat) { _, dragging, _ in
                    dragging = true
                })
                .onChange(of: isDraggingChat) { _, dragging in
                    guard dragging else { return }
                    chatTracking.beganDragging()
                }
                .onPreferenceChange(KikiRoomChatViewportKey.self) { current in
                    guard let request = chatTracking.update(current, hasPositionedChat: hasPositionedChat,
                                                            isDragging: isDraggingChat) else { return }
                    DispatchQueue.main.async {
                        guard chatTracking.mayRestore(request, isDragging: isDraggingChat) else { return }
                        proxy.scrollTo("livekit.room.chat.bottom", anchor: .bottom)
                    }
                }
                .onChange(of: chatScrollIdentity, initial: true) { previous, current in
                    guard previous != current || !hasPositionedChat else { return }
                    // Polling the same revision leaves this identity unchanged. Reading older
                    // messages also leaves the scroll position alone when new room traffic arrives.
                    let localSend = rtc.pendingMessage.map { pending in
                        !previous.contains { $0.hasPrefix("pending-" + pending.clientMessageID) }
                    } ?? false
                    guard chatTracking.isNearBottom || !hasPositionedChat || localSend else { return }
                    let animate = hasPositionedChat
                    hasPositionedChat = hasPositionedChat || !current.isEmpty
                    DispatchQueue.main.async {
                        if animate {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("livekit.room.chat.bottom", anchor: .bottom) }
                        } else { proxy.scrollTo("livekit.room.chat.bottom", anchor: .bottom) }
                    }
                }
            }
        }.frame(maxHeight: .infinity)
    }

    private var chatTimeline: [KikiRoomChatEntry] {
        KikiRoomChatEntry.timeline(messages: rtc.messages, gifts: gifts.events,
                                   announcement: rtc.announcement, blockedIDs: rtc.safetyState.blockedIDs)
    }

    private var chatScrollIdentity: [String] {
        var identity = chatTimeline.map(\.id)
        if let pending = rtc.pendingMessage {
            identity.append("pending-" + pending.clientMessageID + (pending.failure == nil ? "" : "-failed"))
        }
        return identity
    }

    private func messageRow(_ message: KikiVoiceMessage) -> some View {
        KikiRoomChatBubbleRow(id: message.id, senderName: message.senderName, text: message.text,
                              isLocal: message.isLocal, onOpenSender: { openPerson(message.senderID) }) {
            chatAvatar(userID: message.senderID, fallbackIndex: message.senderAvatarIndex)
        } bubbleBackground: {
            KikiChatDecorationBackground(decorationID: gifts.appearance(for: message.senderID).chatBubble)
        }
        .contextMenu {
            if !message.isLocal, let roomID = rtc.currentRoomID {
                Button("举报这条消息", systemImage: "exclamationmark.bubble") {
                    openReport(.init(targetType: .message, roomID: roomID, targetUserID: message.senderID,
                                     messageID: message.id, name: "来自 \(message.senderName) 的消息"))
                }
                Button(rtc.safetyState.blockedIDs.contains(message.senderID) ? "解除拉黑" : "拉黑此用户", systemImage: "person.crop.circle.badge.xmark") {
                    chooseBlock(userID: message.senderID, name: message.senderName)
                }
            }
        }
    }

    private func giftRow(_ event: KikiGiftEvent) -> some View {
        KikiRoomChatBubbleRow(id: "gift-" + event.id, senderName: event.senderName,
                              text: "送给 \(event.recipientName) \(event.giftName) ×\(event.quantity)",
                              isLocal: event.senderUserID == rtc.roomState?.me.userID, isGift: true,
                              onOpenSender: { openPerson(event.senderUserID) }) {
            chatAvatar(userID: event.senderUserID)
        } bubbleBackground: {
            RoundedRectangle(cornerRadius: 15).fill(accent.opacity(0.16))
        }
    }

    private func pendingMessageRow(_ pending: KikiPendingChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            KikiRoomChatBubbleRow(id: "pending-" + pending.clientMessageID,
                                  senderName: rtc.roomState?.me.name ?? "我", text: pending.text,
                                  isLocal: true, onOpenSender: { if let id = rtc.roomState?.me.userID { openPerson(id) } }) {
                chatAvatar(userID: rtc.roomState?.me.userID ?? "")
            } bubbleBackground: {
                KikiChatDecorationBackground(decorationID: gifts.appearance(for: rtc.roomState?.me.userID ?? "").chatBubble)
            }
            if let failure = pending.failure {
                HStack(spacing: 10) {
                    Text("发送失败").foregroundStyle(KikiPalette.warning).accessibilityHint(failure)
                    Button("重试") {
                        Task { if await rtc.sendMessage(pending.text), rtc.messageDraft == pending.text { rtc.messageDraft = "" } }
                    }
                    .disabled(!rtc.canSendChat || rtc.isSendingMessage)
                    .accessibilityIdentifier("livekit.room.message.retry")
                }
                .font(.caption).padding(.leading, 48)
            }
        }
    }

    private func chatAvatar(userID: String, fallbackIndex: Int = 0) -> some View {
        let member = rtc.roomState?.members.first { $0.userID == userID }
        return KikiDecoratedAvatar(gifts: gifts, userID: userID, index: member?.avatarIndex ?? fallbackIndex,
                                   size: 32, customURL: member?.avatarURL)
    }

    private var bottomBar: some View {
        KikiRoomComposerBar {
            KikiRoomMessageInput(text: $rtc.messageDraft, isFocused: $isComposing,
                                 placeholder: rtc.roomState?.me.chatMuted == true ? "已被禁言" : "说点什么…",
                                 isEnabled: rtc.canSendChat, onSubmit: send, onNotice: showRoomNotice)
                .background(KikiPalette.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 21))
                .overlay(RoundedRectangle(cornerRadius: 21).stroke(KikiPalette.text.opacity(0.14), lineWidth: 1))
        } send: {
            Button(action: send) { roomControlIcon("paperplane.fill", size: 42, loading: rtc.isSendingMessage) }
                .buttonStyle(.plain)
                .disabled(!rtc.canSendChat || rtc.isSendingMessage || rtc.messageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送消息").accessibilityIdentifier("livekit.room.send")
        }
    }

    @ViewBuilder private var roomActions: some View {
        Button {
            endComposing()
            showsGifts = true
        } label: { roomControlIcon("gift.fill", size: 42) }
            .buttonStyle(.plain).disabled(!rtc.canSendChat || !gifts.isAvailable)
            .accessibilityLabel("赠送礼物").accessibilityIdentifier("livekit.room.gifts")
        Button { Task { await rtc.toggleMicrophone() } } label: {
            roomControlIcon(rtc.microphoneEnabled ? "mic.fill" : "mic.slash.fill", size: 42,
                            active: rtc.microphoneEnabled, loading: rtc.isChangingMicrophone)
        }
        .buttonStyle(.plain)
        .disabled((!rtc.canUseRoom && !rtc.microphoneEnabled) || (!rtc.microphoneEnabled && !rtc.canPublishAudio) || rtc.isChangingMicrophone)
        .accessibilityLabel(rtc.microphoneEnabled ? "关闭麦克风" : "打开麦克风")
        .accessibilityValue(rtc.microphoneStatus).accessibilityIdentifier("livekit.room.microphone")
        seatRequestControl
        Button {
            endComposing()
            showsExperience = true
        } label: { roomControlIcon("diamond.fill", size: 42) }
            .buttonStyle(.plain)
            .accessibilityLabel("我的钻石与装扮").accessibilityIdentifier("livekit.room.experience")
    }

    private var titleEditor: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("房间名称", text: $roomTitleDraft, axis: .vertical)
                        .lineLimit(1...3).submitLabel(.done)
                        .disabled(rtc.isUpdatingRoomTitle)
                        .accessibilityIdentifier("livekit.room.titleInput")
                } footer: {
                    Text("最多 36 字、100 字节。留空使用“\(KikiRoomTitlePolicy.defaultTitle(nickname: titleEditorNickname))”。")
                }
                if let roomTitleError { Text(roomTitleError).foregroundStyle(.orange).font(.footnote) }
            }
            .navigationTitle("编辑房间名称").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showsTitleEditor = false }.disabled(rtc.isUpdatingRoomTitle) }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard !rtc.isUpdatingRoomTitle else { return }
                        do { _ = try KikiRoomTitlePolicy.resolved(roomTitleDraft, nickname: titleEditorNickname) }
                        catch { roomTitleError = error.localizedDescription; return }
                        roomTitleError = nil
                        let proposedTitle = roomTitleDraft
                        Task {
                            do { try await rtc.updateRoomTitle(proposedTitle); showsTitleEditor = false }
                            catch is CancellationError { }
                            catch { roomTitleError = error.localizedDescription }
                        }
                    } label: {
                        if rtc.isUpdatingRoomTitle { ProgressView() } else { Text("保存") }
                    }
                    .disabled(rtc.isUpdatingRoomTitle || !rtc.isRoomOwner)
                    .accessibilityIdentifier("livekit.room.saveTitle")
                }
            }
        }
        .interactiveDismissDisabled(rtc.isUpdatingRoomTitle)
    }

    private var titleEditorNickname: String {
        rtc.socialStore?.profileName ?? rtc.roomState?.me.name ?? rtc.roomInfo?.host ?? ""
    }

    @ViewBuilder private var seatRequestControl: some View {
        if !rtc.canManageRoom && ["pending", "approved", "seated"].contains(mySeatRequestStatus) {
            Menu {
                Text(mySeatStatusTitle)
                if mySeatRequestStatus == "seated" {
                    Button("主动下麦", systemImage: "arrow.down.circle", role: .destructive) { action(.leaveSeat) }
                        .accessibilityIdentifier("livekit.room.leaveSeat")
                } else {
                    Button("取消上麦申请", systemImage: "xmark.circle") { action(.cancelRequest) }
                        .accessibilityIdentifier("livekit.room.cancelSeatRequest")
                }
            } label: { seatRequestIcon }
                .disabled(!rtc.canUseRoom || rtc.isPerformingRoomAction)
                .accessibilityLabel(mySeatRequestStatus == "seated" ? "上麦管理" : "上麦申请已提交")
                .accessibilityValue(mySeatStatusTitle).accessibilityIdentifier("livekit.room.seatRequests")
        } else {
            Button(action: handleSeatRequest) { seatRequestIcon }
                .buttonStyle(.plain).disabled(!rtc.canUseRoom || rtc.isPerformingRoomAction)
                .accessibilityLabel(rtc.canManageRoom ? "查看上麦申请" : "申请上麦")
                .accessibilityValue(rtc.canManageRoom ? "\(pendingSeatRequests.count) 条待处理申请" : mySeatStatusTitle)
                .accessibilityIdentifier("livekit.room.seatRequests")
        }
    }

    private var seatRequestIcon: some View {
        roomControl(Image("RaiseHand").renderingMode(.template).resizable().scaledToFit().frame(width: 24, height: 24), size: 42,
                        active: !rtc.canManageRoom && ["pending", "approved", "seated"].contains(mySeatRequestStatus),
                        loading: rtc.isPerformingRoomAction)
            .overlay(alignment: .topTrailing) {
                if rtc.canManageRoom, !pendingSeatRequests.isEmpty {
                    Circle().fill(.red).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(KikiPalette.background, lineWidth: 1.5))
                }
            }
    }

    private func handleSeatRequest() {
        endComposing()
        guard rtc.canUseRoom, !rtc.isPerformingRoomAction, let state = rtc.roomState else { return }
        if state.me.isModerator { showsSeatRequests = true; return }
        submitSeatRequest()
    }

    private func submitSeatRequest() {
        endComposing()
        guard rtc.canUseRoom, !rtc.isPerformingRoomAction, !rtc.isRoomOwner,
              let userID = rtc.roomState?.me.userID, let roomID = rtc.currentRoomID else { return }
        guard !["pending", "approved", "seated"].contains(mySeatRequestStatus) else {
            showRoomNotice(mySeatStatusTitle)
            return
        }
        Task {
            guard rtc.currentRoomID == roomID, rtc.roomState?.me.userID == userID, rtc.canUseRoom else { return }
            await rtc.performRoomAction(.requestSeat)
            guard rtc.currentRoomID == roomID, rtc.roomState?.me.userID == userID, rtc.canUseRoom else { return }
            if ["pending", "approved", "seated"].contains(mySeatRequestStatus) { showRoomNotice(mySeatStatusTitle) }
        }
    }

    private func endComposing() { isComposing = false }

    private func showRoomNotice(_ message: String) {
        let id = UUID()
        roomNoticeID = id
        roomNotice = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if roomNoticeID == id { roomNotice = nil }
        }
    }

    private func send() {
        guard rtc.canSendChat, !rtc.isSendingMessage else { return }
        let text = rtc.messageDraft
        Task { if await rtc.sendMessage(text), rtc.messageDraft == text { rtc.messageDraft = "" } }
    }

    private func initials(_ name: String, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hex: 0xA18BDB), Color(hex: 0x6650A6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(String(name.prefix(1))).font(.system(size: size * 0.36, weight: .medium)).foregroundStyle(.white)
        }.frame(width: size, height: size)
    }

    private func endedRoom(_ reason: String) -> some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "waveform.slash").font(.system(size: 38)).foregroundStyle(accent)
                Text("已离开语聊").font(.system(size: 20, weight: .semibold))
                Text(reason).font(.system(size: 14)).foregroundStyle(secondary).multilineTextAlignment(.center)
                Button { Task { await rtc.leaveRoom() } } label: {
                    Text("返回大厅").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .foregroundStyle(.white).background(KikiPalette.action, in: Capsule())
                }.disabled(rtc.isLeavingRoom)
            }
            .foregroundStyle(KikiPalette.text).padding(26).frame(maxWidth: 420)
            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 24)).padding(32)
        }
    }

    private func action(_ value: KikiRoomAction, target: String? = nil, seat: Int? = nil, enabled: Bool? = nil) {
        if [.kick, .setAdmin, .unban].contains(value) {
            let name = rtc.roomState?.members.first { $0.userID == target }?.name ?? rtc.roomState?.bans.first { $0.userID == target }?.name ?? target ?? "此用户"
            pendingModeration = .init(action: value, target: target, seat: seat, enabled: enabled, name: name)
            return
        }
        guard let roomID = rtc.currentRoomID, let userID = rtc.roomState?.me.userID else { return }
        Task {
            guard rtc.currentRoomID == roomID, rtc.roomState?.me.userID == userID, rtc.canUseRoom else { return }
            await rtc.performRoomAction(value, targetUserID: target, seatIndex: seat, enabled: enabled)
        }
    }

    private func presentQueuedDestination() {
        if let target = queuedReportTarget { reportTarget = target; queuedReportTarget = nil }
        else if let person = queuedPerson { selectedPerson = person; queuedPerson = nil }
    }

    private func openPerson(_ userID: String) {
        guard rtc.socialStore != nil else { return }
        if showsParticipants { queuedPerson = .init(id: userID); showsParticipants = false }
        else if showsSeatRequests { queuedPerson = .init(id: userID); showsSeatRequests = false }
        else { selectedPerson = .init(id: userID) }
    }

    private func openReport(_ target: KikiReportTarget) {
        if showsParticipants { queuedReportTarget = target; showsParticipants = false }
        else { reportTarget = target }
    }

    private func chooseBlock(userID: String, name: String) {
        if rtc.safetyState.blockedIDs.contains(userID) {
            Task { do { try await rtc.setBlocked(userID, enabled: false) } catch { rtc.roomError = error.localizedDescription } }
        } else { pendingBlock = .init(userID: userID, name: name, createdAt: 0) }
    }

    private func blockConfirmation(inParticipants: Bool) -> Binding<Bool> {
        Binding(get: { pendingBlock != nil && showsParticipants == inParticipants }, set: { if !$0 { pendingBlock = nil } })
    }

    private var blockConfirmationButtons: some View {
        Group {
            Button("拉黑 \(pendingBlock?.name ?? "此用户")", role: .destructive) {
                guard let userID = pendingBlock?.userID else { return }
                pendingBlock = nil
                Task { do { try await rtc.setBlocked(userID, enabled: true) } catch { rtc.roomError = error.localizedDescription } }
            }
            Button("取消", role: .cancel) { pendingBlock = nil }
        }
    }

    private func moderationConfirmation(inParticipants: Bool) -> Binding<Bool> {
        Binding(get: { pendingModeration != nil && showsParticipants == inParticipants }, set: { if !$0 { pendingModeration = nil } })
    }

    private var moderationConfirmationButtons: some View {
        Group {
            Button("确认", role: .destructive) {
                guard let pending = pendingModeration else { return }
                pendingModeration = nil
                Task { await rtc.performRoomAction(pending.action, targetUserID: pending.target, seatIndex: pending.seat, enabled: pending.enabled) }
            }
            Button("取消", role: .cancel) { pendingModeration = nil }
        }
    }

    @ViewBuilder private func memberActions(_ member: KikiRoomMember, state: KikiRoomState) -> some View {
        if rtc.socialStore != nil { Button("查看个人主页", systemImage: "person.crop.circle") { openPerson(member.userID) } }
        if member.userID != state.me.userID, let roomID = rtc.currentRoomID {
            Button("举报用户", systemImage: "exclamationmark.bubble") {
                openReport(.init(targetType: .user, roomID: roomID, targetUserID: member.userID, messageID: nil, name: member.name))
            }
            Button(rtc.safetyState.blockedIDs.contains(member.userID) ? "解除拉黑" : "拉黑用户", systemImage: "person.crop.circle.badge.xmark") {
                chooseBlock(userID: member.userID, name: member.name)
            }.disabled(rtc.isUpdatingBlock)
        }
        if state.me.canModerate(member) {
            if member.seatIndex != nil {
                Button(member.audioMuted ? "解除禁麦" : "强制禁麦") { action(.muteAudio, target: member.userID, enabled: !member.audioMuted) }
                Button("踢下麦", role: .destructive) { action(.removeSeat, target: member.userID) }
            } else if member.audioMuted {
                Button("解除禁麦") { action(.muteAudio, target: member.userID, enabled: false) }
            }
            Button(member.chatMuted ? "解除文字禁言" : "文字禁言") { action(.muteChat, target: member.userID, enabled: !member.chatMuted) }
            if state.me.role == .owner {
                Button(member.role == .admin ? "取消管理员" : "设为管理员") {
                    action(.setAdmin, target: member.userID, enabled: member.role != .admin)
                }
            }
            Button("踢出并禁止重入", role: .destructive) { action(.kick, target: member.userID) }
        }
    }

    private func memberRow(_ member: KikiRoomMember, state: KikiRoomState) -> some View {
        HStack(spacing: 12) {
            KikiDecoratedAvatar(gifts: gifts, userID: member.userID, index: member.avatarIndex, size: 36, customURL: member.avatarURL)
                .saturation(member.online ? 1 : 0).opacity(member.online ? 1 : 0.42)
            VStack(alignment: .leading, spacing: 3) {
                Text(member.name + (member.userID == state.me.userID ? " (我)" : "") + (rtc.safetyState.blockedIDs.contains(member.userID) ? " · 已拉黑" : ""))
                Text("\(member.role.label) · \(member.seatIndex.map { "\($0) 号麦" } ?? "听众")\(member.chatMuted ? " · 已禁言" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if member.userID != state.me.userID {
                Menu { memberActions(member, state: state) } label: { Image(systemName: "ellipsis.circle").padding(7) }
                    .accessibilityLabel("管理或举报 \(member.name)")
            } else if member.seatIndex != nil {
                Image(systemName: rtc.participants.first(where: { $0.id == member.userID })?.microphoneEnabled == true ? "mic.fill" : "mic.slash.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityValue(member.online ? "在线" : "连接中断，等待恢复")
        .listRowBackground(KikiPalette.surface)
    }

    private var participantList: some View {
        NavigationStack {
            List {
                if let state = rtc.roomState {
                    Section("在麦成员 · \(state.members.filter { $0.seatIndex != nil }.count)") {
                        ForEach(state.members.filter { $0.seatIndex != nil }.sorted { ($0.seatIndex ?? 0) < ($1.seatIndex ?? 0) }) { member in
                            memberRow(member, state: state)
                        }
                    }
                    let listeners = state.members.filter { $0.seatIndex == nil }
                    Section("独立听众 · \(listeners.count)") {
                        if listeners.isEmpty { Text("暂无听众").foregroundStyle(.secondary) }
                        ForEach(listeners) { member in memberRow(member, state: state) }
                    }
                    if state.me.isModerator {
                        Section("禁止重入 · \(state.bans.count)") {
                            if state.bans.isEmpty { Text("暂无禁止重入成员").foregroundStyle(.secondary) }
                            ForEach(state.bans) { ban in
                                HStack {
                                    Text(ban.name)
                                    Spacer()
                                    Button("解除禁入") { action(.unban, target: ban.userID) }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                } else { ProgressView("正在同步房间状态") }
            }
            .disabled(!rtc.canUseRoom || rtc.isPerformingRoomAction)
            .scrollContentBackground(.hidden).background(KikiPalette.background)
            .navigationTitle(rtc.canManageRoom ? "房间成员与管理" : "房间成员").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsParticipants = false } } }
        }
        .alert("语聊提示", isPresented: Binding(get: { rtc.roomError != nil && showsParticipants }, set: { if !$0 { rtc.roomError = nil } })) {
            Button("知道了") { rtc.roomError = nil }
        } message: { Text(rtc.roomError ?? "") }
        .confirmationDialog("拉黑后，你将不再听到对方的声音或看到对方的房间文字。对方仍可能在公开房间听到你；可在设置解除。", isPresented: blockConfirmation(inParticipants: true), titleVisibility: .visible) { blockConfirmationButtons }
        .alert(pendingModeration?.title ?? "确认管理操作", isPresented: moderationConfirmation(inParticipants: true)) { moderationConfirmationButtons } message: { Text(pendingModeration?.message ?? "") }
    }
}

/// The room identity uses all space between the avatar and the fixed touch targets.
struct KikiRoomHeader<Avatar: View, Controls: View>: View {
    let title: String
    let host: String
    var onEditTitle: (() -> Void)? = nil
    var isTitleEditingEnabled = true
    @ViewBuilder var avatar: () -> Avatar
    @ViewBuilder var controls: () -> Controls
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            avatar().fixedSize()
            Group {
                if let onEditTitle {
                    Button(action: onEditTitle) { identity }
                        .buttonStyle(.plain).disabled(!isTitleEditingEnabled)
                        .accessibilityLabel("编辑房间名称")
                        .accessibilityValue(title)
                        .accessibilityIdentifier("livekit.room.editTitle")
                } else { identity }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            controls().fixedSize(horizontal: true, vertical: false)
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.body.weight(.semibold))
                .foregroundStyle(KikiPalette.text)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("房主 \(host)").font(.caption2)
                .foregroundStyle(KikiPalette.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct KikiRoomHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}


/// Connectivity changes tint the existing content; they never add a caption or a row.
struct KikiRoomSeatTile: View {
    let slot: KikiRoomSeat
    let member: KikiRoomMember?
    let participant: KikiVoiceParticipant?
    let localUserID: String?
    let avatarSize: CGFloat
    @ObservedObject var gifts: KikiGiftStore
    private let secondary = KikiPalette.secondary

    var body: some View {
        let online = member?.online != false
        let speaking = online && participant?.isSpeaking == true
        return VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    if let member {
                        KikiDecoratedAvatar(gifts: gifts, userID: member.userID, index: member.avatarIndex, size: avatarSize, customURL: member.avatarURL)
                            .saturation(online ? 1 : 0).opacity(online ? 1 : 0.42)
                    }
                    else {
                        Circle().fill(KikiPalette.elevated)
                        Image(systemName: slot.locked ? "lock.fill" : "mic")
                            .font(.system(size: 21, weight: .light)).foregroundStyle(KikiPalette.muted)
                    }
                }
                .frame(width: avatarSize, height: avatarSize)
                .overlay(Circle().stroke(speaking ? KikiPalette.mint : KikiPalette.text.opacity(0.12), lineWidth: speaking ? 3 : 1))
                .padding(3)
                .overlay(Circle().stroke(speaking ? KikiPalette.mint.opacity(0.24) : .clear, lineWidth: 2))
                .animation(.easeOut(duration: 0.18), value: speaking)
                .overlay {
                    KikiMicDecoration(decorationID: member.flatMap { gifts.appearance(for: $0.userID).micEffect },
                                      isSpeaking: speaking, size: avatarSize + 6)
                        .saturation(online ? 1 : 0).opacity(online ? 1 : 0.25)
                }
                if member != nil || slot.audioLocked {
                    Image(systemName: slot.audioLocked ? "lock.fill" : (participant?.microphoneEnabled == true ? "mic.fill" : "mic.slash.fill"))
                        .font(.system(size: 9)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(KikiPalette.action, in: Circle())
                }
            }
            HStack(spacing: 3) {
                if let member, member.role != .member {
                    Text(member.role.label).font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(KikiPalette.roleBadgeText)
                        .padding(.horizontal, 3).padding(.vertical, 2)
                        .background(KikiPalette.roleBadgeBackground, in: RoundedRectangle(cornerRadius: 3))
                }
                Text(member.map { $0.name + ($0.userID == localUserID ? " (我)" : "") } ?? "\(slot.index)")
                    .font(.system(size: 10)).foregroundStyle(member == nil ? secondary : KikiPalette.text).lineLimit(1)
            }.frame(height: 14)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityValue(member == nil ? (slot.locked ? "麦位已锁定" : "空麦位")
                            : (!online ? "连接中断，保留麦位等待重连" : (speaking ? "正在发言" : "")))
    }
}

private struct KikiRoomChatViewportKey: PreferenceKey {
    static let defaultValue = KikiRoomChatViewport()
    static func reduce(value: inout KikiRoomChatViewport, nextValue: () -> KikiRoomChatViewport) { value = nextValue() }
}

private struct KikiPendingModeration {
    let action: KikiRoomAction
    let target: String?
    let seat: Int?
    let enabled: Bool?
    let name: String
    var title: String { action == .kick ? "踢出并禁止重入？" : (action == .unban ? "解除房间禁入？" : "更改房间管理员？") }
    var message: String {
        if action == .kick { return "\(name) 将离开本房间，并且在解除禁入前无法重新加入。" }
        if action == .unban { return "\(name) 将可以重新加入本房间。" }
        return enabled == true ? "\(name) 将获得本房间的上麦申请管理、禁言和踢人权限。" : "\(name) 将失去本房间的管理员权限。"
    }
}
