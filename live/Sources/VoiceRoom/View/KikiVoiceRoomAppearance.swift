import UIKit
import SnapKit
import Kingfisher
import RTCRoomEngine
import AtomicXCore

/// Views for Kiki's voice room. Every occupant, listener and message comes from the SDK stores.
enum KikiVoicePalette {
    static let background = UIColor(red: 0.18, green: 0.12, blue: 0.40, alpha: 1)
    static let bubble = UIColor(red: 0.10, green: 0.06, blue: 0.24, alpha: 0.85)
    static let accent = UIColor(red: 0.47, green: 0.29, blue: 1, alpha: 1)
    static let secondary = UIColor(red: 0.76, green: 0.70, blue: 0.94, alpha: 1)
}

final class KikiVoiceHeaderView: UIView {
    var onMore: (() -> Void)?
    var onFollow: (() -> Void)?
    var onOwner: (() -> Void)?
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let ownerAvatar = UIImageView()
    private let ownerName = UILabel()
    let followButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.accessibilityIdentifier = "voice.room.title"
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        subtitleLabel.textColor = KikiVoicePalette.secondary
        subtitleLabel.text = "语聊 · 8 个麦位"
        ownerAvatar.contentMode = .scaleAspectFill
        ownerAvatar.clipsToBounds = true
        ownerAvatar.layer.cornerRadius = 12
        ownerName.font = .systemFont(ofSize: 12, weight: .medium)
        ownerName.textColor = .white.withAlphaComponent(0.88)
        ownerName.lineBreakMode = .byTruncatingTail
        ownerName.isUserInteractionEnabled = true
        ownerName.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(ownerTapped)))
        ownerAvatar.isUserInteractionEnabled = true
        ownerAvatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(ownerTapped)))
        followButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        followButton.tintColor = .white
        followButton.backgroundColor = KikiVoicePalette.accent
        followButton.layer.cornerRadius = 14
        followButton.accessibilityIdentifier = "voice.room.follow"
        followButton.addTarget(self, action: #selector(followTapped), for: .touchUpInside)
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = .white
        moreButton.backgroundColor = .black.withAlphaComponent(0.18)
        moreButton.layer.cornerRadius = 20
        moreButton.accessibilityLabel = "房间更多操作"
        moreButton.accessibilityIdentifier = "voice.room.more"
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        [titleLabel, subtitleLabel, ownerAvatar, ownerName, followButton, moreButton].forEach(addSubview)
        moreButton.snp.makeConstraints { make in
            make.trailing.top.equalToSuperview()
            make.size.equalTo(40)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.top.equalToSuperview()
            make.trailing.equalTo(moreButton.snp.leading).offset(-12)
        }
        subtitleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.top.equalTo(titleLabel.snp.bottom).offset(7)
        }
        ownerAvatar.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.top.equalTo(subtitleLabel.snp.bottom).offset(10)
            make.size.equalTo(24)
            make.bottom.equalToSuperview()
        }
        ownerName.snp.makeConstraints { make in
            make.leading.equalTo(ownerAvatar.snp.trailing).offset(7)
            make.centerY.equalTo(ownerAvatar)
            make.trailing.lessThanOrEqualTo(followButton.snp.leading).offset(-8)
        }
        followButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview()
            make.centerY.equalTo(ownerAvatar)
            make.height.equalTo(28)
            make.width.equalTo(66)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(live: AtomicLiveInfo, isOwner: Bool) {
        titleLabel.text = live.liveName.isEmpty ? "一起聊聊天" : live.liveName
        ownerName.text = "房主 · \(live.liveOwner.displayName)"
        ownerAvatar.kf.setImage(with: URL(string: live.liveOwner.avatarURL), placeholder: UIImage.avatarPlaceholderImage)
        followButton.isHidden = isOwner
    }

    func updateFollowing(_ isFollowing: Bool) {
        followButton.setTitle(isFollowing ? "已关注" : "+ 关注", for: .normal)
        followButton.backgroundColor = isFollowing ? .white.withAlphaComponent(0.15) : KikiVoicePalette.accent
        followButton.accessibilityValue = isFollowing ? "已关注" : "未关注"
    }

    @objc private func moreTapped() { onMore?() }
    @objc private func followTapped() { onFollow?() }
    @objc private func ownerTapped() { onOwner?() }
}

