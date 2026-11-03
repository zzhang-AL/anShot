//
//  OverlayWindow.swift
//  AnShotUI
//
//  冻结式覆盖层：每块显示器一个非激活 `NSPanel` + 一个绘制底图的 `NSView`（P3）、
//  以及该视图上的选区交互与装饰（P4）。
//
//  ── 窗口配置的依据 ────────────────────────────────────────────
//
//  1. `.nonactivatingPanel` **必须在 init 的 styleMask 中传入**。
//     事后修改 `styleMask` 不会完整更新激活行为——这是已知陷阱，
//     故本类型不提供修改 styleMask 的接口。
//
//  2. `level = .screenSaver`：需要盖住菜单栏（`.mainMenu`）与
//     全屏应用的窗口层级（`.fullScreen`）。`.screenSaver` 高于二者。
//
//  3. `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`：
//     - `.canJoinAllSpaces`：在所有桌面空间可见，切换 Space 不消失
//     - `.fullScreenAuxiliary`：**关键**——允许窗口浮在全屏应用之上
//     - `.stationary`：不随 Exposé 等空间变换移动
//
//  4. `canBecomeKey` 重写为 true：`.borderless` 窗口默认不能成为
//     key window，而 ESC 取消需要键盘事件。配合 `.nonactivatingPanel`，
//     成为 key window **不会**激活本应用。
//
//  ── 鼠标事件的依据 ────────────────────────────────────────────
//
//  直接重写 `NSView` 的鼠标方法，**不用** `NSEvent.addGlobalMonitorForEvents`。
//  NSEvent.h 原文明确：「your handler will not be called for events that are
//  sent to your own application」——全局监视器收不到发给自己的事件，
//  对覆盖层无效。而键盘事件还额外需要辅助功能权限。
//
//  ── 坐标约定（P4 关键）────────────────────────────────────────
//
//  视图使用左上原点（`isFlipped = true`），与 `AnShotCore` 的底图像素坐标同向。
//  因此「逻辑点 → 像素」是**纯缩放**，不含翻转；换算统一走
//  `CoordinateConversion`（`AnShotCore`，唯一跨边界通道）。
//
//  ── 视觉方向 ─────────────────────────────────────────────────
//
//  「清晰而克制」：选区框是全屏视觉焦点，装饰性控件不得抢走它。
//  - 边框是圆角双层描边（调色板/线宽/圆角统一在 `CaptureFrameStyle`），
//    不是 1 个 backing pixel 的 hairline
//  - 调整控件是四角圆角括号 + 四个中点胶囊，不是八个圆球形手柄
//  - 框选过程中不显示调整控件（那时用户在调范围，控件只是噪音）
//  - 强调色只用于悬停或正在操作的控件
//

import AppKit
import AnShotCapture
import AnShotCore
import CoreText

private let logger = AnShotLog.overlay
// MARK: - 覆盖层视图

/// 绘制底图与遮罩、处理选区交互、接收键盘事件。
///
/// 使用**左上原点**（`isFlipped = true`）以与 `CaptureScope` 的区域坐标约定一致，
/// 使 P4 的选区换算是纯缩放而非「缩放 + 翻转」。
/// 导出动作。
enum ExportAction {
    /// 拷贝到系统剪贴板。
    case copy
    /// 存为 PNG 文件。
    case save
    /// 钉在屏幕上（固定截图）。
    case pin
}

final class OverlayView: NSView {

    /// 本视图所属显示器的标识，用于日志与坐标换算。
    let displayID: CGDirectDisplayID

    /// 底图像素 ÷ 显示器逻辑点。会话期间不变，由 `DisplayGeometry` 提供。
    let scaleFactor: CGFloat

    /// 会话底图。会话结束即随窗口释放，不进入任何缓存。
    ///
    /// 必须用 `didSet` 触发重绘：
    /// 窗口创建后到绑定底图之间存在主 actor 挂起（等待并行抓取完成），
    /// 期间 AppKit 会先绘制一次空视图；若此处不标记脏区，
    /// 绑定底图后视图不再重绘，屏幕上会一直停留那次空绘制（表现为全黑）。
    var backdrop: CGImage? {
        didSet { needsDisplay = true }
    }

    /// 标注编辑器的权威状态（由 `OverlayController` 注入，视图只读）。
    ///
    /// 视图不自己保存编辑数据：已提交标注、草稿、历史都在编辑器里。
    /// 状态变化后由控制器刷新窗口，因此这里不需要订阅回调。
    weak var editorState: AnnotationEditorState?

    /// 待渲染的标注 = 已提交 + 未提交草稿。
    ///
    /// 草稿也参与渲染，用户才能看到正在拖拽的形状；
    /// 但它不进撤销历史（见 `AnnotationEditorState`）。
    private var displayedAnnotations: [Annotation] {
        guard let editorState else { return [] }
        var list = editorState.annotations
        if let draft = editorState.draft {
            list.append(draft)
        }
        return list
    }

    /// 最近一次合成的选区图像及其输入。
    ///
    /// 合成需要读回像素（马赛克），代价远高于矢量绘制，
    /// 而光标悬停、手柄强调色这类装饰性重绘并不改变输入，
    /// 因此缓存最近一次结果，输入未变时直接复用。
    private var composedCache: (selection: CGRect, annotations: [Annotation], image: CGImage)?

    /// 是否显示工具栏上的「录制 / 长截图 / OCR」三个抓屏动作。
    ///
    /// 默认 true（屏幕截图会话）。图片编辑时由控制器设为 false：
    /// 底图来自磁盘，这三个动作无从执行；工具栏因此收窄。
    var allowsCaptureActions = true {
        didSet {
            guard allowsCaptureActions != oldValue else { return }
            refreshToolbar()
        }
    }

    /// 遮罩不透明度。选区内不压暗，选区外压暗。
    var dimAlpha: CGFloat = 0.45 {
        didSet { needsDisplay = true }
    }

    /// 当前选区（视图坐标 = 显示器逻辑点，左上原点）。`nil` 表示尚未框选。
    private(set) var selectionRect: CGRect? {
        didSet {
            needsDisplay = true
            refreshToolbar()
        }
    }

    /// 自动识别会话（由控制器在会话开始时注入）。
    var detectionSession: DetectionSession?

    /// 最近一次识别命中的目标；无命中时为 nil。
    private(set) var currentDetectionTarget: DetectionTarget?

    /// 当前识别身份的生产访问口。
    ///
    /// 直达录制与历史来源需要它；它与诊断用的
    /// `detectionTargetForDiagnostics` 分开，后者被 `#if DEBUG` 包住，
    /// 生产代码若直接引用会让 Release 构建失败（实测）。
    var detectionTargetForIntent: DetectionTarget? { currentDetectionTarget }

    /// 供诊断读取识别会话。
    var detectionSessionForDiagnostics: DetectionSession? { detectionSession }

    /// 诊断用：临时停用自动识别。
    ///
    /// 测工具栏一类的用例必须关掉它——识别会随鼠标移动改变选区，
    /// 而工具栏跟随选区移动，先前读到的按钮坐标随即失效，
    /// 表现为「点击点位存在但没点中」的假失败。
    var isDetectionPausedForDiagnostics = false

    /// 候选态按下时捕获的候选快照（选区 + 识别身份）。
    ///
    /// 用途有二：单击时确认它；越过阈值却没拖够尺寸时把它放回去。
    /// 必须在转成 `.creating` **之前**留底——那一步会把 `selectionRect`
    /// 换成新矩形，候选就找不回来了。
    private var pendingCandidate: (rect: CGRect, target: DetectionTarget?)?

    /// 本次手势是否真的改动了选区几何（新建 / 移动 / 缩放）。
    ///
    /// `mouseUp` 只有在几何变化后才该把识别身份清掉：在已确认选区内部
    /// 单纯单击（按下到松开没有位移）仍然是同一个窗口/应用，身份必须保留，
    /// 否则用户「单击确认后再选录制窗口」会发现目标已经丢了。
    private var selectionGestureChangedGeometry = false

    /// 候选上的按下要移动多远才算「拖拽」而非「单击」（逻辑点）。
    ///
    /// 4pt 是手抖与真拖之间的分界：太小会把单击误判成框选，
    /// 太大则用户拖了一小段却什么都没发生。
    private let pendingDragThreshold: CGFloat = 4

    /// 指针工具点击标注的命中容差（逻辑点）。
    ///
    /// 与 `pendingDragThreshold` 取同一个量级：用户点细线时手抖 2~3pt 是常态，
    /// 容差太小会让「明明点在线上」变成点空、顺带清掉选中。
    private static let annotationHitTolerance: CGFloat = 4

    /// 当前选区是否已被用户确认（而非自动识别给出的候选）。
    ///
    /// 权威在 `AnnotationEditorState`（会话级），这里只是取用：
    /// 多显示器时每屏一个视图，各存一份会让用户在 A 屏确认后
    /// B 屏仍冒出识别候选。
    ///
    /// 无编辑器时按已确认处理：那是诊断直接构造视图的情形，
    /// 不存在自动识别，也就不存在候选。
    private var isSelectionConfirmed: Bool {
        editorState?.isSelectionConfirmed ?? true
    }

    /// 当前识别结果的描述，供界面提示。
    private(set) var detectionTitle: String?
    private(set) var detectionLayerName: String?

    /// 上一条已记录的识别结果，用于给日志去重。
    private var lastDetectionDescription: String?

    /// 取消回调（无选区时按 ESC，或右键）。
    var onCancel: (() -> Void)?

    /// 识别结果所属显示器。
    ///
    /// 程序化更新选区时必须一并告知归属：`selectionDisplayID` 原本只由用户
    /// 手势设置，而识别的选区来自代码路径。缺了这一步，视图层的选区
    /// 永远同步不上（表现为「识别算对了但框没动」）。
    var onDetectedDisplayID: ((CGDirectDisplayID) -> Void)?

    /// 请求把合成结果交给会话层处理（拷贝到剪贴板 / 存盘）。
    ///
    /// 由视图负责合成、控制器负责收尾：合成的输入（底图、选区、标注）
    /// 都在视图手里，而「拷贝完就结束会话」属于会话决定。
    var onExport: ((CGImage, ExportAction) -> Void)?

    /// 请求以当前选区开始录制。参数为选区（逻辑点）；无选区时为 nil（表示整屏）。
    /// 请求录制。参数为当前选区（nil 表示无选区，语义是「录整屏」）
    /// 与**当前识别到的目标**（含 windowID/processID，供选择窗口/应用范围）。
    var onRecord: ((CGRect?, DetectionTarget?) -> Void)?

    /// 以当前选区开始滚动截图（长截图）。
    var onLongScreenshot: ((CGRect?) -> Void)?

    /// 识别当前选区里的文字（OCR）。
    var onRecognizeText: ((CGRect?) -> Void)?

