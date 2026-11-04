//
//  OverlayController.swift
//  AnShotUI
//
//  覆盖层会话的生命周期管理（P3）。
//
//  职责边界：
//    - 决定抓哪些显示器、何时抓、何时释放
//    - 维护「同一时刻只有一个会话」的不变量
//    - 记录分阶段耗时，供延迟预算核对
//
//  不负责：窗口参数（见 OverlayWindow）、事件语义（见 OverlayView）。
//
//  ── 内存纪律 ────────────────────────────────────────────────
//
//  底图的生命周期 = 会话生命周期。`dismiss()` 会显式置空每个视图的
//  `backdrop` 再关闭窗口，不依赖 ARC 的延迟释放，也不进入任何缓存。
//  这是 plan.md §3.3「会话结束立即释放」的落实点。
//

import AppKit
import AnShotCapture
import AnShotCore
import Foundation

private let logger = AnShotLog.overlay

/// 这次会话是「普通截图」还是「按热键直达某个动作」。
///
/// 直达动作（录制 / 长截图 / OCR）与普通截图共用同一套覆盖层、选区与识别，
/// 区别只在于「选区确定后做什么」。把差异压成一个枚举，而不是复制三套
/// 会话创建代码：三套代码一旦分叉，选区吸附、坐标换算、多屏同步就会各自漂移。
public enum OverlaySessionIntent: String, Sendable {
    case capture
    case recording
    case longScreenshot
    case ocr
}

@MainActor
public final class OverlayController {

    /// 覆盖层状态变化回调（用于菜单栏刷新可用性等）。
    public var onSessionStateChanged: (() -> Void)?

    /// 当前选区（**底图像素坐标**）。
    ///
    /// 放在控制器而非视图：视图是可替换的渲染层，
    /// 而 P5 的 `CaptureSession` 需要从这里取选区构造会话，
    /// 多显示器时也不存在「哪个视图持有真值」的歧义。
    public private(set) var selection: PixelRect?

    /// 选区变化回调（像素坐标），供后续阶段的导出 UI 与诊断使用。
    public var onSelectionChanged: ((PixelRect?) -> Void)?

    /// 当前是否正在展示覆盖层。
    public private(set) var isPresenting = false

    /// 本次会话的意图。只影响「选区确定后做什么」，不影响选区本身。
    private var pendingIntent: OverlaySessionIntent = .capture

    /// 图片编辑会话的来源。普通截图会话为 nil。
    private var documentSource: HistorySource?

    /// 正在后台抓取一个窗口。防止连点菜单叠出多个会话。
    private var pendingWindowCapture = false

    /// 标注编辑器状态（仅会话期间存在，随 `teardown` 释放）。
    ///
    /// 它是标注的唯一权威：工具、样式、已提交标注、草稿、撤销历史全在这里。
    /// 覆盖层视图只读它。当前仅供模块内（含诊断）使用。
    private(set) var editorState: AnnotationEditorState?

    /// 当前选区所在的显示器。
    ///
    /// M1 不允许跨屏选区（见 plan.md DP4-2），因此最多只有一块屏持有选区，
    /// 记住它是为了在撤销/重做后把选区放回正确的屏幕。
    /// 不是 private：诊断扩展在另一文件读取/驱动（滚动截图入口验证）。
    var selectionDisplayID: CGDirectDisplayID?

    /// 已提交选区快照 → 所属显示器。
    ///
    /// 撤销/重做恢复的 `EditState` 只含像素矩形；像素坐标以各屏左上角为原点，
    /// 同样的矩形在不同屏上无法靠坐标区分（两块同分辨率副屏尤其如此）。
    /// 因此在选区稳定下来时记下归属，历史回退到某个快照时按值找回。
    ///
    /// 只记「稳定」状态（见 `syncSelectionFromEditor`），数量与用户的手势 /
    /// 标注次数同阶；上限只兜住极端的长会话。
    private var selectionDisplayHistory: [(selection: PixelRect, displayID: CGDirectDisplayID)] = []
    private static let selectionDisplayHistoryLimit = 128

    /// 是否正在执行撤销 / 重做。
    ///
    /// 历史回退是唯一需要「按快照找回显示器」的时机；
    /// 识别预览等其它同步不能查表，否则同尺寸的另一块屏会把
    /// 一个恰好相同的局部矩形误判成历史快照。
    private var isRestoringHistory = false

    private let capturer: ScreenCapturing

    /// 应用设置。保存位置从这里读——导出时**即时读**而不是缓存，
    /// 这样用户改完设置立即生效，不需要重新开会话。
    private let settings: AppSettings

    /// 各屏覆盖层（不是 private：诊断扩展在另一文件读它）。
    var windows: [OverlayWindow] = []
    private(set) var sessionTask: Task<Void, Never>?
    private var sessionID: UUID?

    public init(
        capturer: ScreenCapturing = CapturerFactory.makeDefault(),
        settings: AppSettings = AppSettings()
    ) {
        self.capturer = capturer
        self.settings = settings
        self.pinManager = PinManager(settings: settings)
        self.ocrPanel.onClose = { [weak self] in self?.cancelTextRequests() }
    }

    // MARK: - 会话控制

    /// 展示覆盖层：抓取全部显示器底图 → 建窗 → 显示。
    ///
    /// 已在展示时重复调用会被忽略（热键抖动、菜单与热键同时触发都可能发生），
    /// 而不是重入或叠加会话。
    public func present(intent: OverlaySessionIntent = .capture) {
        guard !isPresenting else {
            logger.debug("present ignored: a session is already presenting")
            return
        }
        pendingIntent = intent
        let sessionID = UUID()
        self.sessionID = sessionID
        isPresenting = true
        onSessionStateChanged?()
        sessionTask = Task { @MainActor [weak self] in
            await self?.runSession(id: sessionID)
        }
    }