final class KikiVoiceAudienceStrip: UIView {
    var onAudienceList: (() -> Void)?
    var onUser: ((LiveUserInfo) -> Void)?
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let countButton = UIButton(type: .system)
    private let emptyLabel = UILabel()
    private var users: [LiveUserInfo] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        stack.axis = .horizontal
        stack.spacing = 12
        emptyLabel.text = "等待朋友加入，一起开聊"
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = KikiVoicePalette.secondary
        countButton.titleLabel?.font = .systemFont(ofSize: 11, weight: .medium)
        countButton.titleLabel?.numberOfLines = 2
        countButton.titleLabel?.textAlignment = .center
        countButton.tintColor = .white
        countButton.backgroundColor = .white.withAlphaComponent(0.12)
        countButton.layer.cornerRadius = 22
        countButton.accessibilityIdentifier = "voice.room.listeners"
        countButton.addTarget(self, action: #selector(audienceTapped), for: .touchUpInside)
        addSubview(scrollView)
        addSubview(countButton)
        scrollView.addSubview(stack)
        scrollView.addSubview(emptyLabel)
        countButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview()
            make.top.equalToSuperview().offset(2)
            make.width.equalTo(44)
            make.height.equalTo(52)
        }
        scrollView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.trailing.equalTo(countButton.snp.leading).offset(-12)
        }
        stack.snp.makeConstraints { make in
            make.edges.equalTo(scrollView.contentLayoutGuide)
            make.height.equalTo(scrollView.frameLayoutGuide)
        }
        emptyLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalTo(scrollView.frameLayoutGuide)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(users: [LiveUserInfo], count: Int) {
        self.users = users
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, user) in users.prefix(30).enumerated() {
            let item = UIButton(type: .custom)
            item.tag = index
            item.accessibilityLabel = "听众 \(user.displayName)"
            item.addTarget(self, action: #selector(userTapped(_:)), for: .touchUpInside)
            let avatar = UIImageView()
            avatar.contentMode = .scaleAspectFill
            avatar.layer.cornerRadius = 18
            avatar.clipsToBounds = true
            avatar.kf.setImage(with: URL(string: user.avatarURL), placeholder: UIImage.avatarPlaceholderImage)
            let name = UILabel()
            name.text = user.displayName
            name.textColor = .white.withAlphaComponent(0.86)
            name.font = .systemFont(ofSize: 10)
            name.textAlignment = .center
            item.addSubview(avatar)
            item.addSubview(name)
            avatar.snp.makeConstraints { make in
                make.top.equalToSuperview().offset(2)
                make.centerX.equalToSuperview()
                make.size.equalTo(36)
            }
            name.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview()
                make.top.equalTo(avatar.snp.bottom).offset(5)
            }
            item.snp.makeConstraints { $0.width.equalTo(42) }
            stack.addArrangedSubview(item)
        }
        emptyLabel.isHidden = !users.isEmpty
        countButton.setTitle("\(max(0, count))\n在听", for: .normal)
        countButton.accessibilityLabel = "当前 \(max(0, count)) 位听众，查看成员"
    }

    @objc private func audienceTapped() { onAudienceList?() }
    @objc private func userTapped(_ sender: UIButton) {
        guard users.indices.contains(sender.tag) else { return }
        onUser?(users[sender.tag])
    }
}

final class KikiVoiceSeatView: UIView {
    private let avatar = UIImageView()
    private let emptyIcon = UIImageView()
    private let circle = UIView()
    private let nameLabel = UILabel()
    private let hostBadge = UIImageView(image: UIImage(systemName: "house.fill"))
    private let microphone = UIImageView(image: UIImage(systemName: "mic.slash.fill"))
    private let speakingRing = UIView()
    private var userID = ""
    private var muted = true