    /// 录制目标选取过程中，鼠标下的候选目标；nil 表示指针不在有效目标上。
    var onRecordingPickHover: ((DetectionTarget?) -> Void)?
    /// 用户单击锁定了录制目标。
    var onRecordingPickCommit: ((DetectionTarget) -> Void)?
    /// 用户按 ESC 放弃了选取。
    var onRecordingPickCancel: (() -> Void)?

    /// 「直达动作」会话：录制 / 长截图 / OCR 由全局热键直接进入。
    ///
    /// 这类会话不显示标注工具栏：用户按热键的意图已经明确是「选完就执行」，
    /// 再摆一排需要二次点击的按钮只会把三步变成四步。选区确定后由控制器
    /// 直接触发对应动作；取消（ESC）则回到普通截图会话。
    var hidesToolbarForIntent = false {
        didSet {
            guard hidesToolbarForIntent != oldValue else { return }
            refreshToolbar()
        }
    }

    /// 是否处于录制准备阶段（准备面板已弹出）。
    ///
    /// 准备阶段整个会话的输入都归面板：截图识别、框选、标注、工具快捷键一律暂停。
    ///
    /// **只拦「选取目标」是不够的：**面板里的「区域」范围与预览框是打开面板那一刻
    /// 的矩形，用户若还能拖动截图选区，两边会当场不一致；锁定目标后按回车又会把
    /// 整个截图会话导出掉。因此"准备中"是一个覆盖到开始/取消/会话结束的独立状态。
    var isRecordSetupActive = false {
        didSet {
            guard isRecordSetupActive != oldValue else { return }
            // 开始编辑中的文字先落定：面板一开就没法再碰输入框了，
            // 留在编辑器里的草稿会成为一个看得到却碰不着的东西。
            if isRecordSetupActive, editorState?.isEditingText == true {
                commitTextEditing()
            }
            // 工具栏是本视图的子视图，它自己就能接到鼠标事件——
            // 只在 `mouseDown` 里拦是拦不住的。
            refreshToolbar()
        }
    }

    /// 准备阶段按 ESC（且不在选取目标时）：取消整个准备。
    var onRecordSetupCancel: (() -> Void)?
    /// 准备阶段按回车：交由面板按其「可开始」状态决定，
    /// 视图不自行判断——可用性只有面板知道。
    var onRecordSetupConfirm: (() -> Void)?

    /// 正在进行的录制目标选取（窗口 / 应用）。
    ///
    /// 选取期间本视图的鼠标与键盘只服务于「选一个目标」：
    /// 不能改截图选区（用户正拿它当录制区域）、不能落到标注里、
    /// 也不能让回车把整个会话导出掉。状态与判定见 `RecordingTargetPick`。
    private var recordingPick = RecordingTargetPick()

    /// 选区变化回调（拖拽与调整过程中持续触发）。参数为逻辑点坐标。
    var onSelectionChanged: ((CGRect?) -> Void)?

    /// 选区确定回调（松开鼠标且尺寸有效）。参数为逻辑点坐标。
    var onSelectionCommitted: ((CGRect) -> Void)?

    /// 撤销 / 重做请求。
    ///
    /// 有回调时由控制器执行：撤销恢复的选区可能属于另一块显示器，
    /// 只有控制器知道每个历史快照的归属，视图自己调 `editorState.undo()`
    /// 就绕过了这次「把选区放回原屏」的机会。
    /// 没有回调时（诊断直接构造视图）退回直接驱动编辑器。
    var onUndoRequested: (() -> Void)?
    var onRedoRequested: (() -> Void)?

    // MARK: - 交互状态

    /// 鼠标交互状态。
    private enum Interaction {
        case idle
        /// 候选选区上的按下：还没决定这次是「单击确认」还是「拖拽重框」。
        ///
        /// 按下瞬间无法区分两者，而后果相差很大（确认 vs 丢掉候选重画），
        /// 因此先进这个状态，由 `mouseDragged` 的位移阈值裁决。
        case pending(anchor: CGPoint)
        /// 从 `anchor` 开始新建选区。
        case creating(anchor: CGPoint)
        /// 拖动选区内部移动。`grabOffset` 是按下点相对选区原点的偏移，
        /// 保存它可避免选区在按下瞬间跳到光标位置。
        case moving(grabOffset: CGPoint)
        /// 拖动某个手柄缩放。
        case resizing(handle: SelectionHandle)
        /// 拖动选中的标注（指针工具）。
        ///
        /// 存的是上一次换算出的**底图像素**位置，而不是按下点：
        /// 移动量按相邻两次像素位置之差累积，拖动过程中视图缩放或
        /// 取整误差都不会把标注推偏。
        case movingAnnotation(lastPixel: PixelPoint)
    }

    private var interaction: Interaction = .idle {
        // 活动手柄需要重绘才能显示强调色
        didSet { needsDisplay = true }
    }

    /// 正在被拖动的手柄（无则为 nil）。
    private var activeHandle: SelectionHandle? {
        if case .resizing(let handle) = interaction { return handle }
        return nil
    }

    /// 指针当前悬停的手柄。仅用于强调色，不参与命中判定。
    private var hoveredHandle: SelectionHandle? {
        didSet {
            if hoveredHandle != oldValue { needsDisplay = true }
        }
    }

    /// 是否正在新建选区（框选过程中不显示调整控件）。
    /// 是否正在进行选区手势。
    ///
    /// 撤销/重做会把模型里的选区同步回视图，而拖动过程中视图自己维护临时值；
    /// 外部同步必须跳过进行中的手势，否则会把用户正在拖的框拽回去。
    /// 当前是否有有效选区（供诊断判断状态，不参与业务逻辑）。
    var hasSelection: Bool { effectiveSelection != nil }

    var isInteracting: Bool {
        if case .idle = interaction { return false }
        return true
    }

    private var isCreating: Bool {
        if case .creating = interaction { return true }
        return false
    }

    // MARK: - 装饰尺寸

    /// 选区装饰的尺寸与阈值（角括号、抓手、命中半径、标签、阈值）。
    private let decoration = SelectionDecoration.standard

    /// 绘制次数。仅在底图为 nil 时用于诊断。
    private var drawCount = 0

    init(frame: NSRect, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.scaleFactor = DisplayGeometry.scaleFactor(for: displayID)
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OverlayView 仅支持代码创建")
    }

    /// 左上原点。与 `CaptureScope` 的区域坐标（左上原点、显示器逻辑点）保持一致。
    override var isFlipped: Bool { true }

    /// 表示本视图可以成为第一响应者，从而接收 ESC。
    override var acceptsFirstResponder: Bool { true }

    // MARK: - 选区控制

    /// 清空选区（会话开始或取消时调用）。
    ///
    /// - Parameter notifying: 是否回调 `onSelectionChanged(nil)`。控制器在
    ///   同步「选区只属于某一块屏」时会静默重置其它屏：那些屏上的框只是
    ///   过期渲染，不是用户清空了选区；若照常回调，控制器会把刚刚提交的
    ///   选区当成一次新的「清空」再提交回去，造成递归与误清空。
    func resetSelection(notifying: Bool = true) {
        selectionRect = nil
        interaction = .idle
        hoveredHandle = nil
        pendingCandidate = nil
        selectionGestureChangedGeometry = false
        currentDetectionTarget = nil
        if notifying {
            onSelectionChanged?(nil)
        }
    }

    /// 以编程方式设置选区（诊断与后续阶段的程序化构造使用）。
    func setSelection(_ rect: CGRect?) {
        guard let rect else {
            resetSelection()
            return
        }
        selectionRect = SelectionGeometry.clamp(rect, to: bounds)
        onSelectionChanged?(effectiveSelection)
    }

    /// 选区的像素尺寸，用于显示与导出。
    var selectionPixelSize: PixelSize? {
        guard let selection = effectiveSelection else { return nil }
        return CoordinateConversion.pixelRect(fromLogical: selection, scaleFactor: scaleFactor).size
    }

    /// 只在尺寸有效时才返回的选区。
    ///
    /// 拖拽起始瞬间是一个零尺寸矩形，此时不应绘制装饰，
    /// 也不应作为有效选区上报。
    /// 不是 private：诊断扩展在另一文件读取（滚动截图入口验证）。
    var effectiveSelection: CGRect? {
        guard let rect = selectionRect, rect.width >= 1, rect.height >= 1 else { return nil }
        return rect
    }

    // MARK: - 手柄布局

    /// 命中测试（与 `handleItems` 同一份布局）。
    private func handle(at point: CGPoint, in selection: CGRect) -> SelectionHandle? {
        let items = SelectionHandleLayout.items(
            for: selection,
            viewBounds: bounds,
            displayID: displayID,
            decoration: decoration,
            activeHandle: activeHandle
        )
        return SelectionHandleLayout.hit(at: point, in: items)
    }

    #if DEBUG
    /// 诊断：某点会命中哪个手柄。
    ///
    /// 用于验证「可见即可点、不可见即点不到」——
    /// 绘制与命中分家正是本次修订要修掉的缺陷。
    func debugHandleName(at point: CGPoint) -> String? {
        guard let selection = effectiveSelection else { return nil }
        return handle(at: point, in: selection)?.rawValue
    }

    /// 诊断：强制标记悬停中的手柄，用于渲染审查高亮配色。
    ///
    /// 直接写状态而不合成 `mouseMoved`：事件路径
    /// （`mouseMoved` → `updateCursor` → `hoveredHandle`）本次未改动，
    /// 需要核对的只是「高亮色画出来会不会与边框同色」这一件事。
    func debugSetHoveredHandle(_ handle: SelectionHandle?) {
        hoveredHandle = handle
    }

    #if DEBUG
    /// 诊断：注入一个受控的识别会话。
    ///
    /// 选取目标的结果取决于「鼠标下恰好有哪个窗口」，真实窗口列表随桌面变化，
    /// 断言就不可复现。替换数据源之后，命中、悬停、单击、锁定身份
    /// 仍是产品代码路径。
    func debugSetDetectionSession(_ session: DetectionSession?) {
        detectionSession = session
    }

    /// 诊断：当前正在选取的范围类型。
    var recordingPickKindForDiagnostics: RecordingScopeKind? { recordingPick.kind }

    /// 诊断：当前候选目标。
    var recordingPickCandidateForDiagnostics: DetectionTarget? { recordingPick.candidate }

    /// 诊断：是否处于录制准备阶段。
    var isRecordSetupActiveForDiagnostics: Bool { isRecordSetupActive }

    /// 诊断：截图工具栏是否被收起（准备阶段必须收起——它是子视图，
    /// 自己就能接到点击）。
    var isToolbarHiddenForDiagnostics: Bool { toolbar.isHidden }
    #endif

    /// 诊断：把给定目标当作一次自动识别命中，走真实的候选应用路径。
    ///
    /// 不直接写 `selectionRect`：那样会绕过身份记录与编辑器同步，
    /// 于是「候选态上拖拽究竟是重框还是平移」就验证不到了——
    /// 而那正是本次要验证的东西。
    func debugApplyDetectionTarget(_ target: DetectionTarget) {
        applyDetectionTarget(target)
    }

