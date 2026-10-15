import SwiftUI
import PhotosUI
import ImageIO

@available(iOS 16.0, *)
struct KikiProfileView: View {
    @EnvironmentObject private var store: KikiDemoStore
    @State private var activeSheet: KikiProfileSheet?
    @State private var pendingRoom: DemoRoom?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                heading
                identity
                activity
                voiceCard
                library
                preferences
                footer
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 30)
        }
        .background(KikiPalette.background.ignoresSafeArea())
        .sheet(item: $activeSheet, onDismiss: openPendingRoom) { sheet in
            sheetContent(sheet)
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .presentationDragIndicator(.visible)
        }
        .task { await store.refreshLibrary() }
        .refreshable { await store.refreshLibrary() }
    }

    private var heading: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("我的空间")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(KikiPalette.secondary)
                Text("我")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(KikiPalette.text)
            }
            Spacer()
            Button {
                activeSheet = .settings
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(KikiPalette.text)
                    .frame(width: 46, height: 46)
                    .background(KikiPalette.surface, in: Circle())
            }
            .accessibilityLabel("打开设置")
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 17) {
                Button {
                    activeSheet = .edit
                } label: {
                    KikiAvatar(index: store.avatarIndex, size: 82, customURL: store.customAvatarURL)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "pencil")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 25, height: 25)
                                .background(KikiPalette.purple, in: Circle())
                                .overlay(Circle().stroke(KikiPalette.background, lineWidth: 3))
                        }
                }
                .accessibilityLabel("编辑头像与个人资料")

                VStack(alignment: .leading, spacing: 9) {
                    Text(store.profileName)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(KikiPalette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    HStack(spacing: 6) {
                        Circle().fill(KikiPalette.mint).frame(width: 6, height: 6)
                        Text("今天也想认识新朋友")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(KikiPalette.secondary)
                    }
                    Text("账号 ID · \(store.userID)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(KikiPalette.muted)
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 12) {
                Text(store.bio.isEmpty ? "写一句介绍，让同频的人找到你。" : store.bio)
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .foregroundStyle(KikiPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    activeSheet = .edit
                } label: {
                    Text("编辑资料")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(KikiPalette.lavender)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(KikiPalette.purple.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(KikiPalette.purple.opacity(0.24), lineWidth: 1))
                }
            }
        }
    }

    private var activity: some View {
        HStack(spacing: 0) {
            activityItem(value: store.favoriteRooms.count, title: "收藏房间", sheet: .favorites)
            Rectangle().fill(KikiPalette.elevated).frame(width: 1, height: 30)
            activityItem(value: store.recentRooms.count, title: "最近足迹", sheet: .history)
            Rectangle().fill(KikiPalette.elevated).frame(width: 1, height: 30)
            activityItem(value: store.createdRooms.count, title: "我的房间", sheet: .created)
        }
        .padding(.vertical, 18)
        .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 22))
    }

    private func activityItem(value: Int, title: String, sheet: KikiProfileSheet) -> some View {
        Button {
            activeSheet = sheet
        } label: {
            VStack(spacing: 7) {
                Text("\(value)")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(KikiPalette.text)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(KikiPalette.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(value) 个")
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                    Text("声音名片")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KikiPalette.lavender)
                Spacer()
                Text("与你同频")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(KikiPalette.lavender.opacity(0.55))
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("每个声音，\n都有自己的引力。")
                        .font(.system(size: 23, weight: .semibold))
                        .lineSpacing(4)
                        .foregroundStyle(.white)
                    Text("下一段有趣的对话，从这里开始")
                        .font(.system(size: 11))
                        .foregroundStyle(KikiPalette.lavender.opacity(0.7))
                }
                Spacer(minLength: 8)
                waveform
            }
            HStack(spacing: 8) {
                Label("此刻相遇，自在表达", systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(KikiPalette.lavender.opacity(0.8))
                Spacer(minLength: 0)
                Image(systemName: "sparkle")
                    .font(.system(size: 18))
                    .foregroundStyle(KikiPalette.lavender.opacity(0.6))
            }
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 25)
                .fill(LinearGradient(colors: [Color(hex: 0x302055), Color(hex: 0x1C1730)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 25)
                        .stroke(KikiPalette.lavender.opacity(0.16), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array([17.0, 33, 50, 29, 66, 43, 24].enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(LinearGradient(colors: [KikiPalette.lavender, KikiPalette.purple], startPoint: .top, endPoint: .bottom))
                    .frame(width: 5, height: height)
                    .opacity(index == 0 || index == 6 ? 0.45 : 0.9)
            }
        }
        .frame(width: 65, height: 80)
        .rotationEffect(.degrees(12))
        .accessibilityHidden(true)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("我的社区", subtitle: "每一次相遇，都值得记住")
            VStack(spacing: 0) {
                profileRow(symbol: "bookmark.fill", title: "我的收藏", subtitle: "留住每一次心动的相遇", count: store.favoriteRooms.count, color: KikiPalette.lavender) {
                    activeSheet = .favorites
                }
                rowDivider
                profileRow(symbol: "clock.arrow.circlepath", title: "最近加入", subtitle: "回到熟悉的声音里", count: store.recentRooms.count, color: KikiPalette.mint) {
                    activeSheet = .history
                }
                rowDivider
                profileRow(symbol: "mic.fill", title: "我的房间", subtitle: "为同频的朋友留一个位置", count: store.createdRooms.count, color: Color(hex: 0xF4B67A)) {
                    activeSheet = .created
                }
            }
            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 23))
        }
    }

    private var preferences: some View {
        VStack(spacing: 0) {
            profileRow(symbol: "slider.horizontal.3", title: "账号设置", color: KikiPalette.secondary) {
                activeSheet = .settings
            }
            rowDivider
            profileRow(symbol: "sparkles", title: "关于 KikiTalk", color: KikiPalette.secondary) {
                activeSheet = .about
            }
        }
        .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 23))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("KikiTalk")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(KikiPalette.muted)
            Text("让世界听见你")
                .font(.system(size: 10))
                .foregroundStyle(KikiPalette.muted.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 1)
    }

    private var rowDivider: some View {
        Rectangle().fill(KikiPalette.elevated).frame(height: 1).padding(.leading, 66)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(KikiPalette.text)
            Spacer()
            Text(subtitle)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .tracking(2)
                .foregroundStyle(KikiPalette.muted)
        }
    }

    private func profileRow(symbol: String, title: String, subtitle: String? = nil, count: Int? = nil, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 34, height: 37)
                    .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(KikiPalette.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(KikiPalette.muted)
                    }
                }
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(KikiPalette.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(KikiPalette.muted)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, subtitle == nil ? 14 : 17)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: KikiProfileSheet) -> some View {
        switch sheet {
        case .edit:
            KikiProfileEditor()
        case .favorites:
            KikiProfileRoomCollection(title: "我的收藏", subtitle: "喜欢的声音，随时再见。", collection: .favorites, emptySymbol: "bookmark", emptyTitle: "把喜欢的房间留在这里", emptyMessage: "长按大厅里的房间卡片即可收藏，下次就能快速找到。", onSelect: chooseRoom)
        case .history:
            KikiProfileRoomCollection(title: "最近加入", subtitle: "每一次相遇，都留下足迹。", collection: .history, emptySymbol: "clock", emptyTitle: "新的故事，等你开启", emptyMessage: "加入感兴趣的房间，你的足迹会出现在这里。", onSelect: chooseRoom)
        case .created:
            KikiProfileRoomCollection(title: "我的房间", subtitle: "你创造的小小世界。", collection: .created, emptySymbol: "mic.badge.plus", emptyTitle: "你的第一个房间，正在等你", emptyMessage: "在「语聊 / 直播」页面轻点右上角创建，邀请朋友来聊聊。", onSelect: chooseRoom)
        case .settings:
            KikiProfileSettings()
        case .about:
            KikiProfileAbout()
        }
    }

    private func chooseRoom(_ room: DemoRoom) {
        pendingRoom = room
        activeSheet = nil
    }

    private func openPendingRoom() {
        guard let room = pendingRoom else { return }
        pendingRoom = nil
        Task {
            do {
                try await store.openRoom(room)
            } catch {
                store.notify(error.localizedDescription)
            }
        }
    }
}