    init(seat: TUISeatInfo, ownerID: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        circle.backgroundColor = .white.withAlphaComponent(0.15)
        circle.layer.borderColor = UIColor.white.withAlphaComponent(0.20).cgColor
        circle.layer.borderWidth = 1.5
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        emptyIcon.contentMode = .scaleAspectFit
        emptyIcon.tintColor = .white.withAlphaComponent(0.95)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textAlignment = .center
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        hostBadge.tintColor = .white
        hostBadge.backgroundColor = KikiVoicePalette.accent
        hostBadge.layer.cornerRadius = 8
        hostBadge.contentMode = .center
        hostBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        microphone.tintColor = .white
        microphone.backgroundColor = KikiVoicePalette.bubble
        microphone.layer.cornerRadius = 8
        microphone.contentMode = .center
        microphone.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9)
        speakingRing.layer.borderColor = UIColor(red: 0.45, green: 0.87, blue: 1, alpha: 1).cgColor
        speakingRing.layer.borderWidth = 2
        speakingRing.layer.shadowColor = UIColor.cyan.cgColor
        speakingRing.layer.shadowRadius = 7
        speakingRing.layer.shadowOpacity = 0.75
        speakingRing.layer.shadowOffset = .zero
        [speakingRing, circle, avatar, nameLabel, hostBadge, microphone].forEach(addSubview)
        circle.addSubview(emptyIcon)
        circle.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(5)
            make.centerX.equalToSuperview()
            make.size.equalTo(54)
        }
        avatar.snp.makeConstraints { $0.edges.equalTo(circle).inset(1.5) }
        speakingRing.snp.makeConstraints { $0.edges.equalTo(circle).inset(-4) }
        emptyIcon.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.size.equalTo(24)
        }
        microphone.snp.makeConstraints { make in
            make.trailing.bottom.equalTo(circle)
            make.size.equalTo(17)
        }
        nameLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalTo(circle.snp.bottom).offset(9)
        }
        hostBadge.snp.makeConstraints { make in
            make.leading.equalTo(circle).offset(-3)
            make.bottom.equalTo(circle).offset(2)
            make.size.equalTo(16)
        }
        update(seat: seat, ownerID: ownerID)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        circle.layer.cornerRadius = circle.bounds.width / 2
        avatar.layer.cornerRadius = avatar.bounds.width / 2
        speakingRing.layer.cornerRadius = speakingRing.bounds.width / 2
    }

    func update(seat: TUISeatInfo, ownerID: String) {
        let newUserID = seat.userId ?? ""
        if newUserID != userID { speakingRing.layer.removeAllAnimations(); speakingRing.isHidden = true }
        userID = newUserID
        let occupied = !userID.isEmpty
        avatar.isHidden = !occupied
        emptyIcon.isHidden = occupied
        hostBadge.isHidden = !occupied || userID != ownerID
        emptyIcon.image = UIImage(systemName: seat.isLocked ? "lock.fill" : "person.wave.2.fill")
        nameLabel.text = occupied ? seat.displayName : "\(seat.index + 1)"
        nameLabel.textColor = occupied ? .white : KikiVoicePalette.secondary
        if occupied {
            avatar.kf.setImage(with: URL(string: seat.avatarUrl ?? ""), placeholder: UIImage.avatarPlaceholderImage)
        }
        muted = seat.isAudioLocked
        microphone.isHidden = !occupied || !muted
        accessibilityLabel = "第 \(seat.index + 1) 麦，\(occupied ? seat.displayName : (seat.isLocked ? "已锁定" : "空麦位"))"
        accessibilityValue = occupied ? (muted ? "已静音" : "麦克风已开启") : nil
        accessibilityIdentifier = "voice.room.seat.\(seat.index + 1)"
        isAccessibilityElement = true
        if !occupied || muted { setVolume(0) }
    }

    func setVolume(_ volume: Int) {
        let speaking = !userID.isEmpty && !muted && volume > 25
        speakingRing.isHidden = !speaking
        if speaking && speakingRing.layer.animation(forKey: "speaking") == nil {
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1
            pulse.toValue = 1.09
            pulse.duration = 0.55
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            speakingRing.layer.add(pulse, forKey: "speaking")
        } else if !speaking {
            speakingRing.layer.removeAnimation(forKey: "speaking")
        }
    }

    func setMuted(_ isMuted: Bool) {
        muted = isMuted
        microphone.isHidden = userID.isEmpty || !isMuted
        accessibilityValue = userID.isEmpty ? nil : (isMuted ? "已静音" : "麦克风已开启")
        if isMuted { setVolume(0) }
    }
}

final class KikiVoiceBarrageCell: UIView {
    init(barrage: Barrage, ownerID: String, senderName: String? = nil, senderAvatarURL: String? = nil) {
        super.init(frame: .zero)
        let displayName = senderName.flatMap { $0.isEmpty ? nil : $0 } ?? barrage.sender.displayName
        let avatar = UIImageView()
        avatar.contentMode = .scaleAspectFill
        avatar.layer.cornerRadius = 13
        avatar.clipsToBounds = true
        avatar.kf.setImage(with: URL(string: senderAvatarURL ?? barrage.sender.avatarURL), placeholder: UIImage.avatarPlaceholderImage)
        let bubble = UIView()
        bubble.backgroundColor = KikiVoicePalette.bubble
        bubble.layer.cornerRadius = 13
        let label = UILabel()
        label.numberOfLines = 0
        let font = UIFont.systemFont(ofSize: 13)
        let text = NSMutableAttributedString()
        if barrage.sender.userID == ownerID {
            text.append(NSAttributedString(string: "房主 ", attributes: [.font: UIFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: UIColor(red: 0.72, green: 0.61, blue: 1, alpha: 1)]))
        }
        text.append(NSAttributedString(string: "\(displayName)：", attributes: [.font: font, .foregroundColor: KikiVoicePalette.secondary]))
        let content = EmotionHelper.shared.obtainImagesAttributedString(byText: barrage.textContent, font: font)
        content.addAttribute(.foregroundColor, value: UIColor.white, range: NSRange(location: 0, length: content.length))
        text.append(content)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        label.textColor = .white
        label.attributedText = text
        addSubview(avatar)
        addSubview(bubble)
        bubble.addSubview(label)
        avatar.snp.makeConstraints { make in
            make.leading.top.equalToSuperview()
            make.size.equalTo(26)
            make.bottom.lessThanOrEqualToSuperview()
        }
        bubble.snp.makeConstraints { make in
            make.leading.equalTo(avatar.snp.trailing).offset(7)
            make.top.bottom.equalToSuperview()
            make.trailing.lessThanOrEqualToSuperview().offset(-20)
        }
        label.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 7, left: 10, bottom: 7, right: 10))
        }
        accessibilityLabel = "\(displayName)：\(barrage.textContent)"
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
