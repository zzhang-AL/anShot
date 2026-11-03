//
//  UpdateWindowController.swift
//  AnShotUI
//
//  更新窗口：检查结果、发布说明、下载进度与安装入口。
//
//  ── 它只负责「显示 + 转发」 ───────────────────────────────────
//
//  窗口不发起网络请求、不碰文件、不判断版本。所有动作都以闭包转给
//  `UpdateCoordinator`，由它统一维护状态机（设置页「关于」读的是同一份状态）。
//  这样做的直接好处：用户在下载过程中关掉窗口，下载不会中断；
//  再次打开时看到的仍是同一阶段，而不是一个「空白重来」的窗口。
//
//  ── 视觉 ─────────────────────────────────────────────────────
//
//  与设置窗口共用 `SettingsTheme` / `SettingsCardView` / `SettingsPushButton`。
//  不引入新的圆角、配色或字体：更新窗口是设置「关于」页的分支视图，
//  两处观感必须连续。发布说明用只读 `NSTextView` 展示**原文**，
//  不做 Markdown 渲染——渲染意味着要决定标题层级、列表缩进、链接样式，
//  而这些在更新场景里只会增加噪声。
//

import AnShotCore
import AppKit

@MainActor
final class UpdateWindowController: NSWindowController {

    /// 窗口阶段。与 `UpdateState`（检查结果）分开：一次「有新版本」之后
    /// 还有下载、校验、安装等若干步，把它们塞进全局状态会让设置页的
    /// 状态行承担它不关心的细节。
    enum Phase: Equatable {
        case checking
        case noRelease
        case upToDate(AppVersion)
        case available(UpdateRelease)
        case downloading(progress: Double)
        case verifying(String)
        case ready
        case installing
        case failed(message: String, canRetry: Bool)
    }

    // 动作全部由 coordinator 注入。
    var onRequestCheck: (() -> Void)?
    var onRequestDownload: (() -> Void)?
    var onRequestInstall: (() -> Void)?
    var onRequestLater: (() -> Void)?
    var onRequestOpenPage: (() -> Void)?
    var onRequestRetry: (() -> Void)?

    private static let contentSize = NSSize(width: 552, height: 620)

    private let content: UpdateContentView
    private var phase: Phase = .checking

    init(currentVersionDescription: String) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "anShot 更新"
        // 与设置窗口同一理由：更新窗口可能被关掉再打开（下载期间尤其常见），
        // 关窗即释放会让「重新打开」变成重建，进度与发布说明都丢了。
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false

        let contentView = UpdateContentView(
            frame: NSRect(origin: .zero, size: Self.contentSize),
            currentVersionDescription: currentVersionDescription
        )
        content = contentView
        window.contentView = contentView
        // 新建窗口的默认原点是屏幕左下角；不居中会有一半在屏幕外。
        window.center()

        super.init(window: window)

        content.onPrimary = { [weak self] in self?.primaryTapped() }
        content.onOpenPage = { [weak self] in self?.onRequestOpenPage?() }
        content.onLater = { [weak self] in self?.onRequestLater?() }

        render(.checking)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - 显示

    func show() {
        // 菜单栏程序平时不是活跃应用；不主动激活，窗口会开在后台，
        // 用户点「查看」后什么都没看到。
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 渲染一个阶段。窗口已关闭时仅记录，重新 `show()` 时仍是同一阶段。
    func render(_ phase: Phase) {
        self.phase = phase
        content.render(phase)
    }

    // MARK: - 动作

    private func primaryTapped() {
        switch phase {
        case .checking, .downloading, .verifying, .installing:
            // 这些阶段主按钮是禁用的；走到这里说明状态刚切换，忽略即可。
            break
        case .noRelease, .upToDate:
            onRequestCheck?()
        case .available(let release):
            // 没有 zip 就没有可自动安装的东西：直接把主按钮指向发布页，
            // 而不是让用户点一次「下载并安装」再收到失败提示。
            if release.zipURL == nil {
                onRequestOpenPage?()
            } else {
                onRequestDownload?()
            }
        case .ready:
            onRequestInstall?()
        case .failed(_, let canRetry):
            if canRetry {
                onRequestRetry?()
            } else {
                onRequestOpenPage?()
            }
        }
    }
}

// MARK: - 内容视图

/// 更新窗口的全部视图与渲染。
///
/// 独立成视图而不是散在 controller 里：controller 负责窗口生命周期与动作转发，
/// 视图只根据 `Phase` 更新文本与可用性，两者互不知道对方的实现。
private final class UpdateContentView: NSView {

