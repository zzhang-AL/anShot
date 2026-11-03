//
//  OverlayController+Diagnostics.swift
//  AnShotUI
//
//  录制准备阶段的诊断接口。
//
//  ── 为什么单独一个文件 ────────────────────────────────────
//
//  这些访问器只服务于诊断：读面板状态、合成一次请求、按类型发起选取。
//  它们没有产品调用方（`#if DEBUG` 之外不参与任何逻辑），却占了主文件
//  近两百行，把「准备阶段到底怎么走」这条主线埋在几十个 `xxxForDiagnostics`
//  之间。按职责分到独立文件后，主文件只留流程本身。
//
//  ── 为什么不抽成独立类型 ──────────────────────────────────
//
//  它们读的都是控制器**内部状态**（面板、预览框、窗口列表、选取类型）。
//  抽成独立类型需要把这些状态全部交出去或做成查询协议，等于为测试便利
//  改产品结构；而它们已经全部在 `#if DEBUG` 内，Release 产物里并不存在。
//

#if DEBUG
import AnShotCapture
import AnShotCore
import AppKit

extension OverlayController {

    /// 诊断用：走真实的录制请求链路，仅跳过物理点击。
    @discardableResult
    func simulateRecordRequestForDiagnostics(
        rect: CGRect?,
        detected: DetectionTarget?,
        displayID: CGDirectDisplayID
    ) -> Bool {
        guard let window = primaryOverlayWindow as? OverlayWindow else { return false }
        handleRecordRequest(
            rect,
            detected: detected,
            displayID: displayID,
            overlayWindow: window
        )
        return true
    }

    /// 诊断用：预览范围框当前的矩形（AppKit 屏幕坐标）。
    var setupPreviewFrameRectForDiagnostics: CGRect? {
        setupPreviewFrame.currentRect
    }

    /// 诊断用：预览范围框当前外观（候选虚线 / 已定实线）。
    var setupPreviewFrameAppearanceForDiagnostics: RecordingRegionFrame.Appearance? {
        setupPreviewFrame.currentAppearance
    }

    /// 诊断用：准备面板当前两个音频开关的状态。
    var setupPanelAudioForDiagnostics: AudioSettings {
        setupPanel.currentAudioForDiagnostics
    }

    /// 诊断用：准备面板当前选定的输出格式与档位。
    var setupPanelOutputForDiagnostics: RecordingOutputChoice {
        setupPanel.currentOutputForDiagnostics
    }

    /// 诊断用：切换输出格式，等价于用户点击分段控件。
    func setSetupPanelOutputForDiagnostics(_ output: RecordingOutputChoice) {
        switch output {
        case .movie:
            setupPanel.selectOutputForDiagnostics(false)
        case .gif(let settings):
            setupPanel.selectOutputForDiagnostics(true)
            setupPanel.setGIFSettingsForDiagnostics(settings)
        }
    }

    /// 诊断用：音频开关此刻是否可用（GIF 时应为 false）。
    var setupPanelAudioEnabledForDiagnostics: Bool {
        setupPanel.audioControlsEnabledForDiagnostics
    }

    /// 诊断用：「GIF 无声音」说明是否可见。
    var setupPanelGIFNoticeVisibleForDiagnostics: Bool {
        setupPanel.gifNoSoundNoticeVisibleForDiagnostics
    }

    /// 诊断用：面板当前高度（MP4 与 GIF 两个尺寸互不干扰）。
    var setupPanelHeightForDiagnostics: CGFloat {
        setupPanel.panelHeightForDiagnostics
    }

    /// 诊断用：面板高度相对内容高度的余量（**负数 = 底部按钮被裁掉**）。
    var setupPanelContentClearanceForDiagnostics: CGFloat {
        setupPanel.contentClearanceForDiagnostics
    }

    /// 诊断用：内容栈真实高度。
    var setupPanelContentHeightForDiagnostics: CGFloat {
        setupPanel.contentFittingHeightForDiagnostics
    }