    /// 诊断：当前选区对应的识别身份（手动框出的选区应为 nil）。
    var detectionTargetForDiagnostics: DetectionTarget? { currentDetectionTarget }

    /// 诊断：视图层的选区（逻辑点）。
    ///
    /// 需要它是因为 `controller.selection` 是**控制器**的状态，
    /// 两者可能因同步条件而短暂不一致——排查时必须能分开看。
    var selectionRectForDiagnostics: CGRect? { selectionRect }

    /// 诊断：待裁决的候选是否已捕获。
    var hasPendingCandidateForDiagnostics: Bool { pendingCandidate != nil }

    /// 诊断：交互状态名。
    var interactionForDiagnostics: String {
        switch interaction {
        case .idle: return "idle"
        case .pending: return "pending"
        case .creating: return "creating"
        case .moving: return "moving"
        case .movingAnnotation: return "movingAnnotation"
        case .resizing: return "resizing"
        }
    }

    /// 诊断：此刻识别是否被允许生效。
    ///
    /// 读的是**守卫本身**而不是某个布尔量：三个条件共同决定它，
    /// 分开读单项无法证明守卫真的挡住了识别。
    var isDetectionAllowedForDiagnostics: Bool { isDetectionAllowed }
    /// 诊断：工具栏某个条目的中心点（不存在时为 nil）。
    func toolbarItemCenterForDiagnostics(_ kind: AnnotationToolbarLayout.Kind) -> CGPoint? {
        toolbar.itemCenter(kind)
    }

    /// 诊断：文字输入控件的状态；不存在时为 "none"。
    ///
    /// 为什么必须连可编辑性一起断言：输入框「存在且已聚焦」并不代表能打字
    /// ——换 cell 会丢掉 `NSTextField` 默认给出的可编辑性，而现象是
    /// 「输入框一切正常、光标也在闪，就是一个字也打不进去」。
    /// 只断言「输入框存在」的测试会安安稳稳地放过这个缺陷。
    func textEditorStateForDiagnostics() -> String {
        guard let field = textEditorHost.field else { return "none" }
        return "editable=\(field.isEditable),selectable=\(field.isSelectable),"
            + "editing=\(field.currentEditor() != nil)"
    }

    /// 诊断：工具栏当前所有可见条目的身份。
    func toolbarVisibleItemKindsForDiagnostics() -> Set<AnnotationToolbarLayout.Kind> {
        Set(toolbar.visibleItemCenters().keys)
    }

    #endif

    // MARK: - 标注工具栏

    /// 跟随选区的标注工具栏。
    ///
    /// 工具栏只显示状态并向上抛回调，编辑数据全部在 `editorState` 里。
    private lazy var toolbar: AnnotationToolbarView = {
        let view = AnnotationToolbarView()
        view.isHidden = true
        view.onSelectTool = { [weak self] tool in
            self?.editorState?.select(tool)
        }
        view.onSelectColor = { [weak self] color in
            self?.applyToolbarColor(color)
        }
        view.onSelectLineWidth = { [weak self] width in
            self?.applyToolbarLineWidth(width)
        }
        view.onSelectFontSize = { [weak self] size in
            self?.applyToolbarFontSize(size)
        }
        view.onSelectMosaicMode = { [weak self] mode in
            self?.editorState?.selectMosaicMode(mode)
        }
        view.onSelectMosaicBlockSize = { [weak self] size in
            self?.editorState?.selectMosaicBlockSize(size)
        }
        view.onSelectMosaicBrushDiameter = { [weak self] diameter in
            self?.editorState?.selectMosaicBrushDiameter(diameter)
        }
        view.onOpenColorPanel = { [weak self] in
            self?.presentColorPanel()
        }
        view.onUndo = { [weak self] in
            guard let self else { return }
            if let handler = self.onUndoRequested {
                handler()
            } else {
                self.editorState?.undo()
            }
        }
        view.onRedo = { [weak self] in
            guard let self else { return }
            if let handler = self.onRedoRequested {
                handler()
            } else {
                self.editorState?.redo()
            }
        }
        view.onLongScreenshot = { [weak self] in
            self?.onLongScreenshot?(self?.effectiveSelection)
        }
        view.onRecognizeText = { [weak self] in
            self?.onRecognizeText?(self?.effectiveSelection)
        }
        view.onSelectNumberingRadius = { [weak self] radius in
            self?.editorState?.selectNumberingRadius(radius)
        }
        view.onSelectMagnifierZoom = { [weak self] zoom in
            self?.editorState?.selectMagnifierZoom(zoom)
        }
        view.onSelectCurvedArrowBend = { [weak self] bend in
            self?.editorState?.selectCurvedArrowBend(bend)
        }
        view.onSelectArrowHeadScale = { [weak self] scale in
            self?.editorState?.selectArrowHeadScale(scale)
        }
        // Pin 走与「拷贝/保存」同一条合成路径：钉住的必须是**用户当前所见**
        //（含标注），而不是原始底图。
        view.onPin = { [weak self] in
            self?.performExport(.pin)
        }
        view.onRecord = { [weak self] in
            guard let self else { return }
            // 录制不做导出：把当前选区与识别目标一起交出去，由上层换算成 CaptureScope。
            // 目标要在这里一并交出——准备面板要据此提供「窗口/应用」范围选项，
            // 而识别结果是随鼠标移动变化的，事后再查已经不是用户点按钮时的那一个。
            self.onRecord?(self.effectiveSelection, self.currentDetectionTarget)
        }
        view.onCopy = { [weak self] in
            self?.performExport(.copy)
        }
        view.onSave = { [weak self] in
            self?.performExport(.save)
        }
        // 删除按钮与键盘上的 Delete 走同一个收口（`deleteSelected`）：
        // 它同时清掉选中、记一步历史并通知控制器刷新。
        view.onDeleteSelected = { [weak self] in
            self?.editorState?.deleteSelected()
        }
        return view
    }()

    /// 按当前选区重新摆放工具栏，并同步它显示的状态。
    ///
    /// 工具栏只在「有选区」时出现：没有选区就没有可标注的目标。
    func refreshToolbar() {
        // 准备阶段收起工具栏：它是本视图的子视图，自己就能接到点击，
        // 父视图的 `mouseDown` 守卫拦不住「点到了按钮」这件事。
        if isRecordSetupActive || hidesToolbarForIntent {
            toolbar.isHidden = true
            return
        }
        guard let editorState, let selection = effectiveSelection, backdrop != nil else {
            toolbar.isHidden = true
            return
        }

        if toolbar.superview == nil {
            addSubview(toolbar)
        }

        toolbar.tool = editorState.tool
        // 候选态不让任何工具显示为「选中」：此刻会话的真实状态是
        // 「还在确定选区」，把指针画成选中会让用户以为现在是移动模式
        // ——这正是用户反馈的困惑来源。
        toolbar.showsToolSelection = editorState.isSelectionConfirmed
        toolbar.style = editorState.style
        toolbar.canUndo = editorState.canUndo
        toolbar.canRedo = editorState.canRedo
        toolbar.allowsCaptureActions = allowsCaptureActions
        toolbar.hasSelectedAnnotation = editorState.hasSelectedAnnotation
        toolbar.selectedAnnotationIsText = selectedAnnotationIsText
        let capabilities = selectedAnnotationStyleCapabilities
        toolbar.selectedAnnotationSupportsColor = capabilities.color
        toolbar.selectedAnnotationSupportsLineWidth = capabilities.lineWidth
        toolbar.isHidden = false

        // 输入中的文字也要跟随面板设置：改字号/颜色后，
        // 输入控件里的字必须立刻变，否则「看到的」与「提交的」不一致。
        syncTextEditor()

        let size = toolbar.toolbarSize
        let gap: CGFloat = 8
        // 三级避让（含为尺寸标签留位）在 `AnnotationToolbarLayout.toolbarOrigin`。
        let origin = AnnotationToolbarLayout.toolbarOrigin(
            selection: selection,
            toolbarSize: size,
            labelReserve: decoration.labelHeight + gap,
            viewBounds: bounds,
            gap: gap
        )
        toolbar.frame = CGRect(origin: origin, size: size)
    }

    /// 选中的标注是否是文字（面板据此显示字号档位）。
    private var selectedAnnotationIsText: Bool {
        guard let kind = editorState?.selectedAnnotation?.kind else { return false }
        if case .text = kind { return true }
        return false
    }

    /// 选中的标注有哪些可改的样式槽。
    ///
    /// 面板只摆**真的会生效**的控件：高亮没有线宽，马赛克既没有颜色也没有线宽
    ///（它是像素处理，改样式无从体现）。否则用户会点到一个个「没反应」的滑块。
    private var selectedAnnotationStyleCapabilities: (color: Bool, lineWidth: Bool) {
        guard let kind = editorState?.selectedAnnotation?.kind else {
            return (color: false, lineWidth: false)
        }
        switch kind {
        case .mosaic, .mosaicStroke:
            return (color: false, lineWidth: false)
        case .highlight, .text:
            // 高亮只有填充色；文字的颜色可改，粗细由字号表达。
            return (color: true, lineWidth: false)
        default:
            return (color: true, lineWidth: true)
        }
    }

    // MARK: - 选中标注的样式

    /// 工具栏取色。
    ///
    /// 指针 + 选中时改的是**那一条标注**（`updateSelectedColor`），
    /// 同时同步样式槽，让面板色卡的选中态与读数仍取自 `style`；
    /// 其余工具保持原行为：只改「下一笔用什么颜色」。
    private func applyToolbarColor(_ color: RGBAColor) {
        guard let editorState else { return }
        if editorState.tool == .pointer, editorState.hasSelectedAnnotation {
            editorState.updateSelectedColor(color)
            editorState.selectColor(color)
        } else {
            editorState.selectColor(color)
        }
    }

    /// 工具栏线宽（滑块）。语义同 `applyToolbarColor`。
    ///
    /// 先走 `selectLineWidth` 拿到量化后的值，再把它写到选中标注上：
    /// 滑块的显示读数与标注的实际线宽因此严格一致（量化只在状态层有一处）。
    private func applyToolbarLineWidth(_ width: Double) {
        guard let editorState else { return }
        if editorState.tool == .pointer, editorState.hasSelectedAnnotation {
            editorState.selectLineWidth(width)
            editorState.updateSelectedLineWidth(editorState.style.shapeLineWidth)
        } else {
            editorState.selectLineWidth(width)
        }
    }