private enum KikiProfileSheet: String, Identifiable {
    case edit, favorites, history, created, settings, about
    var id: String { rawValue }
}

@available(iOS 16.0, *)
private struct KikiProfileEditor: View {
    @EnvironmentObject private var store: KikiDemoStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bio = ""
    @State private var avatarIndex = 0
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pendingJPEG: Data?
    @State private var photoPreview: UIImage?
    @State private var chosePreset = false
    @State private var isLoadingPhoto = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case name, bio }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(spacing: 12) {
                        Group {
                            if let photoPreview {
                                Image(uiImage: photoPreview).resizable().scaledToFill()
                                    .frame(width: 98, height: 98).clipShape(Circle())
                            } else {
                                KikiAvatar(index: avatarIndex, size: 98, customURL: chosePreset ? nil : store.customAvatarURL)
                            }
                        }
                        PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                            HStack(spacing: 7) {
                                if isLoadingPhoto { ProgressView().tint(KikiPalette.lavender) }
                                else { Image(systemName: "photo.on.rectangle") }
                                Text(isLoadingPhoto ? "正在处理照片…" : "从相册选择头像")
                            }.font(.system(size: 13, weight: .semibold)).foregroundStyle(KikiPalette.lavender)
                                .padding(.horizontal, 16).padding(.vertical, 11)
                                .background(KikiPalette.purple.opacity(0.12), in: Capsule())
                        }
                        .disabled(isLoadingPhoto || isSaving)
                        .accessibilityIdentifier("chooseAvatarPhoto")
                        Text(pendingJPEG == nil ? "选择照片，或使用下方预设头像" : "照片将在保存资料后上传")
                            .font(.system(size: 12))
                            .foregroundStyle(KikiPalette.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 16) {
                        ForEach(0..<8) { index in
                            Button {
                                avatarIndex = index
                                chosePreset = true
                                selectedPhoto = nil
                                isLoadingPhoto = false
                                pendingJPEG = nil
                                photoPreview = nil
                                errorMessage = nil
                            } label: {
                                KikiAvatar(index: index, size: 56)
                                    .padding(5)
                                    .overlay {
                                        Circle().stroke(chosePreset && avatarIndex == index ? KikiPalette.lavender : .clear, lineWidth: 2)
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        if chosePreset && avatarIndex == index {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 17, weight: .semibold))
                                                .foregroundStyle(KikiPalette.lavender, KikiPalette.surface)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("头像 \(index + 1)")
                            .accessibilityAddTraits(chosePreset && avatarIndex == index ? .isSelected : [])
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        fieldHeading("昵称", count: name.count, limit: 16)
                        TextField("大家该怎么称呼你？", text: $name)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(KikiPalette.text)
                            .padding(17)
                            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                            .focused($focusedField, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .bio }
                            .onChange(of: name) { value in
                                if value.count > 16 { name = String(value.prefix(16)) }
                            }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        fieldHeading("关于我", count: bio.count, limit: 80)
                        TextField("说说你的兴趣，或想聊的话题…", text: $bio, axis: .vertical)
                            .font(.system(size: 14))
                            .lineSpacing(5)
                            .lineLimit(3...5)
                            .foregroundStyle(KikiPalette.text)
                            .padding(17)
                            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                            .focused($focusedField, equals: .bio)
                            .onChange(of: bio) { value in
                                if value.count > 80 { bio = String(value.prefix(80)) }
                            }
                    }

                    Label("资料保存后会同步到你的账号。", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 11))
                        .foregroundStyle(KikiPalette.muted)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }
                }
                .padding(24)
                .disabled(isSaving)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(KikiPalette.background.ignoresSafeArea())
            .navigationTitle("编辑资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(KikiPalette.secondary)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving { ProgressView().tint(KikiPalette.lavender) }
                        else { Text("保存").fontWeight(.semibold) }
                    }
                    .foregroundStyle(trimmedName.isEmpty ? KikiPalette.muted : KikiPalette.lavender)
                    .disabled(trimmedName.isEmpty || isSaving || isLoadingPhoto)
                    .accessibilityIdentifier("saveProfile")
                }
            }
            .task(id: selectedPhoto) { await loadSelectedPhoto() }
            .onAppear {
                chosePreset = store.customAvatarURL == nil
                name = store.profileName
                bio = store.bio
                avatarIndex = store.avatarIndex
            }
        }
        .tint(KikiPalette.lavender)
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        guard !trimmedName.isEmpty, !isSaving, !isLoadingPhoto else { return }
        focusedField = nil
        errorMessage = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await store.updateProfile(name: trimmedName, bio: bio.trimmingCharacters(in: .whitespacesAndNewlines), avatarIndex: avatarIndex, jpegData: pendingJPEG, clearCustomAvatar: chosePreset)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadSelectedPhoto() async {
        guard let selection = selectedPhoto else { isLoadingPhoto = false; return }
        isLoadingPhoto = true
        errorMessage = nil
        defer { if selectedPhoto == selection { isLoadingPhoto = false } }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self) else {
                throw KikiAPIError.server(422, "无法读取这张照片，请重新选择。")
            }
            try Task.checkCancellation()
            let prepared = try await Task.detached(priority: .userInitiated) {
                try KikiAvatarPhoto.prepare(data)
            }.value
            try Task.checkCancellation()
            guard selectedPhoto == selection else { return }
            pendingJPEG = prepared.data
            photoPreview = prepared.image
            chosePreset = false
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, selectedPhoto == selection else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func fieldHeading(_ title: String, count: Int, limit: Int) -> some View {
        HStack {
            Text(title).foregroundStyle(KikiPalette.secondary)
            Spacer()
            Text("\(count)/\(limit)").foregroundStyle(KikiPalette.muted)
        }
        .font(.system(size: 12, weight: .medium))
    }
}