    /// 诊断用：「开始录制」按钮是否**完整落在面板内容区里**（= 点得到）。
    var setupPanelStartButtonInsideContentForDiagnostics: Bool {
        let bounds = setupPanel.contentBoundsForDiagnostics
        let button = setupPanel.startButtonRectForDiagnostics
        return !button.isEmpty && bounds.contains(button)
    }

    /// 诊断用：按钮矩形的可读描述（断言失败时看得出被裁在哪一边）。
    var setupPanelStartButtonRectDescriptionForDiagnostics: String {
        let bounds = setupPanel.contentBoundsForDiagnostics
        let button = setupPanel.startButtonRectForDiagnostics
        return String(
            format: "button=(%.0f,%.0f,%.0f×%.0f) content=(%.0f×%.0f)",
            button.minX, button.minY, button.width, button.height,
            bounds.width, bounds.height
        )
    }

    /// 诊断用：设置准备面板选中的范围。
    func selectSetupScopeForDiagnostics(index: Int) {
        setupPanel.selectScopeForDiagnostics(index: index)
    }

    /// 诊断用：可选范围数量。
    var setupScopeOptionCountForDiagnostics: Int {
        setupPanel.scopeOptionCountForDiagnostics
    }

    /// 诊断用：预览范围框当前是否可见。
    var setupPreviewFrameIsVisibleForDiagnostics: Bool { setupPreviewFrame.isVisible }

    /// 诊断用：准备面板当前是否可见。
    var setupPanelIsVisibleForDiagnostics: Bool { setupPanel.isVisible }

    /// 诊断用：准备面板当前选中的范围**类型**。
    var setupPanelSelectedKindForDiagnostics: RecordingScopeKind? {
        setupPanel.selectedKind
    }

    /// 诊断用：准备面板当前提供的范围类型列表。
    var setupScopeOptionKindsForDiagnostics: [RecordingScopeKind] {
        setupPanel.scopeOptionKindsForDiagnostics
    }

    /// 诊断用：「开始录制」此刻是否可点。
    var setupPanelStartEnabledForDiagnostics: Bool {
        setupPanel.startEnabledForDiagnostics
    }

    /// 诊断用：状态行文案。
    var setupPanelStatusTextForDiagnostics: String {
        setupPanel.statusTextForDiagnostics
    }

    /// 诊断用：当前候选目标标题。
    var setupPanelCandidateTitleForDiagnostics: String? {
        setupPanel.candidateTitleForDiagnostics
    }

    /// 诊断用：**此刻真正会发出的**录制范围。
    ///
    /// 它不是面板里的某个字段——面板已经不再持有 `CaptureScope`。
    /// 因此这条断言测的是「按下开始后要用的那个值」，而不是「存了哪个值」。
    var setupComposedScopeForDiagnostics: CaptureScope? {
        guard let kind = setupPanel.selectedKind else { return nil }
        return composeRecordingScope(kind: kind)?.scope
    }

    /// 诊断用：**此刻真正会发出的**录制矩形（AppKit 屏幕坐标）。
    var setupComposedRectForDiagnostics: CGRect? {
        guard let kind = setupPanel.selectedKind else { return nil }
        return composeRecordingScope(kind: kind)?.screenRect
    }

    /// 诊断用：是否正在等待点选目标。
    var setupPanelIsPickingForDiagnostics: Bool {
        setupPanel.isPickingForDiagnostics
    }

    /// 诊断用：覆盖层是否处于录制准备阶段。
    var overlayIsRecordSetupActiveForDiagnostics: Bool {
        windows.first?.overlayView.isRecordSetupActiveForDiagnostics ?? false
    }

    /// 诊断用：已提交的标注数（用于证明准备阶段写入被挡住）。
    var debugAnnotationCountForDiagnostics: Int {
        editorState?.annotations.count ?? -1
    }

