import SwiftUI

@available(iOS 16.0, *)
struct KikiLoginView: View {
    @EnvironmentObject private var store: KikiDemoStore
    @State private var id = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Spacer(minLength: 45)
                ZStack {
                    RoundedRectangle(cornerRadius: 28).fill(KikiPalette.purple.opacity(0.2)).frame(width: 94, height: 94)
                    Image(systemName: "waveform").font(.system(size: 46, weight: .medium)).foregroundStyle(KikiPalette.lavender)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("在这里，\n听见同频的你。").font(.system(size: 36, weight: .bold)).lineSpacing(5)
                    Text("用一个 ID，开启一段真实的相遇")
                        .font(.system(size: 14)).foregroundStyle(KikiPalette.secondary)
                }
                VStack(alignment: .leading, spacing: 13) {
                    Text("你的账号 ID").font(.system(size: 13, weight: .medium)).foregroundStyle(KikiPalette.secondary)
                    HStack {
                        Image(systemName: "person").foregroundStyle(KikiPalette.muted)
                        TextField("例如 kiki_001", text: $id)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.asciiCapable).submitLabel(.go).focused($focused)
                            .onSubmit(signIn).accessibilityIdentifier("loginID")
                    }.padding(18).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                    Text("3–32 位字母、数字、下划线或短横线。首次登录将创建账号，账号绑定当前设备。")
                        .font(.system(size: 11)).lineSpacing(5).foregroundStyle(KikiPalette.muted)
                }.padding(.top, 8)
                if let message = errorMessage ?? store.loadingError {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).lineSpacing(4).foregroundStyle(Color(hex: 0xFFAFBD))
                }
                Button(action: signIn) {
                    HStack(spacing: 10) {
                        if store.isSigningIn || store.isEndingSession { ProgressView().tint(.white) }
                        Text(store.isSigningIn || store.isEndingSession ? "正在连接…" : "登录并进入")
                        if !store.isSigningIn && !store.isEndingSession { Image(systemName: "arrow.right") }
                    }.font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity).padding(19)
                        .background(KikiPalette.purple, in: RoundedRectangle(cornerRadius: 17))
                }.disabled(store.isSigningIn || store.isEndingSession || id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(id.isEmpty ? 0.6 : 1).accessibilityIdentifier("loginButton")
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield")
                    Text("安全连接 · 语音房 · 互动直播")
                }.font(.system(size: 11)).foregroundStyle(KikiPalette.muted)
                    .frame(maxWidth: .infinity).padding(.top, 7)
                Spacer(minLength: 30)
                Text("Kiki语聊").font(.system(size: 13, weight: .medium)).foregroundStyle(KikiPalette.muted).frame(maxWidth: .infinity)
            }.padding(.horizontal, 28).padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(KikiPalette.background.ignoresSafeArea())
        .onAppear { if id.isEmpty { id = store.rememberedID } }
    }

    private func signIn() {
        guard !store.isSigningIn, !store.isEndingSession else { return }
        focused = false
        errorMessage = nil
        Task {
            do { try await store.login(id: id) }
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
