import AVFoundation
import SwiftUI
import UIKit

@available(iOS 16.0, *)
struct KikiAgreementChecks: View {
    @Binding var agreed: Bool
    @Binding var adultConfirmed: Bool
    @EnvironmentObject private var consent: KikiConsentStore
    @State private var reading: KikiLegalBundle.Document?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                checkButton($agreed, label: "同意用户协议与隐私政策", identifier: "agreeLegalCheckbox")
                VStack(alignment: .leading, spacing: 6) {
                    Text("我已阅读并同意").font(.system(size: 12))
                    HStack(spacing: 5) {
                        documentButton("terms", title: "《用户协议》")
                        Text("和").font(.system(size: 12))
                        documentButton("privacy", title: "《隐私政策》")
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                checkButton($adultConfirmed, label: "确认已满18周岁", identifier: "adultConfirmedCheckbox")
                Text("我确认已满 18 周岁。KikiTalk 暂仅向成年人开放。")
                    .font(.system(size: 12)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(KikiPalette.secondary)
        .sheet(item: $reading) { KikiLegalDocumentReader(document: $0) }
    }

    private func checkButton(_ value: Binding<Bool>, label: String, identifier: String) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            Image(systemName: value.wrappedValue ? "checkmark.square.fill" : "square")
                .font(.system(size: 22)).foregroundStyle(value.wrappedValue ? KikiPalette.lavender : KikiPalette.muted)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain).accessibilityLabel(label)
        .accessibilityValue(value.wrappedValue ? "已勾选" : "未勾选")
        .accessibilityIdentifier(identifier)
    }

    private func documentButton(_ id: String, title: String) -> some View {
        Button(title) { reading = consent.documents?.documents.first(where: { $0.id == id }) }
            .font(.system(size: 12)).foregroundStyle(KikiPalette.lavender)
            .disabled(consent.documents == nil)
    }
}

@available(iOS 16.0, *)
struct KikiConsentGateView: View {
    @EnvironmentObject private var consent: KikiConsentStore
    @State private var agreed = false
    @State private var adultConfirmed = false
    @State private var declined = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 48))
                        .foregroundStyle(KikiPalette.lavender).padding(.top, 30)
                    Text("先了解，再相遇").font(.system(size: 30, weight: .bold))
                    Text("欢迎使用 KikiTalk LiveKit 实验版。请先了解独立实验账号、公开资料及语音服务如何处理个人信息。")
                        .font(.system(size: 15)).lineSpacing(7).foregroundStyle(KikiPalette.secondary)
                    Text("同意前仅提供本地协议阅读，不登录账号、不连接音视频 SDK、不读取相册内容，也不会申请麦克风或摄像头权限。")
                        .font(.system(size: 13)).lineSpacing(6).foregroundStyle(KikiPalette.secondary)
                        .padding(17).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                    KikiLocalLegalLinks()
                    if consent.documents == nil {
                        message("本机协议文件缺失或无法验证，请重新安装最新版本后再使用。")
                    } else if consent.requiresAppUpdate {
                        message("服务器要求的协议版本或内容已更新。请更新 App，重新核对完整协议后再确认；当前版本无法继续登录。")
                    }
                    if let notice = consent.notice { message(notice) }
                    if declined { message("你可以留在此页离线阅读协议，稍后再决定。拒绝不会退出程序。") }
                    KikiAgreementChecks(agreed: $agreed, adultConfirmed: $adultConfirmed)
                    if let errorMessage { message(errorMessage) }
                    Button {
                        do { try consent.accept(agreed: agreed, adultConfirmed: adultConfirmed) }
                        catch { errorMessage = error.localizedDescription }
                    } label: {
                        Text("同意并继续").font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(18)
                            .background(KikiPalette.purple, in: RoundedRectangle(cornerRadius: 17))
                    }
                    .disabled(!agreed || !adultConfirmed || !consent.canAccept)
                    .opacity(agreed && adultConfirmed && consent.canAccept ? 1 : 0.45)
                    .accessibilityIdentifier("acceptPrivacyGate")
                    Button("暂不同意，继续阅读") { agreed = false; adultConfirmed = false; declined = true }
                        .frame(maxWidth: .infinity).font(.system(size: 13)).foregroundStyle(KikiPalette.secondary)
                        .accessibilityIdentifier("declinePrivacyGate")
                    Text("成年确认属于本人声明，不代表平台已完成实名或年龄核验。")
                        .font(.system(size: 10)).lineSpacing(4).foregroundStyle(KikiPalette.muted)
                }.padding(26)
            }
            .background(KikiPalette.background.ignoresSafeArea())
            .navigationTitle("隐私与用户协议").navigationBarTitleDisplayMode(.inline)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).lineSpacing(5).foregroundStyle(KikiPalette.lavender)
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
                    Text("版本 \(document.version) · 本地完整文本")
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
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(KikiPalette.background.ignoresSafeArea())
            .navigationTitle(document.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(KikiPalette.lavender).foregroundStyle(KikiPalette.text)
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
                }.padding(26).padding(.top, 25)
            }.background(KikiPalette.background.ignoresSafeArea())
                .navigationTitle("撤回同意").navigationBarTitleDisplayMode(.inline)
        }
    }
}

@available(iOS 16.0, *)
struct KikiPrivacyCenter: View {
    @EnvironmentObject private var store: KikiDemoStore
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
                        Text("麦克风：\(microphoneStatus)。仅在打开麦克风发言时申请，用于经自建 LiveKit 向房间成员传送声音。")
                        Text("摄像头：实验版未开放视频，不申请访问。")
                        Text("相册：实验版仅使用预设头像，不申请访问或上传照片。")
                        Button("打开系统设置管理权限") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.foregroundStyle(KikiPalette.lavender)
                    }.font(.system(size: 12)).lineSpacing(6).foregroundStyle(KikiPalette.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("撤回隐私同意").font(.system(size: 17, weight: .semibold))
                        Text("撤回将停止采集，让本人退出房间、音视频及所有业务会话，并返回本地协议阅读页。如果本人是房主，服务器会尝试向在线成员转交房主。已有账号资料不会因此自动删除；注销账号仍在「账号设置」。")
                            .font(.system(size: 13)).lineSpacing(6).foregroundStyle(KikiPalette.secondary)
                        Button("撤回同意并退出") { confirmWithdrawal = true }
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: 0xFFAFBD))
                            .accessibilityIdentifier("withdrawPrivacyConsent")
                    }
                }.padding(24)
            }.background(KikiPalette.background.ignoresSafeArea())
                .navigationTitle("隐私中心").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { await refreshStatus() }
                .confirmationDialog("确认撤回隐私同意？", isPresented: $confirmWithdrawal, titleVisibility: .visible) {
                    Button("停止服务并撤回", role: .destructive) { Task { await store.withdrawConsent() } }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("本人会退出当前房间；如果本人是房主，服务器会尝试向在线成员转交房主。网络失败时将保留待处理状态，供你重试确认服务器已撤回。")
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

    private var cameraStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "已允许"
        case .denied, .restricted: return "未允许"
        default: return "未申请"
        }
    }
}
