//
//  ScrollshotProgressBar.swift
//  AnShotUI
//
//  滚动截图会话的浮层：左栏**整幅长图导航 + 可拖动定位框**，右栏**定位处放大详情**，
//  外加完成 / 取消。
//
//  ── 为什么要两栏（「整幅可见」与「看得清」的矛盾）──────────
//
//  长图是竖长的，比例常见 1:4 ~ 1:10。把它整个塞进一个容器，只剩两个选择：
//
//  * **按宽度铺满**（上一版的做法）：细节清楚，但高度是容器的好几倍，一屏只能
//    看到长图的一小段——用户始终不知道「整体还剩多少、我现在在哪」；
//  * **整幅 contain**：整体可见，但缩成几十点宽的一条，内容完全认不出来。
//
//  上一版选前者，靠滚动 + 位置标记补「我在哪」，代价就是**看不到整体**。
//  这一版把两个诉求拆给两栏：导航栏整幅 contain（回答「整体在哪、我在哪一段」），
//  放大栏按定位取原图切片（回答「那一段长什么样」）。两栏各自只做一件事，
//  合起来才同时成立。
//
//  ── 定位框是「窗口」而不是「游标」────────────────────────
//
//  蓝框高度 = 放大栏一屏能装下的世界行数，于是**框住多少 = 右边显示多少**，
//  拖动它等于把查看窗口滑到别处。用户拖走之后不再自动跟随采集位置——他主动去
//  看了别处，再把框弹回去是打断；状态行会提示，点一下即回到采集位置。
//
//  ── 位置一律用世界坐标 ────────────────────────────────────
//
//  导航图的像素高度会随长图长度、窗口尺寸与像素上限变化，把「用户拖到哪了」挂在
//  它上面就会在每次预览更新时漂移。所以浮层内部只保存 `focusWorldRow`（世界行），
//  显示时才换算成视图坐标；换算基准（`worldStart/worldHeight`）随预览一起下发。
//
//  ── 为什么必须让它「不被拍到」 ────────────────────────────
//
//  抓帧用的是固定区域（`CaptureScope.region`），**无法按窗口排除**。
//  浮层若压在选区里，就会被逐帧抓进长图。解法是 `sharingType = .none`：
//  在窗口层面声明「本窗口不可被共享/捕获」，ScreenCaptureKit 会遵守它。
//  这条设置让浮层可以自由摆放，不必再挤在选区外的缝隙里。
//
//  ⚠️ 该设置同时意味着浮层也无法被诊断**自拍**到（诊断抓的帧里它会是空白）。
//  验证浮层本身的外观要靠渲染成图（`contentViewForDiagnostics`）。
//

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
}

/// 导航栏：整幅长图缩略图 + 可上下拖动的定位框。
///
/// 自己处理鼠标事件而不是用 `NSPanGestureRecognizer`：这里要的是「按哪儿，框就
/// 到哪儿，然后跟着手走」，而不是「把拖动转成滚动量」。手势识别器给不了前一半。
private final class ScrollshotNavigatorView: NSView {

    /// 用户把定位框拖到了新的世界行（中心行）。
    var onFocusChange: (@MainActor (Int) -> Void)?

    private let thumbnailView = NSImageView()
    private let focusView = NSView()

    private var thumbnailPixelSize = CGSize.zero
    private var worldStart = 0
    private var worldHeight = 0
    private var focusWorldRow = 0
    private var focusWindowRows = 1

    /// 定位框的最小显示高度（点）：长图很长时一屏会被压成一条线，太细就拖不住。
    private static let minimumFocusHeight: CGFloat = 14

    /// 左上原点：与图像的行方向一致，省掉上下翻转的换算。
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4

        thumbnailView.imageScaling = .scaleAxesIndependently
        addSubview(thumbnailView)

