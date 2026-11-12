import SwiftUI

/// Birth inputs and chart previews exist only in this account-owned editor.
/// Calendrical conversion, solar-time correction and pillars run on the server.
struct KikiRelationshipProfileView: View {
    @ObservedObject var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = KikiRelationshipProfileDraft()
    @State private var preview: KikiRelationshipProfile?
    @State private var placeName: String?
    @State private var placeZone: String?
    @State private var loaded = false
    @State private var loading = false
    @State private var saving = false
    @State private var calculating = false
    @State private var converting = false
    @State private var error: String?
    @State private var previewError: String?
    @State private var picker: PickerSheet?

    private enum PickerSheet: String, Identifiable {
        case date, time, place
        var id: String { rawValue }
    }
    private static let mbtiTypes = ["INTJ", "INTP", "ENTJ", "ENTP", "INFJ", "INFP", "ENFJ", "ENFP", "ISTJ", "ISFJ", "ESTJ", "ESFJ", "ISTP", "ISFP", "ESTP", "ESFP"]
    private static let zodiacSigns = ["白羊座", "金牛座", "双子座", "巨蟹座", "狮子座", "处女座", "天秤座", "天蝎座", "射手座", "摩羯座", "水瓶座", "双鱼座"]

    var body: some View {
        Form {
            if loading && !loaded {
                Section { HStack { Spacer(); ProgressView("正在读取资料…"); Spacer() }.padding(.vertical, 24) }
            }
            if loaded {
                publicSection
                privateSection
                chartSection
                participationSection
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(KikiPalette.warning)
                    if !loaded { Button("重新读取") { Task { await load() } } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(KikiPalette.background)
        .foregroundStyle(KikiPalette.text)
        .tint(KikiPalette.purple)
        .navigationTitle("关系资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await save() } } label: {
                    if saving { ProgressView() } else { Text("保存").fontWeight(.semibold) }
                }
                .disabled(!loaded || saving || converting)
                .accessibilityIdentifier("relationshipProfile.save")
            }
        }
        .interactiveDismissDisabled(saving)
        .disabled(saving)
        .task { await load() }
        .task(id: draft) { await updatePreview() }
        .onChange(of: store.socialPrivacyRevision) { _, _ in clearAndDismiss() }
        .onChange(of: store.isAuthenticated) { _, authenticated in if !authenticated { clearAndDismiss() } }
        .onDisappear {
            if picker == nil { clearPrivateState() }
        }
        .sheet(item: $picker) { sheet in
            NavigationStack {
                switch sheet {
                case .date:
                    KikiRelationshipDatePicker(calendar: draft.birthCalendar, value: draft.birthDate,
                                               leapMonth: draft.birthLeapMonth) { date, leap in
                        draft.birthDate = date; draft.birthLeapMonth = leap
                        draft.birthFold = nil; draft.zodiacSign = nil; picker = nil
                    }
                case .time:
                    KikiRelationshipTimePicker(value: draft.birthTime) { value in
                        draft.birthTime = value; draft.birthFold = nil; picker = nil
                    }
                case .place:
                    KikiRelationshipPlacePicker(store: store) { place in
                        draft.birthPlaceCode = place.id; draft.birthFold = nil
                        placeName = place.fullName; placeZone = place.timeZone; picker = nil
                    }
                }
            }
            .presentationDragIndicator(.visible)
        }
    }

    private var publicSection: some View {
        Section {
            Picker("MBTI", selection: $draft.mbtiType) {
                Text("未填写").tag(String?.none)
                ForEach(Self.mbtiTypes, id: \.self) { Text($0).tag(Optional($0)) }
            }.accessibilityIdentifier("relationshipProfile.mbti")
            if draft.birthDate == nil {
                Picker("星座", selection: $draft.zodiacSign) {
                    Text("未填写").tag(String?.none)
                    ForEach(Self.zodiacSigns, id: \.self) { Text($0).tag(Optional($0)) }
                }
            } else {
                LabeledContent("星座", value: preview?.zodiacSign ?? "根据生日生成")
            }
            Toggle("公开并参与 MBTI 关系", isOn: $draft.mbtiEnabled)
            Toggle("公开并参与星座关系", isOn: $draft.zodiacEnabled)
        } header: {
            Label("公开标签", systemImage: "person.crop.circle")
        } footer: {
            Text("开启对应选项后，已填写的 MBTI 和星座会显示在个人主页与房间。填写生日后，星座按原始公历生日自动生成；未填生日时可以单独选择。关系标签用于交流参考。")
        }
    }

    private var privateSection: some View {
        Section {
            editableRow("出生地", value: placeName, placeholder: "选择省、市、区县", identifier: "relationshipProfile.birthPlace") {
                picker = .place
            } clear: {
                draft.birthPlaceCode = nil; draft.birthFold = nil; placeName = nil; placeZone = nil
            }
            Picker("日期历法", selection: Binding(get: { draft.birthCalendar }, set: { value in
                Task { await changeCalendar(to: value) }
            })) {
                ForEach(KikiBirthCalendar.allCases) { Text($0.title).tag($0) }
            }.disabled(converting)
            editableRow("出生日期", value: dateLabel, placeholder: "选择出生日期", identifier: "relationshipProfile.birthDate") {
                picker = .date
            } clear: {
                draft.birthDate = nil; draft.birthLeapMonth = false; draft.birthFold = nil
            }
            editableRow("出生时刻", value: draft.birthTime, placeholder: "不清楚／尚未填写", identifier: "relationshipProfile.birthTime") {
                picker = .time
            } clear: {
                draft.birthTime = nil; draft.birthFold = nil
            }
            if let zone = preview?.birthTimeZone ?? placeZone {
                LabeledContent("出生地时区", value: zone).font(.footnote).foregroundStyle(KikiPalette.secondary)
            }
            DisclosureGroup("历史时制选项") {
                Picker("重复钟表时刻", selection: $draft.birthFold) {
                    Text("自动判断").tag(Int?.none)
                    Text("第一次出现").tag(Optional(0))
                    Text("第二次出现").tag(Optional(1))
                }
                Text("仅在夏令时结束导致同一钟点出现两次时使用。服务器会提示需要确认的情况。")
                    .font(.caption).foregroundStyle(KikiPalette.secondary)
            }
        } header: {
            Label("私密出生资料 · 仅本人可见", systemImage: "lock")
        } footer: {
            Text("请填写出生地当地的钟表时间，系统会在服务端换算真太阳时。出生地址、日期、时间、坐标与四柱不会发送给其他用户。时辰不清楚可以留空，资料允许部分保存。")
        }
    }

    private var chartSection: some View {
        Section {
            if calculating || converting {
                HStack(spacing: 10) { ProgressView(); Text(converting ? "正在换算日期…" : "正在生成预览…") }
                    .foregroundStyle(KikiPalette.secondary)
            } else if let chart = preview?.chart {
                if let pillars = chart.pillars, !pillars.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(pillars.joined(separator: "　")).font(.body.monospaced().weight(.medium))
                        if let time = chart.trueSolarTime { LabeledContent("真太阳时", value: time).font(.footnote) }
                        if let civil = chart.civilTime { LabeledContent("原始钟表时间", value: civil).font(.footnote) }
                    }
                    .accessibilityIdentifier("relationshipProfile.privateChart")
                } else {
                    Text(chart.message ?? "完善出生日期、时刻和出生地后自动生成。")
                        .font(.subheadline).foregroundStyle(KikiPalette.secondary)
                }
            } else {
                Text(previewError ?? "完善出生资料后，由服务端生成真太阳时八字。")
                    .font(.subheadline).foregroundStyle(KikiPalette.secondary)
            }
            if let previewError, preview?.chart != nil {
                Text(previewError).font(.caption).foregroundStyle(KikiPalette.warning)
            }
        } header: {
            Text("八字预览 · 仅本人可见")
        } footer: {
            Text("真太阳时定日、时柱；年、月柱按实际交节时刻判定。地区坐标为代表点，接近时辰或换日边界时请核对地点与原始时间。")
        }
    }

    private var participationSection: some View {
        Section {
            Toggle("参与八字关系计算", isOn: $draft.baziEnabled)
                .accessibilityIdentifier("relationshipProfile.baziEnabled")
        } header: {
            Text("房间关系")
        } footer: {
            Text("开启后，上麦时将计算你与其他参与者的八字关系。房间成员只能看到关系结果，不会看到你的出生资料和四柱。资料不完整时暂不生成结果；关闭后移除涉及你的八字关系。")
        }
    }

    private var dateLabel: String? {
        draft.birthDate.map { (draft.birthCalendar == .lunar && draft.birthLeapMonth ? "闰月 · " : "") + $0 }
    }

    private func editableRow(_ title: String, value: String?, placeholder: String, identifier: String,
                             action: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack {
                    Text(title).foregroundStyle(KikiPalette.text)
                    Spacer(minLength: 12)
                    Text(value ?? placeholder).foregroundStyle(value == nil ? KikiPalette.muted : KikiPalette.secondary)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(KikiPalette.muted)
                }
                .frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier(identifier)
            if value != nil {
                Button(action: clear) { Image(systemName: "xmark.circle.fill").foregroundStyle(KikiPalette.muted).frame(width: 32, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("清空\(title)").accessibilityIdentifier(identifier + ".clear")
            }
        }
    }

    private func load() async {
        guard !loading, !loaded else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let profile = try await store.loadRelationshipProfile()
            guard !Task.isCancelled else { return }
            draft = profile.draft; preview = profile
            placeName = profile.birthPlaceName; placeZone = profile.birthTimeZone; loaded = true
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func updatePreview() async {
        guard loaded, !saving, !converting else { return }
        let input = draft
        calculating = true; preview = nil; previewError = nil
        do {
            try await Task.sleep(nanoseconds: 400_000_000)
            let result = try await store.previewRelationshipProfile(input)
            guard !Task.isCancelled, draft == input else { return }
            preview = result; calculating = false
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, draft == input else { return }
            previewError = error.localizedDescription; calculating = false
        }
    }

    private func changeCalendar(to calendar: KikiBirthCalendar) async {
        guard calendar != draft.birthCalendar, !converting else { return }
        guard draft.birthDate != nil else { draft.birthCalendar = calendar; draft.birthLeapMonth = false; return }
        let input = draft
        converting = true; error = nil
        defer { converting = false }
        do {
            let result = try await store.previewRelationshipProfile(input)
            guard !Task.isCancelled, input == draft else { return }
            guard let converted = input.changingCalendar(to: calendar, using: result) else {
                throw KikiAPIError.server(422, "这个日期暂无法换算，请核对出生记录。")
            }
            converting = false
            draft = converted
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard loaded, !saving else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            _ = try await store.saveRelationshipProfile(draft)
            store.notify("关系资料已保存")
            dismiss()
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func clearAndDismiss() {
        clearPrivateState()
        dismiss()
    }

    private func clearPrivateState() {
        loaded = false; draft = .init(); preview = nil; placeName = nil; placeZone = nil
        calculating = false; converting = false; previewError = nil; error = nil
    }
}

private struct KikiRelationshipPlacePicker: View {
    @ObservedObject var store: KikiAppStore
    var parent: KikiRelationshipPlace? = nil
    let onSelect: (KikiRelationshipPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var places: [KikiRelationshipPlace] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            if let parent, parent.hasCoordinates {
                Section {
                    Button { onSelect(parent) } label: { Label("使用\(parent.fullName)", systemImage: "checkmark.circle") }
                } footer: { Text("地区坐标为代表点；选择区县可以进一步缩小地点范围。") }
            }
            Section {
                ForEach(places) { place in
                    if place.hasChildren {
                        NavigationLink(place.name) { KikiRelationshipPlacePicker(store: store, parent: place, onSelect: onSelect) }
                    } else {
                        Button { onSelect(place) } label: {
                            HStack { Text(place.name); Spacer(); if !place.hasCoordinates { Text("坐标待完善").font(.caption).foregroundStyle(KikiPalette.muted) } }
                        }.disabled(!place.hasCoordinates)
                    }
                }
                if loading { ProgressView("正在读取地区…") }
                if let error { Text(error).foregroundStyle(KikiPalette.warning); Button("重试") { Task { await load() } } }
            }
            if parent == nil {
                Section("地区数据与坐标来源") {
                    Text("行政区划：modood（WTFPL）；代表坐标及港澳台目录：GeoNames（CC BY 4.0）；补充坐标：Wikidata（CC0）。目录为固定版本，地区坐标并非详细出生地址。")
                        .font(.caption).foregroundStyle(KikiPalette.secondary)
                    Link("GeoNames 地理数据库", destination: URL(string: "https://www.geonames.org/")!)
                    Link("行政区划数据", destination: URL(string: "https://github.com/modood/Administrative-divisions-of-China")!)
                    Link("Wikidata 数据许可", destination: URL(string: "https://www.wikidata.org/wiki/Wikidata:Licensing")!)
                }
            }
        }
        .navigationTitle(parent?.name ?? "选择出生地")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if parent == nil { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } } }
        .task { await load() }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { places = try await store.relationshipPlaces(parent: parent?.id) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct KikiRelationshipDatePicker: View {
    let calendar: KikiBirthCalendar
    let value: String?
    let leapMonth: Bool
    let onSelect: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var gregorian = KikiRelationshipClock.date("1995-01-01")
    @State private var year = 1995
    @State private var month = 1
    @State private var day = 1
    @State private var leap = false

    var body: some View {
        Form {
            if calendar == .gregorian {
                DatePicker("出生日期", selection: $gregorian,
                           in: KikiRelationshipClock.date("1900-01-01")...KikiRelationshipClock.date("2100-12-31"),
                           displayedComponents: .date)
                    .datePickerStyle(.wheel).labelsHidden()
                    .environment(\.calendar, Calendar(identifier: .gregorian))
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            } else {
                Picker("农历年", selection: $year) { ForEach(1900...2100, id: \.self) { Text(String($0)).tag($0) } }
                Picker("农历月", selection: $month) { ForEach(1...12, id: \.self) { Text("\($0)月").tag($0) } }
                Picker("农历日", selection: $day) { ForEach(1...30, id: \.self) { Text("\($0)日").tag($0) } }
                Toggle("这是闰月", isOn: $leap)
                Text("请按出生记录选择闰月；日期和闰月由服务器核验并换算。")
                    .font(.footnote).foregroundStyle(KikiPalette.secondary)
            }
        }
        .navigationTitle("选择\(calendar.title)日期").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("确定") {
                    onSelect(calendar == .gregorian ? KikiRelationshipClock.string(gregorian, format: "yyyy-MM-dd") : String(format: "%04d-%02d-%02d", year, month, day), calendar == .lunar && leap)
                }
            }
        }
        .onAppear {
            if let value {
                gregorian = KikiRelationshipClock.date(value)
                let parts = value.split(separator: "-").compactMap { Int($0) }
                if parts.count == 3 { year = parts[0]; month = parts[1]; day = parts[2] }
            }
            leap = leapMonth
        }
    }
}

private struct KikiRelationshipTimePicker: View {
    let value: String?
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var time = KikiRelationshipClock.date("2000-01-01 09:00", format: "yyyy-MM-dd HH:mm")
    var body: some View {
        Form {
            DatePicker("当地钟表时刻", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel).labelsHidden()
                .environment(\.calendar, Calendar(identifier: .gregorian))
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            Text("填写记录中的当地钟表时间，无需自行换算真太阳时。不清楚时可以返回并留空。")
                .font(.footnote).foregroundStyle(KikiPalette.secondary)
        }
        .navigationTitle("出生时刻").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("确定") { onSelect(KikiRelationshipClock.string(time, format: "HH:mm")) } }
        }
        .onAppear { if let value { time = KikiRelationshipClock.date("2000-01-01 " + value, format: "yyyy-MM-dd HH:mm") } }
    }
}

/// Formats civil components for the controls; it never calculates a chart.
private enum KikiRelationshipClock {
    static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
    static func date(_ value: String, format: String = "yyyy-MM-dd") -> Date {
        formatter(format).date(from: value) ?? Date(timeIntervalSince1970: 0)
    }
    static func string(_ value: Date, format: String) -> String { formatter(format).string(from: value) }
}

struct KikiPublicRelationshipTags: View {
    let mbtiType: String?
    let zodiacSign: String?
    var body: some View {
        HStack(spacing: 8) {
            if let mbtiType { tag(mbtiType, symbol: "person.text.rectangle") }
            if let zodiacSign { tag(zodiacSign, symbol: "sparkles") }
        }
        .accessibilityElement(children: .combine)
    }
    private func tag(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption.weight(.medium))
            .foregroundStyle(KikiPalette.lavender).padding(.horizontal, 10).padding(.vertical, 6)
            .background(KikiPalette.purple.opacity(0.10), in: Capsule())
    }
}
