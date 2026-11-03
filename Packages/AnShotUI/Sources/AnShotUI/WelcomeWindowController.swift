//
//  WelcomeWindowController.swift
//  AnShotUI
//
//  首启欢迎窗口。
//
//  ── 它解决什么问题 ─────────────────────────────────────────────
//
//  菜单栏程序没有「主窗口」：第一次启动时用户只看到一个图标，
//  既不知道按什么键截图，也不知道缺权限时截出来会是一片空白。
//  权限尤其容易卡住人——屏幕录制未授权时 `ScreenCaptureKit` 只会报错，
//  用户看到的现象却是「这软件不能用」。
//
//  所以本窗口只回答三个问题：按什么键、缺哪些权限、现在先做什么。
//  它**不请求**任何权限：请求权限的时机属于真正需要它的功能
//  （截图、录屏），在这里弹系统对话框只会让首启变成一连串打断。
//  它也**不自己决定**是否重复出现——由 `AppDelegate` 在首次启动或
//  未授权时调用 `show()`，这个类不碰 UserDefaults。
//
//  ── 权限状态的来源 ─────────────────────────────────────────────
//
//  屏幕录制：`ScreenCapturePermissionService.current()`，只读 preflight，
//  不触发弹窗；三种可观测状态直接映射成「已授权 / 尚未授权」。
//  麦克风：`MicrophonePermission.status`，系统给出的四态，无需推断。
//  辅助功能：`SystemElementDetector.hasAccessibilityPermission`（`AXIsProcessTrusted`）。
//  三者都是**查询**，没有一处调用 request / prompt。
//
//  ── 关闭即释放 ─────────────────────────────────────────────────
//
//  本应用「空闲期零窗口」，因此 `windowWillClose` 里把窗口引用置空，
//  让 NSWindow 与整棵视图树一起释放。动作闭包由本对象持有，
//  调用方通过释放控制器回收；闭包本身不捕获本对象（`weak self`），
//  所以不存在「窗口 → 控制器 → 闭包 → 窗口」的环。
//

import AnShotCapture
import AppKit

@MainActor
final class WelcomeWindowController: NSObject {

    /// 窗口内容区尺寸。契约要求约 520×420；高度按当前内容留了约 20pt 余量，
    /// 内容行高变化时不会挤到按钮。
    private static let contentSize = NSSize(width: 520, height: 420)

    private let permission: ScreenCapturePermissionService
    private let settings: AppSettings

    private let onOpenSettings: () -> Void
    private let onRelaunch: () -> Void
    private let onTryCapture: () -> Void

    /// 窗口关闭时通知调用方，以便释放本控制器（与 `SettingsWindowController.onClose` 同义）。
    ///
    /// 不是契约要求，但调用方需要一个「可以安全丢掉引用」的时机；
    /// 没有它，首启控制器只能在别处猜窗口是否还开着。
    var onClose: (() -> Void)?

    private var window: NSWindow?

    // 视图只属于**当前这个窗口**，因此用弱引用：窗口关闭后视图随之释放，
    // 这些引用自动变 nil，下一次 show() 重建一套新的。
    //
    // 不复用视图、也不在关闭时手工拆视图：视图的 `superview` 不是强引用，
    // 留着旧视图会在「关闭后再次打开」时踩到已消失的父视图；
    // 而在按钮自己的动作里把它从层级摘掉，又可能让正在派发事件的控件提前释放。
    // 交给窗口统一持有是最省事也最安全的做法。
    private weak var screenRow: PermissionRowView?
    private weak var microphoneRow: PermissionRowView?
    private weak var accessibilityRow: PermissionRowView?
    private weak var shortcutBadge: ShortcutBadgeView?

