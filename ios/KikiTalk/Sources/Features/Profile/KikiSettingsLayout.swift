import SwiftUI
import UIKit

enum KikiSettingsDestination: String, CaseIterable, Identifiable {
    case account, notifications, language, privacy, rating, about, help

    var id: String { rawValue }

    fileprivate var title: String {
        switch self {
        case .account: return KikiL10n.text("账户")
        case .notifications: return KikiL10n.text("通知")
        case .language: return KikiL10n.text("语言")
        case .privacy: return KikiL10n.text("隐私中心")
        case .rating: return KikiL10n.text("给 kikitalk 评分")
        case .about: return KikiL10n.text("关于 kikitalk")
        case .help: return KikiL10n.text("帮助与反馈")
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .account: return "person.crop.circle.fill"
        case .notifications: return "bell.fill"
        case .language: return "globe"
        case .privacy: return "checkmark.shield.fill"
        case .rating: return "star.fill"
        case .about: return "info.circle.fill"
        case .help: return "questionmark.circle.fill"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .account: return Color(hex: 0xA52AFF)
        case .notifications, .language, .privacy: return Color(hex: 0x7953FF)
        case .rating, .about: return Color(hex: 0x06B8C8)
        case .help: return Color(hex: 0x00C995)
        }
    }
}

/// Shared content for the settings destination; navigation belongs to its host.
@available(iOS 16.0, *)
struct KikiSettingsMenuContent: View {
    let onSelect: (KikiSettingsDestination) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let groups: [[KikiSettingsDestination]] = [
        [.account], [.notifications, .language, .privacy], [.rating, .about], [.help]
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
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { menuIcon(destination); Spacer(); menuChevron(destination) }
                        menuTitle(destination).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(spacing: 13) {
                        menuIcon(destination)
                        menuTitle(destination)
                        Spacer(minLength: 8)
                        menuChevron(destination)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(destination == .rating)
        .accessibilityIdentifier("settings.\(destination.rawValue)")
        .accessibilityHint(destination == .rating ? KikiL10n.text("上架后开放") : "")
    }

    private func menuTitle(_ destination: KikiSettingsDestination) -> some View {
        Text(destination.title)
            .font(.body)
            .foregroundStyle(KikiPalette.text)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func menuIcon(_ destination: KikiSettingsDestination) -> some View {
        Image(systemName: destination.symbol)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(destination.tint)
            .frame(width: 34, height: 34)
            .background(destination.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }

    private func menuChevron(_ destination: KikiSettingsDestination) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(destination == .rating ? KikiPalette.muted : KikiPalette.text)
            .accessibilityHidden(true)
    }
}

/// Changing language updates the existing view hierarchy and preserves sessions.
@available(iOS 16.0, *)
struct KikiLanguageSettingsContent: View {
    private let settings = KikiLanguageSettings.shared

    var body: some View {
        List {
            ForEach(KikiAppLanguage.allCases, id: \.rawValue) { language in
                Button {
                    settings.selection = language
                } label: {
                    HStack(spacing: 16) {
                        Text(language.title)
                            .foregroundStyle(KikiPalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if settings.selection == language {
                            Image(systemName: "checkmark")
                                .foregroundStyle(KikiPalette.purple)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.language." + language.rawValue)
                .accessibilityAddTraits(settings.selection == language ? .isSelected : [])
            }
        }
        .navigationTitle(KikiL10n.text("语言"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.language.options")
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
                        accountRow(title: "kikitalk ID") {
                            Text(userID)
                                .textSelection(.enabled)
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = userID
                                    } label: {
                                        Label(KikiL10n.text("复制 kikitalk ID"), systemImage: "doc.on.doc")
                                    }
                                }
                                .accessibilityIdentifier("settings.kikiID")
                        }
                        Divider()
                            .overlay(KikiPalette.elevated.opacity(0.45))
                            .padding(.horizontal, 16)
                        accountRow(title: "Apple ID") {
                            Text(appleIDBound ? KikiL10n.text("已绑定") : KikiL10n.text("未确认"))
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
                            Text(isLoggingOut ? KikiL10n.text("正在退出…") : KikiL10n.text("退出登录"))
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
                        Text(KikiL10n.text("删除账户"))
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
