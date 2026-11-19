//
//  ScrollshotProgressBar.swift
//  AnShotUI
//
//  长截图实时交互界面（Phase 4 重构）：
//    1. `~42pt` 自适配浅/深色紧凑单行药丸主控制栏（避让 Dock、鼠标移入防抖、实时 W×H 像素尺寸、
//       自动翻页控制、速度切换、无权限内联「授权」、撤销、预览开关、OCR/标注直达、高亮完成/取消）；
//    2. 选区外侧独立可穿透/可折叠预览卡（整幅导航 + 定位框 + 高质量抗锯齿细节放大，
//       动态适配 1x/2x 屏缩放、空态居中与横向朝向修正）。
//
//  两个浮窗均声明 `sharingType = .none`，绝不会被抓进长图。
//

import AnShotCapture
import AnShotCore
import AppKit

/// 滚动截图浮层要显示的预览内容。
struct ScrollshotPreviewContent {
    /// 导航图：**整幅长图**等比 contain 进导航区。
    let navigatorImage: CGImage
    let navigatorPixelWidth: Int
    let navigatorPixelHeight: Int
    /// 长图源像素宽度（放大栏据此换算「一屏装多少世界行」）。
    let worldWidth: Int
    /// 导航图纵向覆盖的世界行区间 `[worldStart, worldStart + worldHeight)`。
    let worldStart: Int
    let worldHeight: Int
    /// 当前屏幕视口在**世界坐标**里的行区间；无法确定时为 nil。
    let viewportWorldRows: Range<Int>?
    /// 长截图滚动轴（竖向或横向），用于预览卡正确朝向与尺寸展示。
    let axis: ScrollAxis

    init(
        navigatorImage: CGImage,
        navigatorPixelWidth: Int,
        navigatorPixelHeight: Int,
        worldWidth: Int,
        worldStart: Int,
        worldHeight: Int,
        viewportWorldRows: Range<Int>?,
        axis: ScrollAxis = .vertical
    ) {
        self.navigatorImage = navigatorImage
        self.navigatorPixelWidth = navigatorPixelWidth
        self.navigatorPixelHeight = navigatorPixelHeight
        self.worldWidth = worldWidth
        self.worldStart = worldStart
        self.worldHeight = worldHeight
        self.viewportWorldRows = viewportWorldRows
        self.axis = axis
    }
}