    init(
        permission: ScreenCapturePermissionService,
        settings: AppSettings,
        onOpenSettings: @escaping () -> Void,
        onRelaunch: @escaping () -> Void,
        onTryCapture: @escaping () -> Void
    ) {
        self.permission = permission
        self.settings = settings
        self.onOpenSettings = onOpenSettings
        self.onRelaunch = onRelaunch
        self.onTryCapture = onTryCapture
        super.init()
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - 显示

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window

        // 每次都重读：用户可能刚从系统设置授权回来，窗口重新打开时
        // 必须显示最新状态，而不是创建时的旧快照。
        refreshStatuses()

        // 本应用平时不是活跃应用；不主动激活的话窗口会开在后台，
        // 用户看不到却以为「点了没反应」——与设置窗口同一理由。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 状态

    private func refreshStatuses() {
        guard let screenRow,
              let microphoneRow,
              let accessibilityRow,
              let shortcutBadge
        else {
            return
        }

        // 只读 preflight：`.notRequested` 与 `.notGranted` 在这里都显示
        // 「尚未授权」，因为本窗口不负责触发系统授权弹窗；
        // 用户唯一的下一步是右边那个「打开系统设置」。
        let screenStatus = permission.current()
        screenRow.apply(
            text: screenStatus.allowsCapture ? "已授权" : "尚未授权",
            isGranted: screenStatus.allowsCapture
        )

        // `.notDetermined` 显示「按需授权」：现在不打扰用户，
        // 等真正开始录屏时系统才会询问。
        let microphoneStatus = MicrophonePermission.status
        microphoneRow.apply(
            text: Self.microphoneStatusText(microphoneStatus),
            isGranted: microphoneStatus.allowsCapture
        )

        let hasAccessibility = SystemElementDetector().hasAccessibilityPermission
        accessibilityRow.apply(
            text: hasAccessibility ? "已授权" : "按需授权",
            isGranted: hasAccessibility
        )

        shortcutBadge.text = settings.captureShortcut.displayName
    }

    private static func microphoneStatusText(_ status: MicrophonePermission.Status) -> String {
        switch status {
        case .granted:        return "已授权"
        case .notDetermined:  return "按需授权"
        case .denied:         return "未授权"
        case .restricted:     return "受系统限制"
        }
    }

    // MARK: - 系统设置

    private func openScreenRecordingSettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    private func openMicrophoneSettings() {
        guard let url = MicrophonePermission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func openAccessibilitySettings() {
        // 复用现有引导：该实现刻意用 URL scheme 而非
        // `AXIsProcessTrustedWithOptions(prompt)`，避免弹系统提示。
        SystemElementDetector.openAccessibilitySettings()
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 窗口

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "欢迎使用 anShot"
        // 窗口由本对象持有并在关闭时置空；交给 AppKit 自动释放会与 ARC 打架。
        window.isReleasedWhenClosed = false
        // 菜单栏程序切到别的应用时窗口不能消失：用户往往是去系统设置
        // 授权，回来还要接着看这张清单。
        window.hidesOnDeactivate = false
        window.delegate = self
        window.contentView = makeContentView()
        window.center()
        return window
    }

    private func makeContentView() -> NSView {
        let root = WelcomeBackgroundView()

        // 每次建窗都新建视图：见属性区的说明。
        let screenRow = PermissionRowView(
            title: "屏幕录制",
            requirement: "必需",
            subtitle: "截图与录屏的基础权限"
        )
        let microphoneRow = PermissionRowView(
            title: "麦克风",
            requirement: "可选",
            subtitle: "录制讲解声音时使用"
        )
        let accessibilityRow = PermissionRowView(
            title: "辅助功能",
            requirement: "可选",
            subtitle: "只影响元素识别，不影响截图"
        )
        let shortcutBadge = ShortcutBadgeView()
        let tryCaptureButton = SettingsPushButton(
            title: "试一下截图",
            emphasis: .primary,
            target: self,
            action: #selector(didTapTryCapture)
        )
        let relaunchButton = SettingsPushButton(
            title: "重新启动",
            target: self,
            action: #selector(didTapRelaunch)
        )
        let openSettingsButton = SettingsPushButton(
            title: "打开设置",
            target: self,
            action: #selector(didTapOpenSettings)
        )

        self.screenRow = screenRow
        self.microphoneRow = microphoneRow
        self.accessibilityRow = accessibilityRow
        self.shortcutBadge = shortcutBadge

        // 每一行只负责「把用户送到该去的地方」，权限请求不在这里发生。
        screenRow.onOpenSettings = { [weak self] in
            self?.openScreenRecordingSettings()
        }
        microphoneRow.onOpenSettings = { [weak self] in
            self?.openMicrophoneSettings()
        }
        accessibilityRow.onOpenSettings = { [weak self] in
            self?.openAccessibilitySettings()
        }

        let header = makeHeader()
        let permissions = makePermissionCard(
            screenRow: screenRow,
            microphoneRow: microphoneRow,
            accessibilityRow: accessibilityRow
        )
        let shortcutLine = makeShortcutLine(badge: shortcutBadge)

        let buttons = NSStackView(views: [tryCaptureButton, relaunchButton, openSettingsButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for view in [header, permissions, shortcutLine] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        root.addSubview(buttons)

        let margin: CGFloat = 24

        // 内容整体偏上、按钮贴底：窗口固定 420 高，内容不足时多出的空白
        // 落在快捷键与按钮之间，而不是把所有东西垂直居中后上下各空一截。
        let buttonGap = buttons.topAnchor.constraint(
            greaterThanOrEqualTo: shortcutLine.bottomAnchor,
            constant: 16
        )

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),

            permissions.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            permissions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            permissions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),

            shortcutLine.topAnchor.constraint(equalTo: permissions.bottomAnchor, constant: 12),
            shortcutLine.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            shortcutLine.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),

            buttons.leadingAnchor.constraint(
                greaterThanOrEqualTo: root.leadingAnchor,
                constant: margin
            ),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margin),
            buttonGap,
        ])

        return root
    }

    private func makeHeader() -> NSView {
        let icon = NSImageView()
        // 菜单栏程序也可能在无 Dock 图标时拿不到 `applicationIconImage`，
        // 此时用系统符号兜底，避免标题左侧空一块。
        icon.image = NSApp.applicationIconImage
            ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
        ])

        let title = NSTextField(labelWithString: "欢迎使用 anShot")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.textColor = .labelColor

        let subtitle = NSTextField(
            labelWithString: "先确认下面的系统权限，之后就能随时截图了。"
        )
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let header = NSStackView(views: [icon, text])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        return header
    }

    private func makePermissionCard(
        screenRow: PermissionRowView,
        microphoneRow: PermissionRowView,
        accessibilityRow: PermissionRowView
    ) -> NSView {
        let firstSeparator = makeSeparator()
        let secondSeparator = makeSeparator()
        let content = NSStackView(views: [
            screenRow,
            firstSeparator,
            microphoneRow,
            secondSeparator,
            accessibilityRow,
        ])
        content.orientation = .vertical
        // 竖向 NSStackView 的 `.width` 对齐在各系统版本上行为并不一致，
        // 这里显式把每一行拉满容器宽度，分隔线也才能贯通整张卡片。
        content.alignment = .leading
        content.spacing = 6

        let items: [NSView] = [
            screenRow,
            firstSeparator,
            microphoneRow,
            secondSeparator,
            accessibilityRow,
        ]
        for item in items {
            item.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        return SettingsCardView(
            symbolName: "lock.shield",
            title: "系统权限",
            content: content
        )
    }

    private func makeSeparator() -> NSView {
        let separator = HairlineView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func makeShortcutLine(badge: ShortcutBadgeView) -> NSView {
        let label = NSTextField(labelWithString: "截图快捷键")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor

        let hint = NSTextField(labelWithString: "可在设置中修改")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        let line = NSStackView(views: [label, badge, hint])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 8
        return line
    }

    // MARK: - 按钮动作

    @objc private func didTapTryCapture() {
        // 先把闭包取到本地再关窗：关窗会触发 onClose，宿主可能因此释放
        // 本控制器，之后再读 `self.onTryCapture` 就不安全了。
        let action = onTryCapture
        // 必须先关窗再开始截图：覆盖层是整屏选区，欢迎窗口留在屏幕上
        // 会被一起截进图里，也会挡住用户判断选区边界。
        window?.close()
        action()
    }

    @objc private func didTapRelaunch() {
        let action = onRelaunch
        window?.close()
        action()
    }

    @objc private func didTapOpenSettings() {
        // 不关窗：用户去设置里改快捷键或保存位置后，可能还要回来
        // 接着看权限清单或点「试一下截图」。
        onOpenSettings()
    }
}

// MARK: - 窗口代理

extension WelcomeWindowController: NSWindowDelegate {

    func windowDidBecomeKey(_ notification: Notification) {
        // 用户去系统设置授权后切回本窗口，状态必须立即反映现实。
        refreshStatuses()
    }

    func windowWillClose(_ notification: Notification) {
        // 关闭即释放窗口与它的整棵视图树，维持「空闲期零窗口」。
        // 视图属性是弱引用，会随窗口一起自动变 nil，不需要手工拆。
        window = nil

        // 回调先取到本地并置空，再通知宿主：宿主通常在 onClose 里
        // 丢掉对本控制器的最后一个引用，之后再访问属性就不安全。
        let notify = onClose
        onClose = nil
        notify?()
    }
}

// MARK: - 背景

/// 窗口底色。
///
/// 走 `wantsUpdateLayer` + `updateLayer()` 而不是在 init 里赋 `cgColor`：
/// 动态色一旦赋给 layer 就会固定在当前外观，切换深浅模式后不会重绘
/// （与 `SettingsTheme` 的约定一致）。
private final class WelcomeBackgroundView: NSView {

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = SettingsTheme.windowBackground.cgColor
    }
}

