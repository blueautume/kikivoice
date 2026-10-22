import SwiftUI
import UIKit

enum KikiSettingsDestination: String, CaseIterable, Identifiable {
    case account, notifications, privacy, rating, about, help

    var id: String { rawValue }

    fileprivate var title: String {
        switch self {
        case .account: return "账户"
        case .notifications: return "通知"
        case .privacy: return "隐私中心"
        case .rating: return "给 KikiTalk 评分"
        case .about: return "关于 KikiTalk"
        case .help: return "帮助与反馈"
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .account: return "person.crop.circle.fill"
        case .notifications: return "bell.fill"
        case .privacy: return "checkmark.shield.fill"
        case .rating: return "star.fill"
        case .about: return "info.circle.fill"
        case .help: return "questionmark.circle.fill"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .account: return Color(hex: 0xA52AFF)
        case .notifications, .privacy: return Color(hex: 0x7953FF)
        case .rating, .about: return Color(hex: 0x06B8C8)
        case .help: return Color(hex: 0x00C995)
        }
    }
}

/// Shared content for the settings destination; navigation belongs to its host.
@available(iOS 16.0, *)
struct KikiSettingsMenuContent: View {
    let onSelect: (KikiSettingsDestination) -> Void

    private let groups: [[KikiSettingsDestination]] = [
        [.account], [.notifications, .privacy], [.rating, .about], [.help]
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(groups.indices, id: \.self) { groupIndex in
                    let destinations = groups[groupIndex]
                    VStack(spacing: 0) {
                        ForEach(destinations) { destination in
                            menuRow(destination)
                            if destination != destinations.last {
                                Divider()
                                    .overlay(KikiPalette.elevated.opacity(0.45))
                                    .padding(.leading, 16)
                                    .padding(.trailing, 16)
                            }
                        }
                    }
                    .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 17))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(KikiPalette.background.ignoresSafeArea())
    }

    private func menuRow(_ destination: KikiSettingsDestination) -> some View {
        Button {
            guard destination != .rating else { return }
            onSelect(destination)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(destination.tint)
                    .frame(width: 34, height: 34)
                    .background(destination.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                Text(destination.title)
                    .font(.body)
                    .foregroundStyle(KikiPalette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(destination == .rating ? KikiPalette.muted : KikiPalette.text)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(destination == .rating)
        .accessibilityIdentifier("settings.\(destination.rawValue)")
        .accessibilityHint(destination == .rating ? "上架后开放" : "")
    }
}

/// Account display and action affordances. The host owns authentication and confirmations.
@available(iOS 16.0, *)
struct KikiAccountSettingsContent: View {
    let userID: String
    let appleIDBound: Bool
    let isLoggingOut: Bool
    let onLogout: () -> Void
    let onDelete: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 0) {
                        accountRow(title: "Kiki ID") {
                            Text(userID)
                                .textSelection(.enabled)
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = userID
                                    } label: {
                                        Label("复制 Kiki ID", systemImage: "doc.on.doc")
                                    }
                                }
                                .accessibilityIdentifier("settings.kikiID")
                        }
                        Divider()
                            .overlay(KikiPalette.elevated.opacity(0.45))
                            .padding(.horizontal, 16)
                        accountRow(title: "Apple ID") {
                            Text(appleIDBound ? "已绑定" : "未确认")
                                .accessibilityIdentifier("settings.appleID")
                        }
                    }
                    .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 17))

                    Button {
                        guard !isLoggingOut else { return }
                        onLogout()
                    } label: {
                        HStack(spacing: 9) {
                            if isLoggingOut {
                                ProgressView().tint(KikiPalette.secondary)
                            }
                            Text(isLoggingOut ? "正在退出…" : "退出登录")
                                .font(.body.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(KikiPalette.text)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .frame(minHeight: 56)
                        .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 17))
                        .contentShape(RoundedRectangle(cornerRadius: 17))
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoggingOut)
                    .accessibilityIdentifier("logoutButton")

                    Spacer(minLength: 64)

                    Button {
                        guard !isLoggingOut else { return }
                        onDelete()
                    } label: {
                        Text("删除账户")
                            .font(.subheadline)
                            .foregroundStyle(KikiPalette.muted)
                            .padding(.horizontal, 24)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoggingOut)
                    .accessibilityIdentifier("deleteAccountButton")
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(minHeight: max(0, geometry.size.height))
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .background(KikiPalette.background.ignoresSafeArea())
    }

    @ViewBuilder
    private func accountRow<Value: View>(title: String, @ViewBuilder value: () -> Value) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
        layout {
            Text(title)
                .foregroundStyle(KikiPalette.text)
                .fixedSize(horizontal: true, vertical: false)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            value()
                .foregroundStyle(KikiPalette.secondary)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
    }
}