/// 自适配系统浅/深主题的动态背景胶囊容器，支持鼠标移入/移出追踪。
private final class ScrollshotSurfaceView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private let cornerRadius: CGFloat
    private let backgroundProvider: () -> NSColor
    private let borderProvider: () -> NSColor
    private var hoverArea: NSTrackingArea?

    init(
        frame frameRect: NSRect = .zero,
        cornerRadius: CGFloat,
        background: @escaping () -> NSColor = { NSColor.windowBackgroundColor.withAlphaComponent(0.94) },
        border: @escaping () -> NSColor = { NSColor.separatorColor }
    ) {
        self.cornerRadius = cornerRadius
        self.backgroundProvider = background
        self.borderProvider = border
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = backgroundProvider().cgColor
        layer?.borderColor = borderProvider().cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

/// 高质量抗锯齿图像视图：启用 `.high` 插值并按比例绘制，消除长图缩略图的锯齿毛刺。
private final class ScrollshotHighQualityImageView: NSView {
    var cgImage: CGImage? {
        didSet { needsDisplay = true }
    }
    var drawsAspectFit: Bool = true {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let cg = context.cgContext
        cg.saveGState()
        cg.setFillColor(NSColor.textBackgroundColor.withAlphaComponent(0.45).cgColor)
        cg.fill(bounds)

        if let cgImage, cgImage.width > 0, cgImage.height > 0 {
            context.imageInterpolation = .high
            cg.interpolationQuality = .high
            let drawRect: CGRect
            if drawsAspectFit {
                let imgW = CGFloat(cgImage.width)
                let imgH = CGFloat(cgImage.height)
                let scale = min(bounds.width / imgW, bounds.height / imgH)
                let targetW = imgW * scale
                let targetH = imgH * scale
                drawRect = CGRect(
                    x: (bounds.width - targetW) / 2,
                    y: (bounds.height - targetH) / 2,
                    width: targetW,
                    height: targetH
                )
            } else {
                drawRect = bounds
            }
            cg.draw(cgImage, in: drawRect)
        }
        cg.restoreGState()
    }
}

/// 导航栏：整幅长图缩略图 + 可上下拖动的定位框（自适应 1x/2x 屏比例与抗锯齿渲染）。
private final class ScrollshotNavigatorView: NSView {

    var onFocusChange: (@MainActor (Int) -> Void)?

    private let thumbnailView = ScrollshotHighQualityImageView(frame: .zero)
    private let focusView = NSView()

    private var thumbnailPixelSize = CGSize.zero
    private var worldStart = 0
    private var worldHeight = 0
    private var focusWorldRow = 0
    private var focusWindowRows = 1

    private static let minimumFocusHeight: CGFloat = 14

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        thumbnailView.drawsAspectFit = false
        addSubview(thumbnailView)

        focusView.wantsLayer = true
        focusView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        focusView.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
        focusView.layer?.borderWidth = 1.5
        focusView.layer?.cornerRadius = 2
        focusView.isHidden = true
        addSubview(focusView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
    }

    /// 根据当前视图尺寸与所在屏 `backingScaleFactor` 计算缩略图等比显示框（彻底修复 1x 屏硬编码 0.5 问题）。
    private var imageFrame: CGRect {
        guard thumbnailPixelSize.width > 0, thumbnailPixelSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        let rawW = thumbnailPixelSize.width / scale
        let rawH = thumbnailPixelSize.height / scale
        let fit = min(1, min(bounds.width / rawW, bounds.height / rawH))
        let displayW = max(1, rawW * fit)
        let displayH = max(1, rawH * fit)
        return CGRect(
            x: (bounds.width - displayW) / 2,
            y: (bounds.height - displayH) / 2,
            width: displayW,
            height: displayH
        )
    }

    func update(content: ScrollshotPreviewContent?, focusWorldRow: Int, windowRows: Int) {
        guard let content else {
            thumbnailPixelSize = .zero
            worldStart = 0
            worldHeight = 0
            thumbnailView.cgImage = nil
            focusView.isHidden = true
            needsLayout = true
            return
        }
        thumbnailPixelSize = CGSize(
            width: content.navigatorPixelWidth,
            height: content.navigatorPixelHeight
        )
        worldStart = content.worldStart
        worldHeight = content.worldHeight
        thumbnailView.cgImage = content.navigatorImage
        self.focusWorldRow = focusWorldRow
        self.focusWindowRows = windowRows
        focusView.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        thumbnailView.frame = imageFrame
        layoutFocusView()
    }

    private func layoutFocusView() {
        guard !focusView.isHidden, worldHeight > 0 else { return }
        let frame = imageFrame
        guard frame.height > 0 else { return }

        let pointsPerRow = frame.height / CGFloat(worldHeight)
        let height = min(frame.height, max(Self.minimumFocusHeight, CGFloat(focusWindowRows) * pointsPerRow))
        let centerY = frame.minY + CGFloat(focusWorldRow - worldStart) * pointsPerRow
        let top = min(max(frame.minY, centerY - height / 2), max(frame.minY, frame.maxY - height))
        focusView.frame = CGRect(x: 0, y: top, width: bounds.width, height: height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    #if DEBUG
    var thumbnailFrameForDiagnostics: CGRect { imageFrame }
    var focusFrameForDiagnostics: CGRect? { focusView.isHidden ? nil : focusView.frame }
    #endif

    override func mouseDown(with event: NSEvent) {
        moveFocus(toViewY: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseDragged(with event: NSEvent) {
        moveFocus(toViewY: convert(event.locationInWindow, from: nil).y)
    }

    private func moveFocus(toViewY y: CGFloat) {
        let frame = imageFrame
        guard worldHeight > 0, frame.height > 0 else { return }
        let clampedY = min(max(y, frame.minY), frame.maxY)
        let ratio = (clampedY - frame.minY) / frame.height
        onFocusChange?(worldStart + Int((ratio * CGFloat(worldHeight)).rounded()))
    }
}

/// 长截图 `42pt` 轻量悬浮控制栏 + 独立侧边预览卡。
@MainActor
final class ScrollshotProgressBar {

    // MARK: - 尺寸常量

    /// 主控制栏高度（42pt 紧凑单行药丸，契约 `ux-polish/plan.md` §4.3）。
    static let controlBarHeight: CGFloat = 42
    static let controlBarMinWidth: CGFloat = 620
    /// 独立侧边预览卡尺寸。
    static let previewCardSize = CGSize(width: 300, height: 280)

    /// 导航图的像素尺寸（按 2x 屏生成，1x 屏由 `ScrollshotNavigatorView` 动态 fit）。
    static let navigatorPixelSize = CGSize(width: 144, height: 440)
    /// 放大详情图的像素宽度。
    static let detailPixelWidth = 420

    // 侧边预览卡内部子区坐标（左下原点）
    private static let navigatorFrame = CGRect(x: 10, y: 10, width: 72, height: 224)
    private static let detailFrame = CGRect(x: 90, y: 10, width: 200, height: 224)
    private static let statusFrame = CGRect(x: 10, y: 242, width: 208, height: 26)

    // MARK: - 窗口与控件

    private let panel: NSPanel
    private let barSurface: ScrollshotSurfaceView
    private let statusDot = NSView()
    private let dimensionsLabel = NSTextField(labelWithString: "0 × 0")
    private let guideLabel = NSTextField(labelWithString: "")
    private let authorizeButton = NSButton(title: "授权", target: nil, action: nil)
    private let autoScrollButton = NSButton(title: "暂停", target: nil, action: nil)
    private let speedButton = NSButton(title: "标准", target: nil, action: nil)
    private let undoButton = NSButton(title: "撤销", target: nil, action: nil)
    private let previewToggleButton = NSButton(title: "预览", target: nil, action: nil)
    private let ocrButton = NSButton(title: "OCR", target: nil, action: nil)
    private let editButton = NSButton(title: "标注", target: nil, action: nil)
    private let finishButton = NSButton(title: "完成", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    // 选区外侧独立可穿透/可折叠预览卡
    private let previewPanel: NSPanel
    private let previewSurface: ScrollshotSurfaceView
    private let navigatorView: ScrollshotNavigatorView
    private let detailView: ScrollshotHighQualityImageView
    private let detailHintLabel: NSTextField
    private let statusButton: NSButton
    private let clickThroughButton: NSButton
    private let collapsePreviewButton: NSButton

    // 状态
    private var content: ScrollshotPreviewContent?
    private var focusWorldRow = 0
    private var isPinned = false
    private(set) var isPreviewVisible = true
    private(set) var isPreviewClickThrough = false
    private var lastSelectionScreenRect: CGRect = .zero

    // MARK: - 回调

    var onDetailRequest: (@MainActor (Range<Int>, Int) -> CGImage?)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOCR: (() -> Void)?
    var onEdit: (() -> Void)?
    var onUndo: (() -> Void)?
    var onToggleAutoScroll: (() -> Void)?
    var onCycleAutoScrollSpeed: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    /// 主控制栏窗口号（诊断/排除用）。
    var windowID: Int? {
        panel.windowNumber > 0 ? panel.windowNumber : nil
    }

    var isVisible: Bool { panel.isVisible }

    /// 主控制栏当前高度（供测试校验 `~42pt` 契约）。
    var controlBarHeightForTesting: CGFloat { panel.frame.height }

    /// 独立预览卡当前是否可见（供测试校验折叠/展开）。
    var isPreviewCardWindowVisibleForTesting: Bool { previewPanel.isVisible }

    /// 独立预览卡当前是否处于穿透态（供测试校验）。
    var isPreviewCardClickThroughForTesting: Bool { previewPanel.ignoresMouseEvents }

    init() {
        // ── 1. 构建 42pt 轻量自适配主控制栏 ────────────────────
        let initialBarSize = CGSize(width: Self.controlBarMinWidth, height: Self.controlBarHeight)
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: initialBarSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .none

        barSurface = ScrollshotSurfaceView(
            frame: CGRect(origin: .zero, size: initialBarSize),
            cornerRadius: Self.controlBarHeight / 2
        )

        // ── 2. 构建选区外侧独立可穿透/可折叠预览卡 ─────────────
        previewPanel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.previewCardSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        previewPanel.isFloatingPanel = true
        previewPanel.hidesOnDeactivate = false
        previewPanel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        previewPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        previewPanel.becomesKeyOnlyIfNeeded = true
        previewPanel.isMovable = true
        previewPanel.isMovableByWindowBackground = true
        previewPanel.backgroundColor = .clear
        previewPanel.isOpaque = false
        previewPanel.hasShadow = true
        previewPanel.sharingType = .none

        previewSurface = ScrollshotSurfaceView(
            frame: CGRect(origin: .zero, size: Self.previewCardSize),
            cornerRadius: 10
        )

        navigatorView = ScrollshotNavigatorView(frame: Self.navigatorFrame)
        detailView = ScrollshotHighQualityImageView(frame: Self.detailFrame)
        detailHintLabel = NSTextField(wrappingLabelWithString: "滚动页面开始拼接\n拖动蓝框查看细节")
        statusButton = NSButton(title: "", target: nil, action: nil)
        clickThroughButton = NSButton(title: "穿透", target: nil, action: nil)
        collapsePreviewButton = NSButton(title: "收起", target: nil, action: nil)

        configureControlBarUI()
        configurePreviewCardUI()

        barSurface.onHoverChanged = { [weak self] hovered in
            self?.onHoverChanged?(hovered)
        }
        navigatorView.onFocusChange = { [weak self] worldRow in
            self?.handleFocusChange(worldRow)
        }

        updateStatus()
        updateGuide(Self.guideScrolling)
        updateAutoScrollState(.idle, speed: .normal)
        updateUndoAvailability(false)
    }

    private func configureControlBarUI() {
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        dimensionsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        dimensionsLabel.textColor = .labelColor
        dimensionsLabel.setContentHuggingPriority(.required, for: .horizontal)
        dimensionsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dimensionsLabel.translatesAutoresizingMaskIntoConstraints = false

        guideLabel.font = .systemFont(ofSize: 11, weight: .regular)
        guideLabel.textColor = .secondaryLabelColor
        guideLabel.lineBreakMode = .byTruncatingTail
        guideLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        guideLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        guideLabel.translatesAutoresizingMaskIntoConstraints = false

        authorizeButton.bezelStyle = .rounded
        authorizeButton.controlSize = .mini
        authorizeButton.contentTintColor = .systemOrange
        authorizeButton.isHidden = true
        authorizeButton.toolTip = "授予辅助功能权限后自动平滑翻页"
        authorizeButton.target = self
        authorizeButton.action = #selector(handleAuthorize)

        func configureSmallButton(
            _ button: NSButton,
            symbol: String? = nil,
            toolTip: String,
            action: Selector
        ) {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.toolTip = toolTip
            button.target = self
            button.action = action
            if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) {
                button.image = img
                button.imagePosition = .imageLeading
            }
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        configureSmallButton(autoScrollButton, symbol: "pause.fill", toolTip: "暂停 / 继续自动翻页（Space）", action: #selector(handleToggleAutoScroll))
        configureSmallButton(speedButton, toolTip: "切换自动翻页速度（慢 / 标准 / 快）", action: #selector(handleCycleSpeed))
        configureSmallButton(undoButton, symbol: "arrow.uturn.backward", toolTip: "撤销上一段拼接（⌘Z）", action: #selector(handleUndo))
        configureSmallButton(previewToggleButton, symbol: "sidebar.right", toolTip: "展开 / 折叠侧边实时预览卡", action: #selector(handleTogglePreviewCard))
        configureSmallButton(ocrButton, symbol: "text.viewfinder", toolTip: "完成并识别长图文字 (OCR)", action: #selector(handleOCR))
        configureSmallButton(editButton, symbol: "pencil.tip", toolTip: "完成并进入标注编辑", action: #selector(handleEdit))
        configureSmallButton(finishButton, symbol: "checkmark", toolTip: "完成长截图（Enter）", action: #selector(handleFinish))
        finishButton.keyEquivalent = "\r"
        finishButton.bezelColor = .controlAccentColor
        configureSmallButton(cancelButton, symbol: "xmark", toolTip: "取消长截图（Esc）", action: #selector(handleCancel))

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [
            statusDot,
            dimensionsLabel,
            guideLabel,
            authorizeButton,
            divider,
            autoScrollButton,
            speedButton,
            undoButton,
            previewToggleButton,
            ocrButton,
            editButton,
            finishButton,
            cancelButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        barSurface.addSubview(row)
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 18),
            guideLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            guideLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180),

            row.leadingAnchor.constraint(equalTo: barSurface.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: barSurface.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: barSurface.centerYAnchor),
        ])

        panel.contentView = barSurface
        resizeBarToFit()
    }

    private func configurePreviewCardUI() {
        previewSurface.addSubview(navigatorView)

        detailView.wantsLayer = true
        detailView.layer?.cornerRadius = 4
        detailView.layer?.masksToBounds = true
        detailView.layer?.borderWidth = 1
        detailView.layer?.borderColor = NSColor.separatorColor.cgColor
        previewSurface.addSubview(detailView)

        // 空态文案真正垂直 + 水平居中（修复旧版顶对齐缺陷）。
        detailHintLabel.font = .systemFont(ofSize: 11)
        detailHintLabel.textColor = .secondaryLabelColor
        detailHintLabel.alignment = .center
        detailHintLabel.maximumNumberOfLines = 3
        detailHintLabel.translatesAutoresizingMaskIntoConstraints = false
        detailView.addSubview(detailHintLabel)
        NSLayoutConstraint.activate([
            detailHintLabel.centerXAnchor.constraint(equalTo: detailView.centerXAnchor),
            detailHintLabel.centerYAnchor.constraint(equalTo: detailView.centerYAnchor),
            detailHintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: detailView.leadingAnchor, constant: 8),
            detailHintLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailView.trailingAnchor, constant: -8),
        ])

        statusButton.isBordered = false
        statusButton.font = .systemFont(ofSize: 11)
        statusButton.alignment = .left
        statusButton.frame = Self.statusFrame
        statusButton.target = self
        statusButton.action = #selector(handleFollowCurrent)
        previewSurface.addSubview(statusButton)

        clickThroughButton.bezelStyle = .rounded
        clickThroughButton.controlSize = .mini
        clickThroughButton.frame = CGRect(x: 212, y: 245, width: 38, height: 20)
        clickThroughButton.toolTip = "开启鼠标穿透（不遮挡滚轮操作，可在主控制栏点击「预览」恢复）"
        clickThroughButton.target = self
        clickThroughButton.action = #selector(handleTogglePreviewClickThrough)
        previewSurface.addSubview(clickThroughButton)

        collapsePreviewButton.bezelStyle = .rounded
        collapsePreviewButton.controlSize = .mini
        collapsePreviewButton.frame = CGRect(x: 254, y: 245, width: 38, height: 20)
        collapsePreviewButton.toolTip = "折叠预览卡"
        collapsePreviewButton.target = self
        collapsePreviewButton.action = #selector(handleTogglePreviewCard)
        previewSurface.addSubview(collapsePreviewButton)

        previewPanel.contentView = previewSurface
    }

    private func resizeBarToFit() {
        barSurface.layoutSubtreeIfNeeded()
        let fittingWidth = max(Self.controlBarMinWidth, ceil(barSurface.fittingSize.width))
        let screenWidth = (panel.screen ?? NSScreen.main)?.visibleFrame.width ?? 1440
        let finalWidth = min(fittingWidth, max(480, screenWidth - 24))
        var frame = panel.frame
        let centerX = frame.midX
        frame.size = CGSize(width: finalWidth, height: Self.controlBarHeight)
        if frame.origin != .zero {
            frame.origin.x = centerX - finalWidth / 2
        }
        panel.setFrame(frame, display: true)
    }

    // MARK: - 定位计算（纯函数，避让 Dock 与选区）

    /// 计算 42pt 主控制栏的最佳落点：优先选区下方居中，不够翻上方，均不够则贴屏幕可见区底部（避让 Dock）。
    static func preferredControlBarFrame(
        near selectionScreenRect: CGRect,
        barSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat = 12
    ) -> CGRect {
        let clampedX = min(
            max(visibleFrame.minX + gap, selectionScreenRect.midX - barSize.width / 2),
            max(visibleFrame.minX + gap, visibleFrame.maxX - barSize.width - gap)
        )
        let belowY = selectionScreenRect.minY - barSize.height - gap
        let aboveY = selectionScreenRect.maxY + gap
        let y: CGFloat
        if belowY >= visibleFrame.minY + gap {
            y = belowY
        } else if aboveY + barSize.height <= visibleFrame.maxY - gap {
            y = aboveY
        } else {
            y = visibleFrame.minY + gap
        }
        return CGRect(origin: CGPoint(x: clampedX, y: y), size: barSize)
    }

    /// 计算侧边独立预览卡的最佳落点：优先选区右侧，放不下翻左侧，均放不下靠可见区右缘。
    static func preferredPreviewCardFrame(
        near selectionScreenRect: CGRect,
        cardSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat = 12
    ) -> CGRect {
        let minY = visibleFrame.minY + gap
        let maxY = max(minY, visibleFrame.maxY - cardSize.height - gap)
        let y = min(max(selectionScreenRect.maxY - cardSize.height, minY), maxY)

        let rightX = selectionScreenRect.maxX + gap
        if rightX + cardSize.width <= visibleFrame.maxX - gap {
            return CGRect(origin: CGPoint(x: rightX, y: y), size: cardSize)
        }
        let leftX = selectionScreenRect.minX - cardSize.width - gap
        if leftX >= visibleFrame.minX + gap {
            return CGRect(origin: CGPoint(x: leftX, y: y), size: cardSize)
        }
        let fallbackX = max(visibleFrame.minX + gap, visibleFrame.maxX - cardSize.width - gap)
        return CGRect(origin: CGPoint(x: fallbackX, y: y), size: cardSize)
    }

    // MARK: - 展示与状态更新

    func show(near selectionScreenRect: CGRect) {
        lastSelectionScreenRect = selectionScreenRect
        isPreviewVisible = true
        setPreviewClickThrough(false)

        let screen = NSScreen.screens.first { $0.frame.intersects(selectionScreenRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        resizeBarToFit()
        let barFrame = Self.preferredControlBarFrame(
            near: selectionScreenRect,
            barSize: panel.frame.size,
            visibleFrame: visible
        )
        panel.setFrame(barFrame, display: true)
        panel.orderFrontRegardless()

        let cardFrame = Self.preferredPreviewCardFrame(
            near: selectionScreenRect,
            cardSize: Self.previewCardSize,
            visibleFrame: visible
        )
        previewPanel.setFrame(cardFrame, display: true)
        previewPanel.orderFrontRegardless()

        updateGuide(Self.guidePreparing)
    }

    /// 引导文案常量（保持语义稳定，兼容既有诊断校验）。
    static let guidePreparing = "准备首帧…"
    static let guideScrolling = "滚动页面，自动捕获更多内容"
    static let guideAutoScrolling = "自动翻页中 · 空格暂停"
    static let guidePaused = "已暂停 · 可继续滚动或空格恢复"
    static let guideReachedBottom = "已自动触底 · 可按回车完成"
    static let guideNeedsAccessibility = "手动滚动（授权可自动翻页）"
    static let guideStalled = "暂未对齐，回滚重叠区可继续滚动"
    static let guideHeightLimit = "已达长度上限，可按回车保存"
    static let guideFrameLimit = "已达抓帧上限，正在生成长图"

    /// 更新实时像素尺寸显示（如 `1280 × 3420`）。
    func updateDimensions(width: Int, height: Int) {
        dimensionsLabel.stringValue = "\(width) × \(height)"
    }

    /// 更新分段撤销按钮可用性。
    func updateUndoAvailability(_ canUndo: Bool) {
        undoButton.isEnabled = canUndo
    }

    /// 更新自动翻页状态与速度按钮视觉。
    func updateAutoScrollState(_ state: AutoScrollState, speed: AutoScrollSpeed) {
        speedButton.title = speed.displayName
        switch state {
        case .running:
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            autoScrollButton.title = "暂停"
            autoScrollButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "暂停")
            authorizeButton.isHidden = true
            updateGuide(Self.guideAutoScrolling)
        case .pausedForHover:
            statusDot.layer?.backgroundColor = NSColor.systemYellow.cgColor
            autoScrollButton.title = "悬停"
            autoScrollButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "悬停暂停")
            authorizeButton.isHidden = true
        case .pausedByUser:
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            autoScrollButton.title = "自动"
            autoScrollButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "继续自动")
            authorizeButton.isHidden = true
            updateGuide(Self.guidePaused)
        case .reachedBottom:
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            autoScrollButton.title = "继续"
            autoScrollButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "继续")
            authorizeButton.isHidden = true
            updateGuide(Self.guideReachedBottom)
        case .needsAccessibilityPermission:
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            autoScrollButton.title = "手动"
            autoScrollButton.image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "手动模式")
            authorizeButton.isHidden = false
            updateGuide(Self.guideNeedsAccessibility, isWarning: true)
        case .idle:
            statusDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            autoScrollButton.title = "自动"
            autoScrollButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "开启自动翻页")
            authorizeButton.isHidden = true
        }
        resizeBarToFit()
    }

    /// 更新引导文案。
    func updateGuide(_ text: String, isWarning: Bool = false) {
        guideLabel.stringValue = text
        guideLabel.textColor = isWarning ? .systemOrange : .secondaryLabelColor
        if isWarning {
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        }
    }

    /// 切换侧边预览卡的展开 / 折叠。
    func setPreviewVisible(_ visible: Bool) {
        isPreviewVisible = visible
        if visible {
            if isPreviewClickThrough {
                setPreviewClickThrough(false)
            }
            if panel.isVisible {
                previewPanel.orderFrontRegardless()
            }
            previewToggleButton.title = "预览"
        } else {
            previewPanel.orderOut(nil)
            previewToggleButton.title = "显图"
        }
    }

    /// 切换侧边预览卡鼠标穿透（避免在窄屏上遮挡底部应用滚轮交互）。
    func setPreviewClickThrough(_ clickThrough: Bool) {
        isPreviewClickThrough = clickThrough
        previewPanel.ignoresMouseEvents = clickThrough
        previewPanel.alphaValue = clickThrough ? 0.65 : 1.0
        clickThroughButton.title = clickThrough ? "锁定" : "穿透"
    }

    /// 更新预览：整幅导航图 + 定位框 + 放大详情 + 实时像素宽高。
    func updatePreview(_ content: ScrollshotPreviewContent?) {
        self.content = content
        guard let content else {
            focusWorldRow = 0
            isPinned = false
            navigatorView.update(content: nil, focusWorldRow: 0, windowRows: 1)
            detailView.cgImage = nil
            detailHintLabel.isHidden = false
            updateStatus()
            return
        }
        if content.axis == .horizontal {
            updateDimensions(width: content.worldHeight, height: content.worldWidth)
        } else {
            updateDimensions(width: content.worldWidth, height: content.worldHeight)
        }
        if !isPinned, let viewport = content.viewportWorldRows {
            focusWorldRow = viewport.lowerBound + viewport.count / 2
        }
        refreshFocus()
    }

    private var detailWindowRows: Int {
        guard let content else { return 1 }
        let rows = Double(Self.detailFrame.height) * Double(content.worldWidth)
            / Double(Self.detailFrame.width)
        return max(1, Int(rows.rounded()))
    }

    private func focusWindow() -> Range<Int>? {
        guard let content, content.worldHeight > 0 else { return nil }
        let rows = min(detailWindowRows, content.worldHeight)
        let start = min(
            max(content.worldStart, focusWorldRow - rows / 2),
            content.worldStart + content.worldHeight - rows
        )
        return start..<(start + rows)
    }

    private func refreshFocus() {
        guard let content, let window = focusWindow() else { return }
        focusWorldRow = window.lowerBound + window.count / 2
        navigatorView.update(
            content: content,
            focusWorldRow: focusWorldRow,
            windowRows: window.count
        )
        refreshDetail(window: window)
        updateStatus()
    }

    private func refreshDetail(window: Range<Int>) {
        guard let image = onDetailRequest?(window, Self.detailPixelWidth) else {
            detailView.cgImage = nil
            detailHintLabel.isHidden = false
            return
        }
        detailView.cgImage = image
        detailHintLabel.isHidden = true
    }

    private func handleFocusChange(_ worldRow: Int) {
        guard content != nil else { return }
        isPinned = true
        focusWorldRow = worldRow
        refreshFocus()
    }

    @objc private func handleFollowCurrent() {
        guard let content else { return }
        isPinned = false
        if let viewport = content.viewportWorldRows {
            focusWorldRow = viewport.lowerBound + viewport.count / 2
        }
        refreshFocus()
    }

    private func updateStatus() {
        guard content != nil else {
            statusButton.title = "等待首帧…"
            statusButton.isEnabled = false
            statusButton.contentTintColor = .tertiaryLabelColor
            return
        }
        if isPinned {
            statusButton.title = "已锁定 · 点此跟随"
            statusButton.isEnabled = true
            statusButton.contentTintColor = .controlAccentColor
        } else {
            statusButton.title = "实时跟随中"
            statusButton.isEnabled = false
            statusButton.contentTintColor = .secondaryLabelColor
        }
    }

    func hide() {
        isPinned = false
        content = nil
        panel.orderOut(nil)
        previewPanel.orderOut(nil)
    }

    // MARK: - 诊断支持

    #if DEBUG
    var guideTextForDiagnostics: String { guideLabel.stringValue }

    func placeForDiagnostics(at frame: CGRect) {
        panel.setFrame(CGRect(origin: frame.origin, size: CGSize(width: max(Self.controlBarMinWidth, frame.width), height: Self.controlBarHeight)), display: true)
        panel.orderFrontRegardless()
        previewPanel.setFrame(
            CGRect(origin: CGPoint(x: frame.minX, y: frame.minY + Self.controlBarHeight + 12), size: Self.previewCardSize),
            display: true
        )
        previewPanel.orderFrontRegardless()
    }

    var frameForDiagnostics: CGRect { panel.frame }

    func focusForDiagnostics(worldRow: Int) {
        handleFocusChange(worldRow)
    }

    var focusWindowForDiagnostics: Range<Int>? { focusWindow() }
    var isPinnedForDiagnostics: Bool { isPinned }

    var layoutFramesForDiagnostics: (
        navigator: CGRect, detail: CGRect, status: CGRect, guide: CGRect, cancel: CGRect, finish: CGRect
    ) {
        (
            Self.navigatorFrame,
            Self.detailFrame,
            Self.statusFrame,
            guideLabel.frame,
            cancelButton.frame,
            finishButton.frame
        )
    }

    var navigatorFramesForDiagnostics: (thumbnail: CGRect, focus: CGRect?) {
        let container = navigatorView.superview
        let thumbnail = navigatorView.convert(navigatorView.thumbnailFrameForDiagnostics, to: container)
        let focus = navigatorView.focusFrameForDiagnostics.map {
            navigatorView.convert($0, to: container)
        }
        return (thumbnail, focus)
    }

    func followCurrentForDiagnostics() { handleFollowCurrent() }
    var contentViewForDiagnostics: NSView? { panel.contentView }
    #endif

    // MARK: - 按钮动作

    @objc private func handleFinish() { onFinish?() }
    @objc private func handleCancel() { onCancel?() }
    @objc private func handleOCR() { onOCR?() }
    @objc private func handleEdit() { onEdit?() }
    @objc private func handleUndo() { onUndo?() }
    @objc private func handleToggleAutoScroll() { onToggleAutoScroll?() }
    @objc private func handleCycleSpeed() { onCycleAutoScrollSpeed?() }
    @objc private func handleAuthorize() { onRequestAccessibility?() }
    @objc private func handleTogglePreviewCard() { setPreviewVisible(!isPreviewVisible) }
    @objc private func handleTogglePreviewClickThrough() { setPreviewClickThrough(!isPreviewClickThrough) }
}
