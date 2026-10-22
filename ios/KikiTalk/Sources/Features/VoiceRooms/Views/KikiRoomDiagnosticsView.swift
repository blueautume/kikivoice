import LiveKit
import SwiftUI

struct KikiRoomDiagnosticsView: View {
    @ObservedObject var rtc: KikiRTCService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("当前连接") {
                    LabeledContent("连接状态", value: rtc.isRecovering ? "恢复并校准中" : (rtc.connectionState == .connected ? "已连接" : "已断开"))
                    LabeledContent("本机连接质量", value: rtc.connectionQuality.kikiLabel)
                    LabeledContent("本次入房重连次数", value: String(rtc.reconnectCount))
                    LabeledContent("媒体往返延迟", value: metric(rtc.networkMetrics.rttMs, suffix: " ms"))
                    LabeledContent("接收最大抖动", value: metric(rtc.networkMetrics.jitterMs, suffix: " ms"))
                    LabeledContent("接收累计丢包", value: metric(rtc.networkMetrics.packetLossPercent, suffix: "%"))
                    Text("指标来自本机 LiveKit 媒体统计；没有音频流或尚无报告时显示未采到，不代表零延迟或零丢包。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let incidentID = KikiIncidentReporter.shared.lastEventID {
                    Section("最近的问题编号") {
                        Text(incidentID).font(.footnote.monospaced()).textSelection(.enabled)
                        Text("联系管理员时可提供此编号。网络恢复后会自动补交问题记录。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("音频设备") {
                    LabeledContent("声音输出", value: rtc.audioState.output)
                    LabeledContent("声音输入", value: rtc.audioState.input)
                    LabeledContent("麦克风权限", value: KikiMicrophonePermission.description)
                    LabeledContent("本机麦克风", value: rtc.microphoneEnabled ? "已开启" : "已关闭")
                    Toggle("内置设备优先使用扬声器", isOn: Binding(get: { rtc.speakerPreferred }, set: rtc.setSpeakerPreferred))
                    HStack {
                        Text("选择音频输出")
                        Spacer()
                        KikiAudioRoutePicker().frame(width: 36, height: 36)
                    }
                    if let notice = rtc.audioState.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                    Text("耳机和蓝牙由系统选择。来电中断、设备断开或权限收回后，需手动开麦。锁屏和切后台可继续收听；系统仍可能限制网络及后台执行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("语聊服务 · 最近 5 分钟") {
                    Button { Task { await rtc.loadServerDiagnostics() } } label: {
                        HStack { Text("刷新服务器状态"); if rtc.isLoadingDiagnostics { Spacer(); ProgressView() } }
                    }.disabled(rtc.isLoadingDiagnostics)
                    if let value = rtc.serverDiagnostics {
                        LabeledContent("活跃房间", value: "\(count(value.capacity.activeRooms)) / \(count(value.capacity.maxRooms))")
                        LabeledContent("实际在线", value: count(value.capacity.activeParticipants))
                        LabeledContent("已占入房名额", value: "\(count(value.capacity.admittedParticipants)) / \(count(value.capacity.maxParticipantsTotal))")
                        LabeledContent("单房人数上限", value: count(value.capacity.maxParticipantsPerRoom))
                        LabeledContent("信令接受 / 拒绝", value: "\(value.connections.accepted) / \(value.connections.rejected)")
                        LabeledContent("信令握手中位数", value: metric(value.connections.handshakeMsP50, suffix: " ms"))
                        LabeledContent("质量样本", value: String(value.quality.samples))
                        LabeledContent("较差 / 丢失样本", value: "\(value.quality.poor) / \(value.quality.lost)")
                        LabeledContent("样本延迟中位数", value: metric(value.quality.rttMsP50, suffix: " ms"))
                        ForEach(value.alerts) { alert in Text(alert.message).font(.caption).foregroundStyle(.orange) }
                        Text("容量为当前保护配置，不是压测容量。质量为登录房内客户端自报的去标识短期聚合。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = rtc.diagnosticsError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
            }
            .scrollContentBackground(.hidden).background(Color(hex: 0x241747))
            .navigationTitle("连接与音频").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(Color(hex: 0xB69AFF))
    }

    private func metric(_ value: Double?, suffix: String) -> String {
        guard let value, value.isFinite else { return "未采到" }
        return String(format: "%.1f", value) + suffix
    }
    private func count(_ value: Int?) -> String { value.map(String.init) ?? "未知" }
}
