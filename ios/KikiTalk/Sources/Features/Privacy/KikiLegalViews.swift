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
                    HStack {
                        Spacer()
                        Menu {
                            Picker(KikiL10n.text("语言"), selection: Binding(
                                get: { KikiLanguageSettings.shared.selection },
                                set: { KikiLanguageSettings.shared.selection = $0 }
                            )) {
                                ForEach(KikiAppLanguage.allCases) { language in
                                    Text(language.title).tag(language)
                                }
                            }
                        } label: {
                            Label(KikiLanguageSettings.shared.selection.title, systemImage: "globe")
                                .font(.footnote).foregroundStyle(KikiPalette.lavender)
                        }.accessibilityIdentifier("consentLanguageSelector")
                    }
                    Spacer(minLength: 32)
                    VStack(alignment: .leading, spacing: 25) {
                        Image("KikiLaunchMark")
                            .resizable().scaledToFit()
                            .frame(width: 76, height: 76)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(KikiL10n.text("欢迎来到 Kiki"))
                                .font(.largeTitle.bold())
                                .accessibilityAddTraits(.isHeader)
                            Text(KikiL10n.text("在开始聊天前，先了解我们如何保护你的个人信息。"))
                                .font(.subheadline).lineSpacing(5)
                                .foregroundStyle(KikiPalette.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        Text(KikiL10n.text("我们使用必要的账号资料提供中文语聊、私聊服务。同意后会先检查网络并申请消息通知权限；麦克风和相册仅在使用相关功能时申请。"))
                        Text(KikiL10n.text("已填写的八字资料用于关系计算，MBTI 和生日生成的星座会公开展示。出生资料和四柱仅本人可见，其他人只能看到八字关系结果。"))
                            .accessibilityIdentifier("consentRelationshipDisclosure")
                        Text(KikiL10n.text("我们会联网获取最新协议；未联网时，你可以阅读已保存的完整文本。同意前，账号、语聊和系统通知服务不会启用。"))
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
                        Text(KikiL10n.text("点击“同意并继续”，表示你已阅读并同意《用户协议》《隐私政策》及上述关系资料使用方式，并确认已满 18 周岁。"))
                            .font(.caption).lineSpacing(5)
                            .foregroundStyle(KikiPalette.secondary)
                            .accessibilityIdentifier("consentAdultDisclosure")
                        if consent.isRefreshingDocuments {
                            HStack(spacing: 10) {
                                ProgressView().tint(KikiPalette.lavender)
                                Text(KikiL10n.text("正在获取最新协议…"))
                                    .font(.footnote).foregroundStyle(KikiPalette.secondary)
                            }
                            .accessibilityIdentifier("legalDocumentsLoading")
                        } else if let documentError = consent.documentError {
                            message(documentError)
                            refreshDocumentsButton
                        } else if !consent.hasVerifiedRemoteDocuments {
                            message("请联网获取最新协议，阅读后即可确认同意。")
                            refreshDocumentsButton
                        } else if KikiL10n.isEnglish && !consent.hasCurrentEnglish {
                            message("完整英文协议暂不可用，请联网重试。")
                            refreshDocumentsButton
                        }
                        if let errorMessage { message(errorMessage) }
                        if let notice = consent.notice { message(notice) }
                        if hasDeclined {
                            Text(KikiL10n.text("你可以留在此页阅读协议，服务会保持关闭。"))
                                .font(.footnote).foregroundStyle(KikiPalette.secondary)
                                .accessibilityIdentifier("privacyDeclinedNotice")
                        }
                        Button {
                            do { try consent.accept() }
                            catch { errorMessage = error.localizedDescription }
                        } label: {
                            Text(KikiL10n.text("同意并继续"))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 17)
                                .background(KikiPalette.action, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .disabled(!consent.canAccept)
                        .opacity(consent.canAccept ? 1 : 0.45)
                        .accessibilityIdentifier("acceptPrivacyGate")
                        Button(KikiL10n.text("暂不同意")) {
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
        Button(KikiL10n.text(title)) {
            reading = consent.documents?.documents.first(where: { $0.id == id })
        }
        .buttonStyle(.plain)
        .foregroundStyle(KikiPalette.lavender)
        .disabled(consent.documents == nil || (KikiL10n.isEnglish && !consent.hasCurrentEnglish))
        .accessibilityIdentifier("legal-\(id)")
    }

    private func message(_ text: String) -> some View {
        Text(KikiL10n.text(text)).font(.footnote).lineSpacing(5)
            .foregroundStyle(KikiPalette.lavender)
    }

    private var refreshDocumentsButton: some View {
        Button(KikiL10n.text("重试获取最新协议")) {
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
            ForEach(consent.displayedDocuments) { document in
                Button { reading = document } label: {
                    HStack {
                        Text(document.title).font(.system(size: 14))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11))
                    }.foregroundStyle(KikiPalette.text).padding(16).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("legal-\(document.id)")
                if document.id != consent.displayedDocuments.last?.id {
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
    @EnvironmentObject private var consent: KikiConsentStore
    @Environment(\.dismiss) private var dismiss
    private var displayedDocument: KikiLegalBundle.Document? { consent.displayedDocument(document) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(displayedDocument?.title ?? KikiL10n.text("完整英文协议暂不可用，请联网重试。")).font(.system(size: 26, weight: .bold))
                    Text(KikiL10n.format("版本 %@ · 完整协议文本", document.version))
                        .font(.system(size: 12)).foregroundStyle(KikiPalette.secondary)
                    ForEach(Array((displayedDocument?.sections ?? []).enumerated()), id: \.offset) { _, section in
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
            .navigationTitle(displayedDocument?.title ?? KikiL10n.text("权限说明")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(KikiL10n.text("完成")) { dismiss() } } }
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
                    Text(KikiL10n.text("撤回正在处理中")).font(.system(size: 28, weight: .bold))
                    Text(KikiL10n.text("已停止本机业务服务。完成当前房间和音视频退出、并收到服务器撤回确认后，才会清除本机同意记录。"))
                        .font(.system(size: 14)).lineSpacing(7).foregroundStyle(KikiPalette.secondary)
                    if let error = consent.withdrawalError {
                        Text(KikiL10n.text(error)).font(.system(size: 13)).lineSpacing(6).foregroundStyle(Color(hex: 0xFFAFBD))
                    }
                    Button { Task { await consent.retryWithdrawal() } } label: {
                        HStack {
                            if consent.withdrawalInProgress { ProgressView().tint(.white) }
                            Text(KikiL10n.text(consent.withdrawalInProgress ? "正在停止服务并同步…" : "重试完成撤回"))
                        }.font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).padding(18)
                            .background(KikiPalette.purple, in: RoundedRectangle(cornerRadius: 16))
                    }.disabled(consent.withdrawalInProgress).accessibilityIdentifier("retryPrivacyWithdrawal")
                    Text(KikiL10n.text("处理期间不会恢复登录或重新连接房间。账号仍保留；撤回同意与注销账号是不同操作。"))
                        .font(.system(size: 12)).lineSpacing(5).foregroundStyle(KikiPalette.muted)
                    if let email = consent.documents?.operator.email {
                        Text(KikiL10n.format("如持续无法确认撤回结果，请联系 %@。", email))
                            .font(.system(size: 12)).foregroundStyle(KikiPalette.secondary).textSelection(.enabled)
                    }
                    KikiLocalLegalLinks()
                }
                .padding(26).padding(.top, 25)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }.background(KikiPalette.background.ignoresSafeArea())
                .navigationTitle(KikiL10n.text("撤回同意")).navigationBarTitleDisplayMode(.inline)
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
                    Text(KikiL10n.text("你的资料，你来掌握")).font(.system(size: 25, weight: .semibold))
                    KikiLocalLegalLinks()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(KikiL10n.text("协议确认记录")).font(.system(size: 17, weight: .semibold))
                        Text(KikiL10n.format("隐私政策：%@", consent.documents?.privacyVersion ?? KikiL10n.text("无法读取")))
                        Text(KikiL10n.format("用户协议：%@", consent.documents?.termsVersion ?? KikiL10n.text("无法读取")))
                        if let acceptedAt = consent.receipt?.acceptedAt {
                            Text(KikiL10n.format("本机确认：%@", acceptedAt.formatted(.dateTime.locale(KikiL10n.locale))))
                        }
                        if let acceptedAt = status?.legalConsent?.acceptedAt {
                            Text(KikiL10n.format("账号服务器记录：%@", Date(timeIntervalSince1970: TimeInterval(acceptedAt)).formatted(.dateTime.locale(KikiL10n.locale))))
                        } else if let statusError { Text(KikiL10n.format("账号记录读取失败：%@", KikiL10n.text(statusError))) }
                        else { Text(KikiL10n.text("正在读取账号服务器记录…")) }
                        Text(KikiL10n.text("成年确认由本人声明，不等同于实名或年龄核验。"))
                    }.font(.system(size: 12)).foregroundStyle(KikiPalette.secondary).lineSpacing(5)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(KikiL10n.text("系统权限")).font(.system(size: 17, weight: .semibold)).foregroundStyle(KikiPalette.text)
                        Text(KikiL10n.format("麦克风：%@。仅在开播或上麦时申请，用于向房间成员传送声音。", KikiL10n.text(microphoneStatus)))
                        Text(KikiL10n.text("相册：使用系统照片选择器，仅访问你选中的头像。保存资料前不会上传照片。"))
                        Button(KikiL10n.text("打开系统设置管理权限")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.foregroundStyle(KikiPalette.lavender)
                    }.font(.system(size: 12)).lineSpacing(6).foregroundStyle(KikiPalette.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(KikiL10n.text("撤回隐私同意")).font(.system(size: 17, weight: .semibold))
                        Text(KikiL10n.text("撤回将停止采集、退出或结束当前房间、退出音视频及所有业务会话，并返回本地协议阅读页。已有账号资料不会因此自动删除；删除账户入口在「设置 > 账户 > 删除账户」。"))
                            .font(.system(size: 13)).lineSpacing(6).foregroundStyle(KikiPalette.secondary)
                        Button(KikiL10n.text("撤回同意并退出")) { confirmWithdrawal = true }
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: 0xFFAFBD))
                            .accessibilityIdentifier("withdrawPrivacyConsent")
                    }
                }
                .padding(24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }.background(KikiPalette.background.ignoresSafeArea())
                .navigationTitle(KikiL10n.text("隐私中心")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(KikiL10n.text("完成")) { dismiss() } } }
                .task { await refreshStatus() }
                .confirmationDialog(KikiL10n.text("确认撤回隐私同意？"), isPresented: $confirmWithdrawal, titleVisibility: .visible) {
                    Button(KikiL10n.text("停止服务并撤回"), role: .destructive) { Task { await store.withdrawConsent() } }
                    Button(KikiL10n.text("取消"), role: .cancel) {}
                } message: {
                    Text(KikiL10n.text("当前房间会退出或结束。网络失败时将保留待处理状态，供你重试确认服务器已撤回。"))
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
