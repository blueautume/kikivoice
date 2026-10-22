import SwiftUI

@available(iOS 16.0, *)
struct KikiLoginView: View {
    @EnvironmentObject private var store: KikiDemoStore
    @State private var name = ""
    @State private var accessCode = ""
    @State private var errorMessage: String?
    @State private var agreed = false
    @State private var adultConfirmed = false
    @FocusState private var focused: Bool

    private var valid: Bool {
        let nickname = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !nickname.isEmpty && nickname.count <= 16 && !accessCode.isEmpty && agreed && adultConfirmed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Spacer(minLength: 30)
                ZStack {
                    RoundedRectangle(cornerRadius: 28).fill(KikiPalette.purple.opacity(0.2)).frame(width: 94, height: 94)
                    Image(systemName: "waveform").font(.system(size: 46, weight: .medium)).foregroundStyle(KikiPalette.lavender)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("在这里，\n听见同频的你。").font(.system(size: 36, weight: .bold)).lineSpacing(5)
                    Text("LiveKit 语聊实验 · furby.top")
                        .font(.system(size: 14)).foregroundStyle(KikiPalette.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("独立实验账号", systemImage: "flask")
                    Text("输入昵称和实验邀请码创建测试账号。实验账号与正式 Kiki 账号独立；退出后重新登录会创建新的实验账号，原账号无法找回。邀请码仅用于本次验证，不会保存到设备。")
                        .font(.system(size: 12)).lineSpacing(5).foregroundStyle(KikiPalette.secondary)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                VStack(spacing: 12) {
                    TextField("你的昵称（1–16 字）", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("labNickname")
                        .onChange(of: name) { value in if value.count > 16 { name = String(value.prefix(16)) } }
                    Divider().overlay(KikiPalette.muted.opacity(0.3))
                    SecureField("实验邀请码", text: $accessCode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive().accessibilityIdentifier("labAccessCode")
                }.focused($focused).padding(18).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                if let message = errorMessage ?? store.loadingError {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).lineSpacing(4).foregroundStyle(Color(hex: 0xFFAFBD))
                }
                if store.canReconnect {
                    Button("恢复当前实验会话") {
                        Task {
                            do { try await store.reconnect() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }.font(.system(size: 13, weight: .semibold)).foregroundStyle(KikiPalette.lavender)
                        .disabled(store.isSigningIn || store.isEndingSession)
                }
                KikiAgreementChecks(agreed: $agreed, adultConfirmed: $adultConfirmed)
                Button(action: signIn) {
                    HStack(spacing: 9) {
                        if store.isSigningIn || store.isEndingSession { ProgressView().tint(.white) }
                        Text(store.isSigningIn ? "正在安全连接…" : "进入语聊实验")
                        if !store.isSigningIn { Image(systemName: "arrow.right") }
                    }.font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity).padding(19)
                        .background(KikiPalette.purple, in: RoundedRectangle(cornerRadius: 17))
                }.disabled(!valid || store.isSigningIn || store.isEndingSession)
                    .opacity(valid ? 1 : 0.45).accessibilityIdentifier("labLoginButton")
                Text("基础验证：语聊房 · 麦克风 · 房间文字消息")
                    .font(.system(size: 11)).foregroundStyle(KikiPalette.muted).frame(maxWidth: .infinity)
                Spacer(minLength: 25)
            }.padding(.horizontal, 28).padding(.bottom, 30)
        }.scrollDismissesKeyboard(.interactively)
            .background(KikiPalette.background.ignoresSafeArea())
            .onDisappear { accessCode = "" }
    }

    private func signIn() {
        guard valid, !store.isSigningIn, !store.isEndingSession else { return }
        focused = false
        errorMessage = nil
        let code = accessCode
        accessCode = ""
        Task {
            do { try await store.loginForLab(name: name, accessCode: code, agreed: agreed, adultConfirmed: adultConfirmed) }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

@available(iOS 16.0, *)
struct KikiNicknameOnboardingView: View {
    @EnvironmentObject private var store: KikiDemoStore
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("欢迎来到 Kiki").font(.system(size: 13, weight: .medium)).foregroundStyle(KikiPalette.lavender)
                    Spacer()
                    Button("退出登录") { Task { await store.logout() } }
                        .font(.system(size: 12)).foregroundStyle(KikiPalette.secondary)
                        .disabled(isSaving || store.isSigningIn).accessibilityIdentifier("nicknameLogout")
                }.padding(.top, 25)
                KikiAvatar(index: store.avatarIndex, size: 84, customURL: store.customAvatarURL).padding(.top, 30)
                VStack(alignment: .leading, spacing: 13) {
                    Text("先认识一下你。").font(.system(size: 32, weight: .bold))
                    Text("为自己取一个昵称，让房间里的朋友知道该怎么称呼你。")
                        .font(.system(size: 14)).lineSpacing(6).foregroundStyle(KikiPalette.secondary)
                    Text("账号 ID · \(store.userID)").font(.system(size: 11, design: .monospaced)).foregroundStyle(KikiPalette.muted)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("你的昵称").foregroundStyle(KikiPalette.secondary)
                        Spacer()
                        Text("\(name.count)/16").foregroundStyle(KikiPalette.muted)
                    }.font(.system(size: 12))
                    TextField("请输入昵称", text: $name)
                        .font(.system(size: 17, weight: .medium))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .focused($focused).submitLabel(.go).onSubmit(save)
                        .padding(18).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("firstNickname")
                        .onChange(of: name) { value in
                            if value.count > 16 { name = String(value.prefix(16)) }
                        }
                    Text("1–16 字，之后可以在「我」中修改昵称和头像。")
                        .font(.system(size: 11)).foregroundStyle(KikiPalette.muted)
                    Text("昵称和头像会展示在大厅、房间、麦位和聊天等场景，房间成员可见，请勿填写敏感个人信息。")
                        .font(.system(size: 11)).lineSpacing(5).foregroundStyle(KikiPalette.secondary)
                }.padding(.top, 5)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(Color(hex: 0xFFAFBD)).lineSpacing(4)
                }
                Button(action: save) {
                    HStack(spacing: 10) {
                        if isSaving { ProgressView().tint(.white) }
                        Text(isSaving ? "正在保存…" : "保存昵称，进入 Kiki")
                        if !isSaving { Image(systemName: "arrow.right") }
                    }.font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity).padding(19)
                        .background(KikiPalette.purple, in: RoundedRectangle(cornerRadius: 17))
                }
                .disabled(trimmedName.isEmpty || isSaving || store.isSigningIn)
                .opacity(trimmedName.isEmpty ? 0.6 : 1)
                .accessibilityIdentifier("completeNickname")
                Spacer(minLength: 35)
            }.padding(.horizontal, 28).padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(KikiPalette.background.ignoresSafeArea())
        .onAppear { focused = true }
    }

    private func save() {
        guard !trimmedName.isEmpty, !isSaving else { return }
        focused = false
        errorMessage = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do { try await store.completeNickname(trimmedName) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
