import SwiftUI
import UIKit

@available(iOS 16.0, *)
struct KikiConsentGateView: View {
    @EnvironmentObject private var consent: KikiConsentStore
    @State private var reading: KikiLegalBundle.Document?
    @State private var errorMessage: String?
    @State private var hasDeclined = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 32)
                    VStack(alignment: .leading, spacing: 25) {
                        Image("KikiLaunchMark")
                            .resizable().scaledToFit()
                            .frame(width: 76, height: 76)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("欢迎来到 Kiki")
                                .font(.largeTitle.bold())
                                .accessibilityAddTraits(.isHeader)
                            Text("在开始聊天前，先了解我们如何保护你的个人信息。")
                                .font(.subheadline).lineSpacing(5)
                                .foregroundStyle(KikiPalette.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        Text("我们使用必要的账号资料提供中文语聊、私聊服务。同意后会先检查网络并申请消息通知权限；麦克风和相册仅在使用相关功能时申请。")
                        Text("我们会联网获取最新协议；未联网时，你可以阅读已保存的完整文本。同意前，账号、语聊和系统通知服务不会启用。")
                    }
                    .font(.subheadline).lineSpacing(6)
                    .foregroundStyle(KikiPalette.secondary)
                    .padding(.top, 32)
                    VStack(alignment: .leading, spacing: 12) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 18) { primaryLinks }
                            VStack(alignment: .leading, spacing: 12) { primaryLinks }
                        }
                        HStack(spacing: 18) {
                            documentButton("sdk", title: "第三方 SDK 清单")
                            documentButton("permissions", title: "权限说明")
                        }
                        .font(.caption)
                    }
                    .padding(.top, 24)
                    Spacer(minLength: 36)
                    VStack(alignment: .leading, spacing: 18) {
                        Text("点击“同意并继续”，表示你已阅读并同意《用户协议》和《隐私政策》，并确认已满 18 周岁。")
                            .font(.caption).lineSpacing(5)
                            .foregroundStyle(KikiPalette.secondary)
                            .accessibilityIdentifier("consentAdultDisclosure")
                        if consent.isRefreshingDocuments {
                            HStack(spacing: 10) {
                                ProgressView().tint(KikiPalette.lavender)
                                Text("正在获取最新协议…")
                                    .font(.footnote).foregroundStyle(KikiPalette.secondary)
                            }
                            .accessibilityIdentifier("legalDocumentsLoading")
                        } else if let documentError = consent.documentError {
                            message(documentError)
                            refreshDocumentsButton
                        } else if !consent.hasVerifiedRemoteDocuments {
                            message("请联网获取最新协议，阅读后即可确认同意。")
                            refreshDocumentsButton
                        }
                        if let errorMessage { message(errorMessage) }
                        if let notice = consent.notice { message(notice) }
                        if hasDeclined {
                            Text("你可以留在此页阅读协议，服务会保持关闭。")
                                .font(.footnote).foregroundStyle(KikiPalette.secondary)
                                .accessibilityIdentifier("privacyDeclinedNotice")
                        }
                        Button {
                            do { try consent.accept() }
                            catch { errorMessage = error.localizedDescription }
                        } label: {
                            Text("同意并继续")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 17)
                                .background(KikiPalette.action, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .disabled(!consent.canAccept)
                        .opacity(consent.canAccept ? 1 : 0.45)
                        .accessibilityIdentifier("acceptPrivacyGate")
                        Button("暂不同意") {
                            errorMessage = nil
                            hasDeclined = true
                        }
                        .font(.subheadline).foregroundStyle(KikiPalette.secondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .accessibilityIdentifier("declinePrivacyGate")
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: 480)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
            }
        }
        .background(KikiPalette.background.ignoresSafeArea())
        .foregroundStyle(KikiPalette.text)
        .accessibilityIdentifier("privacyConsentPage")
        .sheet(item: $reading) { KikiLegalDocumentReader(document: $0) }
        .onChange(of: consent.documents?.versions) { _ in
            reading = nil
            errorMessage = nil
        }
    }

    @ViewBuilder private var primaryLinks: some View {
        documentButton("terms", title: "《用户协议》")
        documentButton("privacy", title: "《隐私政策》")
    }

    private func documentButton(_ id: String, title: String) -> some View {
        Button(title) {
            reading = consent.documents?.documents.first(where: { $0.id == id })
        }
        .buttonStyle(.plain)
        .foregroundStyle(KikiPalette.lavender)
        .disabled(consent.documents == nil)
        .accessibilityIdentifier("legal-\(id)")
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.footnote).lineSpacing(5)
            .foregroundStyle(KikiPalette.lavender)
    }

    private var refreshDocumentsButton: some View {
        Button("重试获取最新协议") {
            errorMessage = nil
            Task {
                guard !consent.serviceTransitionInProgress, !consent.isWithdrawalPending else { return }
                await consent.refreshDocuments()
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(KikiPalette.lavender)
        .disabled(consent.isRefreshingDocuments || consent.serviceTransitionInProgress)
        .accessibilityIdentifier("retryLegalDocuments")
    }
}

@available(iOS 16.0, *)
struct KikiLocalLegalLinks: View {
    @EnvironmentObject private var consent: KikiConsentStore
    @State private var reading: KikiLegalBundle.Document?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(consent.documents?.documents ?? []) { document in
                Button { reading = document } label: {
                    HStack {
                        Text(document.title).font(.system(size: 14))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11))
                    }.foregroundStyle(KikiPalette.text).padding(16).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("legal-\(document.id)")
                if document.id != consent.documents?.documents.last?.id {
                    Divider().overlay(KikiPalette.elevated).padding(.horizontal, 16)
                }
            }
        }.background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 17))
            .sheet(item: $reading) { KikiLegalDocumentReader(document: $0) }
            .onChange(of: consent.documents?.versions) { _ in reading = nil }
    }
}