private enum KikiRoomCollectionKind {
    case favorites, history, created
}

/// Downsample before decoding the full photo, correct EXIF orientation, and
/// center-crop a square JPEG. A chosen image stays local until Save is tapped.
private enum KikiAvatarPhoto {
    static func prepare(_ data: Data) throws -> (data: Data, image: UIImage) {
        guard data.count <= 30 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw KikiAPIError.server(422, "照片无法读取或超过 30 MB，请换一张照片。")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw KikiAPIError.server(422, "这张照片无法处理，请选择其他图片。")
        }
        let side = min(thumbnail.width, thumbnail.height)
        guard side > 0, let cropped = thumbnail.cropping(to: CGRect(x: CGFloat((thumbnail.width - side) / 2),
                                                                 y: CGFloat((thumbnail.height - side) / 2),
                                                                 width: CGFloat(side), height: CGFloat(side))) else {
            throw KikiAPIError.server(422, "头像裁剪失败，请重新选择。")
        }
        let image = UIImage(cgImage: cropped)
        for quality in [0.88, 0.72, 0.55] {
            if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= 2 * 1024 * 1024 {
                return (jpeg, image)
            }
        }
        throw KikiAPIError.server(422, "照片压缩后仍然过大，请换一张照片。")
    }
}

@available(iOS 16.0, *)
private struct KikiProfileRoomCollection: View {
    @EnvironmentObject private var store: KikiDemoStore
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String
    let collection: KikiRoomCollectionKind
    let emptySymbol: String
    let emptyTitle: String
    let emptyMessage: String
    let onSelect: (DemoRoom) -> Void