    /// 诊断用：编辑器状态的原始描述。
    ///
    /// **不能只看 `debugIsSelectionConfirmed`**：它在没有编辑器时返回 true
    /// （保守默认），会把「会话还没建好」误读成「用户已确认选区」——
    /// 而这两个状态下 `handleRecordRequest` 的行为完全不同。
    var debugEditorSummaryForDiagnostics: String {
        guard let editorState else { return "editor=nil" }
        return "confirmed=\(editorState.isSelectionConfirmed) annotations=\(editorState.annotations.count)"
    }

    /// 诊断用：是否存在未提交草稿。
    var debugHasDraftForDiagnostics: Bool {
        editorState?.hasDraft ?? false
    }

    /// 诊断用：第一条标注的描述。
    ///
    /// 用于断言「准备阶段的输入接管没有改动**已有编辑内容**」——
    /// 只数数量不够：一次意外的编辑可能只是改了某条标注的几何。
    var debugFirstAnnotationForDiagnostics: String {
        guard let first = editorState?.annotations.first else { return "none" }
        return String(describing: first)
    }

    /// 诊断用：撤销栈是否可用（准备阶段不应被写入历史）。
    var debugCanUndoForDiagnostics: Bool {
        editorState?.canUndo ?? false
    }

    /// 诊断用：是否正在编辑文字（输入控件仍在）。
    ///
    /// 准备阶段必须为 false：输入控件的第一响应者会拦下键盘，
    /// 那时 ESC/回车就不再归覆盖层管了。
    var debugIsTextEditingForDiagnostics: Bool {
        editorState?.isEditingText ?? false
    }

    /// 诊断用：选中某个标注工具（等价于按快捷键或点工具栏）。
    func debugSelectToolForDiagnostics(_ tool: AnnotationTool) {
        editorState?.select(tool)
    }

    /// 诊断用：系统声音开关。
    func setSystemAudioForDiagnostics(_ on: Bool) {
        setupPanel.setSystemAudioForDiagnostics(on)
    }

    /// 诊断用：截图工具栏是否已收起（准备阶段必须收起）。
    var overlayToolbarHiddenForDiagnostics: Bool {
        windows.first?.overlayView.isToolbarHiddenForDiagnostics ?? false
    }

    /// 诊断用：当前候选目标（选取中）。
    var setupPickCandidateForDiagnostics: DetectionTarget? {
        windows.first?.overlayView.recordingPickCandidateForDiagnostics
    }

    /// 诊断用：正在选取的目标类型（未在选取时为 nil）。
    var setupPickKindForDiagnostics: RecordingScopeKind? { setupPickKind }

    /// 诊断用：直接进入「重新选择」，等价于点面板上的「重新选择」按钮。
    func beginPickForDiagnostics(kind: RecordingScopeKind) {
        beginRecordingTargetPick(for: kind)
    }

    /// 诊断用：覆盖层视图正在选取的目标类型。
    var overlayPickKindForDiagnostics: RecordingScopeKind? {
        windows.first?.overlayView.recordingPickKindForDiagnostics
    }

    /// 诊断用：把识别会话换成受控实现。
    ///
    /// 选取目标的结果取决于「鼠标下恰好有哪个窗口」，真实窗口列表随桌面变化，
    /// 断言就不可复现。只换数据源，命中与交互仍是产品代码。
    func setDetectionSessionForDiagnostics(_ session: DetectionSession) {
        for window in windows {
            window.overlayView.debugSetDetectionSession(session)
        }
    }

    /// 诊断用：触发准备面板的「取消」——只收面板，不发出录制请求、不关闭覆盖层。
    func cancelRecordSetupForDiagnostics() {
        setupPreviewFrame.hide()
        setupPanel.cancelForDiagnostics()
    }