@available(iOS 16.0, *)
struct KikiLegalDocumentReader: View {
    let document: KikiLegalBundle.Document
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(document.title).font(.system(size: 26, weight: .bold))
                    Text("版本 \(document.version) · 完整协议文本")
                        .font(.system(size: 12)).foregroundStyle(KikiPalette.secondary)
                    ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(section.title).font(.system(size: 18, weight: .semibold))
                            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph).font(.system(size: 14)).lineSpacing(7)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(KikiPalette.background.ignoresSafeArea())
            .navigationTitle(document.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(KikiPalette.lavender).foregroundStyle(KikiPalette.text)
    }
}

@available(iOS 16.0, *)
struct KikiWithdrawalPendingView: View {
    @EnvironmentObject private var consent: KikiConsentStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 42)).foregroundStyle(KikiPalette.lavender)
                    Text("撤回正在处理中").font(.system(size: 28, weight: .bold))
                    Text("已停止本机业务服务。完成当前房间和音视频退出、并收到服务器撤回确认后，才会清除本机同意记录。")
                        .font(.system(size: 14)).lineSpacing(7).foregroundStyle(KikiPalette.secondary)
                    if let error = consent.withdrawalError {
                        Text(error).font(.system(size: 13)).lineSpacing(6).foregroundStyle(Color(hex: 0xFFAFBD))
                    }
                    Button { Task { await consent.retryWithdrawal() } } label: {
                        HStack {
                            if consent.withdrawalInProgress { ProgressView().tint(.white) }
                            Text(consent.withdrawalInProgress ? "正在停止服务并同步…" : "重试完成撤回")
                        }.font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).padding(18)
                            .background(KikiPalette.purple, in: RoundedRectangle(cornerRadius: 16))
                    }.disabled(consent.withdrawalInProgress).accessibilityIdentifier("retryPrivacyWithdrawal")
                    Text("处理期间不会恢复登录或重新连接房间。账号仍保留；撤回同意与注销账号是不同操作。")
                        .font(.system(size: 12)).lineSpacing(5).foregroundStyle(KikiPalette.muted)
                    if let email = consent.documents?.operator.email {
                        Text("如持续无法确认撤回结果，请联系 \(email)。")
                            .font(.system(size: 12)).foregroundStyle(KikiPalette.secondary).textSelection(.enabled)
                    }
                    KikiLocalLegalLinks()
                }
                .padding(26).padding(.top, 25)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }.background(KikiPalette.background.ignoresSafeArea())
                .navigationTitle("撤回同意").navigationBarTitleDisplayMode(.inline)
        }
    }
}