    /// 编辑一张已有图片（不截图）。
    ///
    /// 复用截图覆盖层的选区/标注/导出，只是窗口改成围着图片本身：
    /// 用户已经有一张图时，不该为了加一个箭头再截一次屏。
    /// 源文件只读载入，导出仍走保存/复制/钉住，绝不写回原文件。
    public func present(image: CGImage, sourceURL: URL? = nil) {
        guard !isPresenting else {
            logger.debug("present(image:) ignored: a session is already presenting")
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let displayID = screen.displayID else { return }

        // 窗口尺寸：大图缩到屏幕 90% 内，小图放大到至少 600×400 点，
        // 否则工具栏比图片还宽，会被窗口边缘裁掉。
        let visible = screen.visibleFrame
        let maxWidth = max(320, visible.width * 0.9)
        let maxHeight = max(240, visible.height * 0.9)
        let downScale = max(1, CGFloat(image.width) / maxWidth, CGFloat(image.height) / maxHeight)
        let upScale = min(1, max(0.5, min(CGFloat(image.width) / 600, CGFloat(image.height) / 400)))
        let scale = downScale > 1 ? downScale : upScale
        let size = CGSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        let frame = CGRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        let window = OverlayWindow(imageFrame: frame, displayID: displayID)
        let pixel = PixelRect(
            origin: .zero,
            size: PixelSize(width: Double(image.width), height: Double(image.height))
        )
        let editor = AnnotationEditorState(selection: pixel)
        editor.confirmSelection()
        editor.style = EditorStyleStore.shared.load()
        editor.onChange = { [weak self] in self?.refreshAnnotationDisplay() }
        editor.onTextContentChange = { [weak self] in
            guard let self else { return }
            for window in self.windows {
                window.overlayView.syncTextEditorFromState()
            }
        }

        window.overlayView.editorState = editor
        window.overlayView.backdrop = image
        window.overlayView.hidesToolbarForIntent = false
        // 图片编辑器不提供录制/长截图/OCR：它们都要求「当前屏幕上有一块可抓取
        // 的区域」，而这里的底图是磁盘上的文件，不是屏幕。隐藏而不是让按钮
        // 点了没反应——后者会被当成 bug。
        window.overlayView.allowsCaptureActions = false
        window.overlayView.onCancel = { [weak self] in self?.dismiss() }
        window.overlayView.onExport = { [weak self, weak window] image, action in
            self?.handleExport(image, action: action, in: window)
        }
        window.overlayView.onUndoRequested = { [weak self] in self?.undoEditing() }
        window.overlayView.onRedoRequested = { [weak self] in self?.redoEditing() }

        editorState = editor
        selection = pixel
        selectionDisplayID = displayID
        documentSource = HistorySource(
            appName: "图片",
            windowTitle: sourceURL?.lastPathComponent,
            mode: "imported"
        )
        windows = [window]
        isPresenting = true
        onSessionStateChanged?()

        window.presentWithoutActivating()
        window.makeKey()
        window.makeFirstResponder(window.overlayView)

        // 把编辑器里的「整幅图片」选区同步到视图。
        //
        // 少了这一步，视图的 `selectionRect` 仍是 nil：遮罩会把整幅图压暗，
        // 工具栏也因为没有选区而不出现——用户看到的是一张变灰的图，
        // 没有任何可操作控件（实测正是这个症状）。
        syncSelectionFromEditor()
        window.overlayView.refreshToolbar()
        logger.notice("""
            image editor opened; size=\(image.width, privacy: .public)x\(image.height, privacy: .public) \
            scale=\(scale, privacy: .public) visible=\(NSStringFromRect(visible), privacy: .public) \
            frame=\(NSStringFromRect(frame), privacy: .public) actual=\(NSStringFromRect(window.frame), privacy: .public)
            """)
    }

    /// 直接截取一个窗口并进入编辑（不显示全屏覆盖层）。
    ///
    /// 这条路径把「窗口选择器」与「图片编辑器」接起来：用户选中的窗口可能
    /// 被遮挡、甚至在别的桌面，全屏覆盖层根本点不到它；按 windowID 抓取
    /// 是唯一稳定的方式。抓到的图与磁盘图片走同一个编辑会话。
    public func present(
        windowID: CGWindowID,
        appName: String? = nil,
        windowTitle: String? = nil
    ) {
        guard !isPresenting, !pendingWindowCapture else {
            logger.debug("present(windowID:) ignored: session or capture already active")
            return
        }
        pendingWindowCapture = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingWindowCapture = false }
            do {
                let frame = try await self.capturer.captureFrame(scope: .window(windowID))
                self.present(image: frame.image)
                self.documentSource = HistorySource(
                    appName: appName,
                    windowTitle: windowTitle,
                    mode: "window"
                )
                logger.notice("window capture opened in editor; id=\(windowID, privacy: .public)")
            } catch {
                logger.error("window capture failed: \(String(describing: error), privacy: .public)")
                ToastPresenter.show("窗口截图失败：\(error.localizedDescription)")
            }
        }
    }

    /// 关闭覆盖层并立即释放全部底图。未在展示时调用是安全的空操作。
    public func dismiss() {
        sessionTask?.cancel()
        sessionTask = nil
        guard isPresenting else { return }
        teardown()
        logger.notice("overlay dismissed")
    }

    // MARK: - 选区

    /// 以编程方式设置选区（视图逻辑点坐标）。诊断与后续阶段的程序化构造使用。
    ///
    /// 作用于首个窗口（主显示器）。跨显示器选区不在 M1 范围内。
    @discardableResult
    public func setSelection(_ logicalRect: CGRect) -> Bool {
        guard let window = windows.first else { return false }
        window.overlayView.setSelection(logicalRect)
        // 程序式设置选区同样要落进编辑器状态。
        // 否则下次状态刷新时 `syncSelectionFromEditor` 会发现编辑器里没有选区，
        // 反过来把视图上刚设好的选区清掉——诊断曾因此完全失效。
        selectionDidCommit(
            logicalRect,
            displayID: window.displayID,
            pixelsPerPoint: window.overlayView.pixelsPerPoint
        )
        return true
    }

    /// 首个覆盖层窗口（主显示器）。
    ///
    /// 供诊断向窗口投递合成事件，以验证真实的鼠标事件路径
    /// （`setSelection` 绕过了视图的事件处理，无法证明那条链路正确）。
    public var primaryOverlayWindow: NSWindow? {
        windows.first
    }

    #if DEBUG
    /// 诊断专用：把某块显示器的底图换成指定图像。
    ///
    /// 存在的理由：装饰控件的可见性取决于底图明暗，
    /// 而桌面内容不可控。只有换成纯色底才能系统性地比对
    /// 「白 hairline + 深色阴影」和「白色手柄」在浅底与深底上的表现。
    func setBackdropForDiagnostics(_ image: CGImage?, displayID: CGDirectDisplayID) {
        guard let window = windows.first(where: { $0.displayID == displayID }) else { return }
        window.overlayView.backdrop = image
        // 底图变化会影响工具栏的可见性（无底图时不显示），必须重算。
        window.overlayView.refreshToolbar()
    }

    /// 诊断：某点会命中哪个手柄。
    func debugHandleName(at point: CGPoint) -> String? {
        windows.first?.overlayView.debugHandleName(at: point)
    }

    /// 诊断：标记悬停中的手柄，用于渲染审查高亮配色。
    func debugSetHoveredHandle(_ handle: SelectionHandle?) {
        windows.first?.overlayView.debugSetHoveredHandle(handle)
    }

    /// 诊断：注入一次识别命中（走真实的候选应用路径）。
    func debugApplyDetectionTarget(_ target: DetectionTarget) {
        guard let window = windows.first else { return }
        selectionDisplayID = window.displayID
        window.overlayView.debugApplyDetectionTarget(target)
    }

    /// 诊断：选区是否已确认（false 表示它仍是自动识别给出的候选）。
    var debugIsSelectionConfirmed: Bool {
        editorState?.isSelectionConfirmed ?? true
    }

    /// 诊断：当前选区对应的识别身份。
    var debugDetectionTarget: DetectionTarget? {
        windows.first?.overlayView.detectionTargetForDiagnostics
    }

    /// 诊断：暂停 / 恢复全部窗口的真实识别。
    ///
    /// 受控渲染必须挡住它：识别结果取决于鼠标下恰好有什么窗口，
    /// 不挡就同一张预览图每次都不一样。
    func debugSetDetectionPaused(_ paused: Bool) {
        for window in windows {
            window.overlayView.isDetectionPausedForDiagnostics = paused
        }
    }
    #endif

    /// 手势过程中的选区变化。
    ///
    /// - Parameter pixelsPerPoint: 「逻辑点 → 底图像素」的比例，**必须由发起手势的
    ///   那个视图提供**（即 `OverlayView.pixelsPerPoint`）。不要在这里改查
    ///   `DisplayGeometry.scaleFactor(for:)`：那是实时查询显示器 mode，
    ///   与「这张底图实际有多大」是两回事，两者不一致时提交给模型的选区
    ///   会与底图错位——用户看到的现象是「框选一大片，导出只有左上角一小块」。
    private func selectionDidChange(
        _ logicalRect: CGRect?,
        displayID: CGDirectDisplayID,
        pixelsPerPoint: CGFloat
    ) {
        guard let logicalRect else {
            selection = nil
            selectionDisplayID = nil
            onSelectionChanged?(nil)
            // 清除选区同样是一次选区编辑，必须进历史；
            // 否则撤销时会回到「有选区」而画面上选区已消失，两边脱节。
            editorState?.commitSelection(Self.emptyPixelRect)
            return
        }

        // 唯一跨边界换算：逻辑点 → 底图像素。
        let pixel = CoordinateConversion.pixelRect(
            fromLogical: logicalRect,
            scaleFactor: pixelsPerPoint
        )
        selection = pixel
        selectionDisplayID = displayID
        onSelectionChanged?(pixel)
    }

    /// 空选区（零尺寸）的像素矩形。
    private static let emptyPixelRect = PixelRect(
        origin: .zero,
        size: PixelSize(width: 0, height: 0)
    )

    /// 编辑器状态变化后刷新全部覆盖层。
    ///
    /// 视图不各自订阅编辑器回调（多窗口会重复持有），
    /// 由控制器统一扇出，保证「一处状态、多屏一致」。
    ///
    /// 除了重绘，还要把模型里的**选区**同步回视图：
    /// 撤销/重做恢复的是整个 `EditState`（选区 + 标注），
    /// 只更新标注而让画面上的选区留在原处，用户看到的历史就是错的。
    private func refreshAnnotationDisplay() {
        syncSelectionFromEditor()

        for window in windows {
            window.overlayView.needsDisplay = true
            window.overlayView.refreshToolbar()
        }
    }

    /// 把编辑器里的选区同步到视图与控制器状态。
    private func syncSelectionFromEditor() {
        guard let editor = editorState else { return }

        let pixel = editor.selection
        let isEmpty = pixel.size.width <= 0 || pixel.size.height <= 0

        guard !isEmpty else {
            selection = nil
            selectionDisplayID = nil
            // 空选区是编辑器给出的权威结论，静默清掉所有屏即可；
            // 若逐窗回调 `onSelectionChanged(nil)`，控制器会把「清空」
            // 当成一次新的编辑再提交回编辑器，造成无意义的回灌。
            resetOverlaySelections(except: nil)
            onSelectionChanged?(nil)
            return
        }

        // 撤销/重做恢复的只是像素矩形，而像素坐标是**显示器局部**的：
        // 在 A 屏框选、再到 B 屏框选后按 ⌘Z，矩形本身仍是 A 屏的坐标，
        // 若继续按当前的 `selectionDisplayID`（B）绘制，A 的框就会出现在 B 屏上。
        // 归属在每次选区提交时记过，历史回退时按值找回来。
        // 只在选区**真的换了**时才查表：标注类的撤销不改变选区，
        // 当前归属本来就是对的，没必要（也不能）用旧快照去覆盖它。
        if isRestoringHistory, pixel != selection,
           let restored = selectionDisplayHistory.last(where: { $0.selection == pixel }) {
            selectionDisplayID = restored.displayID
        }

        // 记录时机：只有当编辑器选区与控制器当前选区一致时才算「稳定」状态
        // （提交、标注编辑、确认候选）。识别预览连续换矩形时不记录，
        // 免得鼠标划过几十个窗口就把历史快照挤掉。
        let wasAdopted = pixel == selection
        selection = pixel

        guard let displayID = selectionDisplayID,
              let window = windows.first(where: { $0.displayID == displayID }) else {
            // 有选区却没有归属窗口：宁可不画，也不能把框留在其它屏幕上。
            resetOverlaySelections(except: nil)
            return
        }

        // 非空选区同样要清掉其它屏：它们可能留着上一块屏的旧框与工具栏。
        // 必须静默重置——回调会把刚提交的选区当作「用户清空」再提交一次。
        resetOverlaySelections(except: displayID)

        // 拖动中的手势不进历史，也就不会走到这里；
        // 万一外部状态先变，也不该把用户正拖着的框拽回去。
        guard !window.overlayView.isInteracting else { return }

        if !isRestoringHistory, wasAdopted {
            rememberSelectionDisplay(pixel, displayID: displayID)
        }

        // 选区换了显示器，键盘焦点也必须跟着换：否则回车 / ⌘C 仍由旧窗口
        // 处理，导出会用旧屏的底图去裁新屏的像素矩形。
        focusOverlayWindow(for: displayID)

        let logical = CoordinateConversion.logicalRect(
            fromPixel: pixel,
            scaleFactor: window.overlayView.pixelsPerPoint
        )
        window.overlayView.setSelection(logical)
    }

    /// 重置除指定显示器以外所有窗口的选区。
    ///
    /// - Parameter displayID: 要保留的显示器；`nil` 表示全部重置。
    ///
    /// 正在拖动的那块屏跳过：那是尚未结束的用户手势，
    /// 被外部同步清掉会表现为「拖着拖着框自己没了」。
    private func resetOverlaySelections(except displayID: CGDirectDisplayID?) {
        for window in windows where window.displayID != displayID {
            guard !window.overlayView.isInteracting else { continue }
            window.overlayView.resetSelection(notifying: false)
        }
    }

    /// 手势结束后提交选区。
    ///
    /// - Parameter pixelsPerPoint: 同 `selectionDidChange`——比例必须来自
    ///   发起手势的视图，而不是实时查询的显示器 mode。
    private func selectionDidCommit(
        _ logicalRect: CGRect,
        displayID: CGDirectDisplayID,
        pixelsPerPoint: CGFloat
    ) {
        let pixel = CoordinateConversion.pixelRect(
            fromLogical: logicalRect,
            scaleFactor: pixelsPerPoint
        )
        // 先落到控制器状态：随后 `commitSelection` 会同步触发
        // `syncSelectionFromEditor`，此时编辑器选区与控制器一致，
        // 才能被认定为「稳定状态」并记下归属。
        selection = pixel
        selectionDisplayID = displayID
        rememberSelectionDisplay(pixel, displayID: displayID)
        // 提交不一定触发 `onChange`（几何未变时编辑器会忽略），
        // 所以焦点切换不能只依赖随后那次同步。
        focusOverlayWindow(for: displayID)
        // 手势结束后提交一个选区快照：选区属于编辑状态，
        // 撤销一次应当整体回到上一步（含选区和标注）。
        editorState?.commitSelection(pixel)
        logger.notice("""
            selection committed: logical=\(NSStringFromRect(logicalRect), privacy: .public) \
            pixel=\(Int(pixel.size.width.rounded()), privacy: .public)x\(Int(pixel.size.height.rounded()), privacy: .public) \
            origin=(\(Int(pixel.origin.x.rounded()), privacy: .public),\(Int(pixel.origin.y.rounded()), privacy: .public)) \
            pixelsPerPoint=\(Double(pixelsPerPoint), privacy: .public)
            """)

        // 直达动作：选区一旦确定就不再等第二次点击。
        // 查找发起屏幕的窗口而不是 `windows.first`，多显示器时才能把
        // 录制范围 / OCR 面板放到用户正在操作的那块屏。
        if pendingIntent != .capture,
           let window = windows.first(where: { $0.displayID == displayID }) {
            performPendingIntent(pixel, displayID: displayID, window: window)
        }
    }

    /// 执行「直达动作」。
    ///
    /// 先把意图清回 `.capture`：下面的处理函数会打开准备面板 / 长截图 / OCR，
    /// 其中录制准备允许用户取消并回到普通截图；如果意图还留着，取消后
    /// 随便动一下选区又会重新弹面板，用户会觉得「取消不掉」。
    private func performPendingIntent(
        _ pixel: PixelRect,
        displayID: CGDirectDisplayID,
        window: OverlayWindow
    ) {
        let intent = pendingIntent
        guard intent != .capture else { return }
        pendingIntent = .capture
        window.overlayView.hidesToolbarForIntent = false

        let scale = window.overlayView.pixelsPerPoint
        let logical = CoordinateConversion.logicalRect(fromPixel: pixel, scaleFactor: scale)
        guard logical.width >= 8, logical.height >= 8 else {
            NSSound.beep()
            window.overlayView.refreshToolbar()
            return
        }

        logger.notice("""
            intent \(intent.rawValue, privacy: .public) 启动：\
            选区 \(Int(logical.width), privacy: .public)x\(Int(logical.height), privacy: .public)
            """)

        switch intent {
        case .capture:
            break
        case .recording:
            handleRecordRequest(
                logical,
                detected: window.overlayView.detectionTargetForIntent,
                displayID: displayID,
                overlayWindow: window
            )
        case .longScreenshot:
            handleLongScreenshotRequest(
                logical,
                displayID: displayID,
                overlayWindow: window,
                axis: .vertical
            )
        case .ocr:
            handleRecognizeTextRequest(
                logical,
                displayID: displayID,
                overlayWindow: window
            )
        }
    }

    /// 记下某个稳定选区属于哪块显示器。
    private func rememberSelectionDisplay(_ pixel: PixelRect, displayID: CGDirectDisplayID) {
        guard pixel.size.width > 0, pixel.size.height > 0 else { return }
        // 同一矩形只保留最新归属，避免自动识别在同一位置反复命中时膨胀。
        if let index = selectionDisplayHistory.firstIndex(where: { $0.selection == pixel }) {
            selectionDisplayHistory[index] = (pixel, displayID)
            return
        }
        selectionDisplayHistory.append((pixel, displayID))
        if selectionDisplayHistory.count > Self.selectionDisplayHistoryLimit {
            selectionDisplayHistory.removeFirst(
                selectionDisplayHistory.count - Self.selectionDisplayHistoryLimit
            )
        }
    }

    /// 执行一次撤销。选区恢复后由 `syncSelectionFromEditor` 放回原显示器。
    private func undoEditing() {
        guard let editor = editorState else { return }
        isRestoringHistory = true
        editor.undo()
        isRestoringHistory = false
        // 撤销后可能切换了显示器，焦点与选区一起由同步流程处理；
        // 这里不主动 dismiss，会话保持打开（用户可能继续编辑）。
    }

    /// 执行一次重做。同 `undoEditing`。
    private func redoEditing() {
        guard let editor = editorState else { return }
        isRestoringHistory = true
        editor.redo()
        isRestoringHistory = false
    }

    // MARK: - 会话执行

    private func runSession(id: UUID) async {
        guard sessionID == id, !Task.isCancelled else { return }
        // 使用单调时钟：Date 会受系统时间调整影响，不适合测延迟。
        let clock = ContinuousClock()
        let sessionStart = clock.now

        let targets = Self.screenTargets()
        guard !targets.isEmpty else {
            logger.error("overlay aborted: no active displays reported by NSScreen")
            teardown()
            return
        }

        // ── 阶段 1 与 2 并行 ──
        // 抓取底图（主要成本，冷启动约 150ms）与建窗（约 17ms）互不依赖，
        // 串行会让总延迟变成两者之和。
        let captureStart = clock.now
        let displayIDs = targets.map(\.displayID)
        async let backdropTask = Self.captureBackdrops(
            displayIDs: displayIDs,
            using: capturer,
            clock: clock
        )

        // 默认选区 = 鼠标所在显示器的整屏。
        //
        // 做成初始状态而不是「创建后再 commit 一次」：后者会往历史里塞一个
        // 用户没做过的操作，"撤销"一下就回到了无选区，语义不对。
        // 常用场景「截全屏」由此变成 ⌃1 → 回车。
        let defaultSelection = Self.defaultSelectionPixelRect(in: targets)

        // 标注编辑器：会话级存在，随 teardown 释放。
        // 视图不订阅它的回调（多窗口会重复持有），由控制器统一扇出重绘。
        let editor = AnnotationEditorState(selection: defaultSelection)
        // 恢复上一次会话的样式：颜色/线宽/字号每次重选是纯重复劳动，
        // 而工具栏面板本身就展示当前值，持久化不会制造看不见的隐状态。
        editor.style = EditorStyleStore.shared.load()
        // 默认选区也要记录归属，否则它同样同步不到视图上。
        if let defaultSelection, let displayID = Self.defaultSelectionDisplayID(in: targets) {
            selectionDisplayID = displayID
            // 默认整屏选区是历史的初始快照，撤销回到它时同样要回到这块屏。
            rememberSelectionDisplay(defaultSelection, displayID: displayID)
        }
        editor.onChange = { [weak self] in
            self?.refreshAnnotationDisplay()
        }
        // 文字内容变化只同步输入控件：输入框自己就是变化来源，
        // 走全量重绘既没必要，也会在快速输入时白白重合成位图。
        editor.onTextContentChange = { [weak self] in
            guard let self else { return }
            for window in self.windows {
                window.overlayView.syncTextEditorFromState()
            }
        }
        editorState = editor

        // 元素识别器：会话级一个实例，各屏共用。
        let detector = SystemElementDetector()

        var created: [OverlayWindow] = []
        for target in targets {
            let window = OverlayWindow(screen: target.screen, displayID: target.displayID)
            window.overlayView.hidesToolbarForIntent = pendingIntent != .capture
            window.overlayView.editorState = editor
            // 每屏一个识别会话：窗口列表按显示器裁剪，坐标也各按各的屏换算。
            let detection = DetectionSession(
                detector: detector,
                displayID: target.displayID,
                displayBounds: DisplayGeometry.bounds(for: target.displayID)
            )
            window.overlayView.detectionSession = detection
            window.overlayView.onCancel = { [weak self] in
                self?.dismiss()
            }
            window.overlayView.onExport = { [weak self, weak window] image, action in
                self?.handleExport(image, action: action, in: window)
            }
            window.overlayView.onRecognizeText = { [weak self, weak window] rect in
                guard let self, let window else { return }
                self.handleRecognizeTextRequest(
                    rect,
                    displayID: target.displayID,
                    overlayWindow: window
                )
            }
            window.overlayView.onLongScreenshot = { [weak self, weak window] rect in
                guard let self, let window else { return }
                // ── 方向由**修饰键**决定，不靠选区形状推断 ──────────────
                //
                // 曾经按宽高比自动判：宽 ≥ 高的 1.2 倍就当横向。那个假设是错的：
                // 用户完全可能选一个「宽而矮」的区域去滚**纵向**内容（长对话、
                // 日志、聊天记录、代码文件都长这样），结果被当成横向拼成一张
                // 错乱的长图。实测就是这么踩的。
                //
                // 根本原因：选区形状描述的是「看多大范围」，与「内容往哪个方向
                // 滚」没有任何关系。两者只能由用户显式区分。
                //
                // 所以：默认竖向（绝大多数场景）；按住 Option 点长截图 = 横向。
                let axis: ScrollAxis = NSEvent.modifierFlags.contains(.option)
                    ? .horizontal
                    : .vertical
                self.handleLongScreenshotRequest(
                    rect,
                    displayID: target.displayID,
                    overlayWindow: window,
                    axis: axis
                )
            }
            window.overlayView.onRecord = { [weak self, weak window] rect, detected in
                guard let self, let window else { return }
                self.handleRecordRequest(
                    rect,
                    detected: detected,
                    displayID: target.displayID,
                    overlayWindow: window
                )
            }
            window.overlayView.onDetectedDisplayID = { [weak self] displayID in
                guard let self else { return }
                self.selectionDisplayID = displayID
                // 识别把选区候选换到了另一块屏：焦点也要跟过去，
                // 否则此刻按回车 / ⌘C 仍由旧窗口用旧屏底图导出。
                self.focusOverlayWindow(for: displayID)
            }
            window.overlayView.onUndoRequested = { [weak self] in
                self?.undoEditing()
            }
            window.overlayView.onRedoRequested = { [weak self] in
                self?.redoEditing()
            }
            // 录制目标选取：悬停只报候选，单击才锁定身份。
            // 回调都带上发起窗口——目标矩形要经它换算成 AppKit 屏幕坐标。
            window.overlayView.onRecordingPickHover = { [weak self, weak window] target in
                guard let self, let window else { return }
                self.recordingPickHovered(target, in: window)
            }
            window.overlayView.onRecordingPickCommit = { [weak self, weak window] target in
                guard let self, let window else { return }
                self.recordingPickCommitted(target, in: window)
            }
            window.overlayView.onRecordingPickCancel = { [weak self] in
                self?.cancelRecordingTargetPick()
            }
            window.overlayView.onSelectionChanged = { [weak self, weak window] logicalRect in
                guard let self, let window else { return }
                self.selectionDidChange(
                    logicalRect,
                    displayID: target.displayID,
                    pixelsPerPoint: window.overlayView.pixelsPerPoint
                )
            }
            window.overlayView.onSelectionCommitted = { [weak self, weak window] logicalRect in
                guard let self, let window else { return }
                self.selectionDidCommit(
                    logicalRect,
                    displayID: target.displayID,
                    pixelsPerPoint: window.overlayView.pixelsPerPoint
                )
            }
            created.append(window)
        }
        let windowEnd = clock.now

        let backdrops = await backdropTask
        let captureEnd = clock.now

        // 会话可能已在抓取期间被取消（例如用户在热键后立刻按 ESC——
        // 虽然此刻还没有窗口可接收 ESC，但 cancellation 来源不止一处）。
        guard sessionID == id, !Task.isCancelled else {
            logger.notice("overlay session cancelled during capture")
            for window in created { window.close() }
            // 旧请求可能在用户重开后才返回，只能清理它自己创建的窗口。
            if sessionID == id { teardown() }
            return
        }

        // 一块屏幕的底图都没拿到：不展示覆盖层。
        //
        // 照常展示的结果是**所有屏幕被纯黑窗口盖住**——用户看不到任何内容，
        // 也不知道为什么，只能按 ESC 退出。最常见的原因是屏幕录制权限缺失或被撤销
        // （系统会定期要求重新确认），这时应该给出授权引导，而不是一片黑。
        // 部分屏幕失败时仍然展示：其余屏幕可用，失败的那块已有日志。
        if backdrops.isEmpty {
            logger.error("overlay aborted: no backdrop captured on any of \(created.count, privacy: .public) display(s)")
            for window in created { window.close() }
            teardown()
            onBackdropUnavailable?()
            return
        }

        // ── 阶段 3：绑定底图并显示 ──
        let bindStart = clock.now
        for window in created {
            let image = backdrops[window.displayID]
            // 绑定失败会让该屏显示纯黑，必须留下痕迹而不是静默降级。
            if image == nil {
                logger.error("no backdrop for display=\(window.displayID, privacy: .public); window will show black")
            }
            window.overlayView.backdrop = image
        }
        let bindEnd = clock.now

        let showStart = clock.now
        for window in created {
            window.presentWithoutActivating()
        }

        // 识别用不到底图，但与展示同样要在用户开始移动鼠标前就绪。
        // 放在展示之后异步载入：窗口枚举约 10ms，不阻塞覆盖层出现。
        let sessions = created.map(\.overlayView.detectionSession)
        Task { @MainActor in
            for session in sessions.compactMap({ $0 }) {
                await session.load()
            }
        }
        // 让鼠标所在显示器的窗口成为 key window，使 ESC 与后续键盘交互生效。
        // `.nonactivatingPanel` 保证这不会激活本应用（P3 验收判据，需实测确认）。
        if let keyWindow = keyWindowCandidate(in: created) {
            keyWindow.makeKey()
            let accepted = keyWindow.makeFirstResponder(keyWindow.overlayView)
            logger.notice("""
                key window setup: isKey=\(keyWindow.isKeyWindow, privacy: .public) \
                makeFirstResponder=\(accepted, privacy: .public) \
                firstResponder=\(String(describing: type(of: keyWindow.firstResponder ?? keyWindow)), privacy: .public)
                """)
        }
        let showEnd = clock.now
        windows = created

        // 默认选区（整屏）是在构造 `AnnotationEditorState` 时就写进去的，
        // 不会触发 `onChange`，因此必须在这里主动同步一次。
        // 漏掉它的后果：按 Control+1 后画面上没有框，
        // 而且「直接回车截全屏」也没有选区可用。
        syncSelectionFromEditor()

        // ── 分阶段耗时 ──
        // capture 与 windowBuild 并行发生，因此两者之和大于 total。
        // 各阶段独立记录，便于判断瓶颈出在抓取、建窗还是显示环节。
        logger.notice(
            """
            overlay session timing: capture=\(Self.milliseconds(captureStart, captureEnd), privacy: .public)ms \
            windowBuild=\(Self.milliseconds(captureStart, windowEnd), privacy: .public)ms \
            bind=\(Self.milliseconds(bindStart, bindEnd), privacy: .public)ms \
            show=\(Self.milliseconds(showStart, showEnd), privacy: .public)ms \
            total=\(Self.milliseconds(sessionStart, showEnd), privacy: .public)ms \
            displays=\(created.count, privacy: .public) \
            backdropBytes=\(Self.backdropBytes(backdrops), privacy: .public)
            """
        )
    }

    /// 并行抓取每块显示器的整屏底图。
    ///
    /// 单块显示器抓取失败**不**中断会话：该屏窗口显示黑底 + 遮罩，
    /// 用户仍可在其它屏完成操作。失败原因逐个记录，不静默吞掉。
    ///
    /// 标记 `nonisolated static`：要真正与主 actor 上的建窗并行，
    /// 抓取不能占用主 actor。因此只接受 `Sendable` 的显示器标识与捕获器，
    /// 不接收含 `NSScreen` 的目标描述。
    private nonisolated static func captureBackdrops(
        displayIDs: [CGDirectDisplayID],
        using capturer: any ScreenCapturing,
        clock: ContinuousClock
    ) async -> [CGDirectDisplayID: CGImage] {
        var result: [CGDirectDisplayID: CGImage] = [:]

        await withTaskGroup(of: (CGDirectDisplayID, CGImage?).self) { group in
            for displayID in displayIDs {
                group.addTask {
                    let start = clock.now
                    do {
                        let frame = try await capturer.captureFrame(scope: .display(displayID))
                        let elapsed = milliseconds(start, clock.now)
                        logger.debug("backdrop captured; display=\(displayID, privacy: .public) elapsed=\(elapsed, privacy: .public)ms")
                        return (displayID, frame.image)
                    } catch {
                        logger.error("backdrop capture failed; display=\(displayID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                        return (displayID, nil)
                    }
                }
            }

            for await (displayID, image) in group {
                result[displayID] = image
            }
        }

        return result
    }

    /// 处理导出结果。
    ///
    /// 两个动作的失败处理不同：
    /// - 拷贝：成功就结束会话（用户已经拿到图了）；
    /// - 保存：**用户取消保存时保持会话**——他刚画完标注，
    ///   因为误触保存、又不想选路径就把整个会话关掉，等于白干。
    ///
    /// - Parameter window: 发起导出的那个窗口。错误提示要挂在它上面，
    ///   多显示器时 `windows.first` 可能根本不是用户正在看的那个。
    // MARK: - 滚动截图（M3-1）

    /// 滚动截图会话（手动滚动模式：用户自己滚，我们按帧变化自适应采样）。
    /// 不是 private：诊断扩展在另一文件读取/驱动（滚动截图入口验证）。
    var scrollshot: ScrollshotController?

    /// 长截图结果窗口。持有到用户关闭，期间覆盖层可以正常销毁。
    private var scrollshotResult: ScrollshotResultController?

    private let scrollshotBar = ScrollshotProgressBar()

    /// 滚动截图期间的选区框。
    ///
    /// 会话一开始覆盖层就被收起（它盖住了用户要滚的那个窗口，不收没法滚），
    /// 屏幕上于是不再有任何东西说明「正在截哪一块」——用户切个窗口回来就
    /// 找不到边界了。这个框只画边界、鼠标穿透，不影响他继续滚；
    /// 并且声明了不可被捕获，否则那条蓝边会被逐帧拼进长图（见 `init(excludedFromCapture:)`）。
    let scrollshotRegionFrame = RecordingRegionFrame(excludedFromCapture: true)

    /// 以当前选区开始长截图。
    ///
    /// 会话期间**必须隐藏截图覆盖层**：它盖住的正是用户要滚的那个窗口，
    /// 不隐藏就没法滚。进度浮层则留在屏幕上，且位置在**选区之外**——
    /// `.region` 抓帧无法排除窗口，浮层压进选区就会被抓进长图。
    /// 选区在**屏幕坐标**下的矩形。
    ///
    /// 两道换算容易写反：视图坐标要加上窗口原点（覆盖层是铺满一块屏的窗口）；
    /// 而视图是**左上**原点、AppKit 屏幕坐标是**左下**原点，y 必须翻。
    /// 选区框与浮层都靠这个矩形定位，所以只留这一处。
    static func screenRect(for selection: CGRect, in window: NSWindow) -> CGRect {
        let frame = window.frame
        return CGRect(
            x: frame.minX + selection.minX,
            y: frame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        )
    }

    /// 不是 private：诊断扩展在另一文件读取/驱动（滚动截图入口验证）。
    func handleLongScreenshotRequest(
        _ rect: CGRect?,
        displayID: CGDirectDisplayID,
        overlayWindow: OverlayWindow,
        axis: ScrollAxis = .vertical
    ) {
        guard scrollshot == nil, let rect, rect.width >= 8, rect.height >= 8 else { return }
        let scale = DisplayGeometry.scaleFactor(for: displayID)
        let pixelRect = CoordinateConversion.pixelRect(fromLogical: rect, scaleFactor: scale)

        for window in windows {
            window.orderOut(nil)
        }

        // 选区在屏幕上的位置（AppKit 坐标）：覆盖层窗口 frame + 视图内偏移。
        let selectionScreenRect = Self.screenRect(for: rect, in: overlayWindow)
        scrollshotBar.onFinish = { [weak self] in
            Task { await self?.finishScrollshot() }
        }
        scrollshotBar.onCancel = { [weak self] in self?.cancelScrollshot() }
        scrollshotBar.show(near: selectionScreenRect)
        // 选区框要的就是「覆盖层收起之后仍然看得见边界」。
        scrollshotRegionFrame.show(rect: selectionScreenRect, appearance: .scrollshot)

        let controller = ScrollshotController(
            capturer: ScrollshotFrameCapturer(capturer: capturer),
            selection: pixelRect,
            displayID: displayID,
            scaleFactor: scale,
            axis: axis
        )
        controller.onReady = { [weak self] in
            self?.scrollshotBar.updateGuide(ScrollshotProgressBar.guideScrolling)
        }
        // 预览：节流在控制器内，这里只负责把整幅导航图与定位框贴到浮层上。
        // 进度回调不再驱动界面——「已采集 N 帧」是给开发者看的统计，不是用户的
        // 问题；用户要看的是长图的样子与当前位置，那由预览回答。
        controller.onPreview = { [weak self] content in
            self?.scrollshotBar.updatePreview(content)
        }
        // 放大栏：浮层不持有长图，拖动定位框时按世界行区间向会话现取一段切片。
        scrollshotBar.onDetailRequest = { [weak self] worldRows, targetWidth in
            self?.scrollshot?.detailImage(worldRows: worldRows, targetWidth: targetWidth)
        }
        controller.onFinish = { [weak self] outcome in
            self?.reportScrollshot(outcome)
        }
        // 跟丢时暂停收录；回到有重叠的内容后恢复，已采部分始终保留。
        controller.onStall = { [weak self] in
            self?.scrollshotBar.updateGuide(ScrollshotProgressBar.guideStalled, isWarning: true)
        }
        controller.onRecovery = { [weak self] in
            self?.scrollshotBar.updateGuide(ScrollshotProgressBar.guideScrolling)
        }
        // 「上限」与「跟丢」必须说成不同的话：前者已经采够了（长图可用），
        // 后者暂停收录、等待回滚对齐。
        controller.onLimitReached = { [weak self] limit in
            switch limit {
            case .outputHeight:
                self?.scrollshotBar.updateGuide(ScrollshotProgressBar.guideHeightLimit)
            case .frameCount:
                self?.scrollshotBar.updateGuide(ScrollshotProgressBar.guideFrameLimit)
            }
        }
        controller.start()
        scrollshot = controller
        logger.notice("""
            滚动截图会话开始：选区             \(Int(pixelRect.size.width), privacy: .public)x\(Int(pixelRect.size.height), privacy: .public)
            """)
    }

    // MARK: - OCR（M3-2）

    private let ocrPanel = OCRResultPanel()

    /// 识别入口。它只负责选中 provider 并把活交出去（没有回退，理由见 `OCRService`）。
    private let ocrService = OCRService()

    /// 翻译入口。与 `ocrService` 一样只持有配置读取器，可安全地在任务里使用。
    private let translationService = TranslationService()

    /// 最近一次 OCR 结果：翻译需要它（面板只显示文本，不持有模型）。
    private var lastOCRResult: OCRResult?

    /// 正在进行的 OCR 请求。
    ///
    /// 用来挡掉重复点击：识别期间面板上写着「正在识别文字…」，
    /// 再点一次只会再排一个请求，两段等待叠在一起，看起来反而更慢。
    private var ocrTask: Task<Void, Never>?
    private var ocrRequestID: UUID?
    private var translationTask: Task<Void, Never>?
    private var translationRequestID: UUID?

    /// 正在进行的翻译可用性查询。
    ///
    /// 用户可能连续改目标语言，每次都要重新判定；旧判定必须能被取消，
    /// 否则先到的旧结论会盖掉后到的新结论，按钮状态就会与下拉框说的不一致。
    private var translationAvailabilityTask: Task<Void, Never>?

    /// 面板关闭、会话结束或开始新识别时，使未完成的文字请求失效。
    private func cancelTextRequests() {
        ocrRequestID = nil
        translationRequestID = nil
        ocrTask?.cancel()
        ocrTask = nil
        translationTask?.cancel()
        translationTask = nil
        translationAvailabilityTask?.cancel()
        translationAvailabilityTask = nil
        lastOCRResult = nil
        ocrPanel.onCopyAll = nil
        ocrPanel.onTranslate = nil
        ocrPanel.onTargetLanguageChanged = nil
    }

    /// 固定截图（Pin）：它是全尺寸位图的唯一合法长驻点，因此由控制器统一持有，
    /// 数量上限与释放路径都在 `PinManager` 里。
    ///
    /// 不是 private：菜单栏（`AppDelegate`）要从这里取列表来建子菜单。
    let pinManager: PinManager

    /// 固定截图达到上限、无法再钉时的回调。
    ///
    /// 由 `AppDelegate` 接上非模态提示（本层不做任何界面）。
    var onPinLimitReached: ((Int) -> Void)?

    /// 所有显示器的底图都获取失败、会话已放弃时的回调。
    ///
    /// 本层不判断原因、也不做界面：权限状态与引导入口都在 `AppDelegate`。
    var onBackdropUnavailable: (() -> Void)?

    /// 一次交付产生的产物。
    ///
    /// 复制 / 保存 / 钉住 / 长截图都走这里，而不是只广播「保存成功」：
    /// 历史账本需要覆盖所有交付方式，否则用户复制过的图在历史里不存在，
    /// 剪贴板一被覆盖就永久丢失。本层只负责描述产物，不决定怎么记账或提示。
    var onArtifact: ((CaptureArtifact) -> Void)?

    /// 识别当前选区里的文字并展示结果。
    ///
    /// 不结束截图会话：用户常要对着原文核对，且识别后往往还要接着标注。
    ///
    /// 顺序上有一处硬要求：**先把面板摆出来，再去捕获与识别**。
    /// 识别能力首次加载要十几秒（见 `TextRecognizer.prewarm` 的实测），
    /// 之前是等结果回来才显示面板，于是这段等待在界面上没有任何痕迹——
    /// 用户看到的就是「按了没反应」，还会因为不确定而反复点。
    private func handleRecognizeTextRequest(
        _ rect: CGRect?,
        displayID: CGDirectDisplayID,
        overlayWindow: OverlayWindow
    ) {
        guard let rect, rect.width >= 8, rect.height >= 8 else {
            // 静默返回等于「点了没反应」：选区太小时也必须出个声。
            NSSound.beep()
            return
        }
        guard ocrTask == nil else { return }

        // 选区在屏幕上的位置（AppKit 坐标）——面板要避开它。
        let windowFrame = overlayWindow.frame
        let selectionScreenRect = CGRect(
            x: windowFrame.minX + rect.minX,
            y: windowFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )

        // 识别对象取自冻结底图（理由见 `OverlayView.recognitionImage`）。
        // 必须在这里同步取出：会话结束时底图会被显式释放，任务里再取可能已经没了。
        guard let image = overlayWindow.overlayView.recognitionImage(for: rect) else {
            NSSound.beep()
            return
        }

        cancelTextRequests()
        let requestID = UUID()
        ocrRequestID = requestID
        ocrPanel.showLoading(near: selectionScreenRect)
        logger.notice("""
            OCR 开始：选区 \(Int(rect.width), privacy: .public)x\(Int(rect.height), privacy: .public)
            """)

        ocrTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.ocrRequestID == requestID { self.ocrTask = nil }
            }

            let startedAt = Date()
            do {
                let result = try await self.ocrService.recognize(in: image)
                guard !Task.isCancelled, self.ocrRequestID == requestID else { return }
                let recognizedAt = Date()

                self.lastOCRResult = result
                self.ocrPanel.onCopyAll = { [weak self] text in
                    self?.copyRecognizedText(text)
                }
                self.ocrPanel.onTranslate = { [weak self] target in
                    self?.translateRecognizedText(to: target)
                }
                self.ocrPanel.onTargetLanguageChanged = { [weak self] target in
                    self?.refreshTranslationAvailability(target: target)
                }
                self.ocrPanel.applyTranslationAvailability(
                    TranslationSupport.availability(
                        for: self.translationService.selectedStrategy,
                        isCloudConfigured: self.translationService.isCloudConfigured
                    )
                )
                self.ocrPanel.show(result: result, near: selectionScreenRect)

                // 识别对象来自内存中的底图，耗时即识别本身（首次加载识别能力也计在内）。
                logger.notice("""
                    OCR 完成：\(result.lines.count, privacy: .public) 行 \
                    \(Int(result.imagePixelSize.width), privacy: .public)x\(Int(result.imagePixelSize.height), privacy: .public) \
                    provider=\(self.ocrService.selectedKind.rawValue, privacy: .public) \
                    坐标=\(result.coordinateCapability.rawValue, privacy: .public) \
                    识别=\(Int(recognizedAt.timeIntervalSince(startedAt) * 1000), privacy: .public)ms
                    """)
            } catch {
                guard !Task.isCancelled, self.ocrRequestID == requestID else { return }
                logger.error("OCR 失败：\(String(describing: error), privacy: .public)")
                self.ocrPanel.showError(
                    "文字识别失败：\(error.localizedDescription)",
                    near: selectionScreenRect
                )
                NSSound.beep()
            }
        }
    }

    /// 把识别结果整段写入剪贴板。
    /// 翻译已识别的文字。
    ///
    /// 可用性在真正发起前**再查一次**：面板打开与用户点按钮之间可能过了很久，
    /// 而且语言对是否受支持只有真实查询才知道。
    private func translateRecognizedText(to target: String) {
        guard let result = lastOCRResult, !result.lines.isEmpty else {
            NSSound.beep()
            return
        }
        let lines = result.lines
        // 源语言在本机判定（`NLLanguageRecognizer`，快且不联网、不限系统版本）。
        // 判不出来时传 nil 而不是空串：空串会被 `LanguageAvailability` 当成一个
        // 真实的语言标识去查，然后得到「不支持」——那是我们自己的检测失败，
        // 不应该被伪装成系统的能力结论（实测 `"" → en-US` 就是 unsupported）。
        let source = SourceLanguageDetector.detect(in: lines)

        // 旧的语言切换判定已经没有意义了，取消掉，免得它稍后回来改按钮状态。
        translationAvailabilityTask?.cancel()
        translationTask?.cancel()
        let requestID = UUID()
        translationRequestID = requestID
        ocrPanel.setTranslating(true)

        translationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.translationRequestID == requestID {
                    self.translationTask = nil
                    self.ocrPanel.setTranslating(false)
                }
            }
            let availability = await self.translationService.availability(
                source: source,
                target: target
            )
            guard !Task.isCancelled, self.translationRequestID == requestID else { return }
            guard availability.isAvailable else {
                logger.notice("translation: 不可用 → \(availability.explanation, privacy: .public)")
                // 原因必须落在面板上：只 beep 一声，用户只会以为功能坏了。
                self.ocrPanel.showTranslationUnavailable(availability)
                NSSound.beep()
                return
            }
            let translated = await self.translationService.translate(
                lines: lines,
                source: source,
                target: target
            )
            guard !Task.isCancelled, self.translationRequestID == requestID else { return }
            self.ocrPanel.showTranslation(translated)
        }
    }

    /// 目标语言改变后重新判定翻译入口。
    ///
    /// 可用性是「源语言 → 目标语言」的函数，换了目标就得重算：
    /// 「原文已经是英文」与「英文 → 中文」是同一次识别结果下的两种不同结论。
    private func refreshTranslationAvailability(target: String) {
        guard let result = lastOCRResult, !result.lines.isEmpty else { return }
        let source = SourceLanguageDetector.detect(in: result.lines)

        translationRequestID = nil
        translationTask?.cancel()
        translationTask = nil
        ocrPanel.setTranslating(false)
        translationAvailabilityTask?.cancel()
        translationAvailabilityTask = Task { [weak self] in
            guard let self else { return }
            let availability = await self.translationService.availability(
                source: source,
                target: target
            )
            guard !Task.isCancelled else { return }
            self.ocrPanel.applyTranslationAvailability(availability)
        }
    }

    private func copyRecognizedText(_ text: String) {
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.setString(text, forType: .string)
        logger.notice("OCR 复制：\(text.count, privacy: .public) 字符 成功=\(ok, privacy: .public)")
    }

    /// 用户点「完成」：拼接并交付。
    private func finishScrollshot() async {
        await scrollshot?.finish()
    }

    /// 用户点「取消」。
    /// 不是 private：诊断扩展在另一文件读取/驱动（滚动截图入口验证）。
    func cancelScrollshot() {
        scrollshot?.cancel()
        scrollshot = nil
        scrollshotRegionFrame.hide()
        scrollshotBar.updatePreview(nil)
        scrollshotBar.hide()
        logger.notice("滚动截图已取消")
        dismiss()
    }

    /// 会话收尾：把长图交到剪贴板，然后结束截图会话。
    private func reportScrollshot(_ outcome: ScrollshotController.Outcome) {
        scrollshot = nil
        scrollshotRegionFrame.hide()
        scrollshotBar.updatePreview(nil)
        scrollshotBar.hide()

        guard let image = outcome.image else {
            logger.error("滚动截图失败：\(outcome.failure ?? "未知", privacy: .public)")
            NSSound.beep()
            // 失败原因只写日志等于用户什么都没看到：覆盖层一消失，
            // 用户只知道「响了一声」。必须把可读原因摆到屏幕上。
            presentScrollshotFailure(outcome.failure)
            return
        }

        // PNG 只编码一次：这份数据既进剪贴板，也随产物交给历史缓存。
        let copyResult = SessionExporter.copyToPasteboardWithPNG(image)
        let copied = copyResult?.didCopy ?? false

        // 先登记产物：复制失败时结果仍在结果窗口里，
        // 不会出现「会话关了、剪贴板里没有、历史里也没有」的三重丢失。
        // 即便写剪贴板失败，已编码的 PNG 仍然可用，历史缓存照样成立。
        onArtifact?(CaptureArtifact(
            kind: .longScreenshot,
            source: CurrentSource.longScreenshot,
            image: image,
            fileURL: nil,
            delivery: .longShot,
            pngData: copyResult?.pngData
        ))

        logger.notice("""
            滚动截图完成：\(image.width, privacy: .public)x\(image.height, privacy: .public) \
            采纳帧=\(outcome.capturedFrames, privacy: .public) \
            观测帧=\(outcome.observedFrames, privacy: .public) 复制=\(copied, privacy: .public) \
            告警=\(outcome.plan?.warnings.joined(separator: " | ") ?? "-", privacy: .public)
            """)

        presentScrollshotResult(
            image,
            warnings: outcome.plan?.warnings ?? [],
            copied: copied
        )

        // 覆盖层在长截图开始时就已收起；这里结束会话、释放底图。
        // 结果窗口是独立对象，不受 dismiss 影响。
        dismiss()
    }

    /// 当前长截图的来源描述。当前实现只记录「长截图」这一层，
    /// 窗口/应用信息在会话收尾时已随覆盖层释放，不再猜。
    private enum CurrentSource {
        static let longScreenshot = HistorySource(mode: "longScreenshot")
    }

    /// 展示长截图结果，并把后续交付接到同一套导出/钉住路径上。
    private func presentScrollshotResult(
        _ image: CGImage,
        warnings: [String],
        copied: Bool
    ) {
        let screen = selectionDisplayID
            .flatMap { id in NSScreen.screens.first(where: { $0.displayID == id }) }
            ?? NSScreen.main
        let scale = selectionDisplayID.map { DisplayGeometry.scaleFactor(for: $0) } ?? 1

        let controller = ScrollshotResultController(
            image: image,
            warnings: warnings,
            actions: .init(
                onSave: { [weak self] image in
                    self?.saveScrollshotResult(image)
                },
                onCopy: { image in
                    let ok = SessionExporter.copyToPasteboard(image)
                    ToastPresenter.show(ok ? "长截图已复制到剪贴板" : "复制失败，图片仍在结果窗口里")
                },
                onPin: { [weak self] image in
                    guard let self else { return }
                    let result = self.pinManager.pin(
                        image: image,
                        screenScale: scale,
                        topLeft: nil
                    )
                    switch result {
                    case .created:
                        ToastPresenter.show("长截图已固定在屏幕上")
                        self.scrollshotResult?.close()
                    case .limitReached(let limit):
                        ToastPresenter.show("固定截图已达上限（\(limit) 张）")
                    }
                },
                onEdit: { [weak self] image in
                    // 继续编辑：把长图交给图片编辑会话（同一套标注/导出）。
                    // 先关结果窗口，避免两个窗口同时占着同一张位图。
                    self?.scrollshotResult?.close()
                    self?.present(image: image)
                },
                onClose: { [weak self] in
                    self?.scrollshotResult = nil
                }
            )
        )
        scrollshotResult = controller
        controller.show(on: screen)
        if copied {
            ToastPresenter.show("长截图已复制，可在结果窗口保存或钉住")
        } else {
            ToastPresenter.show("长截图已生成，复制失败，请从结果窗口保存")
        }
    }

    private func saveScrollshotResult(_ image: CGImage) {
        let outcome = SessionExporter.save(
            image,
            suggestedName: Exporter.defaultFileName(),
            destination: settings.saveDestination
        )
        switch outcome {
        case .saved(let url):
            ToastPresenter.show(
                "长截图已保存：\(url.lastPathComponent)",
                actionTitle: "在访达中显示"
            ) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            scrollshotResult?.close()
        case .cancelled:
            break
        case .failed(let reason):
            ToastPresenter.show("保存失败：\(reason)")
        }
    }

    /// 弹窗说明长截图失败的原因。
    private func presentScrollshotFailure(_ failure: String?) {
        // 覆盖层是非激活面板，不显式激活应用的话警告框可能显示在它下面。
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "长截图失败"
        alert.informativeText = Self.scrollshotFailureMessage(failure)
        alert.addButton(withTitle: "好")
        // 覆盖层窗口的层级是 `.screenSaver`，普通警告框会被它整个盖住。
        // 只激活应用还不够，弹窗必须压到覆盖层之上才看得见。
        alert.window.level = NSWindow.Level(
            rawValue: NSWindow.Level.screenSaver.rawValue + 1
        )
        alert.runModal()
    }

    /// 把长截图的失败串翻译成用户能理解的一句话。
    ///
    /// 失败串来自两层：`ScrollStitcher.Failure` 经 `String(describing:)` 得到的
    /// 英文枚举名，以及抓帧错误的 description。直接展示前者等于没有解释。
    private static func scrollshotFailureMessage(_ failure: String?) -> String {
        guard let failure, !failure.isEmpty else {
            return "未能生成长截图，请稍后重试。"
        }
        if failure.contains("emptyFirstFrame") {
            return "没有抓到第一帧画面。请确认屏幕录制权限有效，并让选区内有可见内容后重试。"
        }
        if failure.contains("notEnoughFrames") {
            return "滚动过程中没有识别到足够的画面变化，长截图未生成。请让内容多滚动一段距离后重试。"
        }
        if failure.contains("noAcceptedFrame") {
            return "滚动过程中没有可拼接的画面，长截图未生成。请确认选区内有可滚动的内容后重试。"
        }
        if failure.contains("首帧抓取失败") || failure.contains("capture") {
            return "抓取屏幕画面失败，长截图未生成。请确认屏幕录制权限后重试。"
        }
        return "长截图未生成：\(failure)"
    }

    /// 当前选区的左上角在**屏幕坐标**上的位置（AppKit 坐标）。
    ///
    /// 选区记在覆盖层视图里（左上原点、逻辑点），而窗口 `frame` 记的是左下原点，
    /// 所以 y 要做一次翻转——与会话内 OCR 面板避让用的是同一套换算。
    ///
    /// 取不到选区时返回 nil，由 `PinManager` 自己挑位置（不得因此不让钉）。
    private func pinTopLeft(in window: NSWindow?) -> CGPoint? {
        guard let window, let overlay = window as? OverlayWindow,
              let rect = overlay.overlayView.selectionRect else {
            return nil
        }
        return CGPoint(x: window.frame.minX + rect.minX, y: window.frame.maxY - rect.minY)
    }

    /// 当前选区对应的来源描述。
    ///
    /// 历史记录只有「时间 + 尺寸」时，用户在一屏缩略图里根本认不出哪张是哪个
    /// 应用的窗口。来源信息在会话里是现成的（识别目标），离开会话就拿不到了，
    /// 所以必须在交付这一刻一起带出去。
    private func currentSource(mode: String) -> HistorySource? {
        if let documentSource { return documentSource }
        guard let displayID = selectionDisplayID,
              let window = windows.first(where: { $0.displayID == displayID }) else {
            return HistorySource(mode: mode)
        }
        let target = window.overlayView.detectionTargetForIntent
        let appName = target?.processID.flatMap {
            NSRunningApplication(processIdentifier: $0)?.localizedName
        }
        return HistorySource(
            appName: appName,
            windowTitle: target?.title,
            mode: target.map { $0.layer.rawValue } ?? mode
        )
    }

    private func handleExport(_ image: CGImage, action: ExportAction, in window: NSWindow?) {
        // 直达动作会话里，回车 / ⌘C 的语义是「就选这块，开始」，
        // 而不是「拷贝一张还没标注的截图」。工具栏此时是隐藏的，
        // 若仍按普通导出处理，用户会得到一张图却看不到录制/OCR 开始，
        // 只能以为热键坏了。
        if pendingIntent != .capture,
           let overlay = window as? OverlayWindow,
           let pixel = selection {
            performPendingIntent(pixel, displayID: overlay.displayID, window: overlay)
            return
        }

        switch action {
        case .pin:
            // 窗口尺寸要按图像所在屏幕的缩放换算，否则 Pin 会大一倍或小一半。
            let scale = selectionDisplayID.map { DisplayGeometry.scaleFactor(for: $0) } ?? 1
            let result = pinManager.pin(
                image: image,
                screenScale: scale,
                topLeft: pinTopLeft(in: window)
            )
            // 在闭包外取值：多行日志里的属性访问会触发「显式 self」的编译要求，
            // 提前算好既避免它，也让这行日志更短。
            let pinCount = pinManager.pins.count
            let pinMegabytes = pinManager.estimatedBytes / 1024 / 1024
            switch result {
            case .created:
                logger.notice("""
                    pin: \(image.width, privacy: .public)x\(image.height, privacy: .public) \
                    scale=\(scale, privacy: .public) 当前共 \(pinCount, privacy: .public) 个 \
                    估算占用 \(pinMegabytes, privacy: .public)MB
                    """)
                onArtifact?(CaptureArtifact(
                    kind: .screenshot,
                    source: currentSource(mode: "region"),
                    image: image,
                    fileURL: nil,
                    delivery: .pinned
                ))
                dismiss()

            case .limitReached(let limit):
                // **不结束会话**：用户的标注还在，而且他接下来多半要去关掉几张
                // 再回来钉——把会话收掉等于逼他重截一张。
                logger.notice("""
                    pin 被拒绝：已达上限 \(limit, privacy: .public) 当前共 \(pinCount, privacy: .public) 个
                    """)
                NSSound.beep()
                onPinLimitReached?(limit)
            }

        case .copy:
            // 编码一次：成功时那份 PNG 直接进历史缓存，不再二次编码。
            let copyResult = SessionExporter.copyToPasteboardWithPNG(image)
            let copied = copyResult?.didCopy ?? false
            logger.notice("""
                export copy: success=\(copied, privacy: .public) \
                size=\(image.width, privacy: .public)x\(image.height, privacy: .public)
                """)
            if copied, let copyResult {
                onArtifact?(CaptureArtifact(
                    kind: .screenshot,
                    source: currentSource(mode: "region"),
                    image: image,
                    fileURL: nil,
                    delivery: .copied,
                    pngData: copyResult.pngData
                ))
                dismiss()
            } else {
                NSSound.beep()
            }

        case .save:
            let outcome = SessionExporter.save(
                image,
                suggestedName: Exporter.defaultFileName(),
                destination: settings.saveDestination
            )
            switch outcome {
            case .saved(let url):
                logger.notice("export save: \(url.path, privacy: .public)")
                onArtifact?(CaptureArtifact(
                    kind: .screenshot,
                    source: currentSource(mode: "region"),
                    image: image,
                    fileURL: url,
                    delivery: .saved
                ))
                dismiss()

            case .cancelled:
                logger.notice("export save: cancelled by user")

            case .failed(let reason):
                // 失败时保持会话：图还在，用户可以直接重试或改路径。
                // 关掉会话才是真的把图弄丢了。
                logger.error("export save failed: \(reason, privacy: .public)")
                presentSaveFailure(reason, image: image, in: window)
            }
        }
    }

    // MARK: - 录制准备

    /// 录制准备面板。常驻一个实例即可：同一时刻只会有一次录制准备。
    /// 不是 private：诊断扩展在另一文件读它。
    let setupPanel = RecordingSetupPanel()

    /// 准备阶段的**范围框预览**：面板一弹出就显示「将要录哪一块」，
    /// 而不是等开始后才让用户看到边界。
    /// 不是 private：诊断扩展在另一文件读它。
    let setupPreviewFrame = RecordingRegionFrame()

    private var setupTargets: [RecordingScopeKind: SetupTarget] = [:]

    /// 准备阶段打开的选区与它所在的显示器（视图逻辑点坐标）。
    ///
    /// 与 `selection` 分开存：`selection` 会随撤销/重做、鼠标手势变化，
    /// 而准备面板一旦弹出，它该用的就是**打开那一刻**的那个选区。
    private var setupSelectionRect: CGRect?
    private var setupSelectionScreenRect: CGRect?
    private var setupSelectionDisplayID: CGDirectDisplayID?

    /// 正在进行的录制目标选取（窗口 / 应用）。
    /// 不是 private：诊断扩展在另一文件读它。
    var setupPickKind: RecordingScopeKind?

    /// 处理「以当前选区开始录制」。
    ///
    /// 覆盖层先弹出准备面板确认范围与音频，**确认后**才收起覆盖层并发出录制请求：
    /// 覆盖层是全屏的非激活面板并覆盖所有显示器，若留着不走，
    /// 录出来的第一帧就是覆盖层自己。
    ///
    /// 但**取消时不关闭覆盖层**：用户的截图与标注状态原样保留，可以继续编辑。
    /// 不是 private：诊断扩展在另一文件调用（合成请求与组装范围）。
    func handleRecordRequest(
        _ rect: CGRect?,
        detected: DetectionTarget?,
        displayID: CGDirectDisplayID,
        overlayWindow: OverlayWindow
    ) {
        // 坐标转换交给覆盖层窗口：它铺满目标显示器，知道自己的原点与高度。
        // 自己按主屏高度翻转在多显示器上会把矩形算到屏幕外。
        func screenRect(_ local: CGRect) -> CGRect {
            overlayWindow.appKitScreenRect(forLocalRect: local)
        }

        // 全屏范围就是覆盖层覆盖的整块显示器
        let fullScreenRect = overlayWindow.frame

        // 每次弹出都是一次全新的准备：上一轮锁定的目标与待选状态一律作废。
        setupTargets = [:]
        setupPickKind = nil
        setupSelectionDisplayID = displayID
        if let rect, rect.width >= 1, rect.height >= 1 {
            setupSelectionRect = rect
            setupSelectionScreenRect = screenRect(rect)
        } else {
            setupSelectionRect = nil
            setupSelectionScreenRect = nil
        }

        // 打开面板那一刻正好悬停在某个窗口/应用上时，**不**把它当作已选定。
        //
        // 悬停只是「指针恰好在那」，不是「用户要录它」。要预填就要求截图选区已经是
        // 用户明确确认过的（对话候选的单击、或手动框选），此时识别身份才代表一次选择。
        let selectionIsConfirmed = editorState?.isSelectionConfirmed ?? false
        if selectionIsConfirmed, let detected {
            switch detected.layer {
            case .window where detected.windowID != nil:
                setupTargets[.window] = SetupTarget(
                    target: detected,
                    screenRect: RecordingScopeComposer.captureScreenRect(for: detected) {
                        overlayWindow.appKitScreenRect(forLocalRect: $0)
                    }
                )
            case .application where detected.processID != nil:
                setupTargets[.application] = SetupTarget(
                    target: detected,
                    screenRect: RecordingScopeComposer.captureScreenRect(for: detected) {
                        overlayWindow.appKitScreenRect(forLocalRect: $0)
                    }
                )
            default:
                break
            }
        }

        // 区域要有选区，其余三个始终可选。
        var options: [RecordingSetupPanel.ScopeOption] = []
        if setupSelectionRect != nil {
            options.append(.init(kind: .region, title: "区域"))
        }
        options.append(.init(kind: .window, title: "窗口"))
        options.append(.init(kind: .application, title: "应用"))
        options.append(.init(kind: .display, title: "全屏"))

        // 面板跳转到选区附近；无选区时退回全屏区域
        let panelRect = setupSelectionScreenRect
            ?? setupTargets[.window]?.screenRect
            ?? fullScreenRect

        logger.notice("""
            录制准备：范围选项=\(options.count, privacy: .public) \
            识别层级=\(detected?.layer.rawValue ?? "无", privacy: .public)
            """)

        // 切换范围时预览框必须跟着变——否则用户点「全屏」却仍看到区域框，
        // 无从判断最终会不会录整屏。窗口/应用还要顺带进入目标选取。
        setupPanel.onKindChanged = { [weak self] kind in
            self?.recordingScopeKindChanged(to: kind)
        }
        setupPanel.onPickRequested = { [weak self] kind in
            self?.beginRecordingTargetPick(for: kind)
        }
        setupPanel.onStart = { [weak self] outcome in
            self?.startRecordingRequested(
                kind: outcome.kind,
                audio: outcome.audio,
                output: outcome.output
            )
        }
        setupPanel.onCancel = { [weak self] in
            self?.cancelRecordingSetup()
        }

        // 默认选中：有选区就选「区域」，否则选「全屏」。
        // 不能图省事取第 0 项——没有选区时第 0 项是「窗口」，
        // 一开面板就进入目标选取是一件让人莫名其妙的事。
        let preferredKind: RecordingScopeKind = setupSelectionRect != nil ? .region : .display
        let preferredIndex = options.firstIndex { $0.kind == preferredKind } ?? 0
        setupPanel.show(near: panelRect, options: options, preferredIndex: preferredIndex)

        // 面板自己会在 `show` 里清空所有目标状态（每次弹出都是全新的准备），
        // 因此预填的目标必须**在 show 之后**同步回去：
        // 不同步就会出现「预览框画在已选窗口上、面板却说尚未选定目标且禁止开始」。
        for (kind, picked) in setupTargets {
            setupPanel.setTarget(kind: kind, title: picked.target.title ?? kind.displayName)
        }

        // 接管输入：准备阶段的截图侧交互全部暂停（详见 `isRecordSetupActive`）。
        beginRecordSetupInput()
        // `show` 后才有选中项：预览框与选取状态要按它初始化。
        recordingScopeKindChanged(to: setupPanel.selectedKind ?? .display)
    }

    /// 把输入交给准备面板：截图识别、框选、标注、快捷键全部暂停。
    private func beginRecordSetupInput() {
        // 取色器是独立的高层窗口，准备期间它还能收点击——先收起来。
        windows.first?.overlayView.dismissColorPanel()
        for window in windows {
            window.overlayView.isRecordSetupActive = true
            window.overlayView.onRecordSetupCancel = { [weak self] in
                // ESC：优先取消正在进行的选取，否则取消整个准备。
                if self?.setupPickKind != nil {
                    self?.cancelRecordingTargetPick()
                } else {
                    self?.cancelRecordingSetupFromPanel()
                }
            }
            window.overlayView.onRecordSetupConfirm = { [weak self] in
                // 可用性只在面板一处判定，不在这里自行判断后绕过。
                self?.setupPanel.activateStart()
            }
        }
    }

    /// 交回输入（准备结束：开始录制 / 取消 / 会话收尾）。
    private func endRecordSetupInput() {
        for window in windows {
            window.overlayView.isRecordSetupActive = false
            window.overlayView.onRecordSetupCancel = nil
            window.overlayView.onRecordSetupConfirm = nil
        }
    }

    /// 取消整个录制准备（键盘 ESC 与面板取消按钮走同一条路）。
    private func cancelRecordingSetupFromPanel() {
        setupPanel.close()
        cancelRecordingSetup()
    }

    /// 用户切换了录制范围。
    private func recordingScopeKindChanged(to kind: RecordingScopeKind) {
        // 换范围即退出上一次的选取：候选与它所属的层级已经不同了。
        endRecordingTargetPick()

        if kind.requiresTarget, setupTargets[kind] == nil {
            // 没有已锁定的目标就直接进选取，少一次点击。
            beginRecordingTargetPick(for: kind)
        } else {
            updateSetupPreview()
        }
    }

    /// 进入录制目标选取（窗口 / 应用）。
    ///
    /// 重新选取（已有锁定目标）也走这里：**旧目标保留**，只是暂时不能用它开始，
    /// 用户按 ESC 就能退回去——这比先清空再让他重选安全。
    /// 不是 private：诊断扩展在另一文件调用（合成请求与组装范围）。
    func beginRecordingTargetPick(for kind: RecordingScopeKind) {
        guard kind.requiresTarget else { return }
        endRecordingTargetPick()
        setupPickKind = kind
        setupPanel.setPicking(true)
        // 进入选取后先重算预览框：此时该显示的是「已锁定的目标」或「什么都不显示」，
        // 而不是上一个范围留下的那个矩形。**必须在 refresh 之前**：
        // refresh 会带来候选，而候选应当覆盖这个回退值。
        updateSetupPreview()
        for window in windows {
            window.overlayView.beginRecordingTargetPick(kind)
            // 鼠标所在的那块屏才需要立刻算一次候选：用户按下「窗口」时指针通常
            // 已经停在目标上，而他不动鼠标就不会有 `mouseMoved`。
            // 每屏都算会让别的屏也留下一个候选，跨屏时会多出一块框。
            if window.frame.contains(NSEvent.mouseLocation) || windows.count == 1 {
                window.overlayView.refreshRecordingTargetPick()
            }
        }
    }

    /// 退出录制目标选取（不论正常结束、取消还是会话收尾）。
    private func endRecordingTargetPick() {
        setupPickKind = nil
        setupPanel.setPicking(false)
        setupPanel.setCandidateTitle(nil)
        for window in windows {
            window.overlayView.endRecordingTargetPick()
        }
    }

    /// 选取过程中鼠标移到了某个目标上（或移开了）。
    private func recordingPickHovered(_ target: DetectionTarget?, in window: OverlayWindow) {
        guard setupPickKind != nil else { return }
        setupPanel.setCandidateTitle(target?.title)

        guard let target else {
            // 指针到了没有目标的区域：退回「已锁定目标」或干脆收起预览框，
            // 而不是留在上一个候选上——那会让人以为鼠标下面就是它。
            updateSetupPreview()
            return
        }
        // 候选框画的是**指针下的那个对象**（应用层就是该应用的窗口范围），
        // 而锁定后画的是**实际录制范围**（应用层是整块显示器）。
        // 两者必须分开：用候选框当录制边界，用户会以为只录了那一小块。
        setupPreviewFrame.show(
            rect: window.appKitScreenRect(forLocalRect: target.rect),
            appearance: .candidate
        )
    }

    /// 用户单击锁定了录制目标。
    private func recordingPickCommitted(_ target: DetectionTarget, in window: OverlayWindow) {
        guard let kind = setupPickKind, kind.requiresTarget else { return }
        let screenRect = RecordingScopeComposer.captureScreenRect(for: target) {
            window.appKitScreenRect(forLocalRect: $0)
        }
        setupTargets[kind] = SetupTarget(target: target, screenRect: screenRect)
        endRecordingTargetPick()
        setupPanel.setTarget(kind: kind, title: target.title ?? kind.displayName)
        updateSetupPreview()
        logger.notice("""
            录制目标已选定：\(kind.rawValue, privacy: .public) \
            标题=\(target.title ?? "-", privacy: .public) \
            windowID=\(target.windowID.map(String.init) ?? "-", privacy: .public) \
            processID=\(target.processID.map(String.init) ?? "-", privacy: .public) \
            捕获矩形=\(NSStringFromRect(screenRect), privacy: .public)
            """)
    }

    /// 用户按 ESC 放弃了选取。
    private func cancelRecordingTargetPick() {
        endRecordingTargetPick()
        updateSetupPreview()
        logger.notice("录制目标选取已取消")
    }

    /// 范围组装与预览决策的输入（逻辑见 `RecordingScopeComposer`）。
    private var setupComposerState: RecordingScopeComposer.State {
        var state = RecordingScopeComposer.State()
        state.kind = setupPanel.isVisible ? setupPanel.selectedKind : nil
        state.targets = setupTargets
        state.selectionRect = setupSelectionRect
        state.selectionDisplayID = setupSelectionDisplayID
        state.selectionScreenRect = setupSelectionScreenRect
        state.displayScreenRect = fullScreenRectForSetup()
        return state
    }

    /// 按当前状态刷新预览范围框（决策点见 `RecordingScopeComposer.previewRect`）。
    private func updateSetupPreview() {
        guard let rect = RecordingScopeComposer.previewRect(setupComposerState) else {
            setupPreviewFrame.hide()
            return
        }
        setupPreviewFrame.show(rect: rect, appearance: .preview)
    }

    /// 准备阶段所属显示器的整屏矩形（AppKit 屏幕坐标）。
    private func fullScreenRectForSetup() -> CGRect? {
        if let displayID = setupSelectionDisplayID,
           let window = windows.first(where: { $0.displayID == displayID }) {
            return window.frame
        }
        return windows.first?.frame
    }

    /// 组装录制范围与它的屏幕矩形（**范围与矩形同源**，见 `RecordingScopeComposer`）。
    ///
    /// 传入的 `kind` 覆盖面板当前选择：诊断会用它验证「切到某范围后的最终请求」，
    /// 而不必真的去点面板。
    /// 不是 private：诊断扩展在另一文件调用（合成请求与组装范围）。
    func composeRecordingScope(
        kind: RecordingScopeKind
    ) -> (scope: CaptureScope, screenRect: CGRect)? {
        var state = setupComposerState
        state.kind = kind
        return RecordingScopeComposer.compose(state)
    }

    /// 用户确认开始录制。
    private func startRecordingRequested(
        kind: RecordingScopeKind,
        audio: AudioSettings,
        output: RecordingOutputChoice
    ) {
        guard let composed = composeRecordingScope(kind: kind) else {
            // 范围不成立（例如目标只有矩形没有身份）：不发出请求，
            // 也不收起会话——用户的截图与标注还在。
            logger.error("录制范围不可用，忽略开始请求：\(kind.rawValue, privacy: .public)")
            NSSound.beep()
            return
        }
        logger.notice(
            "开始录制：\(composed.scope.displayName, privacy: .public)"
        )
        // 交给 AppDelegate 显示正式的录制范围框（红色），预览框先撤
        setupPreviewFrame.hide()
        endRecordingTargetPick()
        // 交回输入：会话即将结束，面板回调与键盘接管都要拆掉，
        // 否则 `dismiss` 之后还留着一套指向已释放视图的闭包。
        endRecordSetupInput()
        dismiss()
        // 用通知而不是直接持有录制控制器：覆盖层只负责「捕获意图」，
        // 谁来执行属于装配层（AppDelegate）的决定，两者不应相互依赖。
        NotificationCenter.default.post(
            name: .anShotStartRecording,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.captureScope: composed.scope,
                NotificationUserInfoKey.recordingRect: composed.screenRect as Any,
                NotificationUserInfoKey.audioSettings: audio,
                NotificationUserInfoKey.outputChoice: output
            ]
        )
    }

    /// 用户取消了录制准备。
    private func cancelRecordingSetup() {
        // 只关面板与预览框：覆盖层与标注状态保持原样，用户继续截图编辑。
        endRecordingTargetPick()
        setupPreviewFrame.hide()
        setupTargets = [:]
        // 交回输入：截图识别、框选、标注、快捷键全部恢复。
        endRecordSetupInput()
        logger.notice("取消录制准备，返回截图编辑")
    }

    private func presentSaveFailure(_ reason: String, image: CGImage, in window: NSWindow?) {
        // 「好」只是关掉提示——如果失败原因是「固定文件夹已失效」，
        // 用户关掉后再试一次还是同样的失败，他会陷入循环。
        // 所以把「另存为…」摆在第一颗按钮：它绕开坏掉的设置直接走保存面板，
        // 无论配置成什么都能把图存下来。
        NSSound.beep()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "保存失败"
        alert.informativeText = reason + "\n\n截图仍保留在当前会话中。"
        alert.addButton(withTitle: "另存为…")
        alert.addButton(withTitle: "好")

        // 优先挂在发起导出的窗口：多显示器时错误提示应当出现在
        // 用户正在操作的那一块屏上。
        let host = window ?? windows.first
        guard let host else { return }

        alert.beginSheetModal(for: host) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.saveWithPanelKeepingSession(image)
            }
        }
    }

    /// 走系统保存面板。取消则保留会话，成功则结束会话。
    private func saveWithPanelKeepingSession(_ image: CGImage) {
        let outcome = SessionExporter.saveWithPanel(
            image,
            suggestedName: Exporter.defaultFileName()
        )
        switch outcome {
        case .saved(let url):
            logger.notice("export save (panel): \(url.path, privacy: .public)")
            onArtifact?(CaptureArtifact(
                kind: .screenshot,
                source: currentSource(mode: "region"),
                image: image,
                fileURL: url,
                delivery: .saved
            ))
            dismiss()
        case .cancelled:
            logger.notice("export save (panel): cancelled by user")
        case .failed(let reason):
            logger.error("export save (panel) failed: \(reason, privacy: .public)")
            NSSound.beep()
        }
    }

    /// 关闭全部窗口并释放底图。不做任何延迟回收。
    private func teardown() {
        sessionID = nil
        ocrPanel.hide()
        // 准备面板与预览框是**跨会话**存在的实例（不是每个会话新建的），
        // 因此会话结束时必须显式收起：用户完全可能在正在选取录制目标时
        // 直接按 ESC 退出会话，那时面板还开着。
        endRecordingTargetPick()
        setupPreviewFrame.hide()
        // 滚动截图的选区框与浮层同理：会话可能以任何方式终止
        //（ESC、切屏、切回应用），结束时它们必须离开屏幕。
        scrollshotRegionFrame.hide()
        scrollshotBar.hide()
        setupPanel.close()
        endRecordSetupInput()
        setupTargets = [:]
        setupSelectionRect = nil
        setupSelectionScreenRect = nil
        setupSelectionDisplayID = nil
        // 面板保留着上一会话的闭包，清掉：下一次会话前若被误触，
        // 会对着已经释放的覆盖层做操作。
        setupPanel.onKindChanged = nil
        setupPanel.onPickRequested = nil
        setupPanel.onStart = nil
        setupPanel.onCancel = nil

        // 取色器是共享窗口：会话结束必须收起并还原它的层级，
        // 否则本会话为了压住覆盖层提到的最高层会一直留在系统里。
        // 面板全局只有一个，收起一次即可。
        windows.first?.overlayView.dismissColorPanel()

        for window in windows {
            // 显式释放底图，不依赖 ARC 的释放时机。
            window.overlayView.backdrop = nil
            window.overlayView.editorState = nil
            window.overlayView.onCancel = nil
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        selection = nil
        onSelectionChanged?(nil)
        // 样式在会话结束落盘：不在 `style.didSet` 里写，是因为拖动
        // 线宽滑块会在一秒内产生几十次变更，每次都写 UserDefaults
        // 既慢又没有必要。用户真正在意的是「下一次还是这个样式」。
        if let editorState {
            EditorStyleStore.shared.save(editorState.style)
        }
        editorState = nil
        pendingIntent = .capture
        documentSource = nil
        isPresenting = false
        // 覆盖层的 crosshair / 对角光标不是系统光标，
        // 窗口关闭后系统不会自动恢复。
        NSCursor.arrow.set()
        onSessionStateChanged?()
    }

    // MARK: - 辅助

    /// 键盘输入的目标窗口：鼠标所在显示器的窗口，回退到主显示器。
    /// 默认选区所属的显示器。
    private static func defaultSelectionDisplayID(in targets: [ScreenTarget]) -> CGDirectDisplayID? {
        defaultSelectionTarget(in: targets)?.displayID
    }

    /// 会话是否仍在展示（诊断用）。
    var isPresentingForDiagnostics: Bool { !windows.isEmpty }

    /// 鼠标所在显示器的整屏像素矩形；取不到时返回 `nil`（即无默认选区）。
    private static func defaultSelectionPixelRect(in targets: [ScreenTarget]) -> PixelRect? {
        guard let target = defaultSelectionTarget(in: targets) else { return nil }

        let scale = DisplayGeometry.scaleFactor(for: target.displayID)
        let bounds = DisplayGeometry.bounds(for: target.displayID)
        // `bounds` 是**全局**显示坐标（原点在主屏左上），而编辑器与视图的
        // 像素坐标是**本显示器局部**的。副屏直接拿全局原点乘 scale，会把
        // 整屏选区整体平移到本屏之外：右侧副屏导出宽度为 0（只剩一声响），
        // 左侧副屏则只截到残缺一角。
        //
        // 与 `DetectionSession.displayTarget` 一致，先把全局矩形平移成本屏
        // 局部坐标再换像素。`CGDisplayBounds` 与视图坐标同为左上原点、y 向下，
        // 因此只需平移，不需要 AppKit 的上下翻转。
        let local = DetectionGeometry.localRect(fromGlobal: bounds, displayBounds: bounds)
        let pixel = CoordinateConversion.pixelRect(fromLogical: local, scaleFactor: scale)
        return pixel.isNonEmpty ? pixel : nil
    }

    /// 默认选区落在哪块显示器：鼠标所在的那块，退到主屏，再退到第一块。
    private static func defaultSelectionTarget(in targets: [ScreenTarget]) -> ScreenTarget? {
        let mouseLocation = NSEvent.mouseLocation
        return targets.first { $0.screen.frame.contains(mouseLocation) }
            ?? targets.first { $0.displayID == DisplayGeometry.mainDisplay() }
            ?? targets.first
    }

    /// 把键盘焦点交给某块显示器的覆盖层窗口。
    ///
    /// 会话开始时只让鼠标所在屏成为 key；之后选区归属会随识别悬停、
    /// 选区提交、撤销/重做切到另一块屏。不跟着切换的话，回车 / ⌘C 仍由
    /// 旧窗口处理，而 `performExport` 用的是**旧窗口的底图**去裁**新屏的
    /// 像素矩形**——用户得到的是另一块屏的画面。这是多显示器键盘导出的根因。
    private func focusOverlayWindow(for displayID: CGDirectDisplayID) {
        guard let window = windows.first(where: { $0.displayID == displayID }) else { return }
        // 已经是 key 就不打扰：文字编辑期间 firstResponder 是输入控件，
        // 无条件 makeFirstResponder 会把输入焦点抢走。
        guard !window.isKeyWindow else { return }
        window.makeKey()
        _ = window.makeFirstResponder(window.overlayView)
    }

    private func keyWindowCandidate(in candidates: [OverlayWindow]) -> OverlayWindow? {
        let mouseLocation = NSEvent.mouseLocation
        if let underPointer = Self.screenTargets().first(where: { $0.screen.frame.contains(mouseLocation) }),
           let match = candidates.first(where: { $0.displayID == underPointer.displayID }) {
            return match
        }
        let mainDisplayID = DisplayGeometry.mainDisplay()
        return candidates.first { $0.displayID == mainDisplayID } ?? candidates.first
    }

    private struct ScreenTarget {
        let screen: NSScreen
        let displayID: CGDirectDisplayID
    }

    /// 当前连接的全部显示器。
    ///
    /// 以 `NSScreen.screens` 为准而非 `DisplayGeometry.activeDisplays()`：
    /// 建窗需要 `NSScreen`（提供 frame），两处数据源混用会产生对不上的风险。
    private static func screenTargets() -> [ScreenTarget] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else {
                logger.error("screen without NSScreenNumber ignored; frame=\(NSStringFromRect(screen.frame), privacy: .public)")
                return nil
            }
            return ScreenTarget(screen: screen, displayID: displayID)
        }
    }

    /// 底图总字节数（BGRA8 估算），用于核对内存预算。
    private static func backdropBytes(_ backdrops: [CGDirectDisplayID: CGImage]) -> Int {
        backdrops.values.reduce(0) { total, image in
            total + image.bytesPerRow * image.height
        }
    }

    /// 单调时钟的时间差，单位毫秒。
    ///
    /// 标记 `nonisolated`：会在 `withTaskGroup` 的 Sendable 子任务里调用，
    /// 那里不在主 actor 上，而本方法不访问任何隔离状态。
    private nonisolated static func milliseconds(
        _ from: ContinuousClock.Instant,
        _ to: ContinuousClock.Instant
    ) -> String {
        let duration = from.duration(to: to)
        let components = duration.components
        let value = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        return String(format: "%.1f", value)
    }
}

extension NSScreen {
    /// `NSScreen` 对应的 `CGDirectDisplayID`。
    ///
    /// AppKit 不直接暴露该标识，只能从 `deviceDescription` 取。
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}
