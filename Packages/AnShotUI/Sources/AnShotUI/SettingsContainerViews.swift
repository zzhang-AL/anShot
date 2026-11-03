//
//  SettingsContainerViews.swift
//  AnShotUI
//
//  设置窗口的容器视图：卡片、分组表面、字段外壳。
//
//  共同点：只负责**背景与边界**，不含业务语义。它们把一组控件
//  框成一个可识别的层次单元，具体控件由 `SettingsRowViews` 提供。
//
//  设计总纲（为什么自绘、动态色的陷阱）见 `SettingsTheme.swift`。
//
import AppKit

/// 带图标的圆角分组卡片。
///
/// 只负责「一个圆角容器 + 一个带图标的标题 + 一块内容区」，
/// 不做任何设置语义的判断。
final class SettingsCardView: NSView {

    private let symbolName: String
    private let title: String
    private let content: NSView

    init(symbolName: String, title: String, content: NSView) {
        self.symbolName = symbolName
        self.title = title
        self.content = content
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // 走 updateLayer：动态色在每次外观变化后重新解析。
        wantsLayer = true
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = SettingsTheme.cardRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = SettingsTheme.cardBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = SettingsTheme.cardBorder.cgColor
    }

    private func buildLayout() {
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )
        icon.contentTintColor = SettingsTheme.accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = SettingsTheme.sectionLabel

        header.addArrangedSubview(icon)
        header.addArrangedSubview(label)

        let stack = NSStackView(views: [header, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsTheme.innerGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let pad = SettingsTheme.cardPadding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),

            // 内容区撑满卡片宽度，让卡片宽度由外层决定而不是被内容撑开。
            content.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
}

// MARK: - 选项按钮

/// 文件夹状态行：一个内嵌在卡片里的浅色表面。
///
/// 有目录时显示「目录名 + 完整路径」两级信息——只看路径尾部
/// 往往认不出是哪个目录，只看名字又不知道它在哪。
final class SettingsFolderSurface: NSView {

    private let symbolView = NSImageView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let layout = NSStackView()

