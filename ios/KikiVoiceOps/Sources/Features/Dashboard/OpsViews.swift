import SwiftUI
import UIKit

struct OpsRootView: View {
    @ObservedObject var store: OpsStore
    @StateObject private var social: OpsSocialModerationStore
    init(store: OpsStore) {
        self.store = store
        _social = StateObject(wrappedValue: OpsSocialModerationStore(parent: store))
    }
    var body: some View {
        Group {
            if !store.authenticated { PasskeyLoginView(store: store) }
            else if store.needsName { OpsNameSetupView(store: store) }
            else {
                VStack(spacing: 0) {
                    Picker("管理服务", selection: Binding(get: { store.service }, set: { store.selectService($0) })) {
                        ForEach(OpsService.allCases) { service in Text(service.title).tag(service) }
                    }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8)
                        .accessibilityIdentifier("adminServiceSelector")
                    if !store.canAccessSelectedService { OpsPendingAuthorizationView(store: store) }
                    else if store.service == .community {
                        TabView {
                            NavigationStack { OpsCommunityView(store: store) }
                                .tabItem { Label("语聊举报", systemImage: "waveform") }
                            NavigationStack { OpsSocialModerationView(parent: store, store: social) }
                                .tabItem { Label("社交举报", systemImage: "text.bubble") }
                            NavigationStack { ServicesView(store: store) }
                                .tabItem { Label("服务与会话", systemImage: "server.rack") }
                        }.id(store.service)
                    }
                    else {
                        TabView {
                            NavigationStack {
                                if store.service == .voice { OverviewView(store: store) }
                                else { AccountOverviewView(store: store) }
                            }.tabItem { Label("运营概览", systemImage: "chart.bar.xaxis") }
                            NavigationStack {
                                if store.service == .voice { InfrastructureView(store: store) }
                                else { AccountInfrastructureView(store: store) }
                            }.tabItem { Label("服务运维", systemImage: "waveform.path.ecg") }
                            if store.service == .voice {
                                NavigationStack { OpsIncidentsView(store: store) }
                                    .tabItem { Label("问题记录", systemImage: "exclamationmark.bubble") }
                            }
                            NavigationStack { ServicesView(store: store) }
                                .tabItem { Label("服务与会话", systemImage: "server.rack") }
                        }.id(store.service)
                    }
                }
            }
        }.onChange(of: store.socialContextRevision) { _, _ in social.invalidate() }
    }
}

private struct OpsPrivacyLink: View {
    var body: some View {
        Link("运维账户隐私说明", destination: URL(string: "https://kiki.group/ops/privacy/")!)
            .font(.footnote).accessibilityIdentifier("opsPrivacyLink")
    }
}

private struct PasskeyLoginView: View {
    @ObservedObject var store: OpsStore
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "person.badge.key.fill").font(.system(size: 56)).foregroundStyle(.indigo)
                    Text("Kiki 运维").font(.largeTitle.bold())
                    Text("使用通行密钥登录运维账户").font(.title3).foregroundStyle(.secondary)
                    OpsCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("系统安全验证", systemImage: "key.fill").font(.headline)
                            Text("通过系统通行密钥登录。已同步到 iCloud 钥匙串的通行密钥可在你的其他设备使用。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("新账户默认没有任何服务权限。登录后填写名字，并将唯一编号提供给管理员授权。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let error = store.error { ErrorNote(text: error) }
                            if store.isRestoring { ProgressView("正在确认管理会话…") }
                            Button { Task { await store.login(create: false) } } label: {
                                Label(store.isLoggingIn ? "正在等待系统验证…" : "使用通行密钥登录", systemImage: "person.badge.key.fill")
                                    .frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).controlSize(.large)
                                .disabled(store.isLoggingIn || store.isRestoring).accessibilityIdentifier("opsPasskeySignIn")
                            Button { Task { await store.login(create: true) } } label: {
                                Text("创建运维账户与通行密钥").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).controlSize(.large)
                                .disabled(store.isLoggingIn || store.isRestoring).accessibilityIdentifier("opsPasskeyRegister")
                            if store.hasSavedSession && !store.isRestoring {
                                Button("重新确认已保存会话") { Task { await store.refresh() } }
                            }
                            OpsPrivacyLink()
                        }
                    }
                    Text("运维账户独立于 Kiki 的 Apple 登录账户。通行密钥私钥与 Face ID 数据由系统管理，应用不会读取。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24).padding(.top, 36)
            }.background(Color(.systemGroupedBackground))
        }
    }
}