    /// 工具栏字号（仅选中文字时出现）。语义同 `applyToolbarColor`。
    private func applyToolbarFontSize(_ size: Double) {
        guard let editorState else { return }
        if editorState.tool == .pointer, editorState.hasSelectedAnnotation {
            editorState.updateSelectedFontSize(size)
            editorState.selectFontSize(size)
        } else {
            editorState.selectFontSize(size)
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        guard let context = NSGraphicsContext.current?.cgContext else {
            logger.error("OverlayView.draw #\(self.drawCount, privacy: .public): no CGContext; aborting")
            return
        }
        // 正常路径不记日志（绘制会频繁发生）。
        // 但底图为 nil 时必须留痕：那意味着该屏显示为纯黑，是用户可感知的故障。
        if backdrop == nil {
            logger.error("OverlayView.draw #\(self.drawCount, privacy: .public): backdrop is nil; display=\(self.displayID, privacy: .public) will show black")
        }

        drawBackdrop(in: context)
        drawAnnotations(in: context)
        drawMask(in: context)
        drawAnnotationSelection(in: context)
        drawSelection(in: context)
        drawDraftOutline(in: context)
    }

    /// 正在拖拽的标注草稿的辅助轮廓。
    ///
    /// 只有马赛克框选需要它：马赛克的效果是**像素化**，在低对比、大面积纯色
    /// 或不重复的纹理里，拖拽时画面几乎没有变化，用户根本判断不出
    /// 「这一块框到哪了」。其余形状（矩形/直线/箭头）本身就有可见的描边，
    /// 再加一层反而是噪声。
    ///
    /// 轮廓**只在草稿期间**画，也不进入合成位图：它是编辑期的辅助提示，
    /// 不该出现在导出的图里。所以这里直接画在视图坐标系上，
    /// 而不是塞进 `AnnotationRenderer` 的模型（那样会改变持久化格式，
    /// 也会把提示线一起导出）。
    private func drawDraftOutline(in context: CGContext) {
        guard let editorState,
              let draft = editorState.draft,
              let viewRect = Self.draftOutlineRect(for: draft, scaleFactor: scaleFactor),
              viewRect.width >= 1, viewRect.height >= 1 else { return }

        // 虚线：与选区那条实线边框区分开，读得出「这是临时的待确认区域」。
        // 白色 + 自动对比层（`strokePath` 自带），在明暗两种底上都看得见。
        CaptureFrameStyle.strokePath(
            CGPath(rect: viewRect, transform: nil),
            color: RGBAColor(r: 1, g: 1, b: 1, a: 0.95),
            lineWidth: 1,
            dash: [4, 3],
            in: context
        )
    }

    /// 某个草稿标注需要画的辅助轮廓矩形（**视图逻辑点**）；不需要时为 nil。
    ///
    /// 抽成静态函数是为了让诊断能直接断言「哪种草稿该有轮廓、换算落在哪」，
    /// 而不必真开一个覆盖层窗口——那会要求屏幕录制权限，
    /// 而命令行启动的进程拿不到它（已有断言就是因此长期假失败）。
    static func draftOutlineRect(
        for annotation: Annotation,
        scaleFactor: CGFloat
    ) -> CGRect? {
        guard case let .mosaic(rect, _, _) = annotation.kind, scaleFactor > 0 else {
            return nil
        }
        // 模型坐标是底图像素，视图坐标是逻辑点。
        return CGRect(
            x: CGFloat(rect.origin.x) / scaleFactor,
            y: CGFloat(rect.origin.y) / scaleFactor,
            width: CGFloat(rect.size.width) / scaleFactor,
            height: CGFloat(rect.size.height) / scaleFactor
        )
    }

    /// 绘制标注。
    ///
    /// 必须夹在底图与遮罩之间：遮罩会把选区外压暗，
    /// 因此选区外的标注随之变暗，而选区内的保持原亮度。
    ///
    /// 实现上不以屏幕上下文直接画标注，而是先用 `AnnotationRenderer.render`
    /// 合成一幅**原生像素分辨率的选区位图**再画上去。原因：
    /// 马赛克要直接读写 `context.data` 才能拿到已知的 BGRA 存储，
    /// 而 AppKit 的屏幕上下文不提供这个前提。
    /// 这样显示与导出走的是同一个 `render`（`model.md` §7.2），
    /// 屏幕上看到的标注必然与导出图一致。
    private func drawAnnotations(in context: CGContext) {
        let displayed = displayedAnnotations
        guard let backdrop, let selection = effectiveSelection,
              !displayed.isEmpty, bounds.width > 0 else {
            return
        }

        // 视图坐标是逻辑点，模型坐标是底图像素（= 逻辑点 × scaleFactor）。
        let scale = CGFloat(backdrop.width) / bounds.width
        guard scale > 0 else {
            return
        }
        let image: CGImage
        if let cache = composedCache,
           cache.selection == selection,
           cache.annotations == displayed {
            // 光标本类装饰性重绘不会改变输入，直接复用上次合成结果。
            image = cache.image
        } else {
            guard let pixelSelection = pixelSelection(from: selection),
                  let composed = AnnotationRenderer.render(
                      backdrop: backdrop,
                      selection: pixelSelection,
                      annotations: displayed
                  ) else {
                return
            }

            composedCache = (selection, displayed, composed)
            image = composed
        }

        // 视图是左上原点，CGImage 绘制以左下原点为准，因此翻回来再画。
        // 目标矩形就是选区本身（不缩到 bounds，因为只画选区那一块）。
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(
                x: selection.minX,
                y: bounds.height - selection.maxY,
                width: selection.width,
                height: selection.height
            )
        )
        context.restoreGState()
    }

    /// 选中标注的虚线高亮框。
    ///
    /// 只画在本视图上，**不进入合成**：导出的像素只来自 `AnnotationRenderer`
    /// 与底图，这条辅助线永远不会出现在成图里（与选区手柄同理）。
    /// 几何取 `hitBoundingRect` 而不是 `boundingRect`——后者的文字盒是零尺寸，
    /// 那样选中文字时看不到任何框。
    private func drawAnnotationSelection(in context: CGContext) {
        guard let annotation = editorState?.selectedAnnotation else { return }
        guard backdrop != nil, bounds.width > 0 else { return }
        let scale = backdropScale
        guard scale > 0 else { return }

        let pixelRect = annotation.hitBoundingRect
        // 外扩几像素：虚线贴着内容边缘会被笔画本身挡住，
        // 看起来像「框只画了一半」；这是纯装饰量，不影响命中。
        let rect = CGRect(
            x: CGFloat(pixelRect.origin.x) / scale,
            y: CGFloat(pixelRect.origin.y) / scale,
            width: CGFloat(pixelRect.size.width) / scale,
            height: CGFloat(pixelRect.size.height) / scale
        ).insetBy(dx: -3, dy: -3)

        context.saveGState()
        // 先画一条深色实底，再叠亮色虚线：纯亮色虚线在浅色内容上会糊掉。
        context.setLineWidth(1)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.stroke(rect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(rect)
        context.restoreGState()
    }

    private func drawBackdrop(in context: CGContext) {
        // 先铺黑底：某块显示器抓取失败时不应露出桌面，
        // 否则遮罩会叠在透明区域上而不产生压暗效果。
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)

        guard let backdrop else { return }

        context.saveGState()
        // 本视图是左上原点，而 CGImage 的绘制以左下原点为准。
        // 临时翻回左下原点绘制，否则底图上下颠倒。
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        // 底图与视图尺寸相同（都是该显示器的逻辑点尺寸），
        // 且 CGContext 已带 backing scale 变换，故为 1:1 像素映射，不做重采样。
        context.interpolationQuality = .none
        context.draw(backdrop, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    private func drawMask(in context: CGContext) {
        guard dimAlpha > 0 else { return }

        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)

        if let selection = effectiveSelection {
            // 用 even-odd 规则挖空选区：选区内保持原始亮度，
            // 用户能直接看清将要截取的内容，而不是隔着压暗层判断。
            //
            // 挖空路径必须与边框**同形**（同一份圆角几何，只差一个 strokeInset，
            // 见 `SelectionHandleLayout.maskRadii`）。用直角矩形挖空会在四个角
            // 各留下一块没被压暗的小三角——用户看到的就是
            // 「边框明明是圆的，外面却还有一个直角」。
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addPath(SelectionHandleLayout.maskPath(
                for: selection,
                viewBounds: bounds,
                displayID: displayID
            ))
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        } else {
            context.fill(bounds)
        }
        context.restoreGState()
    }

    /// 绘制选区外观：边框、手柄、像素尺寸标签。
    ///
    /// 几何与绘制都在 `SelectionChromeRenderer`：它只接收值、不持有视图状态，
    /// 因此渲染结果可以脱离视图验证。这里只负责把本视图的状态摊平传进去。
    private func drawSelection(in context: CGContext) {
        guard let selection = effectiveSelection else { return }
        SelectionChromeRenderer.draw(
            SelectionChromeRenderer.Chrome(
                selection: selection,
                viewBounds: bounds,
                displayID: displayID,
                // 尺寸标签必须用「底图像素 ÷ 视图逻辑点」，而不是显示器比例。
                // 磁盘图片编辑时二者不同（图片可能被缩放到 90% 屏幕内），
                // 用显示器比例会把 1360×1196 的图标成 1892×1664。
                scaleFactor: pixelsPerPoint,
                decoration: decoration,
                isConfirmed: isSelectionConfirmed,
                isCreating: isCreating,
                activeHandle: activeHandle,
                hoveredHandle: hoveredHandle
            ),
            in: context
        )
    }

    // MARK: - 光标

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 选取目标优先于一切截图侧处理：此时鼠标的职责是「指向要录的对象」，
        // 若再走一遍识别，候选会被写进编辑器，把用户的截图选区抢走。
        if updateRecordingPick(at: point) { return }
        updateCursor(at: point)
        updateDetection(at: point)
    }

    /// 修饰键变化时立即重算识别结果。
    ///
    /// 只监听鼠标移动是不够的：用户按住 `⌥` 但没动鼠标时不会产生
    /// `mouseMoved`，选区会停在上一层的识别结果上，看起来像「按键没反应」。
    override func flagsChanged(with event: NSEvent) {
        guard let lastMouse = window?.mouseLocationOutsideOfEventStream else {
            super.flagsChanged(with: event)
            return
        }
        // 选取目标时修饰键不参与决定层级（层级由所选范围强制），
        // 更不能让它触发一次截图侧识别。
        if !updateRecordingPick(at: convert(lastMouse, from: nil)) {
            updateDetection(at: convert(lastMouse, from: nil))
        }
        super.flagsChanged(with: event)
    }

    /// 修饰键决定的识别层级。
    ///
    /// 读 `NSEvent.modifierFlags` 这类**实时状态**而不是事件里的 flags：
    /// 用户可能先按住键再移动鼠标，此时事件携带的 flags 未必反映当下。
    private var detectionPreference: DetectionLayerPreference {
        let flags = NSEvent.modifierFlags
        // 顺序有意义：⌥ 优先级最高（它是「别识别」的逃生口），
        // 其次是 ⌘（应用级）、⇧（窗口级）。
        if flags.contains(.option) { return .disabled }
        if flags.contains(.command) { return .application }
        if flags.contains(.shift) { return .window }
        return .automatic
    }