@available(iOS 16.0, *)
struct KikiPrivacyCenter: View {
    @EnvironmentObject private var store: KikiAppStore
    @EnvironmentObject private var consent: KikiConsentStore
    @Environment(\.dismiss) private var dismiss
    @State private var status: KikiLegalStatus?
    @State private var statusError: String?
    @State private var confirmWithdrawal = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("你的资料，你来掌握").font(.system(size: 25, weight: .semibold))
                    KikiLocalLegalLinks()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("协议确认记录").font(.system(size: 17, weight: .semibold))
                        Text("隐私政策：\(consent.documents?.privacyVersion ?? "无法读取")")
                        Text("用户协议：\(consent.documents?.termsVersion ?? "无法读取")")
                        if let acceptedAt = consent.receipt?.acceptedAt {
                            Text("本机确认：\(acceptedAt.formatted(date: .numeric, time: .shortened))")
                        }
                        if let acceptedAt = status?.legalConsent?.acceptedAt {
                            Text("账号服务器记录：\(Date(timeIntervalSince1970: TimeInterval(acceptedAt)).formatted(date: .numeric, time: .shortened))")
                        } else if let statusError { Text("账号记录读取失败：\(statusError)") }
                        else { Text("正在读取账号服务器记录…") }
                        Text("成年确认由本人声明，不等同于实名或年龄核验。")
                    }.font(.system(size: 12)).foregroundStyle(KikiPalette.secondary).lineSpacing(5)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("系统权限").font(.system(size: 17, weight: .semibold)).foregroundStyle(KikiPalette.text)
                        Text("麦克风：\(microphoneStatus)。仅在开播或上麦时申请，用于向房间成员传送声音。")
                        Text("相册：使用系统照片选择器，仅访问你选中的头像。保存资料前不会上传照片。")
                        Button("打开系统设置管理权限") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.foregroundStyle(KikiPalette.lavender)
                    }.font(.system(size: 12)).lineSpacing(6).foregroundStyle(KikiPalette.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("撤回隐私同意").font(.system(size: 17, weight: .semibold))
                        Text("撤回将停止采集、退出或结束当前房间、退出音视频及所有业务会话，并返回本地协议阅读页。已有账号资料不会因此自动删除；删除账户入口在「设置 > 账户 > 删除账户」。")
                            .font(.system(size: 13)).lineSpacing(6).foregroundStyle(KikiPalette.secondary)
                        Button("撤回同意并退出") { confirmWithdrawal = true }
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: 0xFFAFBD))
                            .accessibilityIdentifier("withdrawPrivacyConsent")
                    }
                }
                .padding(24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }.background(KikiPalette.background.ignoresSafeArea())
                .navigationTitle("隐私中心").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { await refreshStatus() }
                .confirmationDialog("确认撤回隐私同意？", isPresented: $confirmWithdrawal, titleVisibility: .visible) {
                    Button("停止服务并撤回", role: .destructive) { Task { await store.withdrawConsent() } }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("当前房间会退出或结束。网络失败时将保留待处理状态，供你重试确认服务器已撤回。")
                }
        }.foregroundStyle(KikiPalette.text).tint(KikiPalette.lavender)
    }

    private func refreshStatus() async {
        do { status = try await store.legalStatus() }
        catch { statusError = error.localizedDescription }
    }

    private var microphoneStatus: String {
        KikiMicrophonePermission.description
    }

}