private struct OpsIdentityCard: View {
    let account: OpsAccount
    var body: some View {
        OpsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(account.name ?? "尚未设置名字").font(.title3.bold())
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("唯一编号").font(.caption).foregroundStyle(.secondary)
                        Text(account.id).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            .accessibilityIdentifier("opsIdentityID")
                    }
                    Spacer(minLength: 8)
                    Button { UIPasteboard.general.string = account.id } label: { Label("复制", systemImage: "doc.on.doc") }
                        .font(.footnote).accessibilityIdentifier("opsCopyIdentity")
                }
            }
        }
    }
}

private struct OpsNameSetupView: View {
    @ObservedObject var store: OpsStore
    @State private var name = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("设置你的名字").font(.largeTitle.bold())
                    Text("名字可以相同，唯一编号不会重复。管理员会核对名字与编号后单独授权。")
                        .foregroundStyle(.secondary)
                    if let account = store.account { OpsIdentityCard(account: account) }
                    OpsCard {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("1–32 字的名字", text: $name).textContentType(.name)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("opsDisplayName")
                            if let error = store.error { ErrorNote(text: error) }
                            Button { Task { await store.saveName(name) } } label: {
                                HStack { if store.isSavingName { ProgressView() }; Text("保存名字") }.frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).disabled(store.isSavingName || OpsAccount.validName(name) == nil)
                                .accessibilityIdentifier("opsSaveName")
                        }
                    }
                    OpsPrivacyLink()
                    Button("退出管理账户", role: .destructive) { store.logout() }
                }.padding(24)
            }.background(Color(.systemGroupedBackground))
        }
    }
}

struct OpsPendingAuthorizationView: View {
    @ObservedObject var store: OpsStore
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let account = store.account {
                        OpsIdentityCard(account: account)
                        ForEach(OpsService.allCases) { service in
                            let allowed = account.permissions.permits(service)
                            OpsCard {
                                HStack {
                                    Label(service.title, systemImage: allowed ? "checkmark.shield" : "lock.fill")
                                    Spacer()
                                    Text(allowed ? "已授权" : "待授权").foregroundStyle(allowed ? .green : .secondary)
                                }
                            }.accessibilityIdentifier("opsPermission.\(service.rawValue)")
                        }
                    }
                    if let error = store.error { ErrorNote(text: error) }
                    Button("刷新授权状态") { Task { await store.refresh() } }.buttonStyle(.borderedProminent)
                        .disabled(store.isRefreshing).accessibilityIdentifier("opsRefreshPermissions")
                    Button("退出管理账户", role: .destructive) { store.logout() }
                }.padding(16)
            }.background(Color(.systemGroupedBackground)).navigationTitle("\(store.service.title)待授权")
        }
    }
}