    /// 此刻自动识别是否应当生效。
    ///
    /// 三个条件各自独立，但它们失效时用户看到的现象一模一样
    /// （选区被抢走，或者拖着跳），因此只能靠单一入口分辨到底谁拦住的。
    private var isDetectionAllowed: Bool {
        guard detectionSession != nil else { return false }
        // 准备阶段（面板已弹出）：识别一律暂停。
        // 面板里的「区域」范围与预览框取自打开面板那一刻的选区，
        // 此时再把识别结果写进选区，两边会当场矛盾。
        if isRecordSetupActive { return false }
        // 已确认选区：识别到此为止。否则新候选会把用户刚定下的框抢走，
        // 而且它会静默退回候选态，让下一次拖拽又变成重新框选。
        if isSelectionConfirmed { return false }
        if isDetectionPausedForDiagnostics { return false }
        // 手势进行中（含按住未动）不再识别：拖到一半被识别结果接管，
        // 表现就是「拖着拖着自己跳了」。
        if isInteracting { return false }
        return true
    }

    /// 按当前鼠标位置更新识别结果。
    private func updateDetection(at viewPoint: CGPoint) {
        guard isDetectionAllowed, let session = detectionSession else { return }
        // 画标注时选区是画布，不该被识别抢走。
        if let editorState, editorState.tool.isDrawingTool {
            return
        }

        let globalPoint = globalScreenPoint(fromViewPoint: viewPoint)
        guard let target = session.target(
            atGlobalPoint: globalPoint,
            preference: detectionPreference
        ) else {
            return
        }

        applyDetectionTarget(target)
    }