        // 当前位置标记：标出「放大栏正在显示的是长图里的哪一段」。
        focusView.wantsLayer = true
        focusView.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.22).cgColor
        focusView.layer?.borderColor = NSColor.controlAccentColor
            .withAlphaComponent(0.95).cgColor
        focusView.layer?.borderWidth = 1
        focusView.layer?.cornerRadius = 2
        focusView.isHidden = true
        addSubview(focusView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 缩略图在视图内的显示框（点）。缩略图按 2x 生成、按 1x 显示，所以是像素的一半。
    private var imageFrame: CGRect {
        let size = CGSize(
            width: CGFloat(thumbnailPixelSize.width) * 0.5,
            height: CGFloat(thumbnailPixelSize.height) * 0.5
        )
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func update(content: ScrollshotPreviewContent?, focusWorldRow: Int, windowRows: Int) {
        guard let content else {
            thumbnailPixelSize = .zero
            worldStart = 0
            worldHeight = 0
            thumbnailView.image = nil
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
        let displaySize = CGSize(
            width: CGFloat(content.navigatorPixelWidth) * 0.5,
            height: CGFloat(content.navigatorPixelHeight) * 0.5
        )
        thumbnailView.image = NSImage(cgImage: content.navigatorImage, size: displaySize)
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

    /// 面板是 `nonactivatingPanel`：不覆写这条，第一次点击只会激活窗口、拖不动框。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    #if DEBUG
    /// 诊断专用：缩略图在导航栏里的显示框（点，左上原点）。
    var thumbnailFrameForDiagnostics: CGRect { imageFrame }

    /// 诊断专用：定位框的框；未显示时为 nil。
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
        // 拖出边界时夹住：夹的是位置，不是事件——这样手指回到视图内能立刻追上。
        let clampedY = min(max(y, frame.minY), frame.maxY)
        let ratio = (clampedY - frame.minY) / frame.height
        onFocusChange?(worldStart + Int((ratio * CGFloat(worldHeight)).rounded()))
    }
}

/// 滚动截图的进度浮层。
@MainActor
final class ScrollshotProgressBar {

    private let panel: NSPanel
    private let navigatorView: ScrollshotNavigatorView
    private let detailView: NSImageView
    private let detailHintLabel: NSTextField
    /// 引导行：告诉用户「现在该做什么」。
    ///
    /// 长截图靠用户**自己滚动**推进（自动滚动需要辅助功能权限，不为一个功能再要一次），
    /// 所以「请滚动」是这个界面唯一必须说清的操作指引。
    ///
    /// 位置在**底部左侧、与完成/取消同一行**：那时用户的视线本来就在这一带
    /// （他刚点完按钮、正在看下方的内容），而且它说的与那两个按钮是同一件事——
    /// 「接下来该怎么办」。它不是按钮，所以用纯文字（无底、白色字重）与
    /// 带底的按钮分开，不会被误认为可以点。
    private let guideLabel: NSTextField
    private let statusButton: NSButton
    private let finishButton: NSButton
    private let cancelButton: NSButton

    /// 最近一次预览快照。
    private var content: ScrollshotPreviewContent?
    /// 定位框中心的世界行。
    private var focusWorldRow = 0
    /// 用户是否把定位框拖离了采集位置（此后不再自动跟随）。
    private var isPinned = false

    /// 详情栏请求：按世界行区间取原图切片。
    ///
    /// 浮层不持有长图（那是几百 MB 的像素缓冲），只按需向会话要**当前这一段**。
    var onDetailRequest: (@MainActor (Range<Int>, Int) -> CGImage?)?
    /// 用户点了「完成」。
    var onFinish: (() -> Void)?
    /// 用户点了「取消」。
    var onCancel: (() -> Void)?

    /// 面板窗口号（诊断/排除用）。
    var windowID: Int? {
        panel.windowNumber > 0 ? panel.windowNumber : nil
    }

    var isVisible: Bool { panel.isVisible }

    /// 浮层尺寸（点）。
    private static let size = CGSize(width: 460, height: 332)
    /// 导航区（视图内坐标，左下原点）。
    private static let navigatorFrame = CGRect(x: 12, y: 52, width: 84, height: 244)
    /// 放大详情区。
    private static let detailFrame = CGRect(x: 104, y: 52, width: 344, height: 244)
    /// 状态行。
    private static let statusFrame = CGRect(x: 12, y: 302, width: 436, height: 20)
    /// 引导行（底部左侧，与完成/取消同一行；右侧 280pt 留给按钮）。
    ///
    /// 坐标是**左下原点**：`y = 17` 贴着底边，与 `cancelButton` 的 `y = 12` 基本对齐。
    private static let guideFrame = CGRect(x: 14, y: 17, width: 268, height: 20)

    /// 导航图的像素尺寸（导航区 84×244 点 @2x）：缩略图按它等比 contain。
    static let navigatorPixelSize = CGSize(width: 168, height: 488)
    /// 放大详情图的像素宽度（详情区 344 点 @2x）。
    static let detailPixelWidth = 688

    init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // 与录制范围框同层级：高于覆盖层，避免被截图覆盖层盖住。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // 不抢焦点：用户会话期间还要继续滚下层应用。
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        // **关键**：声明本窗口不可被屏幕捕获，否则它会出现在长图里。
        panel.sharingType = .none

        let contentView = NSView(frame: CGRect(origin: .zero, size: Self.size))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        contentView.layer?.cornerRadius = 10

        navigatorView = ScrollshotNavigatorView(frame: Self.navigatorFrame)
        contentView.addSubview(navigatorView)

        detailView = NSImageView(frame: Self.detailFrame)
        detailView.imageScaling = .scaleProportionallyUpOrDown
        detailView.wantsLayer = true
        detailView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        detailView.layer?.cornerRadius = 4
        detailView.layer?.masksToBounds = true
        contentView.addSubview(detailView)

        // 放大栏空态说明：没有它，用户看到一块空白不知道能干什么。
        detailHintLabel = NSTextField(labelWithString: "拖动蓝色定位框\n查看该处细节")
        detailHintLabel.font = .systemFont(ofSize: 11)
        detailHintLabel.textColor = .secondaryLabelColor
        detailHintLabel.alignment = .center
        detailHintLabel.frame = Self.detailFrame
        contentView.addSubview(detailHintLabel)

        guideLabel = NSTextField(labelWithString: "")
        guideLabel.font = .systemFont(ofSize: 12, weight: .medium)
        guideLabel.textColor = .white
        guideLabel.alignment = .left
        guideLabel.lineBreakMode = .byTruncatingTail
        guideLabel.frame = Self.guideFrame
        contentView.addSubview(guideLabel)

        statusButton = NSButton(title: "", target: nil, action: nil)
        statusButton.isBordered = false
        statusButton.font = .systemFont(ofSize: 11)
        statusButton.alignment = .center
        statusButton.frame = Self.statusFrame
        contentView.addSubview(statusButton)

        cancelButton = NSButton(title: "取消", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.frame = CGRect(x: 292, y: 12, width: 74, height: 28)
        contentView.addSubview(cancelButton)

        finishButton = NSButton(title: "完成", target: nil, action: nil)
        finishButton.bezelStyle = .rounded
        finishButton.controlSize = .small
        finishButton.keyEquivalent = "\r"
        finishButton.frame = CGRect(x: 374, y: 12, width: 74, height: 28)
        contentView.addSubview(finishButton)

        panel.contentView = contentView

        finishButton.target = self
        finishButton.action = #selector(handleFinish)
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        statusButton.target = self
        statusButton.action = #selector(handleFollowCurrent)
        navigatorView.onFocusChange = { [weak self] worldRow in
            self?.handleFocusChange(worldRow)
        }
        updateStatus()
        // 默认引导文案在这里就给：`show(near:)` 只负责「新一轮重置」，
        // 而诊断/自检路径不会调 `show`，不在这里设就会是一个空标签。
        updateGuide(Self.guideScrolling)
    }

    /// 显示在选区附近。浮层声明了 `sharingType = .none`，因此**压在选区上也不会
    /// 被抓进长图**；布局仍然优先选区外的空白，放不下时再贴可用区域。
    func show(near selectionScreenRect: CGRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(selectionScreenRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 10

        var y = selectionScreenRect.minY - Self.size.height - gap
        if y < visible.minY + gap {
            y = selectionScreenRect.maxY + gap
        }
        if y + Self.size.height > visible.maxY - gap {
            y = max(visible.minY + gap, min(y, visible.maxY - Self.size.height - gap))
        }
        let x = min(
            max(visible.minX + gap, selectionScreenRect.minX),
            visible.maxX - Self.size.width - gap
        )
        panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: Self.size), display: true)
        panel.orderFrontRegardless()
        updateGuide(Self.guidePreparing)
    }

    /// 引导文案：等待/进行中。
    static let guidePreparing = "正在准备首帧，请稍候"
    static let guideScrolling = "滚动页面，自动捕获更多内容"
    /// 配准失败时保留已有内容，回到重叠画面即可继续。
    static let guideStalled = "暂未对齐，请缓慢回滚到已采内容后继续"
    /// 引导文案：输出高度到顶。
    ///
    /// 到顶**不是失败**：已采到的部分是一张可用的长图，所以说的是
    /// 「可以收尾」而不是「请重新开始」——把上限说成跟丢，用户会白丢一张图。
    static let guideHeightLimit = "已达长度上限，已采内容可以保存"
    /// 引导文案：抓帧数到顶（紧接着会自动生成长图）。
    static let guideFrameLimit = "已达抓帧上限，正在生成长图"

    /// 更新引导文案。
    ///
    /// - Parameter isWarning: 出问题时用警示色，让「需要你处理」与「继续滚就行」一眼可分。
    func updateGuide(_ text: String, isWarning: Bool = false) {
        guideLabel.stringValue = text
        guideLabel.textColor = isWarning ? .systemOrange : .white
    }

    /// 更新预览：整幅导航图 + 定位框 + 该处的放大详情。
    func updatePreview(_ content: ScrollshotPreviewContent?) {
        self.content = content
        guard let content else {
            focusWorldRow = 0
            isPinned = false
            navigatorView.update(content: nil, focusWorldRow: 0, windowRows: 1)
            detailView.image = nil
            detailHintLabel.isHidden = false
            updateStatus()
            return
        }
        // 自动跟随：定位框落在「当前屏幕视口」上；用户拖走后不再改它。
        if !isPinned, let viewport = content.viewportWorldRows {
            focusWorldRow = viewport.lowerBound + viewport.count / 2
        }
        refreshFocus()
    }

    /// 放大栏一屏能装下的世界行数。
    ///
    /// 详情图横向铺满详情区（`detailPixelWidth` 像素），纵向按同一比例，于是可容纳
    /// 的行数 = 详情区高度(点) × 长图宽度 / 详情区宽度(点)。定位框的高度取的就是它，
    /// 「框住多少」与「右边显示多少」因此永远是同一段。
    private var detailWindowRows: Int {
        guard let content else { return 1 }
        let rows = Double(Self.detailFrame.height) * Double(content.worldWidth)
            / Double(Self.detailFrame.width)
        return max(1, Int(rows.rounded()))
    }

    /// 定位框覆盖的世界行区间：以 `focusWorldRow` 为中心，夹在已覆盖范围内。
    private func focusWindow() -> Range<Int>? {
        guard let content, content.worldHeight > 0 else { return nil }
        let rows = min(detailWindowRows, content.worldHeight)
        let start = min(
            max(content.worldStart, focusWorldRow - rows / 2),
            content.worldStart + content.worldHeight - rows
        )
        return start..<(start + rows)
    }

    /// 按当前 `focusWorldRow` 把定位框、放大栏与状态行刷一遍。
    private func refreshFocus() {
        guard let content, let window = focusWindow() else { return }
        // 夹过界之后回写：`focusWorldRow` 始终是「框的中心」，拖动与跟随后都对得上。
        focusWorldRow = window.lowerBound + window.count / 2
        navigatorView.update(
            content: content,
            focusWorldRow: focusWorldRow,
            windowRows: window.count
        )
        refreshDetail(window: window)
        updateStatus()
    }

    /// 渲染放大栏：取定位框那一段的原图切片。
    private func refreshDetail(window: Range<Int>) {
        guard let image = onDetailRequest?(window, Self.detailPixelWidth) else {
            detailView.image = nil
            detailHintLabel.isHidden = false
            return
        }
        detailView.image = NSImage(cgImage: image, size: Self.detailFrame.size)
        detailHintLabel.isHidden = true
    }

    /// 用户拖动定位框：进入「锁定查看」，不再跟随采集位置。
    private func handleFocusChange(_ worldRow: Int) {
        guard content != nil else { return }
        isPinned = true
        focusWorldRow = worldRow
        refreshFocus()
    }

    /// 回到采集位置（状态行可点击）。
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
            statusButton.title = "已锁定查看 · 点此回到采集位置"
            statusButton.isEnabled = true
            statusButton.contentTintColor = .controlAccentColor
        } else {
            statusButton.title = "跟随采集位置"
            statusButton.isEnabled = false
            statusButton.contentTintColor = .secondaryLabelColor
        }
    }

    func hide() {
        isPinned = false
        content = nil
        panel.orderOut(nil)
    }

    #if DEBUG
    /// 诊断专用：当前引导文案（核对「跟丢时确实换成了警示语」）。
    var guideTextForDiagnostics: String { guideLabel.stringValue }

    /// 诊断专用：把浮层直接摆到指定位置（AppKit 屏幕坐标）。
    ///
    /// 存在的理由：验证 `sharingType = .none` 是否真的生效，必须让浮层**压在
    /// 待抓区域上**，而正式布局总是尽量把它放到区域外。
    func placeForDiagnostics(at frame: CGRect) {
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    /// 诊断专用：浮层的实际屏幕框。
    var frameForDiagnostics: CGRect { panel.frame }

    /// 诊断专用：模拟用户把定位框拖到某个世界行（无法合成真实鼠标事件时用它）。
    func focusForDiagnostics(worldRow: Int) {
        handleFocusChange(worldRow)
    }

    /// 诊断专用：当前定位框覆盖的世界行区间。
    var focusWindowForDiagnostics: Range<Int>? { focusWindow() }

    /// 诊断专用：是否处于「锁定查看」（已脱离采集位置）。
    var isPinnedForDiagnostics: Bool { isPinned }

    /// 诊断专用：各栏在内容视图坐标里的框（断言互不重叠、都在面板内）。
    var layoutFramesForDiagnostics: (
        navigator: CGRect, detail: CGRect, status: CGRect, guide: CGRect, cancel: CGRect, finish: CGRect
    ) {
        (
            Self.navigatorFrame, Self.detailFrame, Self.statusFrame,
            Self.guideFrame, cancelButton.frame, finishButton.frame
        )
    }

    /// 诊断专用：导航栏里缩略图与定位框的框（**已换算到内容视图坐标**，
    /// 与 `layoutFramesForDiagnostics` 同一套，才能直接比较）。
    var navigatorFramesForDiagnostics: (thumbnail: CGRect, focus: CGRect?) {
        let container = navigatorView.superview
        let thumbnail = navigatorView.convert(navigatorView.thumbnailFrameForDiagnostics, to: container)
        let focus = navigatorView.focusFrameForDiagnostics.map {
            navigatorView.convert($0, to: container)
        }
        return (thumbnail, focus)
    }

    /// 诊断专用：点一下状态行（回到采集位置）。
    func followCurrentForDiagnostics() { handleFollowCurrent() }

    /// 诊断专用：浮层的内容视图，用于**渲染成图**核对观感。
    ///
    /// 不能用屏幕捕获来核对：`sharingType = .none` 让浮层对所有屏幕捕获都不可见
    /// （那正是它不会被拍进长图的原因）。直接渲染视图不受这条限制。
    var contentViewForDiagnostics: NSView? { panel.contentView }
    #endif

    @objc private func handleFinish() {
        onFinish?()
    }

    @objc private func handleCancel() {
        onCancel?()
    }
}
