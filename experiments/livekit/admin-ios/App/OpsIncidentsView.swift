import SwiftUI

struct OpsIncidentSummaryView: View {
    let summary: OpsIncidentSummary
    var body: some View {
        OpsCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("近 24 小时问题", systemImage: "exclamationmark.bubble").font(.headline)
                HStack(alignment: .top, spacing: 8) {
                    counter("错误记录", summary.errorsLast24Hours, color: .red)
                    counter("警告记录", summary.warningsLast24Hours, color: .orange)
                    counter("创建/入房问题操作", summary.failedAttemptsLast24Hours, color: .indigo)
                }
                Text("创建和入房相关记录按账号＋操作编号去重。一项操作可有多侧证据或非致命警告，不能据此认定最终失败；没有全部尝试的分母，不提供失败率。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityIdentifier("opsIncidentSummary")
    }
    private func counter(_ title: String, _ value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(value)).font(.system(.title, design: .rounded).weight(.semibold)).foregroundStyle(color).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

struct OpsIncidentsView: View {
    @ObservedObject var store: OpsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var severity = OpsIncidentSeverity.all
    @State private var operation = OpsIncidentOperation.all
    @State private var userQuery = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary = store.dashboard?.incidents { OpsIncidentSummaryView(summary: summary) }
                else {
                    OpsCard { Text("服务器暂未提供问题统计。旧版本看板仍可正常使用。")
                        .font(.subheadline).foregroundStyle(.secondary) }
                }
                filterCard
                if let error = store.incidentError {
                    OpsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.subheadline)
                            Button("刷新记录") { Task { await store.loadIncidents() } }.buttonStyle(.bordered)
                        }
                    }.accessibilityIdentifier("opsIncidentError")
                }
                HStack {
                    Text("问题记录").font(.headline)
                    Spacer()
                    if let page = store.incidentPage { Text("已加载 \(page.events.count) 条").font(.caption).foregroundStyle(.secondary) }
                }
                if let page = store.incidentPage, !page.events.isEmpty {
                    ForEach(page.events) { incident in
                        NavigationLink { OpsIncidentDetailView(store: store, eventID: incident.eventID) } label: {
                            OpsIncidentRow(incident: incident)
                        }.buttonStyle(.plain).accessibilityIdentifier("opsIncident.\(incident.eventID)")
                    }
                    if page.nextCursor != nil {
                        Button { Task { await store.loadIncidents(loadMore: true) } } label: {
                            HStack { if store.isLoadingIncidents { ProgressView() }; Text("加载更多") }.frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).disabled(store.isLoadingIncidents).accessibilityIdentifier("opsIncidentLoadMore")
                    } else {
                        Text("已显示当前筛选下的全部记录").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                } else if store.isLoadingIncidents {
                    ProgressView("正在读取问题记录…").frame(maxWidth: .infinity).padding(24)
                } else if store.incidentPage != nil {
                    OpsCard {
                        ContentUnavailableView("当前筛选下没有记录", systemImage: "checkmark.bubble",
                            description: Text("没有记录只代表当前已收到的上报中没有匹配项；设备离线时可能稍后补报。"))
                    }.accessibilityIdentifier("opsIncidentEmpty")
                }
                retentionCard
            }.padding(16)
        }
        .background(Color(.systemGroupedBackground)).navigationTitle("语聊问题记录")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.loadIncidents() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.isLoadingIncidents).accessibilityLabel("刷新问题记录")
            }
        }
        .refreshable { await store.refresh(); await store.loadIncidents() }
        .task {
            severity = store.incidentFilter.severity; operation = store.incidentFilter.operation; userQuery = store.incidentFilter.userQuery
            if store.incidentPage == nil { await store.loadIncidents() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.loadIncidents() } }
        }
    }
    private var filterCard: some View {
        OpsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("筛选记录").font(.headline)
                TextField("用户昵称或公开编号", text: $userQuery)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    .submitLabel(.search).onSubmit { search() }.accessibilityIdentifier("opsIncidentUserQuery")
                HStack {
                    Picker("严重程度", selection: $severity) {
                        ForEach(OpsIncidentSeverity.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("opsIncidentSeverity")
                    Spacer()
                    Picker("操作", selection: $operation) {
                        ForEach(OpsIncidentOperation.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("opsIncidentOperation")
                }.pickerStyle(.menu)
                HStack {
                    Button("查询", action: search).buttonStyle(.borderedProminent).accessibilityIdentifier("opsIncidentSearch")
                    Button("重置") {
                        severity = .all; operation = .all; userQuery = ""; search()
                    }.buttonStyle(.bordered)
                    Spacer()
                    if store.isLoadingIncidents { ProgressView().controlSize(.small) }
                }
                if let date = store.incidentsUpdatedAt {
                    Text("更新于 \(date.formatted(date: .omitted, time: .standard)) · 按服务器收到时间倒序")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func search() {
        let filter = OpsIncidentFilter(severity: severity, operation: operation, userQuery: userQuery)
        Task { await store.loadIncidents(filter: filter) }
    }
    private var retentionCard: some View {
        OpsCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("记录范围", systemImage: "info.circle").font(.subheadline.bold())
                Text("只读查看语聊问题，使用语聊看板权限；账号授权阶段的问题也汇集到这里。")
                Text("最多保留 7 天、全局最近 10000 条。注销或撤回协议会清理相应记录；高频重复质量警告会合并。")
                Text("客户端、语聊服务器、账号服务器分别提供观测。同一故障可有多条证据，客户端超时不等于服务器没有完成操作。")
                Text("只记录允许的技术分类和公开账号信息，不展示原始错误、令牌、IP、消息或房间正文。")
                if let summary = store.dashboard?.incidents {
                    Text("开始记录：\(Date(timeIntervalSince1970: Double(summary.trackingSince)).formatted(date: .abbreviated, time: .shortened))；当前留存 \(summary.totalEvents) 条。")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct OpsIncidentRow: View {
    let incident: OpsIncident
    var body: some View {
        OpsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(incident.severity.title, systemImage: incident.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption.bold()).foregroundStyle(incident.severity == .error ? .red : .orange)
                    Text(incident.operation.title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                Text(incident.safeMessage).font(.headline).foregroundStyle(.primary)
                Text("\(incident.userName) · \(incident.stageTitle)").font(.subheadline).foregroundStyle(.secondary)
                Text(incident.userID).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text(incident.sourceTitle)
                    Spacer()
                    Text(Date(timeIntervalSince1970: Double(incident.occurredAt)), format: .dateTime.month().day().hour().minute().second())
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct OpsIncidentDetailView: View {
    @ObservedObject var store: OpsStore
    let eventID: String
    private var incident: OpsIncident? {
        guard store.authenticated, store.service == .voice, store.canAccessSelectedService else { return nil }
        return store.incidentPage?.events.first { $0.eventID == eventID }
            ?? store.dashboard?.incidents?.events.first { $0.eventID == eventID }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let incident {
                    OpsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(incident.severity.title, systemImage: "exclamationmark.bubble.fill")
                                .font(.headline).foregroundStyle(incident.severity == .error ? .red : .orange)
                            Text(incident.safeMessage).font(.title3.bold())
                            DataRow("操作", value: incident.operation.title)
                            DataRow("阶段", value: incident.stageTitle)
                            DataRow("来源", value: incident.sourceTitle)
                            Text("客户端超时表示未及时收到响应。应结合相同操作编号的服务器证据核对实际结果。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    OpsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("用户与设备").font(.headline)
                            DataRow("昵称", value: incident.userName)
                            identifier("公开账号编号", incident.userID)
                            DataRow("平台", value: incident.platformTitle)
                            DataRow("App 版本", value: incident.appVersion)
                            DataRow("系统版本", value: incident.osVersion)
                        }
                    }
                    OpsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("发生与接收").font(.headline)
                            DataRow("发生时间", value: date(incident.occurredAt))
                            DataRow("收到时间", value: date(incident.receivedAt))
                            DataRow("记录耗时", value: incident.elapsedMs.map { "\($0) ms" } ?? "未提供")
                            DataRow("HTTP 状态", value: incident.httpStatus.map(String.init) ?? "未提供")
                            Text("客户端为操作累计耗时，服务器为请求耗时。")
                                .font(.caption).foregroundStyle(.secondary)
                            if let room = incident.roomID { identifier("房间编号", room) }
                        }
                    }
                    OpsCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("关联问题").font(.headline)
                            identifier("操作编号 · 关联多侧证据", incident.attemptID)
                            identifier("事件编号 · 去重", incident.eventID)
                            identifier("服务请求编号", incident.requestID ?? "未提供")
                            identifier("技术分类", incident.code)
                            Text("以上为结构化诊断字段，不包含原始请求或错误正文。记录最多保留 7 天。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView("记录已不可用", systemImage: "lock.document",
                        description: Text("记录可能已刷新、到期或当前语聊查看权限已变化，请返回重新查询。"))
                }
            }.padding(16)
        }.background(Color(.systemGroupedBackground)).navigationTitle("问题详情").navigationBarTitleDisplayMode(.inline)
    }
    private func date(_ value: Int) -> String { Date(timeIntervalSince1970: Double(value)).formatted(date: .abbreviated, time: .standard) }
    private func identifier(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