    private let currentVersionDescription: String

    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let notesTextView = NSTextView()

    private let primaryButton = SettingsPushButton(
        title: "检查更新", emphasis: .primary, target: nil, action: nil
    )
    private let pageButton = SettingsPushButton(title: "打开发布页", target: nil, action: nil)
    private let laterButton = SettingsPushButton(title: "稍后", target: nil, action: nil)

    private(set) var lastRelease: UpdateRelease?

    var onPrimary: (() -> Void)?
    var onOpenPage: (() -> Void)?
    var onLater: (() -> Void)?

    init(frame: NSRect, currentVersionDescription: String) {
        self.currentVersionDescription = currentVersionDescription
        super.init(frame: frame)
        wantsLayer = true
        buildLayout()
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        pageButton.target = self
        pageButton.action = #selector(pageTapped)
        laterButton.target = self
        laterButton.action = #selector(laterTapped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // 动态色在每次外观变化后重新解析（理由见 SettingsTheme 顶部注释）。
        layer?.backgroundColor = SettingsTheme.windowBackground.cgColor
    }

    // MARK: 布局

    private func buildLayout() {
        let header = SettingsHeaderView(
            symbolName: "arrow.down.circle",
            title: "软件更新",
            subtitle: "从 GitHub Releases 获取新版本，下载后会校验来源与完整性。"
        )

        // 状态卡片
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.cell?.usesSingleLineMode = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        detailLabel.cell?.usesSingleLineMode = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        let statusStack = NSStackView(views: [statusLabel, detailLabel, progressBar])
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 8
        for view in [statusLabel, detailLabel, progressBar] {
            view.widthAnchor.constraint(equalTo: statusStack.widthAnchor).isActive = true
        }
        progressBar.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let statusCard = SettingsCardView(
            symbolName: "arrow.triangle.2.circlepath",
            title: "版本",
            content: statusStack
        )

        // 发布说明卡片
        let scrollView = makeNotesScrollView()
        let notesCard = SettingsCardView(
            symbolName: "text.alignleft",
            title: "发布说明",
            content: scrollView
        )

        // 按钮行右对齐：主操作永远在最右，符合 macOS 习惯。
        let buttonStack = NSStackView(views: [pageButton, laterButton, primaryButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 10
        let buttonRow = NSView()
        buttonRow.addSubview(buttonStack)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            buttonStack.topAnchor.constraint(equalTo: buttonRow.topAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: buttonRow.trailingAnchor),
        ])

        let stack = NSStackView(views: [header, statusCard, notesCard, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsTheme.cardGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let margin = SettingsTheme.margin
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            // 只约束上边界：内容比窗口矮时下方留白，比内容被挤压好。
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -margin),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notesCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        render(.checking)
    }

    private func makeNotesScrollView() -> NSScrollView {
        // 文本视图必须有一个非零初始 frame：`documentView` 不会替它布局，
        // 零尺寸的文档视图在第一次 `string` 赋值前看起来像「发布说明是空的」。
        notesTextView.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
        notesTextView.isEditable = false
        notesTextView.isSelectable = true
        notesTextView.isRichText = false
        notesTextView.drawsBackground = false
        notesTextView.font = .systemFont(ofSize: 12)
        notesTextView.textColor = .labelColor
        notesTextView.textContainerInset = NSSize(width: 4, height: 4)
        notesTextView.minSize = NSSize(width: 0, height: 0)
        notesTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        notesTextView.isVerticallyResizable = true
        notesTextView.isHorizontallyResizable = false
        notesTextView.autoresizingMask = [.width]
        notesTextView.textContainer?.widthTracksTextView = true
        notesTextView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = notesTextView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // 固定高度：窗口不可缩放，发布说明比窗口长时在卡片内滚动。
        scrollView.heightAnchor.constraint(equalToConstant: 200).isActive = true
        return scrollView
    }

    // MARK: 渲染

    func render(_ phase: UpdateWindowController.Phase) {
        switch phase {
        case .checking:
            statusLabel.stringValue = "正在检查更新…"
            detailLabel.stringValue = "当前版本 \(currentVersionDescription)"
            notesTextView.string = "检查完成后会在这里显示发布说明。"
            setProgress(indeterminate: true, value: 0)
            updateButtons(primary: ("检查中…", false), showsLater: false)

        case .noRelease:
            statusLabel.stringValue = "GitHub 上还没有发布版本。"
            detailLabel.stringValue = "当前版本 \(currentVersionDescription) · 有发布后会在这里提示。"
            notesTextView.string = "仓库尚未发布任何版本，因此暂时没有可下载的安装包。"
            hideProgress()
            updateButtons(primary: ("重新检查", true), showsLater: false)

        case .upToDate(let version):
            statusLabel.stringValue = "已是最新（\(version)）。"
            detailLabel.stringValue = "当前版本 \(currentVersionDescription)"
            notesTextView.string = "当前没有可安装的新版本。"
            hideProgress()
            updateButtons(primary: ("再次检查", true), showsLater: false)

        case .available(let release):
            lastRelease = release
            statusLabel.stringValue = "发现新版本 \(release.version)。"
            detailLabel.stringValue = detailText(for: release)
            notesTextView.string = notesText(for: release)
            hideProgress()
            updateButtons(
                primary: release.zipURL == nil ? ("打开发布页", true) : ("下载并安装", true),
                showsLater: true
            )

        case .downloading(let progress):
            let percent = Int((progress * 100).rounded())
            statusLabel.stringValue = "正在下载新版本… \(percent)%"
            detailLabel.stringValue = "下载完成后会自动校验 SHA256 与代码签名。"
            setProgress(indeterminate: false, value: progress)
            updateButtons(primary: ("下载中…", false), showsLater: false)

        case .verifying(let message):
            statusLabel.stringValue = message
            detailLabel.stringValue = "这一步失败会停止安装，不会替换当前版本。"
            setProgress(indeterminate: false, value: 1)
            updateButtons(primary: ("校验中…", false), showsLater: false)

        case .ready:
            statusLabel.stringValue = "新版本已下载并通过校验。"
            detailLabel.stringValue = "安装会退出 anShot，替换「应用程序」中的版本并自动重新打开。"
            hideProgress()
            updateButtons(primary: ("立即重启安装", true), showsLater: true)

        case .installing:
            statusLabel.stringValue = "正在安装，anShot 即将退出…"
            detailLabel.stringValue = "安装脚本会在退出后完成替换；失败时会自动回滚并重新打开旧版本。"
            setProgress(indeterminate: true, value: 0)
            updateButtons(primary: ("安装中…", false), showsLater: false)

        case .failed(let message, let canRetry):
            statusLabel.stringValue = message
            detailLabel.stringValue = canRetry
                ? "当前版本 \(currentVersionDescription) · 可以重试，或打开发布页手动下载。"
                : "当前版本 \(currentVersionDescription) · 请打开发布页手动下载安装包。"
            hideProgress()
            updateButtons(
                primary: canRetry ? ("重试", true) : ("打开发布页", true),
                showsLater: lastRelease != nil
            )
        }
    }

    private func detailText(for release: UpdateRelease) -> String {
        var parts = ["当前版本 \(currentVersionDescription)"]
        if let publishedAt = release.publishedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            parts.append("发布于 \(formatter.string(from: publishedAt))")
        }
        if release.size > 0 {
            parts.append(Self.formatBytes(release.size))
        }
        if release.zipURL == nil {
            parts.append("这个版本没有 zip 安装包，请打开发布页手动下载")
        }
        return parts.joined(separator: " · ")
    }

