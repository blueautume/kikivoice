import AuthenticationServices
import CryptoKit
import SwiftUI
import UIKit

struct KikiAppleCredential {
    let subject: String
    let identityToken: String
    let authorizationCode: String
}

enum KikiAppleCredentialState { case authorized, revoked, notFound, transferred }

@MainActor
protocol KikiAppleAuthorizing: AnyObject {
    func authorize(nonce: String, state: String) async throws -> KikiAppleCredential
    func credentialState(subject: String) async throws -> KikiAppleCredentialState
    func cancel()
}

/// Apple owns the authorization UI. No Apple password, name or email is read by the app.
@MainActor
final class KikiAppleAuthorizationService: NSObject, KikiAppleAuthorizing,
    ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<KikiAppleCredential, Error>?
    private var expectedState: String?

    static func hashedNonce(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func authorize(nonce: String, state: String) async throws -> KikiAppleCredential {
        guard continuation == nil else { throw KikiAPIError.security("Apple 授权正在进行中，请稍候。") }
        guard UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .contains(where: { $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow) }) else {
            throw KikiAPIError.security("请在应用前台重新发起 Apple 登录。")
        }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.nonce = Self.hashedNonce(nonce)
        request.state = state
        // Nickname is entered in Kiki; no email or full name scope is requested.
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        expectedState = state
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(controller: controller) }
        }
    }

    func credentialState(subject: String) async throws -> KikiAppleCredentialState {
        try await withCheckedThrowingContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: subject) { state, error in
                if let error { continuation.resume(throwing: error); return }
                let result: KikiAppleCredentialState
                switch state {
                case .authorized: result = .authorized
                case .revoked: result = .revoked
                case .notFound: result = .notFound
                case .transferred: result = .transferred
                @unknown default: result = .notFound
                }
                continuation.resume(returning: result)
            }
        }
    }

    func cancel() {
        guard let controller else { return }
        cancel(controller: controller)
    }

    private func cancel(controller: ASAuthorizationController) {
        guard self.controller === controller else { return }
        controller.cancel()
        finish(.failure(CancellationError()))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow) ?? UIWindow()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard self.controller === controller else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              credential.state == expectedState,
              let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8), !token.isEmpty,
              let codeData = credential.authorizationCode, let code = String(data: codeData, encoding: .utf8), !code.isEmpty,
              !credential.user.isEmpty else {
            finish(.failure(KikiAPIError.security("Apple 授权凭据不完整，请重新登录。"))); return
        }
        finish(.success(KikiAppleCredential(subject: credential.user, identityToken: token, authorizationCode: code)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard self.controller === controller else { return }
        if let error = error as? ASAuthorizationError, error.code == .canceled { finish(.failure(CancellationError())) }
        else { finish(.failure(KikiAPIError.security("Apple 登录未完成，请检查 Apple 账户和网络后重试。"))) }
    }

    private func finish(_ result: Result<KikiAppleCredential, Error>) {
        let pending = continuation
        continuation = nil; controller = nil; expectedState = nil
        pending?.resume(with: result)
    }
}

@available(iOS 16.0, *)
private struct KikiAppleLoginButton: UIViewRepresentable {
    var enabled: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn,
                                                   authorizationButtonStyle: colorScheme == .dark ? .white : .black)
        button.cornerRadius = 14
        button.addTarget(context.coordinator, action: #selector(Coordinator.signIn), for: .touchUpInside)
        button.accessibilityIdentifier = "appleLoginButton"
        return button
    }
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        button.isEnabled = enabled
        button.alpha = enabled ? 1 : 0.45
    }
    final class Coordinator: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func signIn() { action() }
    }
}

@available(iOS 16.0, *)
struct KikiLoginView: View {
    @EnvironmentObject private var store: KikiAppStore
    @EnvironmentObject private var consent: KikiConsentStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var errorMessage: String?
    @State private var reading: KikiLegalBundle.Document?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 60)
                    VStack(spacing: 22) {
                        Image("KikiLaunchMark")
                            .resizable().scaledToFit().frame(width: 84, height: 84)
                            .accessibilityHidden(true)
                        Text("听见同频的你")
                            .font(.title.weight(.semibold)).foregroundStyle(KikiPalette.text)
                            .accessibilityAddTraits(.isHeader)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 80)
                    VStack(spacing: 16) {
                        if let message = errorMessage ?? store.loadingError {
                            Label(message, systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(KikiPalette.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }
                        KikiAppleLoginButton(enabled: !store.isSigningIn && !store.isEndingSession && consent.hasCurrentConsent,
                                             action: signIn)
                            .id(colorScheme).frame(height: 54)
                        if store.isSigningIn || store.isEndingSession {
                            HStack(spacing: 8) { ProgressView(); Text("正在登录…") }
                                .font(.footnote).foregroundStyle(KikiPalette.secondary)
                        }
                    }
                    Spacer(minLength: 28)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { documentLink("terms", title: "《用户协议》"); documentLink("privacy", title: "《隐私政策》") }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(spacing: 0) { documentLink("terms", title: "《用户协议》"); documentLink("privacy", title: "《隐私政策》") }
                    }
                }
                .frame(maxWidth: 420)
                .frame(minHeight: max(0, geometry.size.height - 64))
                .padding(.horizontal, 28).padding(.vertical, 32)
                .frame(maxWidth: .infinity)
            }
        }
        .background(KikiPalette.background.ignoresSafeArea())
        .sheet(item: $reading) { KikiLegalDocumentReader(document: $0) }
    }

    private func documentLink(_ id: String, title: String) -> some View {
        Button(title) { reading = consent.documents?.documents.first(where: { $0.id == id }) }
            .buttonStyle(.plain).font(.caption).foregroundStyle(KikiPalette.muted)
            .frame(minHeight: 44).disabled(consent.documents == nil)
            .accessibilityIdentifier("legal-\(id)")
    }

    private func signIn() {
        guard consent.hasCurrentConsent, !store.isSigningIn, !store.isEndingSession else { return }
        errorMessage = nil
        Task {
            do { try await store.loginWithApple() }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

@available(iOS 16.0, *)
struct KikiNicknameOnboardingView: View {
    @EnvironmentObject private var store: KikiAppStore
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
            }
            .padding(.horizontal, 28).padding(.bottom, 30)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
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