    /// 诊断用：触发准备面板的「开始录制」。
    func confirmRecordSetupForDiagnostics() {
        setupPanel.confirmForDiagnostics()
    }
    // MARK: - 滚动截图（M3-1）

    /// 诊断：滚动截图会话是否在进行。
    var isScrollshotActiveForDiagnostics: Bool { scrollshot != nil }

    /// 诊断：长截图按钮在工具栏里的中心（nil = 不存在）。
    var longScreenshotButtonCenterForDiagnostics: CGPoint? {
        windows.first?.overlayView.toolbarItemCenterForDiagnostics(.longScreenshot)
    }

    /// 诊断：走真实入口启动滚动截图（与工具栏点击进的是同一个方法）。
    @discardableResult
    func startScrollshotForDiagnostics() -> Bool {
        guard let displayID = selectionDisplayID,
              let window = windows.first(where: { $0.displayID == displayID }) ?? windows.first,
              let selection = window.overlayView.effectiveSelection else {
            return false
        }
        handleLongScreenshotRequest(selection, displayID: displayID, overlayWindow: window)
        return scrollshot != nil
    }

    /// 诊断：滚动截图选区框是否可见。
    ///
    /// 会话一开始覆盖层就被 `orderOut`（它盖住了用户要滚的窗口），
    /// 屏幕上于是不再有任何东西说明「在截哪一块」——这个断言就是那句提醒
    /// 是否真的落在了屏幕上。
    var scrollshotRegionFrameIsVisibleForDiagnostics: Bool { scrollshotRegionFrame.isVisible }

    /// 诊断：选区框的外观（核对用的是 `.scrollshot` 而不是别的状态）。
    var scrollshotRegionFrameAppearanceForDiagnostics: RecordingRegionFrame.Appearance? {
        scrollshotRegionFrame.currentAppearance
    }

    /// 诊断：选区框所在的矩形（**AppKit 屏幕坐标**）。
    var scrollshotRegionFrameRectForDiagnostics: CGRect? { scrollshotRegionFrame.currentRect }

    /// 诊断：取消滚动截图会话。
    func cancelScrollshotForDiagnostics() {
        cancelScrollshot()
    }

    /// 诊断：保存回调是否接上（历史记录的接线验证需要它）。
    var debugHasSavedHandlerForDiagnostics: Bool { onArtifact != nil }

    /// 诊断：所有标注的类型名（空格分隔），用于确认拖拽真的产生了对应类型的标注。
    var debugAnnotationSummaryForDiagnostics: String {
        guard let editorState else { return "editor=nil" }
        return editorState.annotations.map(\.kind.typeName).joined(separator: " ")
    }

    /// **最后一条**手绘笔迹的点数；没有手绘标注时为 -1。
    ///
    /// `debugAnnotationSummaryForDiagnostics` 只看类型名，而
    /// 「手绘采到了轨迹」与「手绘退化成一条直线」的类型名完全一样（都是 freehand），
    /// 只有点数能把两者分开——这正是那个缺陷当初能潜伏的原因。
    ///
    /// 取最后一条而不是第一条：后续还会再画一条用于验证「拖动中不简化」，
    /// 读最后一条才能拿到刚画的那条。
    var debugFreehandPointCountForDiagnostics: Int {
        guard let editorState else { return -1 }
        for annotation in editorState.annotations.reversed() {
            if case let .freehand(points, _) = annotation.kind {
                return points.count
            }
        }
        return -1
    }

    /// 当前**草稿**若是自由笔迹的点数；无草稿或非手绘时为 -1。
    ///
    /// 用于验证「拖动过程中草稿不被简化」：简化是全局算法，
    /// 边拖边简化会让已经画出的轨迹反复变形（用户看到的就是「笔迹在抖」）。
    var debugDraftFreehandPointCountForDiagnostics: Int {
        guard let draft = editorState?.draft,
              case let .freehand(points, _) = draft.kind else { return -1 }
        return points.count
    }

}

#endif