    /// 视图坐标（左上原点）→ 全局屏幕坐标（左上原点）。
    ///
    /// 视图 → 窗口需要一次翻转（窗口坐标原点在左下），漏掉这一步会让识别
    /// 永远偏出目标——在取色器定位上踩过同一个坑。翻转量取**主屏**高度，
    /// 不能用手边这块屏的高度：多屏时每块屏的翻转量不同。
    private func globalScreenPoint(fromViewPoint point: CGPoint) -> CGPoint {
        guard let window else { return point }
        let inWindow = convert(point, to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        guard let primary = NSScreen.screens.first else { return onScreen }
        return CGPoint(
            x: onScreen.x,
            y: primary.frame.maxY - onScreen.y
        )
    }

    /// 把识别结果落到选区上。
    private func applyDetectionTarget(_ target: DetectionTarget) {
        // 留存当前命中目标：录制准备面板需要它的身份（windowID / processID）
        // 才能提供「窗口」「应用」范围。身份只在命中测试那一刻有效，
        // 事后再查会因窗口移动或被遮挡而得到不同结果。
        currentDetectionTarget = target

        let scale = backdropScale
        let pixel = CoordinateConversion.pixelRect(
            fromLogical: target.rect,
            scaleFactor: scale
        )
        guard pixel.isNonEmpty else { return }

        // 仅在层级或标题变化时记录：鼠标在同一目标上移动会高频触发，
        // 每次都记会刷满日志且看不出规律。
        let description = "\(target.layer.rawValue)/\(target.title ?? "-")"
        if description != lastDetectionDescription {
            lastDetectionDescription = description
            logger.notice("""
                detection hit: \(description, privacy: .public) \
                rect=\(Int(target.rect.minX.rounded()), privacy: .public),\
                \(Int(target.rect.minY.rounded()), privacy: .public) \
                \(Int(target.rect.width.rounded()), privacy: .public)x\
                \(Int(target.rect.height.rounded()), privacy: .public)
                """)
        }

        detectionTitle = target.title
        detectionLayerName = target.layer.displayName

        // 先告知归属，再更新选区：控制器要用它决定把选区同步到哪块屏的窗口。
        onDetectedDisplayID?(target.displayID)

        // 只更新预览，不写历史。
        editorState?.setPreviewSelection(pixel)
    }

    // MARK: - 录制目标选取

    /// 进入录制目标选取。
    ///
    /// 只接受需要目标的范围类型（窗口 / 应用）：区域与全屏不需要选对象。
    func beginRecordingTargetPick(_ kind: RecordingScopeKind) {
        guard recordingPick.begin(kind) else { return }
        // 选取期间光标固定为十字：它不依赖选区几何，也不会因为候选项
        // 恰好压在截图选区边界上而变成「移动」的样子。
        NSCursor.crosshair.set()
    }

    /// 退出录制目标选取（保留手势标记，理由见 `RecordingTargetPick.end()`）。
    func endRecordingTargetPick() {
        recordingPick.end()
    }

    /// 以当前鼠标位置重算一次候选。
    ///
    /// 进入选取时必须调用：用户点「窗口」时指针通常已经停在目标上，
    /// 而他没移动鼠标就不会有 `mouseMoved`，候选会一直是空的——
    /// 看起来像「选取根本没生效」。
    func refreshRecordingTargetPick() {
        guard recordingPick.isActive, let window else { return }
        _ = updateRecordingPick(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// 选取模式下按鼠标位置更新候选目标。
    ///
    /// - Returns: 是否处在选取模式。true 时调用方不得再做截图侧处理。
    private func updateRecordingPick(at viewPoint: CGPoint) -> Bool {
        guard recordingPick.isActive else { return false }
        // 上报本身不去重（理由见 `RecordingTargetPick.update(candidate:)`）。
        let target = recordingPick.accept(hitTarget(at: viewPoint))
        recordingPick.update(candidate: target)
        onRecordingPickHover?(target)
        return true
    }

    /// 按位置取一次**原始命中**（层级校验由 `RecordingTargetPick.accept` 做）。
    ///
    /// 点击锁定**必须**走这里重新命中，不能直接消费上一次悬停的缓存：
    /// 用户可能没有先移动鼠标（刚进选取就点），也可能按下与松开之间指针已移动，
    /// 缓存值此时要么为空要么已经过时。
    private func hitTarget(at viewPoint: CGPoint) -> DetectionTarget? {
        guard let preference = recordingPick.preference, let session = detectionSession else {
            return nil
        }
        return session.target(
            atGlobalPoint: globalScreenPoint(fromViewPoint: viewPoint),
            preference: preference
        )
    }

    /// 绘制模式下的光标。
    ///
    /// 绝大多数绘图工具用十字即可，但**马赛克涂抹是笔刷**：
    /// 十字光标无法表达「笔刷有多大」，用户落笔前不知道会盖住多少内容。
    /// 这里换成与笔刷同直径的圆，与 `mouseDown` / `mouseDragged`
    /// 实际生效的笔刷半径读同一个值（`style.mosaicBrushRadius`）。
    private func setDrawingCursor(for editorState: AnnotationEditorState) {
        if editorState.tool == .mosaic, editorState.style.mosaicMode == .brush {
            MosaicBrushCursor
                .cursor(radius: CGFloat(editorState.style.mosaicBrushRadius))
                .set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    /// 依据指针位置切换光标，让「哪里可拖」在视觉上可预期。
    ///
    /// 判定顺序必须与 `mouseDown` 完全一致（手柄 → 选区内部 → 空白），
    /// 否则会出现「光标说是移动、结果却改了尺寸」的错位。
    private func updateCursor(at point: CGPoint) {
        guard let selection = effectiveSelection else {
            hoveredHandle = nil
            NSCursor.crosshair.set()
            return
        }

        // 候选态：整个候选都是「按这里开始框选」的靶面，没有可拖的控件。
        // 光标因此统一为十字，与 `mouseDown` 的判定一致（那里候选内一律进 pending）。
        if !isSelectionConfirmed {
            hoveredHandle = nil
            NSCursor.crosshair.set()
            return
        }

        // 绘制模式：选区内部是「画布」，光标统一为十字，
        // 不再显示手柄与拖动手势——否则用户会以为拖内部是移动选区。
        if let editorState, editorState.tool.isDrawingTool, selection.contains(point) {
            hoveredHandle = nil
            setDrawingCursor(for: editorState)
            return
        }

        let hit = handle(at: point, in: selection)
        hoveredHandle = hit

        if let hit {
            SelectionCursor.cursor(for: hit).set()
        } else if selection.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: - 坐标换算

    /// 底图像素 / 视图逻辑点的比例。
    ///
    /// 视图用逻辑点、模型用像素，所有跨边界的换算都必须走这一处，
    /// 否则字号、笔刷半径、行高这些「既出现在界面又写进模型」的值会各算各的。
    private var backdropScale: CGFloat {
        guard let backdrop, bounds.width > 0 else { return 1 }
        return CGFloat(backdrop.width) / bounds.width
    }

    /// 底图像素 ÷ 视图逻辑点。**会话外的换算必须用它**，不要另查显示器比例。
    ///
    /// ── 为什么不能让调用方自己算 ────────────────────────────────
    ///
    /// 选区最终要与**这张底图**一起送进渲染器裁剪，所以「逻辑点 → 像素」的
    /// 比例只能是「底图宽度 ÷ 视图宽度」。而
    /// `DisplayGeometry.scaleFactor(for:)` 是**实时查询**显示器 mode 得到的：
    /// 它在显示器切换分辨率、睡眠唤醒、系统繁忙时会瞬时失手。
    ///
    /// 曾经控制器用后者、视图用前者，同一块选区于是有了两套像素尺寸：
    /// 控制器提交给模型的选区只有真实尺寸的一半（原点也减半），
    /// 而导出按模型裁剪底图——用户看到的现象正是
    /// **「框选一大片，导出的图只有左上角一小块」**。
    ///
    /// 底图未绑定（会话尚未展示）时退回显示器比例，保证属性恒为正值。
    var pixelsPerPoint: CGFloat {
        let scale = backdropScale
        return scale > 0 ? scale : scaleFactor
    }

    /// 选区在**冻结底图**上的画面（含已提交的标注），供文字识别使用。
    ///
    /// 不重新截屏，原因有三：
    /// * 单帧截图不排除本应用的窗口（「还原用户所见」），重截拿到的是**覆盖层自己**——
    ///   选区边框、拖拽手柄、贴边时落进选区的工具栏都会混进识别结果；
    /// * 用户框选、核对的是冻结的画面，识别对象应当与它逐像素一致；
    /// * 底图已在内存里，省掉一次可共享内容查询与抓帧。
    ///
    /// 带上标注：与导出保持「所见即所得」。尤其是马赛克——用户打码的内容
    /// 不应被识别出来，更不应在选用云端识别时被发出去。
    func recognitionImage(for logicalRect: CGRect) -> CGImage? {
        guard let backdrop else { return nil }
        return Exporter.compose(
            backdrop: backdrop,
            selection: CoordinateConversion.pixelRect(fromLogical: logicalRect, scaleFactor: pixelsPerPoint),
            annotations: editorState?.annotations ?? []
        )
    }

    /// 视图逻辑点 → 底图像素。
    private func pixelPoint(from viewPoint: CGPoint) -> PixelPoint {
        let scale = Double(backdropScale)
        return PixelPoint(
            x: Double(viewPoint.x) * scale,
            y: Double(viewPoint.y) * scale
        )
    }

    /// 视图逻辑矩形 → 底图像素矩形。
    private func pixelSelection(from selection: CGRect) -> PixelRect? {
        guard backdrop != nil, bounds.width > 0 else {
            return nil
        }
        let scale = Double(backdropScale)
        return PixelRect(
            origin: PixelPoint(
                x: Double(selection.minX) * scale,
                y: Double(selection.minY) * scale
            ),
            size: PixelSize(
                width: Double(selection.width) * scale,
                height: Double(selection.height) * scale
            )
        )
    }

    // MARK: - 文字编辑

    /// 文字输入控件（生命周期与输入法规则见 `OverlayTextEditor`）。
    ///
    /// 回调在首次使用时配置：`lazy` 让闭包能安全引用 `self`，不必把这段
    /// 配置塞进已经很长的 `init`。
    private lazy var textEditorHost: OverlayTextEditor = {
        let host = OverlayTextEditor()
        host.onTextChange = { [weak self] text in
            self?.editorState?.updateTextDraft(text)
        }
        host.onCommit = { [weak self] in self?.commitTextEditing() }
        host.onCancel = { [weak self] in self?.cancelTextEditing() }
        return host
    }()

    /// 把编辑器状态里的文字草稿同步到输入控件。
    ///
    /// 视图**不保存**文字内容：字号、颜色、文本都在 `AnnotationEditorState` 里。
    /// 用户改设置时状态先变，再由这里推给控件，
    /// 于是「输入中看到的」与「提交后写进模型的」不会各记一份而分叉。
    /// 把编辑器状态里的文字草稿同步到输入控件。
    ///
    /// 视图**不保存**文字内容：字号、颜色、文本都在 `AnnotationEditorState` 里。
    /// 用户改设置时状态先变，再由这里推给控件，
    /// 于是「输入中看到的」与「提交后写进模型的」不会各记一份而分叉。
    private func syncTextEditor() {
        textEditorHost.sync(draft: editorState?.textDraft, scaleFactor: backdropScale, host: self)
    }

    // MARK: - 取色器

    /// 取色器面板的生命周期与摆放（见 `OverlayColorPickerPresenter`）。
    private let colorPicker = OverlayColorPickerPresenter()

    /// 合成当前会话并交给会话层导出。
    ///
    /// 合成失败（选区非法等）时只响一声，**不结束会话**——
    /// 用户的标注还在，静默关掉窗口等于把工作丢掉。
    private func performExport(_ action: ExportAction) {
        guard let editorState, let backdrop else {
            NSSound.beep()
            return
        }

        // 先把仍在进行中的选区手势落定，再合成。
        //
        // 快捷键可以在鼠标还没抬起时按下——「框完立刻按 ⌘C」是很常见的手感，
        // 而选区**只在 `mouseUp` 时才写进模型**（拖拽途中控制器不更新
        // `editor.selection`），它此刻还停留在自动识别给出的候选框上，
        // 而那通常比用户刚拖出的框小得多。于是合成拿到的是旧选区，
        // 用户看到的是「框了一大片，复制到的只有一小块」。
        //
        // 放这里而不是 `SessionExporter.finishEditing`：选区的权威在视图
        // （`selectionRect`），导出层拿不到它，只能由视图先落定。
        guard settleSelectionGestureForExport() else {
            NSSound.beep()
            return
        }

        guard let image = SessionExporter.compose(
            editor: editorState,
            backdrop: backdrop,
            scaleFactor: backdropScale
        ) else {
            NSSound.beep()
            return
        }

        onExport?(image, action)
    }

    /// 导出前把进行中的选区手势落定到模型；返回是否可以继续导出。
    ///
    /// 三种情形：
    /// - **没有手势**：直接放行，这是绝大多数调用；
    /// - **手势已有足够大的选区**：按 `mouseUp` 的同一套收尾提交，放行；
    /// - **手势刚起步、选区还太小**：按误触收掉（与 `mouseUp` 一致地把
    ///   候选放回去），**并且拒绝导出**——导出一个与用户刚画的框无关的
    ///   旧选区，比明确拒绝更糟。
    ///
    /// 不做成 `private`：单元测试要直接驱动这条时序路径，
    /// 而在测试里造真实鼠标事件序列的代价远高于收益。
    @discardableResult
    func settleSelectionGestureForExport() -> Bool {
        guard isInteracting else { return true }

        let wasCreating = isCreating
        let changedGeometry = selectionGestureChangedGeometry
        selectionGestureChangedGeometry = false
        interaction = .idle
        hoveredHandle = nil

        guard let selection = effectiveSelection,
              selection.width >= decoration.minimumSelectionSize,
              selection.height >= decoration.minimumSelectionSize else {
            if wasCreating {
                // 与 `mouseUp` 的失败分支同一套处理：越过阈值却没拖够时把候选
                // 放回去，新建失败则清掉那个零尺寸矩形（否则会留下一根看不见的
                // 细线选区）。
                if let candidate = pendingCandidate {
                    selectionRect = candidate.rect
                    currentDetectionTarget = candidate.target
                } else {
                    selectionRect = nil
                }
            }
            pendingCandidate = nil
            onSelectionChanged?(effectiveSelection)
            return false
        }

        // 用户自己拖出的矩形与任何识别目标都无关：留着旧身份会让「录制窗口 /
        // 应用」拿到一个与该矩形无关的窗口 ID。与 `mouseUp` 保持一致：
        // 只有确实改动了几何的手势才清身份，单纯按下未拖动仍保留目标。
        if changedGeometry {
            currentDetectionTarget = nil
        }
        pendingCandidate = nil
        onSelectionChanged?(selection)
        onSelectionCommitted?(selection)
        return true
    }

    private func presentColorPanel() {
        guard let editorState else { return }
        // 锚点取颜色入口按钮的中心；取不到时退回工具栏左上角。
        let itemCenter = toolbar.itemCenter(.colorButton) ?? CGPoint(x: 24, y: 18)
        colorPicker.present(
            anchorInView: CGPoint(
                x: toolbarFrame.minX + itemCenter.x,
                y: toolbarFrame.minY + itemCenter.y
            ),
            toolbarFrame: toolbarFrame,
            selection: effectiveSelection,
            in: self,
            state: editorState
        )
    }

    /// 供诊断读取取色器状态（不参与业务逻辑）。
    var colorPickerForDiagnostics: ColorPickerView? { colorPicker.pickerView }

    /// 供诊断读取取色器窗口（用于查窗口服务器的在屏列表）。
    var colorPickerWindowForDiagnostics: NSWindow? { colorPicker.panelWindow }

    /// 收起取色器。会话结束必须调用。
    func dismissColorPanel() {
        colorPicker.dismiss()
    }

    /// 供控制器在「文字内容变化」时调用：只同步输入控件，不做全量重绘。
    func syncTextEditorFromState() {
        syncTextEditor()
    }

    /// 提交当前文字编辑，写进模型。
    private func commitTextEditing() {
        guard let editorState, editorState.isEditingText else { return }
        let committed = editorState.commitTextDraft(scaleFactor: backdropScale)
        textEditorHost.remove(host: self)
        if committed {
            needsDisplay = true
        }
    }

    /// 放弃当前文字编辑，原有标注保持原内容。
    private func cancelTextEditing() {
        guard let editorState, editorState.isEditingText else { return }
        editorState.cancelTextEditing()
        textEditorHost.remove(host: self)
    }

    /// 某个视图点是否落在输入控件上。
    private func isPointInTextEditor(_ point: CGPoint) -> Bool {
        textEditorHost.frame?.contains(point) ?? false
    }

    /// 工具栏整体在本视图坐标系里的 frame。
    ///
    /// 供诊断把「祖先坐标系里的按钮位置」换算回工具栏内部坐标，
    /// 以便与布局常量这种独立预期比较。
    var toolbarFrame: CGRect {
        toolbar.isHidden ? .zero : toolbar.frame
    }

    /// 工具栏上各可点击项在本视图坐标系里的中心点。
    ///
    /// 供诊断按真实坐标合成点击。
    /// 供诊断读取背景状态（不参与业务逻辑）。
    var hasBackdropForDiagnostics: Bool { backdrop != nil }

    var backdropForDiagnostics: CGImage? { backdrop }

    var backdropScaleForDiagnostics: CGFloat { backdropScale }

    func toolbarItemCenters() -> [AnnotationToolbarView.Kind: CGPoint] {
        guard !toolbar.isHidden else { return [:] }
        var result: [AnnotationToolbarView.Kind: CGPoint] = [:]
        for (kind, center) in toolbar.visibleItemCenters() {
            result[kind] = CGPoint(
                x: toolbar.frame.minX + center.x,
                y: toolbar.frame.minY + center.y
            )
        }
        return result
    }

    /// 点击是否落在工具栏（或它的二级面板）上。
    ///
    /// 设置操作不应顺手把刚输入的文字提交掉，所以点击工具栏时要排除在外。
    private func isPointInsideToolbar(_ point: CGPoint) -> Bool {
        !toolbar.isHidden && toolbar.frame.contains(point)
    }

    /// 双击命中已有文字时进入重新编辑。命中返回 true。
    private func beginEditingExistingText(at point: CGPoint) -> Bool {
        guard let editorState else { return false }

        // 从后往前找：数组顺序即 z 序，上层文字优先被命中。
        for annotation in editorState.annotations.reversed() {
            guard case let .text(origin, text, font, _, _, _) = annotation.kind else {
                continue
            }

            // 模型的 origin 是基线左端，反推出用于命中的左上角与包围盒：
            // 宽度用与渲染同一套 CoreText 排版，高度用同一份行高。
            let topLeft = PixelPoint(
                x: origin.x,
                y: origin.y - TextMetrics.ascent(for: font)
            )
            let width = Self.textWidth(text: text, font: font)
            let height = TextMetrics.lineHeight(for: font)
            let rect = CGRect(
                x: topLeft.x / Double(backdropScale),
                y: topLeft.y / Double(backdropScale),
                width: max(width / Double(backdropScale), 12),
                height: max(height / Double(backdropScale), 12)
            )

            // 命中框略外扩，细字也好点中。
            if rect.insetBy(dx: -4, dy: -3).contains(point) {
                editorState.beginTextEditing(annotation: annotation, topLeft: topLeft)
                syncTextEditor()
                return true
            }
        }
        return false
    }

    /// 单行文字的排版宽度（底图像素）。
    private static func textWidth(text: String, font: FontDescriptor) -> Double {
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: TextMetrics.font(for: font)
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    // MARK: - 鼠标事件

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 新手势从「没有改动几何」开始；真正改动发生在 `mouseDragged`。
        selectionGestureChangedGeometry = false

        // 选取模式下的按下不作决定：它是「点击锁定目标」的前半段，由 `mouseUp` 落实。
        // 但**要按位置重算一次候选**：用户可能刚进选取就直接点，没有任何悬停，
        // 此时缓存的候选是空的或已过时（指针已移动）。
        if recordingPick.isActive {
            recordingPick.markGestureDown()
            _ = updateRecordingPick(at: point)
            return
        }

        // 准备阶段（面板已弹出）：截图侧的一切交互暂停。
        // 否则用户能一边看着面板里的「区域」预览框，一边把截图选区拖到别处。
        if isRecordSetupActive { return }

        // 点工具栏是设置操作，不应顺手把刚输入的文字提交掉。
        // 正常情况下工具栏作为子视图先拿到事件，这里只是兜底。
        if isPointInsideToolbar(point) {
            return
        }

        // 点击输入控件之外时先结束编辑（与常见文本输入行为一致）。
        if editorState?.isEditingText == true, !isPointInTextEditor(point) {
            commitTextEditing()
        }

        // 候选选区上的按下：先不做决定。
        //
        // 按下点落在候选内时，无法立刻区分用户想「单击确认」还是
        // 「重新框选」，因此先进 pending 由位移阈值裁决。
        //
        // 这个判断**优先于手柄命中**：候选态本就不绘制手柄（见 `drawSelection`），
        // 若这里仍按手柄判定，就会重现「看不见却能点中」那个旧缺陷。
        if let selection = effectiveSelection,
           selection.contains(point),
           !isSelectionConfirmed {
            // 留底：转成 `.creating` 后 `selectionRect` 就被新矩形覆盖了。
            pendingCandidate = (selection, currentDetectionTarget)
            interaction = .pending(anchor: point)
            NSCursor.crosshair.set()
            return
        }

        // 指针工具：点击已有标注即选中，随后拖动即移动。
        //
        // 命中失败（点在空白）时 `selectAnnotation` 会顺便清掉选中，
        // 然后继续走下面的选区手势——与改造前「拖选区内部移动选区」一致。
        // 点在画布外同样是空白：只清选中，不改选区手势的既有含义。
        if let editorState, editorState.tool == .pointer, isSelectionConfirmed {
            if let selection = effectiveSelection, selection.contains(point) {
                let pixel = pixelPoint(from: point)
                let tolerance = Double(Self.annotationHitTolerance) * Double(backdropScale)
                if editorState.selectAnnotation(at: pixel, tolerance: tolerance) {
                    interaction = .movingAnnotation(lastPixel: pixel)
                    NSCursor.closedHand.set()
                    return
                }
            } else {
                editorState.clearAnnotationSelection()
            }
        }

        // 绘制模式：在选区内按下开始创建。
        // 文字是「点一下再输入」，其余绘图工具靠拖拽，因此分开处理。
        if let editorState, let selection = effectiveSelection,
           selection.contains(point), isSelectionConfirmed {
            if editorState.tool == .text {
                // 双击已有文字进入重新编辑；单击空白处新建。
                if event.clickCount >= 2, beginEditingExistingText(at: point) {
                    return
                }
                guard !editorState.isEditingText else { return }
                editorState.beginTextEditing(at: pixelPoint(from: point))
                syncTextEditor()
                return
            }
            if editorState.tool.isDraggable {
                editorState.beginDraft(at: pixelPoint(from: point))
                return
            }
        }

        if let selection = effectiveSelection, isSelectionConfirmed {
            // 与 `updateCursor` 同一套判定：手柄优先于「内部移动」，
            // 因为手柄位于选区边界上，两者区域重叠。
            if let hit = handle(at: point, in: selection) {
                interaction = .resizing(handle: hit)
                // 拖动期间系统不会重置光标，设一次即可全程保持
                SelectionCursor.cursor(for: hit).set()
                return
            }

            if selection.contains(point) {
                interaction = .moving(
                    grabOffset: CGPoint(x: point.x - selection.minX, y: point.y - selection.minY)
                )
                NSCursor.closedHand.set()
                return
            }
        }

        // 其余位置（含已确认选区之外）都开始新建选区。
        interaction = .creating(anchor: point)
        NSCursor.crosshair.set()
        selectionRect = CGRect(origin: point, size: .zero)
        // 不在这里上报 nil：同上，零尺寸是中间态。真正的「选区被清空」
        // 由 `mouseUp` 在尺寸不足时上报。
    }

    override func mouseDragged(with event: NSEvent) {
        // 拖拽点钳制在视图内：选区不允许越出本显示器范围。
        // （跨显示器选区不在 M1 范围内，故不做跨屏扩展。）
        let point = SelectionGeometry.clamp(convert(event.locationInWindow, from: nil), to: bounds)

        // 选取模式下拖拽只是持续换目标（指针划过的窗口依次成为候选），
        // 不能借此框选：那会同时改掉用户的截图选区。
        if updateRecordingPick(at: point) { return }

        // 准备阶段：拖拽不产生任何截图侧效果。
        if isRecordSetupActive { return }

        switch interaction {
        case .idle:
            // 绘制模式下的拖拽不改变选区，只更新未提交的草稿。
            if editorState?.hasDraft == true {
                editorState?.updateDraft(to: pixelPoint(from: point))
            }
            return

        case .movingAnnotation(let lastPixel):
            // 按「相邻两次像素位置之差」累积：视图坐标可能带缩放，
            // 直接传单次位移会在往返换算里累积取整误差。
            let current = pixelPoint(from: point)
            let delta = PixelPoint(x: current.x - lastPixel.x, y: current.y - lastPixel.y)
            guard delta != PixelPoint.zero else { return }
            editorState?.moveSelected(by: delta)
            interaction = .movingAnnotation(lastPixel: current)
            return

        case .pending(let anchor):
            // 越过阈值才转成真正的框选：单击（含手抖）不越过，
            // 留给 `mouseUp` 确认候选。未越阈值时不动 `selectionRect`，
            // 候选保持原样可见，不闪烁。
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            guard hypot(dx, dy) >= pendingDragThreshold else { return }
            interaction = .creating(anchor: anchor)
            selectionRect = SelectionGeometry.normalizedRect(from: anchor, to: point)
            selectionGestureChangedGeometry = true

        case .creating(let anchor):
            selectionRect = SelectionGeometry.normalizedRect(from: anchor, to: point)
            selectionGestureChangedGeometry = true

        case .moving(let grabOffset):
            guard let current = selectionRect else { return }
            let moved = CGRect(
                origin: CGPoint(x: point.x - grabOffset.x, y: point.y - grabOffset.y),
                size: current.size
            )
            selectionRect = SelectionGeometry.clamp(moved, to: bounds)
            selectionGestureChangedGeometry = true

        case .resizing(let handle):
            guard let current = selectionRect else { return }
            selectionRect = SelectionGeometry.resizedRect(
                current,
                handle: handle,
                to: point,
                minimumSize: decoration.minimumSelectionSize
            )
            selectionGestureChangedGeometry = true
        }

        // 只在选区有效时上报。
        //
        // 手势中的零尺寸矩形只是**中间态**，不是「用户清空了选区」。
        // 若照报过去，`selectionDidChange(nil)` 会提交一个空选区并触发全量
        // 同步，`syncSelectionFromEditor` 再见空选区就 `resetSelection()`——
        // 于是 `interaction` 与 `pendingCandidate` 在拖拽刚起步时就被抹掉，
        // 表现是「拖着拖着框自己没了」。
        if let selection = effectiveSelection {
            onSelectionChanged?(selection)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // 选取模式：单击＝锁定鼠标下的目标。
        //
        // **按松开位置重新命中**，而不是提交悬停缓存：可能没有先悬停
        // （刚进选取就点），也可能按下与松开之间指针已移开。
        //
        // `consumeGestureDown` 覆盖「按下后按 ESC 取消」的情形：此时选取已退出，
        // 不吞掉这次松手就会落进下面的草稿/选区提交路径，
        // 把一次取消变成一次意外的编辑。
        if recordingPick.consumeGestureDown() {
            if recordingPick.isActive {
                let point = convert(event.locationInWindow, from: nil)
                let target = recordingPick.accept(hitTarget(at: point))
                // 候选为空时单击无任何效果，而且不会留下痕迹——
                // 正是最难查的一类「点了没反应」，故记一条。
                logger.notice("""
                    recording pick: click at \(NSStringFromPoint(point), privacy: .public) \
                    target=\(target?.title ?? "nil", privacy: .public)
                    """)
                if let target {
                    onRecordingPickCommit?(target)
                }
            }
            return
        }

        // 准备阶段：不提交草稿、不改选区。
        if isRecordSetupActive {
            if let editorState, editorState.hasDraft {
                editorState.discardDraft()
            }
            return
        }

        // 拖动标注：松手只是结束手势，不改选区、不提交任何东西——
        // 每次移动都已由 `moveSelected` 记成一步历史。
        if case .movingAnnotation = interaction {
            interaction = .idle
            updateCursor(at: convert(event.locationInWindow, from: nil))
            return
        }

        // 绘制模式：松手才提交。拖拽期间它只是草稿，不进撤销历史，
        // 因此「撤销一次」对应撤掉一个标注，而不是撤掉一串中间鼠标位置。
        if let editorState, editorState.hasDraft {
            // 选区由编辑器自己持有，提交时直接取用；
            // 选区手势已经在它自己的 mouseUp 分支里提交过了。
            if effectiveSelection == nil {
                editorState.discardDraft()
            } else {
                editorState.commitDraft()
            }
            updateCursor(at: convert(event.locationInWindow, from: nil))
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let wasPending: Bool = {
            if case .pending = interaction { return true }
            return false
        }()
        let wasCreating = isCreating
        interaction = .idle
        // 松手后控件才出现，光标要跟着指回指针下方的部件
        // （可能已从手柄移到选区内部）
        updateCursor(at: point)

        // 候选上的一次单击（没越过拖拽阈值）= 确认这个候选。
        // 几何不变，但要带着它原有的识别身份：用户接受的是「这个窗口/应用」，
        // 身份丢了，「录制窗口范围」就没有目标可用。
        if wasPending {
            pendingCandidate = nil
            editorState?.confirmSelection()
            // 单击确认候选也是一次「选区确定」。
            //
            // 之前这里只翻 `isSelectionConfirmed`、不通知控制器，于是
            // 「点窗口」这条路径既不进撤销历史，也无法触发「直达动作」
            //（录制 / 长截图 / OCR）。几何没变，提交同一个矩形是安全的：
            // `commitSelection` 对相同值本来就会忽略。
            if let confirmed = effectiveSelection {
                onSelectionCommitted?(confirmed)
            }
            return
        }

        guard let selection = effectiveSelection,
              selection.width >= decoration.minimumSelectionSize,
              selection.height >= decoration.minimumSelectionSize else {
            // 尺寸不足视为误触（最常见的是单击）。
            if wasCreating {
                if let candidate = pendingCandidate {
                    // 越过阈值却没拖够：用户是想框选的，只是手没移开。
                    // 把候选放回去并恢复识别，**不能**当成一次单击确认——
                    // 那会把一个失败的拖拽变成一个意外的决定。
                    selectionRect = candidate.rect
                    currentDetectionTarget = candidate.target
                    pendingCandidate = nil
                    onSelectionChanged?(candidate.rect)
                } else {
                    // 新建失败：清掉那个零尺寸矩形，
                    // 避免留下一根看不见的细线选区。
                    selectionRect = nil
                    onSelectionChanged?(nil)
                }
            }
            return
        }

        // 用户自己拖出的矩形与任何识别目标都无关：留着旧身份会让
        // 「录制窗口/应用」拿到一个与该矩形无关的窗口 ID。
        // 但「按下又松开、没有拖动」不改变几何，选区仍是识别到的那个目标，
        // 身份必须保留——否则单击确认候选后目标就丢了。
        if selectionGestureChangedGeometry {
            currentDetectionTarget = nil
        }
        pendingCandidate = nil
        onSelectionChanged?(selection)
        onSelectionCommitted?(selection)
    }

    override func rightMouseDown(with event: NSEvent) {
        // 右键＝「取消当前这一层」，与多数截图工具一致。
        //
        // **必须按状态分派**：准备面板开着时直接走 `onCancel` 会把整个截图会话
        // 连同选区、标注一起销毁，而那正是「取消准备」要保留的东西。
        if recordingPick.isActive {
            endRecordingTargetPick()
            onRecordingPickCancel?()
            return
        }
        if isRecordSetupActive {
            onRecordSetupCancel?()
            return
        }
        onCancel?()
    }

    // MARK: - 键盘事件

    override func keyDown(with event: NSEvent) {
        // 选取目标与录制准备阶段的键盘归属。
        //
        // 截图语义里的回车是「拷贝并结束会话」，在面板开着时误按一下就会把
        // 整个会话截掉，所以这里要把输入接管过来：
        // - 选取中：只接受 ESC（取消选取），其余全部吞掉
        // - 准备中：ESC 取消准备；回车交由面板按其「可开始」状态处理
        if recordingPick.isActive {
            if event.keyCode == 53 {
                endRecordingTargetPick()
                onRecordingPickCancel?()
            }
            return
        }
        if isRecordSetupActive {
            switch event.keyCode {
            case 53:
                onRecordSetupCancel?()
            case 36, 76:
                onRecordSetupConfirm?()
            default:
                break
            }
            return
        }

        // 文字编辑期间键盘归输入控件：firstResponder 是 NSTextField 时
        // 正常不会走到这里，此处仅作兜底，避免工具快捷键把文字吞掉。
        if editorState?.isEditingText == true {
            super.keyDown(with: event)
            return
        }

        // Delete / Backspace 删除选中的标注。
        //
        // 放在文字编辑判断**之后**：正在输入时这两个键属于输入框（删字），
        // 而不是删掉整条标注。没有选中时不吞键，保持原有的系统行为。
        // 51 = 主键盘 Delete(Backspace)，117 = 前向删除。
        if let editorState, editorState.hasSelectedAnnotation,
           event.keyCode == 51 || event.keyCode == 117 {
            editorState.deleteSelected()
            return
        }

        #if DEBUG
        // 只记录导出相关的按键：这两个分支一旦因为焦点问题收不到事件，
        // 用户看到的是「按了没反应」，没有任何报错可查。
        let exportKeyCode = event.keyCode == 36 || event.keyCode == 76
        let isCommandS = event.modifierFlags.contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "s"
        let isCommandC = event.modifierFlags.contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "c"
        if exportKeyCode || isCommandS || isCommandC {
            logger.notice("""
                overlay keyDown: keyCode=\(event.keyCode, privacy: .public) \
                chars=\(event.charactersIgnoringModifiers ?? "-", privacy: .public) \
                editingText=\(self.editorState?.isEditingText == true, privacy: .public)
                """)
        }
        #endif

        // 命令识别与执行分开：识别在 `OverlayKeyCommand`（纯查表，可独立断言），
        // 这里只做执行。上面三段已经决定了「键盘属于谁」，到这里仍是本视图的。
        guard let command = OverlayKeyCommand.parse(event) else {
            super.keyDown(with: event)
            return
        }
        // 与抽取前一致：编辑器状态尚未建立时，除 ESC 外的按键一律交给系统，
        // 否则「会话还没准备好」的瞬间按 ⌘S 会走到导出路径上。
        guard command == .cancel || editorState != nil else {
            super.keyDown(with: event)
            return
        }
        perform(command)
    }

    /// 执行一条按键命令。
    private func perform(_ command: OverlayKeyCommand) {
        switch command {
        case .cancel:
            // ESC 一次结束会话。
            //
            // 早先做成三级回退（丢草稿 → 清选区 → 退会话），理由是
            // 「不必为取消一笔标注重开一次截图」。实际用起来不成立：
            // 这个键在截图工具里的含义就是**退出**，用户按它时已经决定放弃，
            // 需要按两次三次反而像卡住了。
            // 草稿与选区都随会话一起释放，不需要单独清理。
            onCancel?()
        case .save:
            performExport(.save)
        case .copy:
            performExport(.copy)
        case .undo:
            if let onUndoRequested {
                onUndoRequested()
            } else {
                editorState?.undo()
            }
        case .redo:
            if let onRedoRequested {
                onRedoRequested()
            } else {
                editorState?.redo()
            }
        case .selectTool(let tool):
            editorState?.select(tool)
        }
    }
}

// MARK: - 覆盖层窗口

/// 铺满单块显示器的非激活面板。
final class OverlayWindow: NSPanel {

    /// 显示器内逻辑点矩形 → AppKit 屏幕坐标矩形。
    ///
    /// 用**本窗口自身**的 frame 做基准：覆盖层窗口正好铺满一台显示器，
    /// 其 `origin` 就是该显示器在 AppKit 坐标下的原点，其高度就是该显示器的翻转量。
    ///
    /// 为什么不能放在 `OverlayView` 上：视图的 frame 是**窗口内**坐标，
    /// 不含窗口在屏幕上的原点，用它算出来的是屏幕上的错误位置。
    ///
    /// 也不能自己拿「主屏高度」做翻转——多显示器时每块屏的翻转量不同，
    /// 非主屏上的选区会被算到屏幕外（实测表现为控制条与准备面板贴到屏幕边角）。
    func appKitScreenRect(forLocalRect rect: CGRect) -> CGRect {
        CGRect(
            x: frame.origin.x + rect.minX,
            y: frame.origin.y + frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 全局左上原点矩形 → AppKit 屏幕坐标矩形。
    ///
    /// 与 `appKitScreenRect(forLocalRect:)` 的分工：那个处理**本显示器内**的
    /// 矩形（翻转量取本屏高度），这个处理**跨屏**矩形——窗口可以横跨两块屏，
    /// 而 AppKit 全局坐标的原点只有主屏左下角一个，故翻转量取主屏高度。
    static func appKitScreenRect(forGlobalRect rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(
            x: rect.minX,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    let displayID: CGDirectDisplayID
    let overlayView: OverlayView

    /// 图片编辑模式的窗口。
    ///
    /// 与截图覆盖层共用同一套 `OverlayView`（选区、标注、工具栏、导出），
    /// 区别只在窗口尺寸与层级：这里不是铺满一块屏，而是围着图片本身；
    /// 层级用 `.floating` 而不是 `.screenSaver`，否则编辑一张图会盖住菜单栏，
    /// 用户连「另存为」面板都可能被自己挡住。
    init(imageFrame: NSRect, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.overlayView = OverlayView(
            frame: NSRect(origin: .zero, size: imageFrame.size),
            displayID: displayID
        )

        super.init(
            contentRect: imageFrame,
            // 图片编辑器需要可见的关闭按钮：它不像截图覆盖层那样按 ESC 就走，
            // 用户可能在这里停留很久。标题栏同时给出「这是一张图」的身份。
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        title = "编辑图片"
        isOpaque = true
        backgroundColor = .black
        level = .floating
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // 图片编辑器允许被外部录屏看到：用户可能正是在给教程录素材。
        sharingType = .readOnly
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = true
        contentMinSize = imageFrame.size
        contentMaxSize = imageFrame.size
        collectionBehavior = [.fullScreenAuxiliary, .stationary]
        contentView = overlayView
    }

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.overlayView = OverlayView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            displayID: displayID
        )

        super.init(
            contentRect: screen.frame,
            // `.nonactivatingPanel` 必须在此传入，事后修改无效。
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // 不透明背景 + 黑色：窗口显示瞬间若视图尚未绘制，看到的是黑屏而非桌面透出。
        isOpaque = true
        backgroundColor = .black
        // 层级需高于菜单栏（.mainMenu）与全屏窗口（.fullScreen）。
        level = .screenSaver
        hasShadow = false
        // 本应用激活策略为 .accessory，失焦是常态，不可因此隐藏覆盖层。
        hidesOnDeactivate = false
        // 生命周期由 OverlayController 显式管理。
        isReleasedWhenClosed = false
        // 不使用系统出现/消失动画，避免可见的淡入延迟。
        animationBehavior = .none
        // 不参与其它录屏 / 屏幕共享的窗口捕获。
        //
        // 本应用自己的截图与录制走 SCStream / SCScreenshotManager 的显示器采集，
        // 不受 `sharingType` 影响（导出拿到的仍是覆盖层之下的桌面）；
        // 但外部录屏、会议共享走窗口级捕获时会把整个截图界面录进去。
        // 覆盖层铺满全屏、层级又高于菜单栏，一旦入镜整段视频都会被挡住，
        // 因此明确声明「不可被共享」。
        sharingType = .none
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovable = false
        isMovableByWindowBackground = false
        minSize = screen.frame.size
        maxSize = screen.frame.size

        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        contentView = overlayView
    }

    /// `.borderless` 窗口默认不能成为 key window；重写以接收 ESC。
    ///
    /// 配合 `.nonactivatingPanel`，成为 key window 不会激活本应用，
    /// 因此前台应用的标题栏应保持活跃外观（P3 验收判据之一）。
    override var canBecomeKey: Bool { true }

    /// 覆盖层不需要成为 main window。
    override var canBecomeMain: Bool { false }

    /// 显示但**不**抢焦点。
    func presentWithoutActivating() {
        orderFrontRegardless()
    }
}

// MARK: - 顶部对齐的输入框

/// 让文字从框顶开始排版的 `NSTextFieldCell`。
///
/// 系统默认把单行文字在框内垂直居中、并留出内边距；
/// 那样输入框里的字与 CoreText 按「左上角 + 基线」定位出来的字对不上，
/// 用户会看到「输入时一个位置、提交后另一个位置」。
/// 覆写绘制/编辑矩形让文字贴着框顶，输入预览与最终渲染才一致。
final class TopAlignedTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = rect
        // 水平方向**不留**内边距：输入预览必须与提交后的渲染落点一致，
        // 留边会让用户在输入时看到的字比实际提交后的位置偏移几个点。
        // 垂直方向贴合框顶，使 frame.origin 就是文字的左上角。
        result.size.height = cellSize(forBounds: rect).height
        return result
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        drawingRect(forBounds: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