    private func notesText(for release: UpdateRelease) -> String {
        let trimmed = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "这个版本没有填写发布说明。" : trimmed
    }

    private func hideProgress() {
        progressBar.stopAnimation(nil)
        progressBar.isHidden = true
    }

    private func setProgress(indeterminate: Bool, value: Double) {
        progressBar.isHidden = false
        progressBar.isIndeterminate = indeterminate
        if indeterminate {
            progressBar.startAnimation(nil)
        } else {
            progressBar.stopAnimation(nil)
            progressBar.doubleValue = min(max(value, 0), 1)
        }
    }

    private func updateButtons(primary: (title: String, enabled: Bool), showsLater: Bool) {
        primaryButton.title = primary.title
        primaryButton.isEnabled = primary.enabled
        // 自绘按钮不会自动变灰：不压暗的话「下载中…」看起来仍然可按。
        primaryButton.alphaValue = primary.enabled ? 1 : 0.5
        // 自绘按钮的宽度来自 intrinsicContentSize；换标题后必须显式失效，
        // 否则「下载中…」会沿用上一个标题的宽度。
        primaryButton.invalidateIntrinsicContentSize()
        primaryButton.needsDisplay = true
        laterButton.isHidden = !showsLater
    }

    private static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: 动作

    @objc private func primaryTapped() {
        onPrimary?()
    }

    @objc private func pageTapped() {
        onOpenPage?()
    }

    @objc private func laterTapped() {
        onLater?()
    }
}