    private var rooms: [DemoRoom] {
        switch collection {
        case .favorites: return store.favoriteRooms
        case .history: return store.recentRooms
        case .created: return store.createdRooms
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(KikiPalette.secondary)
                        Spacer()
                        Text("\(rooms.count) 个房间")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(KikiPalette.muted)
                    }
                    .padding(.vertical, 8)

                    if rooms.isEmpty {
                        VStack(spacing: 18) {
                            Image(systemName: emptySymbol)
                                .font(.system(size: 35, weight: .light))
                                .foregroundStyle(KikiPalette.lavender)
                                .frame(width: 88, height: 88)
                                .background(KikiPalette.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 30))
                            Text(emptyTitle)
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(KikiPalette.text)
                            Text(emptyMessage)
                                .font(.system(size: 13))
                                .lineSpacing(6)
                                .foregroundStyle(KikiPalette.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 270)
                            Button("返回我的空间") { dismiss() }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(KikiPalette.lavender)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                                .background(KikiPalette.purple.opacity(0.15), in: Capsule())
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 90)
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(rooms) { room in
                                Button {
                                    onSelect(room)
                                } label: {
                                    KikiRoomCard(room: room)
                                        .overlay(alignment: .topTrailing) {
                                            if room.status != "live" {
                                                Text(room.status == "draft" ? "未开播" : "已结束")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(KikiPalette.secondary)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 6)
                                                    .background(KikiPalette.background.opacity(0.9), in: Capsule())
                                                    .padding(12)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        store.toggleFavorite(room)
                                    } label: {
                                        Label(store.favoriteIDs.contains(room.id) ? "取消收藏" : "收藏房间", systemImage: store.favoriteIDs.contains(room.id) ? "bookmark.slash" : "bookmark")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .padding(.bottom, 25)
            }
            .background(KikiPalette.background.ignoresSafeArea())
            .refreshable { await store.refreshLibrary() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(KikiPalette.lavender)
                }
            }
        }
    }
}