    let chooseButton = SettingsPushButton(title: "选择文件夹…", target: nil, action: nil)
    let changeButton = SettingsPushButton(title: "更改…", target: nil, action: nil)
    let revealButton = SettingsPushButton(title: "在访达中打开", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        buildLayout()
        render(folder: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = SettingsTheme.surfaceRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = SettingsTheme.insetBackground.cgColor
    }

    private func buildLayout() {
        symbolView.image = NSImage(
            systemSymbolName: "folder.fill",
            accessibilityDescription: nil
        )
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        symbolView.contentTintColor = SettingsTheme.accent
        symbolView.translatesAutoresizingMaskIntoConstraints = false

        primaryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        primaryLabel.textColor = .labelColor
        primaryLabel.lineBreakMode = .byTruncatingMiddle

        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        // 路径可能很长。允许被压缩（否则会把窗口撑开），
        // 但给一个宽度下限，免得被压成没有信息量的碎片。
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 120 而不是 200：按钮另起一行后，文本行的可用宽度只受卡片内宽限制，
        // 但路径很长时仍需被压缩，下限取小一点避免把卡片撑开。
        pathLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let text = NSStackView(views: [primaryLabel, pathLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1


        let buttons = NSStackView(views: [chooseButton, changeButton, revealButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        // 图标与文本一行，按钮另起一行。
        //
        // 原来三者挤在同一行（图标 + 文本 + 按钮），而文本有一个 200pt 的宽度
        // 下限、三个按钮加起来又超过 300pt（输入框统一放大后按钮也变宽了），
        // 卡片内部实际只有约 420pt——按钮被挤出卡片右边，用户看到的就是
        // 「按钮显示不全」。
        let topRow = NSStackView(views: [symbolView, text])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 12

        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 10
        layout.translatesAutoresizingMaskIntoConstraints = false
        layout.addArrangedSubview(topRow)
        layout.addArrangedSubview(buttons)
        layout.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(layout)

        NSLayoutConstraint.activate([
            layout.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            layout.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            // 文本行撑满可用宽度，路径才能在正确的宽度上截断（而不是按
            // 内容固有宽度排完再溢出）。
            topRow.widthAnchor.constraint(equalTo: layout.widthAnchor),
        ])
    }

    /// 诊断用：当前显示的路径文本。
    var displayedPath: String { pathLabel.stringValue }

    /// 诊断用：当前显示的主标题（目录名）。
    var displayedPrimary: String { primaryLabel.stringValue }

    /// 按当前文件夹状态刷新显示。
    ///
    /// - Parameter folder: `nil` 表示尚未选择过任何目录。
    func render(folder: URL?) {
        guard let folder else {
            primaryLabel.stringValue = "尚未选择文件夹"
            pathLabel.stringValue = "选定后，截图会直接存进这个目录"
            symbolView.contentTintColor = .tertiaryLabelColor
            chooseButton.isHidden = false
            changeButton.isHidden = true
            revealButton.isHidden = true
            return
        }

        // 目录名作为主信息：路径的最后一段才是人认得出的那部分。
        primaryLabel.stringValue = folder.lastPathComponent
        pathLabel.stringValue = (folder.path as NSString).abbreviatingWithTildeInPath
        symbolView.contentTintColor = SettingsTheme.accent
        chooseButton.isHidden = true
        changeButton.isHidden = false
        revealButton.isHidden = false
    }
}

// MARK: - 表单行

/// 表单控件的外壳：统一背景、圆角、描边与聚焦反馈。
///
/// ── 为什么要自绘 ──────────────────────────────────────────
///
/// 系统的 `NSTextField` / `NSPopUpButton` 默认外观是「圆角浮凸 + 系统蓝聚焦环」，
/// 与整窗的体系直接冲突：本设计**不使用任何色相**，层次全靠明度，
/// 而系统蓝会变成整窗唯一的一处彩色。
///
/// 把外壳与控件分开之后，两类控件共享同一套视觉；也不会因为系统版本
/// 改动默认样式而走样。
final class SettingsFieldShell: NSView {

    /// 外壳内承载的控件（应以无边框状态使用）。
    let control: NSView

    /// 尾部附件（例如密钥的显示/隐藏按钮）。为 nil 时控件一直铺到右侧内边距。
    private let accessory: NSView?

    private var isFocused = false {
        didSet {
            if oldValue != isFocused { needsDisplay = true }
        }
    }

    /// 聚焦态观察者。
    ///
    /// `nonisolated(unsafe)` 是因为 `deinit` 在 Swift 6 里是 nonisolated，
    /// 访问不了 actor 隔离的 non-Sendable 属性。这里安全：两个 token 只在
    /// `init` 里赋值（主线程）、在 `deinit` 里读取，且注册时已限定 `queue: .main`，
    /// 不存在并发读写。
    nonisolated(unsafe) private var beginObserver: NSObjectProtocol?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?

    private static let radius: CGFloat = 8
    private static let horizontalPadding: CGFloat = 10

    /// 输入框外壳高度。
    ///
    /// 与 `SettingsPushButton.height` 必须相等：两者在卡片里经常并排出现
    /// （输入框 + 测试按钮），高度差一点就能被看出来。
    static let height: CGFloat = 32

    init(control: NSView, accessory: NSView? = nil) {
        self.control = control
        self.accessory = accessory
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)

        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: Self.height),
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]

        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            constraints += [
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
                accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
                control.trailingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: -4),
            ]
        } else {
            constraints.append(
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding)
            )
        }
        NSLayoutConstraint.activate(constraints)

        // 只对文本控件做聚焦反馈：下拉框的「聚焦」语义不同，
        // 它自己还要画弹出态，再叠一层描边反而乱。
        if let field = control as? NSTextField {
            beginObserver = NotificationCenter.default.addObserver(
                forName: NSControl.textDidBeginEditingNotification,
                object: field,
                queue: .main
            ) { [weak self] _ in
                // 观察者挂在主队列上，这里必然在主线程；用 assumeIsolated
                // 而不是 Task{}，避免聚焦描边比光标慢一拍。
                MainActor.assumeIsolated { self?.isFocused = true }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: NSControl.textDidEndEditingNotification,
                object: field,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFocused = false }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    deinit {
        if let beginObserver { NotificationCenter.default.removeObserver(beginObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        SettingsTheme.fillRoundedRect(
            bounds,
            radius: Self.radius,
            color: SettingsTheme.insetBackground,
            in: context
        )
        SettingsTheme.strokeRoundedRect(
            bounds,
            radius: Self.radius,
            color: isFocused
                ? NSColor.labelColor.withAlphaComponent(0.5)
                : SettingsTheme.cardBorder,
            lineWidth: isFocused ? 1.5 : 1,
            in: context
        )
    }
}

// MARK: - 侧边栏
