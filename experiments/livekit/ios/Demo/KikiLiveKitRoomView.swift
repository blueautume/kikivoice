import LiveKit
import SwiftUI

/// Eight server-owned seats and an independent audience; LiveKit supplies live speaking state.
struct KikiLiveKitRoomView: View {
    @ObservedObject var rtc: KikiRTCService
    @State private var confirmsExit = false
    @State private var showsParticipants = false
    @State private var showsDiagnostics = false
    @State private var showsAnnouncement = false
    @FocusState private var isComposing: Bool
    private let accent = Color(hex: 0x8B66FF)
    private let secondary = Color.white.opacity(0.66)
    private var canTransferOwnership: Bool {
        guard let state = rtc.roomState else { return false }
        return state.members.contains { $0.online && $0.userID != state.me.userID }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x372461), Color(hex: 0x241747), Color(hex: 0x171025)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(spacing: 14) {
                header
                connectionBanner
                seats
                audienceStrip
                seatControls
                announcementBar
                HStack {
                    Text("房间聊天").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("LiveKit 实验版").font(.system(size: 10)).foregroundStyle(secondary)
                }
                chat
                bottomBar
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 8).foregroundStyle(.white)
            if let reason = rtc.disconnectionReason { endedRoom(reason) }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .confirmationDialog(rtc.isRoomOwner ? (canTransferOwnership ? "结束房间，或离开并将房主转交给在线成员。" : "结束本次语聊？") : "确定离开本次语聊？",
                            isPresented: $confirmsExit, titleVisibility: .visible) {
            if rtc.isRoomOwner {
                Button("结束房间并离开", role: .destructive) {
                    isComposing = false
                    Task { await rtc.leaveRoom(endRoom: true) }
                }
                if canTransferOwnership {
                    Button("离开并转交房主") {
                        isComposing = false
                        Task { await rtc.leaveRoom() }
                    }
                }
            } else {
                Button("离开房间", role: .destructive) {
                    isComposing = false
                    Task { await rtc.leaveRoom() }
                }
            }
            Button("取消", role: .cancel) { }
        }
        .alert("语聊提示", isPresented: Binding(get: { rtc.roomError != nil }, set: { if !$0 { rtc.roomError = nil } })) {
            Button("知道了") { rtc.roomError = nil }
        } message: { Text(rtc.roomError ?? "") }
        .sheet(isPresented: $showsParticipants) { participantList }
        .sheet(isPresented: $showsDiagnostics) { KikiRoomDiagnosticsView(rtc: rtc) }
        .sheet(isPresented: $showsAnnouncement) { KikiRoomAnnouncementView(rtc: rtc) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            initials(rtc.roomInfo?.host ?? "", size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(rtc.roomInfo?.title ?? "语聊房").font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text("房主 \(rtc.roomInfo?.host ?? "")").font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { showsDiagnostics = true } label: {
                Image(systemName: rtc.connectionQuality == .poor || rtc.connectionQuality == .lost ? "wifi.exclamationmark" : "waveform.path.ecg")
                    .font(.system(size: 15)).frame(width: 30, height: 36)
            }.accessibilityLabel("连接与音频诊断").accessibilityIdentifier("livekit.room.diagnostics")
            Button { showsParticipants = true } label: {
                Image(systemName: "person.2").font(.system(size: 16)).frame(width: 36, height: 36)
                    .background(.white.opacity(0.09), in: Circle())
            }.accessibilityLabel("房间成员")
            Button {
                isComposing = false
                Task { await rtc.minimizeRoom() }
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 36)
            }
            .disabled(rtc.isLeavingRoom || rtc.isTransitioningRoom)
            .accessibilityLabel("最小化语聊房").accessibilityIdentifier("livekit.room.minimize")
            Button { confirmsExit = true } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36)
                    .background(.white.opacity(0.09), in: Circle())
            }
            .disabled(rtc.isLeavingRoom)
            .accessibilityLabel(rtc.isRoomOwner ? "结束房间" : "离开房间")
            .accessibilityIdentifier("livekit.room.leave")
        }
    }

    @ViewBuilder private var connectionBanner: some View {
        if rtc.isRecovering || rtc.connectionState == .reconnecting || rtc.connectionState == .connecting || rtc.isLeavingRoom {
            HStack(spacing: 8) {
                ProgressView().tint(.white).scaleEffect(0.7)
                Text(rtc.isLeavingRoom ? "正在离开房间…" : "正在恢复连接并校准麦位，暂时无法发言或发送消息…").font(.system(size: 11))
                Spacer()
            }.padding(8).background(accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        } else if let notice = rtc.audioState.notice {
            Text(notice).font(.system(size: 11)).foregroundStyle(Color(hex: 0xEAC6A3))
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder private var announcementBar: some View {
        if !rtc.announcement.text.isEmpty || rtc.canManageRoom {
            Button { showsAnnouncement = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "megaphone.fill").font(.system(size: 12))
                    Text(rtc.announcement.text.isEmpty ? "发布房间公告" : rtc.announcement.text)
                        .font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right").font(.system(size: 9))
                }.foregroundStyle(Color(hex: 0xD4C7FF)).padding(9)
                    .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
            }.accessibilityLabel("房间公告").accessibilityIdentifier("livekit.room.announcement")
        }
    }

    private var seats: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 14) {
            ForEach(1...8, id: \.self) { number in
                if let slot = rtc.roomState?.seats.first(where: { $0.index == number }) {
                    Menu { seatMenu(slot) } label: { seat(slot) }
                        .disabled(!rtc.canUseRoom || rtc.isPerformingRoomAction)
                } else {
                    seatPlaceholder(number: number)
                }
            }
        }.padding(.top, 4).padding(.bottom, 2)
    }

    private func seat(_ slot: KikiRoomSeat) -> some View {
        let member = rtc.roomState?.member(on: slot)
        let participant = rtc.participants.first { $0.id == member?.userID }
        return VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    if let member { KikiAvatar(index: member.avatarIndex, size: 55) }
                    else {
                        Circle().fill(.white.opacity(0.07))
                        Image(systemName: slot.locked ? "lock.fill" : "mic")
                            .font(.system(size: 21, weight: .light)).foregroundStyle(.white.opacity(0.38))
                    }
                }
                .frame(width: 55, height: 55)
                .overlay(Circle().stroke(participant?.isSpeaking == true ? Color(hex: 0xB9F2D1) : .white.opacity(0.12), lineWidth: participant?.isSpeaking == true ? 3 : 1))
                .padding(3)
                .overlay(Circle().stroke(participant?.isSpeaking == true ? Color(hex: 0xB9F2D1).opacity(0.24) : .clear, lineWidth: 2))
                .animation(.easeOut(duration: 0.18), value: participant?.isSpeaking)
                if member != nil || slot.audioLocked {
                    Image(systemName: slot.audioLocked ? "lock.fill" : (participant?.microphoneEnabled == true ? "mic.fill" : "mic.slash.fill"))
                        .font(.system(size: 9)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Color(hex: 0x2D204C), in: Circle())
                }
            }
            HStack(spacing: 3) {
                if let member, member.role != .member {
                    Text(member.role.label).font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 3).padding(.vertical, 2).background(accent, in: RoundedRectangle(cornerRadius: 3))
                }
                Text(member.map { $0.name + ($0.userID == rtc.roomState?.me.userID ? " (我)" : "") } ?? "\(slot.index) 号麦\(slot.locked ? "·锁定" : "位")")
                    .font(.system(size: 10)).foregroundStyle(member == nil ? secondary : .white).lineLimit(1)
            }.frame(height: 14)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityValue(participant?.isSpeaking == true ? "正在发言" : "")
    }

    private func seatPlaceholder(number: Int) -> some View {
        VStack(spacing: 9) {
            Circle().fill(.white.opacity(0.07)).frame(width: 61, height: 61)
                .overlay(Image(systemName: "mic").foregroundStyle(secondary))
            Text("\(number) 号麦位").font(.system(size: 10)).foregroundStyle(secondary)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private func seatMenu(_ slot: KikiRoomSeat) -> some View {
        if let state = rtc.roomState {
            if let member = state.member(on: slot) {
                if member.userID == state.me.userID {
                    Button("主动下麦", role: .destructive) { action(.leaveSeat) }
                } else {
                    memberActions(member, state: state)
                }
            } else if !slot.locked {
                if state.canMoveSeats {
                    Button("换到 \(slot.index) 号麦") { action(.moveSeat, seat: slot.index) }
                } else if state.me.seatIndex == nil, state.myRequest == nil {
                    Button(state.me.isModerator ? "上麦" : "申请上麦") { action(.requestSeat) }
                }
            }
            if state.me.isModerator {
                let occupant = state.member(on: slot)
                if occupant == nil || occupant?.userID == state.me.userID || occupant.map({ state.me.canModerate($0) }) == true {
                    Button(slot.locked ? "解锁麦位" : "锁定麦位") { action(.lockSeat, seat: slot.index, enabled: !slot.locked) }
                    Button(slot.audioLocked ? "解除音频锁定" : "锁定音频") { action(.lockAudio, seat: slot.index, enabled: !slot.audioLocked) }
                }
            }
        }
    }

    private var audienceStrip: some View {
        Button { showsParticipants = true } label: {
            HStack(spacing: 8) {
                Label("听众 \(rtc.roomState?.listeners.count ?? 0)", systemImage: "headphones")
                HStack(spacing: -7) {
                    ForEach(Array((rtc.roomState?.listeners ?? []).prefix(5))) { member in
                        KikiAvatar(index: member.avatarIndex, size: 25)
                    }
                }
                Spacer()
                Text("\(rtc.roomState?.members.filter(\.online).count ?? rtc.participants.count) 人在线")
                Image(systemName: "chevron.right").font(.system(size: 9))
            }.font(.system(size: 11)).foregroundStyle(secondary).padding(.horizontal, 4)
        }.accessibilityLabel("查看独立听众和房间成员")
    }

    private var seatControls: some View {
        VStack(spacing: 8) {
            if let state = rtc.roomState {
                if let invite = state.myInvitation, state.me.seatIndex == nil {
                    HStack {
                        Text("管理者邀请你上 \(invite.seatIndex) 号麦").font(.system(size: 11))
                        Spacer()
                        Button("拒绝") { action(.declineInvite) }.font(.system(size: 11))
                        Button("接受") { action(.acceptInvite) }.font(.system(size: 11, weight: .semibold))
                    }
                }
                HStack(spacing: 8) {
                    Text(rtc.microphoneStatus).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(2)
                    Spacer(minLength: 2)
                    if state.me.seatIndex == nil {
                        if let request = state.myRequest {
                            Button("排队 \(request.position) · 取消") { action(.cancelRequest) }
                        } else {
                            Button(state.me.isModerator ? "上麦" : "申请上麦") { action(.requestSeat) }
                        }
                    } else {
                        Menu("麦位") {
                            if state.canMoveSeats {
                                ForEach(state.availableSeats) { slot in
                                    Button("换到 \(slot.index) 号麦") { action(.moveSeat, seat: slot.index) }
                                }
                            } else {
                                Text("当前麦位音频已锁定")
                            }
                            Button("主动下麦", role: .destructive) { action(.leaveSeat) }
                        }
                    }
                    Button(state.me.isModerator ? "管理 · \(state.queue.count)" : "排麦 · \(state.queue.count)") { showsParticipants = true }
                }.font(.system(size: 11, weight: .semibold))
                if state.me.chatMuted {
                    Text("你已被文字禁言，暂时无法发送聊天消息").font(.system(size: 10)).foregroundStyle(Color(hex: 0xEAC6A3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("正在同步房间麦位与权限…").font(.system(size: 11)).foregroundStyle(secondary)
            }
        }
        .padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .disabled(!rtc.canUseRoom || rtc.isPerformingRoomAction)
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let notice = rtc.chatSyncNotice {
                        Text(notice).font(.system(size: 10)).foregroundStyle(secondary)
                    }
                    if rtc.messages.isEmpty {
                        Text("欢迎来到语聊房，和大家打个招呼吧").font(.system(size: 11)).foregroundStyle(secondary).padding(.vertical, 10)
                    }
                    ForEach(rtc.messages) { message in
                        HStack(alignment: .top, spacing: 0) {
                            (Text(message.senderName + "：").foregroundColor(message.isLocal ? Color(hex: 0xC6B5FF) : Color.white.opacity(0.65))
                             + Text(message.text).foregroundColor(.white))
                                .font(.system(size: 12)).lineSpacing(4)
                                .padding(.horizontal, 11).padding(.vertical, 8)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            Spacer(minLength: 24)
                        }.id(message.id)
                    }
                    if let pending = rtc.pendingMessage {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pending.text).font(.system(size: 12)).foregroundStyle(secondary)
                            if let failure = pending.failure {
                                HStack(alignment: .top) {
                                    Text("发送未确认：\(failure)").font(.system(size: 10)).foregroundStyle(Color(hex: 0xEAC6A3))
                                    Spacer()
                                    Button("重试") {
                                        Task { if await rtc.sendMessage(pending.text), rtc.messageDraft == pending.text { rtc.messageDraft = "" } }
                                    }.font(.system(size: 11, weight: .semibold)).disabled(!rtc.canSendChat || rtc.isSendingMessage)
                                }
                            } else { Text("正在等待服务器确认…").font(.system(size: 10)).foregroundStyle(secondary) }
                        }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: rtc.messages.last?.id) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }.frame(maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 9) {
            TextField(rtc.roomState?.me.chatMuted == true ? "已被禁言" : "说点什么…", text: $rtc.messageDraft).font(.system(size: 13))
                .focused($isComposing).submitLabel(.send).onSubmit(send)
                .padding(.horizontal, 14).frame(height: 42)
                .background(.black.opacity(0.2), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                .disabled(!rtc.canSendChat || rtc.isSendingMessage)
                .accessibilityIdentifier("livekit.room.message")
            Button(action: send) {
                Group {
                    if rtc.isSendingMessage { ProgressView().tint(.white) }
                    else { Image(systemName: "paperplane.fill").font(.system(size: 16)) }
                }.frame(width: 42, height: 42).background(accent.opacity(0.8), in: Circle())
            }
            .disabled(!rtc.canSendChat || rtc.isSendingMessage || rtc.messageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("发送消息").accessibilityIdentifier("livekit.room.send")
            Button { Task { await rtc.toggleMicrophone() } } label: {
                VStack(spacing: 3) {
                    if rtc.isChangingMicrophone { ProgressView().tint(.white).frame(height: 18) }
                    else { Image(systemName: rtc.microphoneEnabled ? "mic.fill" : "mic.slash.fill").font(.system(size: 18)) }
                    Text(rtc.microphoneEnabled ? "闭麦" : "开麦").font(.system(size: 9))
                }.frame(width: 46, height: 46)
                    .background(rtc.microphoneEnabled ? accent.opacity(0.35) : .white.opacity(0.08), in: Circle())
            }
            .disabled((!rtc.canUseRoom && !rtc.microphoneEnabled) || (!rtc.microphoneEnabled && !rtc.canPublishAudio) || rtc.isChangingMicrophone)
            .accessibilityLabel(rtc.microphoneEnabled ? "关闭麦克风" : "打开麦克风")
            .accessibilityIdentifier("livekit.room.microphone")
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
                Image(systemName: "waveform.slash").font(.system(size: 38)).foregroundStyle(Color(hex: 0xC6B5FF))
                Text("已离开语聊").font(.system(size: 20, weight: .semibold))
                Text(reason).font(.system(size: 14)).foregroundStyle(secondary).multilineTextAlignment(.center)
                Button { Task { await rtc.leaveRoom() } } label: {
                    Text("返回大厅").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(accent, in: Capsule())
                }.disabled(rtc.isLeavingRoom)
            }
            .foregroundStyle(.white).padding(26)
            .background(Color(hex: 0x2B2044), in: RoundedRectangle(cornerRadius: 24)).padding(32)
        }
    }

    private func action(_ value: KikiRoomAction, target: String? = nil, seat: Int? = nil, enabled: Bool? = nil) {
        Task { await rtc.performRoomAction(value, targetUserID: target, seatIndex: seat, enabled: enabled) }
    }

    @ViewBuilder private func memberActions(_ member: KikiRoomMember, state: KikiRoomState) -> some View {
        if state.me.canModerate(member) {
            if member.seatIndex == nil, member.online {
                Menu("邀请上麦") {
                    ForEach(state.availableSeats) { slot in
                        Button("\(slot.index) 号麦") { action(.inviteSeat, target: member.userID, seat: slot.index) }
                    }
                    if state.availableSeats.isEmpty { Text("暂无可用麦位") }
                }
            }
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
            KikiAvatar(index: member.avatarIndex, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(member.name + (member.userID == state.me.userID ? " (我)" : ""))
                Text("\(member.role.label) · \(member.seatIndex.map { "\($0) 号麦" } ?? "听众")\(member.chatMuted ? " · 已禁言" : "")\(member.online ? "" : " · 离线")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state.me.canModerate(member) {
                Menu { memberActions(member, state: state) } label: { Image(systemName: "ellipsis.circle").padding(7) }
                    .accessibilityLabel("管理 \(member.name)")
            } else if member.seatIndex != nil {
                Image(systemName: rtc.participants.first(where: { $0.id == member.userID })?.microphoneEnabled == true ? "mic.fill" : "mic.slash.fill")
                    .foregroundStyle(.secondary)
            }
        }.listRowBackground(Color.white.opacity(0.05))
    }

    private var participantList: some View {
        NavigationStack {
            List {
                if let state = rtc.roomState {
                    Section("排麦队列 · \(state.queue.count)") {
                        if state.queue.isEmpty { Text("暂无上麦申请").foregroundStyle(.secondary) }
                        ForEach(state.queue) { request in
                            HStack {
                                Text("\(request.position). \(request.name)")
                                Spacer()
                                if state.me.isModerator, request.userID != state.me.userID,
                                   state.members.first(where: { $0.userID == request.userID }).map({ state.me.canModerate($0) }) == true {
                                    Button("拒绝") { action(.rejectRequest, target: request.userID) }.buttonStyle(.borderless)
                                    Menu("同意") {
                                        ForEach(state.availableSeats) { slot in
                                            Button("\(slot.index) 号麦") { action(.approveRequest, target: request.userID, seat: slot.index) }
                                        }
                                        if state.availableSeats.isEmpty { Text("暂无可用麦位") }
                                    }
                                } else if request.userID == state.me.userID {
                                    Button("取消") { action(.cancelRequest) }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    if !state.invitations.isEmpty {
                        Section("上麦邀请") {
                            ForEach(state.invitations) { invite in
                                HStack {
                                    Text("\(invite.name) → \(invite.seatIndex) 号麦")
                                    Spacer()
                                    if invite.userID == state.me.userID {
                                        Button("拒绝") { action(.declineInvite) }.buttonStyle(.borderless)
                                        Button("接受") { action(.acceptInvite) }.buttonStyle(.borderless)
                                    } else { Text("等待回应").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    Section("在麦成员 · \(state.members.filter { $0.seatIndex != nil }.count)") {
                        ForEach(state.members.filter { $0.seatIndex != nil }.sorted { ($0.seatIndex ?? 0) < ($1.seatIndex ?? 0) }) { member in
                            memberRow(member, state: state)
                        }
                    }
                    Section("独立听众 · \(state.listeners.count)") {
                        if state.listeners.isEmpty { Text("暂无听众").foregroundStyle(.secondary) }
                        ForEach(state.listeners) { member in memberRow(member, state: state) }
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
            .scrollContentBackground(.hidden).background(Color(hex: 0x211732))
            .navigationTitle(rtc.canManageRoom ? "房间管理" : "成员与排麦").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsParticipants = false } } }
        }.preferredColorScheme(.dark)
    }
}