/// 卡片内的 1pt 分隔线。
private final class HairlineView: NSView {

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

// MARK: - 权限行

/// 一行权限：状态圆点 + 名称/说明 + 当前状态 + 「打开系统设置」。
///
/// 只做展示与跳转，不持有任何权限逻辑——状态由控制器查询后 `apply` 进来，
/// 这样「查询」与「画一行」不会各自演化出第二套判断。
private final class PermissionRowView: NSView {

    /// 用户点击「打开系统设置」时执行。由控制器注入，避免本视图直接依赖
    /// `NSWorkspace` 与 URL scheme。
    var onOpenSettings: (() -> Void)?

    private let statusDot = StatusDotView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let actionButton = SettingsPushButton(
        title: "打开系统设置",
        emphasis: .secondary,
        target: nil,
        action: nil
    )

    init(title: String, requirement: String, subtitle: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        let requirementLabel = NSTextField(labelWithString: requirement)
        requirementLabel.font = .systemFont(ofSize: 11)
        requirementLabel.textColor = .tertiaryLabelColor

        let titleLine = NSStackView(views: [titleLabel, requirementLabel])
        titleLine.orientation = .horizontal
        titleLine.alignment = .firstBaseline
        titleLine.spacing = 6

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        let text = NSStackView(views: [titleLine, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        // 文本块吃掉行内剩余宽度，状态与按钮才能稳定靠右。
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionButton.target = self
        actionButton.action = #selector(openSettings)

        // 文本与状态之间放一个可伸缩空隙。
        //
        // 只靠 `text` 的低 hugging 优先级时，NSStackView 仍可能按各行
        // 内容宽度排布，于是「按需授权」比「已授权」宽出来的部分会把
        // 按钮推右——截图里三行按钮正是错开的。显式空隙把状态与按钮
        // 钉在右端，三行才对得上。
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [statusDot, text, spacer, statusLabel, actionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // 状态与按钮各自固定一列。
        //
        // 否则「已授权」与「按需授权」的宽度差会把按钮推成错落的阶梯；
        // 权限清单是拿来从上往下扫的，列不对齐会让每一行都像独立的一块。
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            statusLabel.widthAnchor.constraint(equalToConstant: 72),
            actionButton.widthAnchor.constraint(equalToConstant: 108),

            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    /// 写入当前状态。绿点表示可用，橙点表示「可以按需处理」；
    /// 可选权限未授权不是错误，所以不用红色制造紧张。
    func apply(text: String, isGranted: Bool) {
        statusLabel.stringValue = text
        statusDot.color = isGranted ? .systemGreen : .systemOrange
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }
}

/// 权限状态圆点。
private final class StatusDotView: NSView {

    var color: NSColor = .systemOrange {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

// MARK: - 快捷键键帽

/// 与设置窗口键帽同形制的快捷键徽标。
///
/// 自绘而不是用带背景色的 `NSTextField`：后者没有圆角，
/// 与设置窗口里裸键帽的观感对不上。
private final class ShortcutBadgeView: NSView {

    var text: String = "" {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private static let horizontalPadding: CGFloat = 16

    private var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Self.font,
            .foregroundColor: NSColor.labelColor,
        ]
    }

    override var intrinsicContentSize: NSSize {
        let width = (text as NSString).size(withAttributes: textAttributes).width
        return NSSize(
            width: ceil(width) + Self.horizontalPadding,
            height: SettingsTheme.keycapHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let radius = SettingsTheme.keycapRadius
        SettingsTheme.fillRoundedRect(
            bounds,
            radius: radius,
            color: SettingsTheme.keycapBackground,
            in: context
        )
        SettingsTheme.strokeRoundedRect(
            bounds.insetBy(dx: 0.5, dy: 0.5),
            radius: radius,
            color: SettingsTheme.keycapEdge,
            lineWidth: 1,
            in: context
        )

        guard !text.isEmpty else { return }
        let attributed = NSAttributedString(string: text, attributes: textAttributes)
        let size = attributed.size()
        attributed.draw(at: CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        ))
    }
}