@available(iOS 16.0, *)
private struct KikiProfileSettings: View {
    @EnvironmentObject private var store: KikiDemoStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLogoutConfirmation = false
    @State private var showDeletion = false
    @State private var isLoggingOut = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("让相遇，安心继续")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(KikiPalette.text)
                        Text("管理你的账号与个人资料。")
                            .font(.system(size: 13))
                            .foregroundStyle(KikiPalette.secondary)
                    }
                    .padding(.top, 20)

                    VStack(alignment: .leading, spacing: 15) {
                        Label("当前账号", systemImage: "person.crop.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(KikiPalette.lavender)
                        Text(store.userID)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .foregroundStyle(KikiPalette.text)
                            .textSelection(.enabled)
                        Text("资料、收藏与房间记录会同步到当前账号。")
                            .font(.system(size: 12))
                            .lineSpacing(5)
                            .foregroundStyle(KikiPalette.secondary)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 21))

                    Button {
                        showLogoutConfirmation = true
                    } label: {
                        HStack(spacing: 12) {
                            if isLoggingOut { ProgressView().tint(KikiPalette.lavender) }
                            else { Image(systemName: "rectangle.portrait.and.arrow.right") }
                            Text("退出登录")
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(KikiPalette.text)
                        .padding(20)
                        .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 19))
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoggingOut)
                    .accessibilityIdentifier("logoutButton")

                    VStack(alignment: .leading, spacing: 12) {
                        Button("注销账号") { showDeletion = true }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.red.opacity(0.85))
                            .accessibilityIdentifier("deleteAccountButton")
                        Text("注销会永久删除账号数据，请谨慎操作。")
                            .font(.system(size: 11))
                            .foregroundStyle(KikiPalette.muted)
                    }
                    .padding(.horizontal, 3)
                }
                .padding(24)
            }
            .background(KikiPalette.background.ignoresSafeArea())
            .navigationTitle("账号设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(KikiPalette.lavender)
                        .disabled(isLoggingOut)
                }
            }
            .confirmationDialog("退出当前账号？", isPresented: $showLogoutConfirmation, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    isLoggingOut = true
                    Task {
                        await store.logout()
                        isLoggingOut = false
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("资料和房间记录会保留，再次登录后可继续使用。")
            }
            .sheet(isPresented: $showDeletion) {
                KikiAccountDeletion {
                    showDeletion = false
                    dismiss()
                }
                .environmentObject(store)
                .preferredColorScheme(.dark)
            }
        }
        .interactiveDismissDisabled(isLoggingOut)
    }
}