struct OverviewView: View {
    @ObservedObject var store: OpsStore
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        DashboardScroll(store: store, title: "语聊运营") {
            if let data = store.dashboard {
                SectionHeading(title: "此刻", subtitle: "语聊服务 · furby.top")
                LazyVGrid(columns: columns, spacing: 12) {
                    MetricCard("在线房间", value: String(data.operations.activeRooms), symbol: "rectangle.3.group")
                    MetricCard("实际在线人数", value: data.capacity.sfuStale ? "未知" : OpsFormat.count(data.capacity.activeParticipants), symbol: "person.2")
                    MetricCard("今日新建房间", value: String(data.operations.roomsCreatedToday), symbol: "plus.rectangle.on.rectangle")
                    MetricCard("今日参与身份", value: String(data.operations.participatingIdentitiesToday), symbol: "person.crop.circle")
                }
                OpsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("统计口径", systemImage: "info.circle").font(.subheadline.bold())
                        Text("今日按 \(data.operations.timeZone) · \(data.operations.day) 统计。")
                        Text(data.operations.identityMetricNote)
                        Text("账号数据请切换至账号服务；以上不是账号 DAU。")
                        if data.capacity.sfuStale { Text("SFU 在线采样暂不可用，实际人数显示未知。") }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                AlertCard(alerts: data.alerts)
                if let summary = data.incidents {
                    OpsIncidentSummaryView(summary: summary)
                    NavigationLink("查看问题记录") { OpsIncidentsView(store: store) }.font(.subheadline)
                }
                if let activity = data.operations.activity {
                    OpsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("语聊活跃与社区").font(.headline)
                            DataRow("今日活跃 / 回访", value: "\(activity.activeUsersToday) / \(activity.returningUsersToday)")
                            DataRow("当前去重在线", value: OpsFormat.count(activity.onlineUsersNow))
                            DataRow("今日上麦次数", value: String(activity.micSeatJoinsToday))
                            DataRow("今日累计停留", value: OpsFormat.uptime(activity.roomStaySecondsToday))
                            DataRow("今日举报 / 待处理", value: "\(activity.reportsToday) / \(activity.pendingReports)")
                            Text(activity.note).font(.caption).foregroundStyle(.secondary)
                            Text("统计起始：\(Date(timeIntervalSince1970: activity.trackingSince).formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                SectionHeading(title: "活动房间", subtitle: "\(data.rooms.count) 个 · 只读")
                if data.rooms.isEmpty {
                    OpsCard {
                        ContentUnavailableView("暂无活动房间", systemImage: "bubble.left.and.bubble.right", description: Text("房间创建后会在这里展示。"))
                    }
                } else {
                    ForEach(data.rooms) { room in RoomCard(room: room) }
                }
                OpsCard {
                    VStack(spacing: 12) {
                        DataRow("今日结束房间", value: String(data.operations.roomsEndedToday))
                        DataRow("累计创建房间", value: String(data.operations.totalRooms))
                        DataRow("累计参与身份", value: String(data.operations.totalParticipatingIdentities))
                        if let since = data.operations.roomEndTrackingSince {
                            Text("结束房间统计始于 \(OpsFormat.date(since))，早期历史未追补。")
                                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}

struct InfrastructureView: View {
    @ObservedObject var store: OpsStore

    var body: some View {
        DashboardScroll(store: store, title: "语聊运维") {
            if let data = store.dashboard {
                AlertCard(alerts: data.alerts)
                SectionHeading(title: "容量与健康", subtitle: "语聊服务器 · 保护上限不等于实测容量")
                OpsCard {
                    VStack(spacing: 14) {
                        CapacityBar(title: "活动房间", used: data.capacity.activeRooms, maximum: data.capacity.maxRooms)
                        CapacityBar(title: "入场名额", used: data.capacity.admittedParticipants, maximum: data.capacity.maxParticipantsTotal)
                        DataRow("每房人数上限", value: "\(data.capacity.maxParticipantsPerRoom) 人")
                        DataRow("实际在线人数", value: data.capacity.sfuStale ? "未知" : OpsFormat.count(data.capacity.activeParticipants))
                        Text("入场名额包含已获准但尚未连上的成员，区别于实际在线人数。")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        HealthRow(name: "语聊 API", state: data.health.api)
                        HealthRow(name: "媒体服务", state: data.health.sfu)
                        DataRow("待处理媒体清理", value: String(data.health.pendingMediaCleanup))
                    }
                }
                BackupStatusCard(maintenance: data.maintenance)
                SectionHeading(title: "服务器资源", subtitle: data.infrastructure.stale ? "历史采样 \(OpsFormat.date(data.infrastructure.sampledAt)) · 已过期或未就绪" : "采样于 \(OpsFormat.date(data.infrastructure.sampledAt))")
                OpsCard {
                    VStack(spacing: 14) {
                        DataRow("CPU", value: OpsFormat.percent(data.infrastructure.cpuPercent))
                        DataRow("CPU 核心", value: OpsFormat.count(data.infrastructure.cpuCores))
                        DataRow("内存", value: OpsFormat.usage(data.infrastructure.memoryUsedBytes, data.infrastructure.memoryTotalBytes, percent: data.infrastructure.memoryPercent))
                        DataRow("磁盘", value: OpsFormat.usage(data.infrastructure.diskUsedBytes, data.infrastructure.diskTotalBytes, percent: data.infrastructure.diskPercent))
                        DataRow("网络接收", value: OpsFormat.rate(data.infrastructure.networkReceiveBytesPerSecond))
                        DataRow("网络发送", value: OpsFormat.rate(data.infrastructure.networkTransmitBytesPerSecond))
                        DataRow("服务器运行", value: OpsFormat.uptime(data.infrastructure.uptimeSeconds))
                        DataRow("证书剩余", value: data.infrastructure.certificateDaysRemaining.map { "\(Int($0.rounded(.down))) 天" } ?? "未知")
                        DataRow("证书到期", value: OpsFormat.date(data.infrastructure.certificateExpiresAt))
                        Divider()
                        ForEach(data.infrastructure.services) { service in HealthRow(name: service.name, state: service.state) }
                        Text("主机指标约每 10 秒采样。CPU 与网络速率需要两次采样；未知值不按零计算。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SectionHeading(title: "连接质量", subtitle: "最近 \(data.connections.windowSeconds / 60) 分钟 · 进程内统计")
                OpsCard {
                    VStack(spacing: 14) {
                        DataRow("信令接入成功率", value: OpsFormat.percent(data.connections.successPercent))
                        DataRow("接入尝试 / 接受", value: "\(data.connections.attempts) / \(data.connections.accepted)")
                        DataRow("拒绝 / 重连", value: "\(data.connections.rejected) / \(data.connections.reconnects)")
                        DataRow("活动信令", value: String(data.connections.activeSignals))
                        DataRow("握手时长 P50", value: OpsFormat.milliseconds(data.connections.handshakeMsP50))
                        Text(data.connections.sampleNote).font(.caption).foregroundStyle(.secondary)
                        Divider()
                        DataRow("音频质量样本", value: String(data.quality.samples))
                        DataRow("较差与丢失占比", value: OpsFormat.percent(data.quality.poorPercent))
                        DataRow("优秀 / 良好", value: "\(data.quality.excellent) / \(data.quality.good)")
                        DataRow("较差 / 丢失 / 未知", value: "\(data.quality.poor) / \(data.quality.lost) / \(data.quality.unknown)")
                        DataRow("往返延迟 P50", value: OpsFormat.milliseconds(data.quality.rttMsP50))
                        DataRow("抖动 P50", value: OpsFormat.milliseconds(data.quality.jitterMsP50))
                        DataRow("丢包率 P50", value: OpsFormat.percent(data.quality.packetLossPercentP50))
                        Text(data.quality.sampleNote ?? "最近 1000 条、最长 5 分钟的设备上报样本；未知质量也计入样本数，不代表已验证的音质。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct AccountOverviewView: View {
    @ObservedObject var store: OpsStore
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        DashboardScroll(store: store, title: "账号运营") {
            if let data = store.accountDashboard {
                SectionHeading(title: "账号与登录", subtitle: "\(data.operations.timeZone) · \(data.operations.day)")
                LazyVGrid(columns: columns, spacing: 12) {
                    MetricCard("总账号", value: String(data.operations.totalAccounts), symbol: "person.2")
                    MetricCard("今日新建账号", value: String(data.operations.accountsCreatedToday), symbol: "person.badge.plus")
                    MetricCard("持有效会话账号", value: String(data.operations.accountsWithValidSessions), symbol: "person.crop.circle.badge.checkmark")
                    MetricCard("有效业务会话", value: String(data.operations.validBusinessSessions), symbol: "key.horizontal")
                }
                AlertCard(alerts: data.alerts)
                OpsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        DataRow("今日新建有效会话账号", value: String(data.operations.accountsWithSessionsCreatedToday))
                        Text(data.operations.sessionMetricNote).font(.caption).foregroundStyle(.secondary)
                        Text(data.voiceService.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let activity = data.operations.activity {
                    OpsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("账号真实活跃").font(.headline)
                            DataRow("今日活跃账号", value: String(activity.activeAccountsToday))
                            DataRow("今日回访账号", value: String(activity.returningAccountsToday))
                            Text(activity.note).font(.caption).foregroundStyle(.secondary)
                            Text("统计起始：\(Date(timeIntervalSince1970: activity.trackingSince).formatted(date: .abbreviated, time: .shortened)) · 行为记录保留 \(activity.retentionDays) 天")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if let social = data.operations.social {
                    OpsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("社区使用").font(.headline)
                            DataRow("关注关系 / 互关对", value: "\(social.follows) / \(social.mutualPairs)")
                            DataRow("近 30 天私聊消息", value: String(social.messagesLast30Days))
                            DataRow("待处理社交举报", value: String(social.pendingReports))
                            DataRow("有效社交禁言", value: String(social.activePostingRestrictions))
                            Text(social.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                SectionHeading(title: "Apple 授权", subtitle: "只展示汇总数量")
                OpsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        DataRow("保存授权凭据的账号", value: String(data.operations.appleAuthorizedAccounts))
                        DataRow("待撤销授权", value: String(data.operations.pendingAppleRevocations))
                        DataRow("已到重试时间", value: String(data.operations.dueAppleRevocations))
                        Text(data.operations.appleMetricNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
                SectionHeading(title: "存储", subtitle: "账号服务器本地数据")
                OpsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        DataRow("使用自定义头像的账号", value: String(data.operations.accountsWithCustomAvatar))
                        DataRow("头像文件", value: data.storage.avatarFiles.map { String(Int($0)) } ?? "未知")
                        DataRow("头像占用", value: OpsFormat.bytes(data.storage.avatarBytes))
                        DataRow("数据库占用", value: OpsFormat.bytes(data.storage.databaseBytes))
                        Text(data.storage.sampleNote).font(.caption).foregroundStyle(.secondary)
                        if data.storage.avatarScanLimited { Text("头像扫描已达上限，数量与占用暂不可用。").font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
        }
    }
}

struct AccountInfrastructureView: View {
    @ObservedObject var store: OpsStore
    var body: some View {
        DashboardScroll(store: store, title: "账号运维") {
            if let data = store.accountDashboard {
                AlertCard(alerts: data.alerts)
                OpsCard { HealthRow(name: "账号 API", state: data.health.api) }
                OpsPushStatusCard(summary: data.push)
                SectionHeading(title: "账号服务器资源", subtitle: data.infrastructure.stale ? "采样未就绪或已过期" : "采样于 \(OpsFormat.date(data.infrastructure.sampledAt))")
                HostResourceCard(data: data.infrastructure)
                BackupStatusCard(maintenance: data.maintenance)
            }
        }
    }
}

struct OpsPushStatusCard: View {
    let summary: OpsPushSummary?
    var body: some View {
        OpsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("系统通知", systemImage: "bell.badge").font(.headline)
                if let summary {
                    DataRow("服务配置", value: summary.configured ? "已配置" : "尚未配置")
                    DataRow("发送开关", value: summary.enabled ? "已开启" : "已停用")
                    DataRow("有效设备绑定", value: String(summary.activeDevices))
                    DataRow("待发送", value: String(summary.pending))
                    DataRow("APNs 已接收 · 24 小时", value: String(summary.accepted))
                    DataRow("最终失败 · 24 小时", value: String(summary.failed))
                    Text("设备绑定数量不表示在线人数。APNs 接收表示 Apple 已接受请求，不能据此确认设备已显示或用户已读。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !summary.recentFailures.isEmpty {
                        Text("最近失败").font(.subheadline.bold()).padding(.top, 4)
                        ForEach(Array(summary.recentFailures.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.message).font(.caption).foregroundStyle(.orange)
                                Text(Date(timeIntervalSince1970: Double(item.occurredAt)).formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("尚未收到系统通知状态。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.accessibilityIdentifier("accountPushStatus")
    }
}

private struct HostResourceCard: View {
    let data: OpsDashboard.Infrastructure
    var body: some View {
        OpsCard {
            VStack(spacing: 14) {
                DataRow("CPU", value: OpsFormat.percent(data.cpuPercent))
                DataRow("CPU 核心", value: OpsFormat.count(data.cpuCores))
                DataRow("内存", value: OpsFormat.usage(data.memoryUsedBytes, data.memoryTotalBytes, percent: data.memoryPercent))
                DataRow("磁盘", value: OpsFormat.usage(data.diskUsedBytes, data.diskTotalBytes, percent: data.diskPercent))
                DataRow("网络接收", value: OpsFormat.rate(data.networkReceiveBytesPerSecond))
                DataRow("网络发送", value: OpsFormat.rate(data.networkTransmitBytesPerSecond))
                DataRow("服务器运行", value: OpsFormat.uptime(data.uptimeSeconds))
                DataRow("证书剩余", value: data.certificateDaysRemaining.map { "\(Int($0.rounded(.down))) 天" } ?? "未知")
                DataRow("证书到期", value: OpsFormat.date(data.certificateExpiresAt))
                Divider()
                ForEach(data.services) { service in HealthRow(name: service.name, state: service.state) }
                Text("仅采集 kiki.group 所在主机；约每 10 秒采样。未知值不按零计算。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ServicesView: View {
    @ObservedObject var store: OpsStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let account = store.account { OpsIdentityCard(account: account) }
                SectionHeading(title: "当前服务", subtitle: store.service == .community ? "独立授权的社区处置" : "只读运营管理")
                OpsCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(store.service.title, systemImage: store.service == .voice ? "waveform" : "person.crop.circle").font(.headline)
                        DataRow("数据来源", value: store.service.hostLabel)
                        DataRow("权限", value: store.service == .community ? "举报查看与处置" : "只读查看")
                        DataRow("会话到期", value: store.sessionExpiresAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "未知")
                        Text("统一运维身份通过 kiki.group 验证。账号看板、语聊看板、社区管理分别授权；社区处置仅针对语聊服务。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                OpsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("通行密钥与隐私").font(.headline)
                        Text("通行密钥由系统管理与同步；管理会话只保存在本机安全存储。本应用不读取生物识别数据，不请求麦克风、通讯录或定位权限。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        OpsPrivacyLink()
                        Button("退出管理账户", role: .destructive) { store.logout() }
                            .buttonStyle(.bordered).accessibilityIdentifier("adminLogout")
                    }
                }
            }.padding(16)
        }.background(Color(.systemGroupedBackground)).navigationTitle("服务与会话")
    }
}

private struct DashboardScroll<Content: View>: View {
    @ObservedObject var store: OpsStore
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(store.service.title) · \(store.service.hostLabel)", systemImage: "server.rack").font(.subheadline.bold())
                        Text(store.lastUpdated.map { "最近更新 \($0.formatted(date: .omitted, time: .standard))" } ?? "尚未获取数据")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                }
                if let error = store.error {
                    ErrorNote(text: error + (store.lastUpdated == nil ? "" : "\n当前保留上次成功获取的数据。"))
                }
                if store.dashboard == nil && store.accountDashboard == nil {
                    OpsCard {
                        ContentUnavailableView("等待看板数据", systemImage: "chart.bar.doc.horizontal", description: Text("前台每 15 秒刷新，也可下拉重试。"))
                    }
                }
                content()
                Text("前台每 15 秒刷新 · 后台暂停 · 只读看板")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(16)
        }.background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                        .disabled(store.isRefreshing).accessibilityIdentifier("adminRefresh")
                }
            }
            .refreshable { await store.refresh() }
    }
}

private struct RoomCard: View {
    let room: OpsDashboard.Room
    var body: some View {
        OpsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(room.title).font(.headline).lineLimit(2)
                    Spacer()
                    Text(room.category).font(.caption).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.indigo.opacity(0.08), in: Capsule()).foregroundStyle(.indigo)
                }
                DataRow("在线 / 已入场", value: "\(room.sfuStale ? "未知" : OpsFormat.count(room.onlineParticipants)) / \(room.admittedParticipants)")
                DataRow("麦位", value: "\(room.occupiedSeats) / \(room.totalSeats)")
                DataRow("房主 / 管理员 / 听众", value: "\(room.owners) / \(room.admins) / \(room.listeners)")
                DataRow("禁麦 / 禁言", value: "\(room.audioMutedMembers) / \(room.chatMutedMembers)")
                Text("创建于 \(Date(timeIntervalSince1970: room.createdAt).formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AlertCard: View {
    let alerts: [OpsDashboard.Alert]
    var body: some View {
        OpsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(alerts.isEmpty ? "当前没有告警" : "需要关注", systemImage: alerts.isEmpty ? "checkmark.shield" : "exclamationmark.triangle")
                    .font(.subheadline.bold()).foregroundStyle(alerts.isEmpty ? .green : .orange)
                ForEach(alerts) { alert in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(alert.level == "critical" ? Color.red : alert.level == "warning" ? Color.orange : Color.blue)
                            .frame(width: 6, height: 6).padding(.top, 6)
                        Text(alert.message).font(.subheadline)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct OpsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct SectionHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 4)
    }
}

private struct MetricCard: View {
    let title, value, symbol: String
    init(_ title: String, value: String, symbol: String) { self.title = title; self.value = value; self.symbol = symbol }
    var body: some View {
        OpsCard {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.indigo)
                Text(value).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct DataRow: View {
    let title, value: String
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }.font(.subheadline).accessibilityElement(children: .combine)
    }
}

private struct CapacityBar: View {
    let title: String
    let used, maximum: Int
    var body: some View {
        VStack(spacing: 7) {
            DataRow(title, value: "\(used) / \(maximum)")
            ProgressView(value: maximum > 0 ? min(Double(used) / Double(maximum), 1) : 0)
                .tint(maximum > 0 && Double(used) / Double(maximum) >= 0.8 ? .orange : .indigo)
        }
    }
}

private struct HealthRow: View {
    let name, state: String
    private var presentation: (String, Color) {
        switch state {
        case "active", "healthy", "ok": ("正常", .green)
        case "inactive", "failed", "unhealthy", "unavailable", "error": ("异常", .red)
        default: ("未知", .secondary)
        }
    }
    var body: some View {
        HStack {
            Text(name).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Label(presentation.0, systemImage: presentation.0 == "正常" ? "checkmark.circle.fill" : "circle.fill")
                .font(.subheadline).foregroundStyle(presentation.1)
        }.accessibilityElement(children: .combine)
    }
}

private struct ErrorNote: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.subheadline).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

enum OpsFormat {
    static func count(_ value: Int?) -> String { value.map(String.init) ?? "未知" }
    static func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "未知" }
    static func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "未知" }
    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "未知" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, Double(Int64.max - 1024))), countStyle: .binary)
    }
    static func rate(_ value: Double?) -> String { value.map { bytes($0) + "/s" } ?? "未知" }
    static func usage(_ used: Double?, _ total: Double?, percent: Double?) -> String {
        guard used != nil, total != nil else { return "未知" }
        return "\(bytes(used)) / \(bytes(total)) · \(self.percent(percent))"
    }
    static func date(_ string: String?) -> String {
        guard let string else { return "未知" }
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: string)
        if date == nil { formatter.formatOptions.insert(.withFractionalSeconds); date = formatter.date(from: string) }
        return date?.formatted(date: .abbreviated, time: .shortened) ?? "未知"
    }
    static func uptime(_ seconds: Double?) -> String {
        guard let seconds else { return "未知" }
        let hours = Int(seconds / 3600)
        return hours >= 24 ? "\(hours / 24) 天 \(hours % 24) 小时" : "\(hours) 小时"
    }
}

private struct BackupStatusCard: View {
    let maintenance: OpsMaintenance?
    var body: some View {
        OpsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("数据备份与副本校验", systemImage: "externaldrive.badge.checkmark").font(.headline)
                if let backup = maintenance?.backup {
                    DataRow("状态", value: backup.healthy.map { $0 ? "正常" : "需要处理" } ?? "尚无校验记录")
                    DataRow("最近成功", value: date(backup.lastSuccessAt))
                    DataRow("副本恢复校验", value: date(backup.verifiedAt))
                    DataRow("日常备份保留", value: "\(backup.retentionDays) 天")
                    if let message = backup.lastError { Text(message).font(.caption).foregroundStyle(.orange) }
                    Text("每日在本机生成一致性快照，并复制到隔离目录校验数据库及文件；不覆盖在线数据。同机备份无法抵御整台服务器丢失。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("尚未收到备份状态，不能据此判断已有可恢复备份。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func date(_ value: Double?) -> String {
        value.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "未知"
    }
}