@available(iOS 16.0, *)
private struct KikiAccountDeletion: View {
    @EnvironmentObject private var store: KikiDemoStore
    @Environment(\.dismiss) private var dismiss
    let onDeleted: () -> Void
    @State private var confirmationID = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?
    private var canDelete: Bool { !store.userID.isEmpty && confirmationID == store.userID && !isDeleting }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "person.crop.circle.badge.minus")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .padding(.top, 20)
                    Text("确认注销账号")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(KikiPalette.text)
                    Text("此操作会永久删除个人资料、收藏和加入记录，并结束你创建的活动房间。删除后不可恢复。")
                        .font(.system(size: 14))
                        .lineSpacing(7)
                        .foregroundStyle(KikiPalette.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("请输入当前账号 ID：\(store.userID)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(KikiPalette.secondary)
                        TextField("账号 ID", text: $confirmationID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundStyle(KikiPalette.text)
                            .padding(17)
                            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                            .disabled(isDeleting)
                            .accessibilityIdentifier("deleteAccountConfirmationID")
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }
                    Button(action: deleteAccount) {
                        HStack(spacing: 10) {
                            if isDeleting { ProgressView().tint(.white) }
                            Text(isDeleting ? "正在注销…" : "永久注销账号")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canDelete || isDeleting ? .white : KikiPalette.muted)
                        .frame(maxWidth: .infinity)
                        .padding(18)
                        .background(canDelete || isDeleting ? Color.red.opacity(0.8) : KikiPalette.elevated, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(!canDelete)
                    .accessibilityIdentifier("confirmDeleteAccount")
                }
                .padding(24)
            }
            .background(KikiPalette.background.ignoresSafeArea())
            .navigationTitle("注销账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(KikiPalette.lavender)
                        .disabled(isDeleting)
                }
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private func deleteAccount() {
        guard canDelete else { return }
        errorMessage = nil
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                try await store.deleteAccount()
                onDeleted()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

@available(iOS 16.0, *)
private struct KikiProfileAbout: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 27) {
                    VStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 28)
                                .fill(LinearGradient(colors: [KikiPalette.lavender, KikiPalette.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 96, height: 96)
                            Image(systemName: "waveform")
                                .font(.system(size: 42, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        Text("KikiTalk")
                            .font(.system(size: 29, weight: .bold, design: .rounded))
                            .foregroundStyle(KikiPalette.text)
                        Text("让世界听见你")
                            .font(.system(size: 14))
                            .tracking(3)
                            .foregroundStyle(KikiPalette.secondary)
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(KikiPalette.lavender)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(KikiPalette.purple.opacity(0.12), in: Capsule())
                    }
                    .padding(.top, 36)
                    .padding(.bottom, 10)

                    VStack(alignment: .leading, spacing: 18) {
                        aboutItem("bubble.left.and.bubble.right", title: "从一句你好开始", message: "发现语聊与直播房间，用声音结识有趣的人，找到属于你的同频社区。")
                        Rectangle().fill(KikiPalette.elevated).frame(height: 1)
                        aboutItem("waveform", title: "让声音跨越距离", message: "开启语聊房或直播间，邀请朋友加入，一起分享声音和此刻。")
                        Rectangle().fill(KikiPalette.elevated).frame(height: 1)
                        aboutItem("person.crop.circle.badge.checkmark", title: "你的社区，随时相见", message: "个人资料、收藏与加入记录跟随账号保存。账号绑定当前设备，重新登录后可继续访问。")
                    }
                    .padding(22)
                    .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 25))

                    Text("一段对话，一个新的可能。")
                        .font(.system(size: 11))
                        .foregroundStyle(KikiPalette.muted)
                        .padding(.bottom, 25)
                }
                .padding(.horizontal, 24)
            }
            .background(KikiPalette.background.ignoresSafeArea())
            .navigationTitle("关于 KikiTalk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(KikiPalette.lavender)
                }
            }
        }
    }

    private func aboutItem(_ symbol: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(KikiPalette.lavender)
                .frame(width: 25)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(KikiPalette.text)
                Text(message)
                    .font(.system(size: 12))
                    .lineSpacing(6)
                    .foregroundStyle(KikiPalette.secondary)
            }
        }
    }
}
