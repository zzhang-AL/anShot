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
    /// 按当前默认格式保存文件。
    case save
    /// 按指定格式保存或临时强制弹出另存为面板（工具栏 `⌥+点击保存` 或右键快捷格式菜单）。
    case saveAs(format: ExportFormatOption?, forceAsk: Bool)
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

    /// 待渲染的标注 = 已提交 + 未提交草稿（正在重编辑的原静态文字暂时隐藏，防止叠印重影）。
    ///
    /// 草稿也参与渲染，用户才能看到正在拖拽的形状；
    /// 但它不进撤销历史（见 `AnnotationEditorState`）。
    private var displayedAnnotations: [Annotation] {
        guard let editorState else { return [] }
        let editingID = editorState.textDraft?.annotationID
        var list = editorState.annotations.filter { $0.id != editingID }
        if let draft = editorState.draft {
            list.append(draft)
        }
        return list
    }

    /// 当前是否正在编辑文字（供 `OverlayWindow.performKeyEquivalent` 分流快捷键）。
    var isEditingText: Bool { editorState?.isEditingText == true }

    /// 是否正在选取录制目标（供 `OverlayWindow.performKeyEquivalent` 判别）。
    var isRecordingPickActive: Bool { recordingPick.isActive }

    /// 主动释放底图与合成缓存（用于进入长截图或会话结束时快速降低内存峰值）。
    func releaseBackdropMemory() {
        detectionSession?.cancelPendingControlLookup()
        backdrop = nil
        composedCache = nil
        loupeView.isHidden = true
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

    /// 标注命中容差（逻辑点）。
    ///
    /// 取 `6pt`（略大于外扩 3pt 的选中虚线框）：既让刚画好的细边框/细线容易抓握拖动，
    /// 又不会大到吞掉空心框内部空白区的叠加绘制空间。
    private static let annotationHitTolerance: CGFloat = 6

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
    /// 上一次发起控件探测的视图点与偏好（用于 3pt 移动死区，避免像素级慢移反复查 AX）。
    private var lastDetectionProbePoint: CGPoint?
    private var lastDetectionProbePreference: DetectionLayerPreference?

    /// 应用设置（用于读取防误关双按 Esc 开关与工具栏隐藏槽位）。
    weak var appSettings: AppSettings?

    /// 独立窗体捕获模式（未框选态按 `Space` 切换，或由菜单栏「窗体截图」直达）。
    var isWindowPickerMode = false {
        didSet {
            guard isWindowPickerMode != oldValue else { return }
            if !isWindowPickerMode {
                windowPickerCandidates = []
                windowPickerIndex = 0
                lastWindowPickerPoint = nil
            }
            needsDisplay = true
            refreshToolbar()
        }
    }

    /// 窗体模式开关变化回调（供控制器同步多显示器窗口状态与最大化抑制开关）。
    var onWindowPickerModeChanged: ((Bool) -> Void)?

    /// 窗体模式下单击确认捕获某个窗口（参数：目标窗口、是否按住 `⌥` 反转阴影）。
    var onWindowPickerCommit: ((DetectionTarget, Bool) -> Void)?

    /// 光标下方按 Z-order 排序的窗口候选栈与当前穿透下标（供 `Tab`/`⇧Tab` 切换）。
    private var windowPickerCandidates: [DetectionTarget] = []
    private var windowPickerIndex: Int = 0
    private var lastWindowPickerPoint: CGPoint?

    /// 等比缩放选区（按住 `Shift`）时记录的初始选区快照。
    private var resizingInitialRect: CGRect?

    /// 在已有确认选区上从暗区拖拽重框前的原选区快照（若新框未达最小尺寸则恢复原选区而非清空）。
    private var preCreatingSelectionRect: CGRect?

    /// 键盘方向键连续微调的事务合并防抖任务（400ms 内连按合并为单条撤销记录）。
    private var nudgeCommitWorkItem: DispatchWorkItem?
    /// 键盘微调选区期间暂存的最新逻辑选区（待防抖结束统一提交一条历史）。
    private var pendingSelectionNudgeRect: CGRect?

    /// 确认态下是否正按住空格键用于平移整个选区。
    private var isSpaceKeyPressed = false

    /// 完整快捷键速查卡是否展开（按 `?` 或点击左下角微提示切换）。
    private(set) var isShortcutCheatSheetVisible = false {
        didSet {
            if isShortcutCheatSheetVisible != oldValue {
                needsDisplay = true
            }
        }
    }

    /// 复位空格平移状态（窗口失焦、切换焦点或重置选区时调用，防止漏收 keyUp 导致卡死）。
    func clearSpaceKeyState() {
        guard isSpaceKeyPressed else { return }
        isSpaceKeyPressed = false
        if let window {
            let mousePoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            updateCursor(at: mousePoint)
        }
    }

    /// 绘图工具下按下瞬间命中的已有标注与起点（用于松手位移 < 3pt 时原地选中该标注）。
    private var pendingDrawingHitAnnotationID: UUID?
    private var pendingDrawingDownPoint: CGPoint?

    /// 双按 `Esc` 防误关的上次提醒时间戳。
    private var lastCancelPromptTime: ContinuousClock.Instant?

    /// 滚轮微调参数的平滑累积器，避免触控板微滑连跳多档。
    private var wheelDeltaAccumulator: CGFloat = 0

    /// 编号标注双击就地编辑数字的轻量输入框。
    private var numberingEditorField: NSTextField?
    private var editingNumberingAnnotationID: UUID?

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

    /// 直达动作模式在未框选阶段展示的顶部居中引导横幅文案（如直达长截图操作提示）。
    var intentBannerText: String? {
        didSet {
            guard intentBannerText != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 为 `true` 时，未框选状态下按 `Enter`/`⌘C` 等不隐式回退成整屏普通截图（用于直达长截图防误触）。
    var preventsImplicitFullScreenExport = false

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
        /// 已确认选区外暗区的按下（尚无标注）：单击只取消标注选中不闪烁，拖动超过阈值再重新框选。
        case pendingRecreate(anchor: CGPoint, previousSelection: CGRect)
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
        /// 拖动选中标注的几何控制手柄。
        case resizingAnnotation(handle: AnnotationControlHandle)
    }

    private var interaction: Interaction = .idle {
        // 活动手柄需要重绘才能显示强调色；选区拖拽起止需即时隐显工具栏。
        didSet {
            needsDisplay = true
            refreshToolbar()
        }
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

    /// 指针是否悬停在选区尺寸胶囊平移把手上（用于高亮边框视觉反馈）。
    private var isHoveringSizeLabel = false {
        didSet {
            if isHoveringSizeLabel != oldValue { needsDisplay = true }
        }
    }

    /// 当前是否正通过尺寸胶囊平移选区（用于激活态主题色高亮）。
    private var isDraggingSizeLabel = false {
        didSet {
            if isDraggingSizeLabel != oldValue { needsDisplay = true }
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
        clearSpaceKeyState()
        isShortcutCheatSheetVisible = false
        isHoveringSizeLabel = false
        isDraggingSizeLabel = false
        lastDetectionProbePoint = nil
        lastDetectionProbePreference = nil
        detectionSession?.clearControlHierarchy()
        selectionRect = nil
        customToolbarOrigin = nil
        lastSelectionForToolbarOrigin = nil
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

    /// 命中测试（含角、中点手柄及整边带状缩放热区）。
    private func handle(at point: CGPoint, in selection: CGRect) -> SelectionHandle? {
        SelectionHandleLayout.hit(
            at: point,
            for: selection,
            viewBounds: bounds,
            displayID: displayID,
            decoration: decoration,
            activeHandle: activeHandle
        )
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
        case .pendingRecreate: return "pendingRecreate"
        case .creating: return "creating"
        case .moving: return "moving"
        case .movingAnnotation: return "movingAnnotation"
        case .resizingAnnotation: return "resizingAnnotation"
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
        textEditorHost.diagnosticStateString
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
    /// 用户手动拖动工具栏后的自定义位置（选区变动或重置时恢复自动避让）。
    private var customToolbarOrigin: CGPoint?
    private var lastSelectionForToolbarOrigin: CGRect?

    /// 像素放大镜视图与最近采样缓存。
    private lazy var loupeView = OverlayLoupeView(frame: .zero)
    private var lastLoupeSample: LoupeSample?

    private lazy var toolbar: AnnotationToolbarView = {
        let view = AnnotationToolbarView()
        view.isHidden = true
        view.onSelectTool = { [weak self] tool in
            guard let self else { return }
            self.editorState?.select(tool)
            if self.colorPicker.isPresented,
               self.editorState?.style.color(for: tool) == nil {
                self.dismissColorPanel()
            }
            if let window = self.window {
                let mousePoint = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                self.updateCursor(at: mousePoint)
                self.updateLoupe(at: mousePoint)
            }
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
        view.onSelectMosaicEffectMode = { [weak self] mode in
            self?.editorState?.selectMosaicEffectMode(mode)
        }
        view.onToggleSketchy = { [weak self] in
            self?.editorState?.toggleSketchy()
        }
        view.onToggleFill = { [weak self] in
            self?.editorState?.toggleShapeFilled()
        }
        view.onToggleTextBold = { [weak self] in
            self?.editorState?.toggleTextBold()
        }
        view.onToggleTextItalic = { [weak self] in
            self?.editorState?.toggleTextItalic()
        }
        view.onCycleTextFontFamily = { [weak self] in
            self?.editorState?.cycleTextFontFamily()
        }
        view.onSelectSpotlightDimOpacity = { [weak self] opacity in
            self?.editorState?.selectSpotlightDimOpacity(opacity)
        }
        view.onCancel = { [weak self] in
            self?.requestCancel(source: .toolbar)
        }
        view.onSelectMosaicBlockSize = { [weak self] size in
            guard let self else { return }
            self.editorState?.selectMosaicBlockSize(size, scaleFactor: self.backdropScale)
        }
        view.onSelectMosaicBrushDiameter = { [weak self] diameter in
            self?.editorState?.selectMosaicBrushDiameter(diameter)
        }
        view.onOpenColorPanel = { [weak self] in
            self?.toggleColorPanel()
        }
        view.onIntrinsicSizeChanged = { [weak self] in
            self?.refreshToolbar()
        }
        view.onSliderGestureBegan = { [weak self] in
            self?.editorState?.beginEditTransaction()
        }
        view.onSliderGestureEnded = { [weak self] in
            self?.editorState?.commitEditTransaction()
        }
        view.onDragMove = { [weak self] delta in
            self?.moveToolbar(by: delta)
        }
        view.onResetPosition = { [weak self] in
            self?.resetToolbarPosition()
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
        view.onSaveAs = { [weak self] format, forceAsk in
            self?.performExport(.saveAs(format: format, forceAsk: forceAsk))
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
    /// 候选态、拖拽新建/移动/缩放选区及窗体选择模式全程隐藏工具栏；
    /// 仅当选区已确认且未在拖拽选区时展示。
    func refreshToolbar() {
        if isRecordSetupActive || hidesToolbarForIntent || isWindowPickerMode {
            toolbar.isHidden = true
            return
        }
        guard let editorState,
              editorState.isSelectionConfirmed,
              !isAdjustingSelectionRect,
              let selection = effectiveSelection,
              backdrop != nil else {
            toolbar.isHidden = true
            return
        }

        if toolbar.superview == nil {
            addSubview(toolbar)
        }

        toolbar.tool = editorState.tool
        toolbar.showsToolSelection = editorState.isSelectionConfirmed
        toolbar.style = editorState.style
        toolbar.canUndo = editorState.canUndo
        toolbar.canRedo = editorState.canRedo
        toolbar.allowsCaptureActions = allowsCaptureActions
        toolbar.hasSelectedAnnotation = editorState.hasSelectedAnnotation
        toolbar.selectedAnnotationMatchesTool = editorState.selectedAnnotationMatchesTool
        toolbar.selectedAnnotationIsText = selectedAnnotationIsText
        toolbar.selectedAnnotationIsHighlight = selectedAnnotationIsHighlight
        toolbar.selectedAnnotationColor = editorState.selectedAnnotationColor
        toolbar.activeFontSizeForToolbar = editorState.isEditingText
            ? editorState.textDraft?.fontSize
            : editorState.selectedTextLogicalFontSize(scaleFactor: pixelsPerPoint)
        let capabilities = selectedAnnotationStyleCapabilities
        toolbar.selectedAnnotationSupportsColor = capabilities.color
        toolbar.selectedAnnotationSupportsLineWidth = capabilities.lineWidth
        toolbar.selectedAnnotationSupportsSketchy = editorState.selectedAnnotationSupportsSketchy
        toolbar.selectedAnnotationIsSketchy = editorState.selectedAnnotationIsSketchy
        toolbar.selectedAnnotationSupportsFill = editorState.selectedAnnotationSupportsFill
        toolbar.selectedAnnotationIsFilled = editorState.selectedAnnotationIsFilled
        toolbar.selectedAnnotationIsBold = editorState.selectedAnnotationIsBold
        toolbar.selectedAnnotationIsItalic = editorState.selectedAnnotationIsItalic
        toolbar.selectedAnnotationFontFamily = editorState.selectedAnnotationFontFamily
        toolbar.selectedAnnotationIsSpotlight = editorState.selectedAnnotationIsSpotlight
        toolbar.selectedAnnotationSpotlightDimOpacity = editorState.selectedAnnotationSpotlightDimOpacity
        toolbar.selectedAnnotationSupportsMosaicEffect = editorState.selectedAnnotationSupportsMosaicEffect
        toolbar.selectedAnnotationMosaicMode = editorState.selectedAnnotationMosaicMode
        toolbar.selectedAnnotationMosaicBlockSize = editorState.selectedAnnotationMosaicIntensity.map {
            AnnotationStyle.logicalMosaicBlockSize(forPixelIntensity: $0, scaleFactor: backdropScale)
        }
        toolbar.hiddenSlots = appSettings?.toolbarHiddenSlots ?? []
        toolbar.isHidden = false

        // 输入中的文字也要跟随面板设置：改字号/颜色/粗斜体后，
        // 输入控件里的字必须立刻变，否则「看到的」与「提交的」不一致。
        syncTextEditor()

        if lastSelectionForToolbarOrigin != selection {
            lastSelectionForToolbarOrigin = selection
            customToolbarOrigin = nil
        }

        let gap: CGFloat = 8
        let safeInsets = effectiveSafeAreaInsets
        let layoutBounds = toolbarLayoutBounds
        let initialSize = toolbar.toolbarSize
        // 按尺寸胶囊实际停靠方向精确预留避让高度：胶囊在上方时工具栏紧贴下方，互不重叠也不留白缝。
        let labelFrame = sizeLabelDragRect()
        let labelIsAbove = labelFrame.map { $0.maxY <= selection.minY } ?? true
        let labelIsBelow = labelFrame.map { $0.minY >= selection.maxY } ?? false
        let belowReserve: CGFloat = labelIsBelow ? (decoration.labelHeight + gap) : 0
        let aboveReserve: CGFloat = labelIsAbove ? (decoration.labelHeight + gap) : 0

        toolbar.panelPlacement = AnnotationToolbarLayout.preferredPanelPlacement(
            selection: selection,
            toolbarSize: initialSize,
            labelReserve: belowReserve,
            aboveLabelReserve: aboveReserve,
            viewBounds: layoutBounds,
            gap: gap,
            safeInsets: safeInsets
        )

        let size = toolbar.toolbarSize
        let origin: CGPoint
        if let customBarOrigin = customToolbarOrigin {
            // `customToolbarOrigin` 锚定主栏自身的左上角坐标，而非外接大矩形：
            // 这样无论上方二级气泡展开还是收起，主栏在屏幕上 100% 纹丝不动，零上下跳动。
            let proposedContainerOrigin = CGPoint(
                x: customBarOrigin.x,
                y: customBarOrigin.y - toolbar.barOriginY
            )
            origin = clampedToolbarOrigin(
                proposedContainerOrigin,
                size: size,
                gap: gap,
                safeInsets: safeInsets,
                in: layoutBounds
            )
            self.customToolbarOrigin = CGPoint(
                x: origin.x,
                y: origin.y + toolbar.barOriginY
            )
        } else {
            origin = AnnotationToolbarLayout.toolbarOrigin(
                selection: selection,
                toolbarSize: size,
                labelReserve: belowReserve,
                aboveLabelReserve: aboveReserve,
                viewBounds: layoutBounds,
                gap: gap,
                safeInsets: safeInsets
            )
        }
        toolbar.frame = CGRect(origin: origin, size: size)
    }

    /// 当前是否正在拖拽新建、平移或缩放选区本身（此类手势期间须隐藏工具栏）。
    private var isAdjustingSelectionRect: Bool {
        switch interaction {
        case .creating, .moving, .resizing:
            return true
        default:
            return false
        }
    }

    /// 工具栏布局与钳制所参考的可见视口范围。
    ///
    /// 全屏覆盖层下直接等于 `bounds`；在独立图片/长截图可滚动编辑窗口内等于当前滚到的可视区，
    /// 确保滚动查看超长图时工具栏始终停留在可见区域内。
    private var toolbarLayoutBounds: CGRect {
        if let scrollView = enclosingScrollView {
            let visible = scrollView.documentVisibleRect.intersection(bounds)
            if !visible.isNull && visible.width > 0 && visible.height > 0 {
                return visible
            }
        }
        return bounds
    }

    /// 计算当前窗口与屏幕物理刘海/菜单栏相交时的安全边距。
    private var effectiveSafeAreaInsets: NSEdgeInsets {
        guard let window, let screen = window.screen else { return NSEdgeInsetsZero }
        // 仅当窗口顶边贴近屏幕顶边（全屏覆盖层）时，才需避让硬件刘海区域。
        guard window.frame.maxY >= screen.frame.maxY - 2 else { return NSEdgeInsetsZero }
        return screen.safeAreaInsets
    }

    private func clampedToolbarOrigin(
        _ origin: CGPoint,
        size: CGSize,
        gap: CGFloat,
        safeInsets: NSEdgeInsets,
        in container: CGRect
    ) -> CGPoint {
        let minX = container.minX + max(gap, safeInsets.left + gap)
        let maxX = max(minX, container.maxX - max(gap, safeInsets.right + gap) - size.width)
        let minY = container.minY + max(gap, safeInsets.top + gap)
        let maxY = max(minY, container.maxY - max(gap, safeInsets.bottom + gap) - size.height)
        return CGPoint(
            x: min(max(minX, origin.x), maxX),
            y: min(max(minY, origin.y), maxY)
        )
    }

    /// 用户按住工具栏握把或空白处拖移位置（记录主栏自身原点，折叠上方气泡不跳动）。
    private func moveToolbar(by delta: CGSize) {
        guard !toolbar.isHidden else { return }
        let safeInsets = effectiveSafeAreaInsets
        let proposed = CGPoint(
            x: toolbar.frame.origin.x + delta.width,
            y: toolbar.frame.origin.y + delta.height
        )
        let clamped = clampedToolbarOrigin(
            proposed,
            size: toolbar.frame.size,
            gap: 8,
            safeInsets: safeInsets,
            in: toolbarLayoutBounds
        )
        customToolbarOrigin = CGPoint(x: clamped.x, y: clamped.y + toolbar.barOriginY)
        toolbar.frame.origin = clamped
    }

    /// 双击拖拽握把或工具栏空白处一键复位到选区默认停靠位置。
    private func resetToolbarPosition() {
        customToolbarOrigin = nil
        refreshToolbar()
    }

    /// 选中的标注是否是文字（面板据此显示字号档位）。
    private var selectedAnnotationIsText: Bool {
        guard let kind = editorState?.selectedAnnotation?.kind else { return false }
        if case .text = kind { return true }
        return false
    }

    /// 选中的标注是否是高亮荧光笔（面板据此切换半透明色板）。
    private var selectedAnnotationIsHighlight: Bool {
        guard let kind = editorState?.selectedAnnotation?.kind else { return false }
        if case .highlight = kind { return true }
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
        case .mosaic, .mosaicStroke, .spotlight:
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
    /// 绘制优先模式下，只要当前存在选中标注（无论指针或绘图工具），取色同时更新选中标注与默认样式。
    private func applyToolbarColor(_ color: RGBAColor) {
        editorState?.selectColor(color)
    }

    /// 工具栏线宽（滑块）。语义同 `applyToolbarColor`。
    private func applyToolbarLineWidth(_ width: Double) {
        editorState?.selectLineWidth(width)
    }

    /// 工具栏字号（文字工具或选中文字时）。语义同 `applyToolbarColor`。
    private func applyToolbarFontSize(_ size: Double) {
        editorState?.selectFontSize(size, scaleFactor: backdropScale)
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
        drawWindowPickerHUD(in: context)
        OverlayShortcutHUD.draw(shortcutHUDState(), in: context)
    }

    /// 构造左下角快捷微提示与 `?` 速查卡的当前输入快照（绘制与命中同源）。
    func shortcutHUDState() -> OverlayShortcutHUD.State {
        var avoidRects: [CGRect] = []
        if let selection = effectiveSelection {
            avoidRects.append(selection)
        }
        if !toolbar.isHidden, toolbar.frame.width > 0, toolbar.frame.height > 0 {
            avoidRects.append(toolbar.frame)
        }
        if let labelRect = sizeLabelDragRect() {
            avoidRects.append(labelRect)
        }
        let isSuppressed = isWindowPickerMode
            || isRecordSetupActive
            || recordingPick.isActive
            || isInteracting
            || editorState?.hasDraft == true
            || editorState?.isEditingText == true
            || numberingEditorField != nil
            || enclosingScrollView != nil
        return OverlayShortcutHUD.State(
            viewBounds: bounds,
            safeInsets: effectiveSafeAreaInsets,
            isSelectionConfirmed: isSelectionConfirmed,
            isHintEnabled: appSettings?.showOverlayShortcutHint ?? true,
            isCheatSheetVisible: isShortcutCheatSheetVisible,
            isSuppressedByMode: isSuppressed,
            avoidRects: avoidRects,
            isEnglish: AnShotLocalization.isEnglish
        )
    }

    /// 当前已确认选区外侧「像素尺寸胶囊」的几何矩形（仅非创建态返回，作为全局平移选区把手）。
    func sizeLabelDragRect() -> CGRect? {
        guard isSelectionConfirmed, !isCreating, let selection = effectiveSelection else { return nil }
        return SelectionChromeRenderer.sizeLabelRect(
            for: SelectionChromeRenderer.Chrome(
                selection: selection,
                viewBounds: bounds,
                displayID: displayID,
                scaleFactor: pixelsPerPoint,
                decoration: decoration,
                isConfirmed: true,
                isCreating: false,
                activeHandle: activeHandle,
                hoveredHandle: hoveredHandle,
                topSafeInset: effectiveSafeAreaInsets.top,
                isSizeLabelHovered: isHoveringSizeLabel,
                isSizeLabelActive: isDraggingSizeLabel
            )
        )
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
        guard scaleFactor > 0 else { return nil }
        let rect: PixelRect
        switch annotation.kind {
        case let .mosaic(r, _, _, _), let .spotlight(r, _, _):
            rect = r
        default:
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
            // 先断开旧缓存再分配新画布：两者都是整张选区大小的位图，
            // 同时在场只会白白抬高峰值内存（释放发生在 render 分配之前）。
            composedCache = nil
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
        context.interpolationQuality = backdropInterpolationQuality
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
        guard backdrop != nil, bounds.width > 0, bounds.height > 0 else { return }
        let sx = backdropScaleX
        let sy = backdropScaleY
        guard sx > 0, sy > 0 else { return }

        let pixelRect = annotation.hitBoundingRect
        // 外扩几像素：虚线贴着内容边缘会被笔画本身挡住，
        // 看起来像「框只画了一半」；这是纯装饰量，不影响命中。
        let rect = CGRect(
            x: CGFloat(pixelRect.origin.x) / sx,
            y: CGFloat(pixelRect.origin.y) / sy,
            width: CGFloat(pixelRect.size.width) / sx,
            height: CGFloat(pixelRect.size.height) / sy
        ).insetBy(dx: -3, dy: -3)

        context.saveGState()
        // 先画一条深色实底，再叠亮色虚线：纯亮色虚线在浅色内容上会糊掉。
        context.setLineWidth(1)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.stroke(rect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(rect)

        // 绘制指针二次编辑几何控制手柄。
        let handles = AnnotationEditorState.controlHandles(for: annotation)
        for item in handles {
            let viewPoint = CGPoint(x: item.point.x / sx, y: item.point.y / sy)
            let radius: CGFloat = 4
            let handleRect = CGRect(
                x: viewPoint.x - radius,
                y: viewPoint.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let fillColor: NSColor
            switch item.handle {
            case .control:
                fillColor = .systemYellow
            case .cornerRadius:
                fillColor = .systemOrange
            default:
                fillColor = .white
            }
            context.setFillColor(fillColor.cgColor)
            context.fillEllipse(in: handleRect)
            context.setLineDash(phase: 0, lengths: [])
            context.setLineWidth(1.25)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.strokeEllipse(in: handleRect)
        }
        context.restoreGState()
    }

    /// 命中选中标注的几何控制手柄（视图逻辑点坐标）。
    private func annotationControlHandle(at point: CGPoint) -> AnnotationControlHandle? {
        guard let annotation = editorState?.selectedAnnotation, backdrop != nil,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let sx = backdropScaleX
        let sy = backdropScaleY
        guard sx > 0, sy > 0 else { return nil }
        let handles = AnnotationEditorState.controlHandles(for: annotation)
        var best: (handle: AnnotationControlHandle, dist: CGFloat)?
        for item in handles {
            let center = CGPoint(x: item.point.x / sx, y: item.point.y / sy)
            let dist = hypot(point.x - center.x, point.y - center.y)
            guard dist <= 8 else { continue }
            if let current = best, dist >= current.dist { continue }
            best = (item.handle, dist)
        }
        return best?.handle
    }

    /// 底图缩放预览时启用 `.high` 抗锯齿插值；1:1 像素映射时关闭插值保锐利。
    private var backdropInterpolationQuality: CGInterpolationQuality {
        let displayScale = window?.backingScaleFactor ?? scaleFactor
        let diffX = abs(backdropScaleX - displayScale)
        let diffY = abs(backdropScaleY - displayScale)
        return (diffX > 0.01 || diffY > 0.01) ? .high : .none
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
        context.interpolationQuality = backdropInterpolationQuality
        context.draw(backdrop, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    private func drawMask(in context: CGContext) {
        // 零闪屏护城河：
        // - 普通区域截图的未确认候选态（!isSelectionConfirmed && !isCreating && !isWindowPickerMode）
        //   保持屏幕 100% 原亮度静止，仅由 `SelectionChromeRenderer` 绘制清晰蓝框 + 柔和微光填充，
        //   彻底杜绝控件悬停慢移时全屏在 0% ↔ 45% 压暗之间剧烈明暗频闪；
        // - 独立窗体选择模式使用柔和 0.28 压暗突出目标窗；
        // - 拖拽框选（isCreating）与确认态（isSelectionConfirmed）正常压暗选区外 `dimAlpha`（0.45）。
        guard dimAlpha > 0, let selection = effectiveSelection else { return }
        let effectiveDimAlpha: CGFloat
        if isSelectionConfirmed || isCreating {
            effectiveDimAlpha = dimAlpha
        } else if isWindowPickerMode {
            effectiveDimAlpha = min(dimAlpha, 0.28)
        } else {
            return
        }

        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(effectiveDimAlpha).cgColor)

        // 用 even-odd 规则挖空选区：选区内保持原始亮度，
        // 挖空路径必须与边框**同形**（同一份圆角几何，只差一个 strokeInset）。
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addPath(SelectionHandleLayout.maskPath(
            for: selection,
            viewBounds: bounds,
            displayID: displayID
        ))
        context.addPath(path)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    /// 独立窗体捕获模式顶部信息胶囊（展示序号/总数、应用名、尺寸、无阴影状态及快捷键提示）。
    private func drawWindowPickerHUD(in context: CGContext) {
        let text: String
        if isWindowPickerMode {
            let total = windowPickerCandidates.count
            let noShadowActive: Bool = {
                let base = appSettings?.windowCaptureShadow ?? true
                let optionFlipped = NSEvent.modifierFlags.contains(.option)
                return !(optionFlipped ? !base : base)
            }()

            if total > 0, windowPickerIndex < total {
                let target = windowPickerCandidates[windowPickerIndex]
                let app = target.applicationName ?? target.title ?? "窗口"
                let w = Int((target.rect.width * pixelsPerPoint).rounded())
                let h = Int((target.rect.height * pixelsPerPoint).rounded())
                let shadowSuffix = noShadowActive ? " · 无阴影" : ""
                text = "\(windowPickerIndex + 1)/\(total) · \(app) · \(w) × \(h)\(shadowSuffix)   Tab 穿透 · ⌥ 阴影 · Space 区域"
            } else {
                text = "独立窗体模式 · 移动指针选择窗口 · Space 切换区域框选"
            }
        } else if let banner = intentBannerText, !banner.isEmpty, effectiveSelection == nil {
            text = banner
        } else {
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96),
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        var drawAttrs = attrs
        drawAttrs[.paragraphStyle] = paragraph
        let attributed = NSAttributedString(string: text, attributes: drawAttrs)
        let textSize = attributed.size()
        let padX: CGFloat = 14
        let height: CGFloat = 28
        let maxPillWidth = max(220, bounds.width - 40)
        let width = min(maxPillWidth, ceil(textSize.width) + padX * 2 + 2)
        let topSafe = max(16, effectiveSafeAreaInsets.top + 12)
        let pillRect = CGRect(
            x: ((bounds.width - width) / 2).rounded(),
            y: topSafe,
            width: width,
            height: height
        )

        context.saveGState()
        let path = CGPath(roundedRect: pillRect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        context.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()

        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext
        let textRect = CGRect(
            x: pillRect.minX + padX,
            y: pillRect.midY - textSize.height / 2,
            width: max(1, pillRect.width - padX * 2),
            height: ceil(textSize.height) + 1
        )
        attributed.draw(in: textRect)
        NSGraphicsContext.restoreGraphicsState()
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
                hoveredHandle: hoveredHandle,
                topSafeInset: effectiveSafeAreaInsets.top,
                isSizeLabelHovered: isHoveringSizeLabel,
                isSizeLabelActive: isDraggingSizeLabel
            ),
            in: context
        )
    }

    // MARK: - 光标

    /// 覆盖层刚展示时立即按当前鼠标位置显示像素放大镜（并在窗体模式下刷新候选窗）。
    func presentInitialLoupeAndHint() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        if isWindowPickerMode {
            updateWindowPicker(at: point, resetIndex: true)
        } else {
            updateLoupe(at: point)
        }
    }

    /// 窗口列表异步加载完成后调用：若当前处于窗体模式，立即按指针位置高亮候选窗。
    func refreshWindowPickerAfterDetectionLoad() {
        guard isWindowPickerMode, let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        updateWindowPicker(at: point, resetIndex: true)
    }

    /// 按光标位置更新独立窗体模式下的 Z-order 候选栈。
    private func updateWindowPicker(at viewPoint: CGPoint, resetIndex: Bool) {
        guard isWindowPickerMode, let session = detectionSession else { return }
        let globalPoint = globalScreenPoint(fromViewPoint: viewPoint)
        let candidates = session.windowCandidates(atGlobalPoint: globalPoint)

        if resetIndex || lastWindowPickerPoint == nil || hypot(viewPoint.x - (lastWindowPickerPoint?.x ?? 0), viewPoint.y - (lastWindowPickerPoint?.y ?? 0)) > 4 {
            lastWindowPickerPoint = viewPoint
            windowPickerCandidates = candidates
            windowPickerIndex = 0
        } else if windowPickerCandidates != candidates {
            windowPickerCandidates = candidates
            windowPickerIndex = min(windowPickerIndex, max(0, candidates.count - 1))
        }

        if windowPickerIndex < windowPickerCandidates.count {
            applyDetectionTarget(windowPickerCandidates[windowPickerIndex])
        } else {
            clearPreviewCandidate()
        }
        loupeView.isHidden = true
        needsDisplay = true
    }

    /// 窗体模式下按 `Tab` / `⇧Tab` 在光标下所有叠放窗口间循环穿透。
    @discardableResult
    func cycleWindowPickerCandidate(reverse: Bool) -> Bool {
        guard isWindowPickerMode else { return false }
        if windowPickerCandidates.isEmpty, let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            updateWindowPicker(at: point, resetIndex: true)
        }
        guard !windowPickerCandidates.isEmpty else { return false }
        let count = windowPickerCandidates.count
        windowPickerIndex = reverse
            ? (windowPickerIndex - 1 + count) % count
            : (windowPickerIndex + 1) % count
        applyDetectionTarget(windowPickerCandidates[windowPickerIndex])
        needsDisplay = true
        return true
    }

    /// 清空未确认态下的候选预览框，回归 100% 原亮度静默画面。
    private func clearPreviewCandidate() {
        guard !isSelectionConfirmed else { return }
        // 若当前已经处于空候选静默态，直接跳过，避免重复触发无效重绘。
        if currentDetectionTarget == nil, effectiveSelection == nil {
            return
        }
        currentDetectionTarget = nil
        detectionTitle = nil
        detectionLayerName = nil
        lastDetectionDescription = nil
        editorState?.setPreviewSelection(PixelRect(origin: .zero, size: PixelSize(width: 0, height: 0)))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 选取目标优先于一切截图侧处理：此时鼠标的职责是「指向要录的对象」，
        // 若再走一遍识别，候选会被写进编辑器，把用户的截图选区抢走。
        if updateRecordingPick(at: point) {
            loupeView.isHidden = true
            return
        }
        if isWindowPickerMode {
            updateWindowPicker(at: point, resetIndex: false)
            NSCursor.pointingHand.set()
            return
        }
        updateCursor(at: point)
        updateDetection(at: point)
        updateLoupe(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        loupeView.isHidden = true
        isHoveringSizeLabel = false
        detectionSession?.cancelPendingControlLookup()
        super.mouseExited(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    /// 刷新光标下像素放大镜：仅在候选态或调整选区边界时显示，标注绘制期间克制隐藏。
    private func updateLoupe(at viewPoint: CGPoint) {
        guard let backdrop,
              !isRecordSetupActive,
              !recordingPick.isActive,
              editorState?.isEditingText != true,
              !colorPicker.isPresented else {
            loupeView.isHidden = true
            lastLoupeSample = nil
            return
        }

        let isAdjustingSelection: Bool = {
            switch interaction {
            case .creating, .resizing: return true
            default: return false
            }
        }()
        let shouldShow = !isSelectionConfirmed || isAdjustingSelection
        guard shouldShow, !isPointInsideToolbar(viewPoint) else {
            loupeView.isHidden = true
            return
        }

        if loupeView.superview == nil {
            addSubview(loupeView)
        } else if subviews.last !== loupeView {
            // 仅在放大镜不在最顶层时置顶一次，避免每次 mouseMoved 反复重排子视图树引发闪烁。
            addSubview(loupeView, positioned: .above, relativeTo: nil)
        }

        let sample = OverlayLoupeSampler.sample(
            from: backdrop,
            at: viewPoint,
            scaleFactor: backdropScale
        )
        lastLoupeSample = sample
        loupeView.update(
            sample: sample,
            cursorPoint: viewPoint,
            viewBounds: bounds,
            safeTopInset: effectiveSafeAreaInsets.top,
            showsCopyHint: !isSelectionConfirmed
        )
    }

    /// 修饰键变化时立即重算识别结果。
    ///
    /// 只监听鼠标移动是不够的：用户按住 `⌥` 但没动鼠标时不会产生
    /// `mouseMoved`，选区会停在上一层的识别结果上，看起来像「按键没反应」。
    override func flagsChanged(with event: NSEvent) {
        if isWindowPickerMode {
            // 按下/松开 ⌥ 切换无阴影提示胶囊。
            needsDisplay = true
            super.flagsChanged(with: event)
            return
        }
        guard let lastMouse = window?.mouseLocationOutsideOfEventStream else {
            super.flagsChanged(with: event)
            return
        }
        // 选取目标时修饰键不参与决定层级（层级由所选范围强制），
        // 更不能让它触发一次截图侧识别。
        let localPoint = convert(lastMouse, from: nil)
        if !updateRecordingPick(at: localPoint) {
            updateDetection(at: localPoint)
            updateCursor(at: localPoint)
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

    /// 按当前鼠标位置更新识别结果（两阶段防闪烁异步探测）：
    ///
    /// 若光标仍在当前已命中的控件/目标区域内且未切换顶层窗口，**不**在同步阶段把选区
    /// 强行退回整窗或清空（否则鼠标在同一区域缓慢移动会引发「控件 ↔ 整窗/空白」的高频乒乓闪烁），
    /// 而是保持当前高亮稳定，交由后台去抖查询确认后再平滑切换或回退。
    private func updateDetection(at viewPoint: CGPoint) {
        guard isDetectionAllowed, let session = detectionSession else { return }
        // 画标注时选区是画布，不该被识别抢走。
        if let editorState, editorState.tool.isDrawingTool {
            session.cancelPendingControlLookup()
            return
        }

        let globalPoint = globalScreenPoint(fromViewPoint: viewPoint)
        let preference = detectionPreference

        // 3pt 移动死区：同一偏好下像素级微移不重复发起跨进程 AX 查询。
        if let lastPt = lastDetectionProbePoint,
           lastDetectionProbePreference == preference,
           hypot(viewPoint.x - lastPt.x, viewPoint.y - lastPt.y) < 3 {
            return
        }
        lastDetectionProbePoint = viewPoint
        lastDetectionProbePreference = preference

        // 粘性保稳判定：自动模式下，只要当前已命中控件且光标仍在同一个顶层窗口内，
        // 同步阶段暂不提前覆盖为整窗或清屏（避免同一控件内慢移、以及相邻控件切换时出现
        // 乒乓抖动），统一由后台 AX 回调无缝切换或平滑回退。
        let topWindowID = session.topWindowID(atGlobalPoint: globalPoint)
        let shouldHoldCurrentControl: Bool = {
            guard preference == .automatic,
                  let current = currentDetectionTarget,
                  current.layer == .control,
                  current.displayID == displayID,
                  current.windowID == topWindowID else {
                return false
            }
            return true
        }()

        if !shouldHoldCurrentControl {
            if let immediate = session.immediateTarget(
                atGlobalPoint: globalPoint,
                preference: preference
            ) {
                applyDetectionTarget(immediate)
            } else if session.suppressesMaximizedWindow {
                clearPreviewCandidate()
            }
        }

        session.scheduleControlTarget(
            atGlobalPoint: globalPoint,
            preference: preference
        ) { [weak self] controlTarget in
            guard let self,
                  self.isDetectionAllowed,
                  !self.isWindowPickerMode,
                  self.editorState?.tool.isDrawingTool != true else {
                return
            }
            if let controlTarget {
                self.applyDetectionTarget(controlTarget)
            } else if shouldHoldCurrentControl {
                // 后台确认光标下已无细控件命中时，再平滑回退到窗口候选或静默空态。
                if let fallback = session.immediateTarget(
                    atGlobalPoint: globalPoint,
                    preference: preference
                ) {
                    self.applyDetectionTarget(fallback)
                } else if session.suppressesMaximizedWindow {
                    self.clearPreviewCandidate()
                }
            }
        }
    }

    /// 视图坐标（左上原点）→ 全局屏幕坐标（CoreGraphics 左上原点，与 `SCWindow.frame` / `AXUIElement` 同源）。
    ///
    /// 全屏覆盖层视图直接按 `CGDisplayBounds(displayID).origin + point` 映射，
    /// 避免经由 `NSScreen.screens.first` 二次翻转导致多屏或刘海屏偏移；
    /// 非全屏窗口（如图片编辑）回落至以 `CGMainDisplayID()` 高度为基准的屏幕坐标翻转。
    private func globalScreenPoint(fromViewPoint point: CGPoint) -> CGPoint {
        let displayBounds = DisplayGeometry.bounds(for: displayID)
        if enclosingScrollView == nil,
           displayBounds.width > 0, displayBounds.height > 0,
           abs(bounds.width - displayBounds.width) <= 2,
           abs(bounds.height - displayBounds.height) <= 2 {
            return CGPoint(
                x: displayBounds.origin.x + point.x,
                y: displayBounds.origin.y + point.y
            )
        }
        guard let window else { return point }
        let inWindow = convert(point, to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        let mainHeight = DisplayGeometry.bounds(for: DisplayGeometry.mainDisplay()).height
        let flipHeight = mainHeight > 0 ? mainHeight : (NSScreen.screens.first?.frame.maxY ?? 0)
        return CGPoint(
            x: onScreen.x,
            y: flipHeight - onScreen.y
        )
    }

    /// 把识别结果落到选区上（同目标去重，避免鼠标微移触发无效整屏重绘）。
    private func applyDetectionTarget(_ target: DetectionTarget) {
        let scale = backdropScale
        let pixel = CoordinateConversion.pixelRect(
            fromLogical: target.rect,
            scaleFactor: scale
        )
        guard pixel.isNonEmpty else { return }

        // 若新候选与当前已显示的候选完全相同，直接短路，避免重复触发视图重绘。
        if let existing = currentDetectionTarget,
           existing.layer == target.layer,
           existing.displayID == target.displayID,
           existing.windowID == target.windowID,
           existing.rect == target.rect,
           editorState?.selection == pixel {
            return
        }

        // 留存当前命中目标：录制准备面板需要它的身份（windowID / processID）
        // 才能提供「窗口」「应用」范围。身份只在命中测试那一刻有效，
        // 事后再查会因窗口移动或被遮挡而得到不同结果。
        currentDetectionTarget = target

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
        isHoveringSizeLabel = false
        // 悬停在左下角快捷微提示或速查卡开关上时显示手型光标。
        if let hudHit = OverlayShortcutHUD.hitTest(point, state: shortcutHUDState()) {
            hoveredHandle = nil
            switch hudHit {
            case .toggleCheatSheet, .toggleHintVisibility:
                NSCursor.pointingHand.set()
            case .cheatSheetBody:
                NSCursor.arrow.set()
            }
            return
        }

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

        // 确认态按住 Space：临时抓手平移选区（不限于指针工具）。
        if isSpaceKeyPressed, selection.contains(point) {
            hoveredHandle = nil
            NSCursor.openHand.set()
            return
        }

        // 绘制优先：无论处于指针还是绘图工具，命中当前选中标注的控制手柄都优先给出调整光标（不限于选区内部，保证贴边控点 360° 可点）。
        if let annoHandle = annotationControlHandle(at: point) {
            hoveredHandle = nil
            switch annoHandle {
            case let .rect(rectHandle):
                SelectionCursor.cursor(for: rectHandle).set()
            case .start, .control, .end, .radius, .cornerRadius:
                NSCursor.crosshair.set()
            }
            return
        }

        // 命中可直接拖动的标注（刚画好/已选中的标注含空心框内部，或非背景型已有标注，或按住 ⌘/⌃ 命中任意标注）时
        // 立刻切换为抓手光标，与 `mouseDown` 共用同一份 `directMoveTarget` 判定。
        if let editorState {
            let flags = NSEvent.modifierFlags
            let forceMove = flags.contains(.command) || flags.contains(.control)
            let pixel = pixelPoint(from: point)
            let tolerance = Double(Self.annotationHitTolerance) * Double(backdropScale)
            let canCheckAnnotation = selection.contains(point) || editorState.hasSelectedAnnotation
            if canCheckAnnotation,
               editorState.directMoveTarget(at: pixel, tolerance: tolerance, forceMove: forceMove) != nil {
                hoveredHandle = nil
                NSCursor.openHand.set()
                return
            }
        }

        // 选区 8 个边角缩放手柄：未命中标注及标注控点时，无论指针还是绘图工具均可直接拉动调整截图边界。
        let hit = handle(at: point, in: selection)
        hoveredHandle = hit
        if let hit {
            SelectionCursor.cursor(for: hit).set()
            return
        }

        // 尺寸胶囊平移把手（严格排在选区 8 个边角缩放手柄之后，绝不抢占角/边缩放）：
        // 任意工具下悬停在选区外侧尺寸胶囊上显示抓手与高亮边框，可直接按住平移整个截图框。
        if let labelRect = sizeLabelDragRect(), labelRect.contains(point) {
            isHoveringSizeLabel = true
            NSCursor.openHand.set()
            return
        }

        // 选区内部其余区域：绘图工具显示绘制光标，指针工具显示抓手平移选区。
        if selection.contains(point) {
            if let editorState, editorState.tool.isDrawingTool {
                setDrawingCursor(for: editorState)
            } else {
                NSCursor.openHand.set()
            }
            return
        }

        // 已确认选区外暗区：若已有标注则提示默认箭头（点击仅取消选中不清空选区），无标注则显示十字允许拖拽重框。
        if editorState?.annotations.isEmpty == false {
            NSCursor.arrow.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: - 坐标换算

    private var backdropScaleX: CGFloat {
        guard let backdrop, bounds.width > 0 else { return 1 }
        return CGFloat(backdrop.width) / bounds.width
    }

    private var backdropScaleY: CGFloat {
        guard let backdrop, bounds.height > 0 else { return 1 }
        return CGFloat(backdrop.height) / bounds.height
    }

    /// 底图像素 / 视图逻辑点的比例。
    ///
    /// 视图用逻辑点、模型用像素，所有跨边界的换算都必须走这一处，
    /// 否则字号、笔刷半径、行高这些「既出现在界面又写进模型」的值会各算各的。
    private var backdropScale: CGFloat {
        backdropScaleX
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
        guard let backdrop, let pixelSelection = pixelSelection(from: logicalRect) else { return nil }
        return Exporter.compose(
            backdrop: backdrop,
            selection: pixelSelection,
            annotations: editorState?.annotations ?? []
        )
    }

    /// 视图逻辑点 → 底图像素（双轴独立映射，消除极端比例缩放下的累计偏差）。
    func pixelPoint(from viewPoint: CGPoint) -> PixelPoint {
        PixelPoint(
            x: Double(viewPoint.x) * Double(backdropScaleX),
            y: Double(viewPoint.y) * Double(backdropScaleY)
        )
    }

    /// 视图逻辑矩形 → 底图像素矩形。
    func pixelSelection(from selection: CGRect) -> PixelRect? {
        guard backdrop != nil, bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        let sx = Double(backdropScaleX)
        let sy = Double(backdropScaleY)
        return PixelRect(
            origin: PixelPoint(
                x: Double(selection.minX) * sx,
                y: Double(selection.minY) * sy
            ),
            size: PixelSize(
                width: Double(selection.width) * sx,
                height: Double(selection.height) * sy
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
        host.onMaxWidthChange = { [weak self] maxWidth in
            self?.editorState?.updateTextDraftMaxWidth(maxWidth)
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
    private func syncTextEditor() {
        textEditorHost.sync(
            draft: editorState?.textDraft,
            scaleFactor: backdropScale,
            selectionBounds: effectiveSelection,
            host: self
        )
    }

    // MARK: - 取色器

    /// 取色器面板的生命周期与摆放（见 `OverlayColorPickerPresenter`）。
    private let colorPicker = OverlayColorPickerPresenter()

    /// 合成当前会话并交给会话层导出。
    ///
    /// 合成失败（选区非法等）时只响一声，**不结束会话**——
    /// 用户的标注还在，静默关掉窗口等于把工作丢掉。
    /// 合成结果优先复用显示侧缓存（见 `composedImageForExport()`）。
    private func performExport(_ action: ExportAction) {
        guard editorState != nil, backdrop != nil else {
            NSSound.beep()
            return
        }

        // 先落定进行中的编号就地编辑（若有）。
        commitNumberingEditing()

        // 静默首帧兜底：若用户呼出普通截图后尚未框选就直接按 Enter / ⌘C / ⌘S / ⌘P，
        // 自动以当前屏整屏作为选区执行导出；但在直达长截图模式下拦截隐式全屏，避免误触普通截图。
        if effectiveSelection == nil, !isInteracting, !isWindowPickerMode, bounds.width >= 8, bounds.height >= 8 {
            if preventsImplicitFullScreenExport {
                NSSound.beep()
                ToastPresenter.show("请先拖拽框选滚动区域（按住 ⌥ 可横向滚动）")
                return
            }
            selectionRect = bounds
            onSelectionChanged?(bounds)
            onSelectionCommitted?(bounds)
        }

        // 先把仍在进行中的选区手势落定，再合成。
        guard settleSelectionGestureForExport() else {
            NSSound.beep()
            return
        }

        guard let image = composedImageForExport() else {
            NSSound.beep()
            return
        }

        onExport?(image, action)
    }

    /// 导出用的合成图，优先复用显示侧那份缓存。
    ///
    /// 显示侧（`drawAnnotations`）已经把当前输入合成过一次；导出再合一遍
    /// 等于在用户按下 ⌘C 的那一帧上多分配一张整选区大小的位图。缓存里那幅
    /// 图**本来就是选区原像素尺寸的成品**，输入（选区 + 标注）没变就能直接用，
    /// 也因此仍然满足「显示与导出走同一个 `AnnotationRenderer.render`」。
    ///
    /// 不直接裁 `backdrop` 走捷径：渲染器会归一化到 BGRA/sRGB，
    /// 裸裁剪会改变色彩语义，看到的与存下来的就不一致了。
    ///
    /// - Returns: 合成结果；选区非法或渲染失败时为 `nil`（调用方响一声并留在会话里）。
    private func composedImageForExport() -> CGImage? {
        guard let editorState, let backdrop, let selection = effectiveSelection else {
            return nil
        }

        // 文字草稿必须在取标注之前提交：导出图不能少掉用户刚敲的字。
        SessionExporter.finishEditing(editorState, scaleFactor: backdropScale)

        let annotations = displayedAnnotations
        if let cache = composedCache,
           cache.selection == selection,
           cache.annotations == annotations {
            return cache.image
        }

        // 先释放旧的整幅缓存，再让渲染器分配新画布 + 新 CGImage。
        composedCache = nil
        return pixelSelection(from: selection).flatMap {
            AnnotationRenderer.render(
                backdrop: backdrop,
                selection: $0,
                annotations: annotations
            )
        }
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
        flushPendingNudgeTransaction()
        guard isInteracting else { return true }

        let wasPendingRecreate: Bool = {
            if case .pendingRecreate = interaction { return true }
            return false
        }()
        let wasCreating = isCreating
        let previousConfirmedSelection = preCreatingSelectionRect
        preCreatingSelectionRect = nil
        let changedGeometry = selectionGestureChangedGeometry
        selectionGestureChangedGeometry = false
        interaction = .idle
        hoveredHandle = nil

        if wasPendingRecreate {
            return true
        }

        guard let selection = effectiveSelection,
              selection.width >= decoration.minimumSelectionSize,
              selection.height >= decoration.minimumSelectionSize else {
            if wasCreating {
                // 与 `mouseUp` 的失败分支同一套处理：越过阈值却没拖够时把候选
                // 或原确认选区放回去，新建失败则清掉那个零尺寸矩形（否则会留下一根看不见的
                // 细线选区）。
                if let candidate = pendingCandidate {
                    selectionRect = candidate.rect
                    currentDetectionTarget = candidate.target
                } else if let previousConfirmedSelection {
                    selectionRect = previousConfirmedSelection
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

    private func toggleColorPanel() {
        guard let editorState else { return }
        // 锚点优先取自定义取色器色环按钮中心，次选当前激活工具图标中心，退回左上角。
        let itemCenter = toolbar.itemCenter(.colorPicker)
            ?? toolbar.itemCenter(.tool(editorState.tool))
            ?? toolbar.itemCenter(.moreTools)
            ?? CGPoint(x: 24, y: 18)
        colorPicker.toggle(
            anchorInView: CGPoint(
                x: toolbarFrame.minX + itemCenter.x,
                y: toolbarFrame.minY + itemCenter.y
            ),
            toolbarFrame: toolbarFrame,
            selection: effectiveSelection,
            in: self,
            state: editorState
        )
        if let pickerView = colorPicker.pickerView,
           let selectedColor = editorState.selectedAnnotationColor {
            pickerView.color = selectedColor
        }
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

    /// 点击是否落在工具栏实际可见区域（主栏胶囊或二级属性气泡）上；透明空气区返回 `false` 穿透回画布。
    private func isPointInsideToolbar(_ point: CGPoint) -> Bool {
        guard !toolbar.isHidden else { return false }
        let local = CGPoint(x: point.x - toolbar.frame.minX, y: point.y - toolbar.frame.minY)
        return toolbar.containsInteractivePoint(local)
    }

    /// 双击命中已有文字时进入重新编辑。命中返回 true。
    private func beginEditingExistingText(at point: CGPoint) -> Bool {
        guard let editorState else { return false }
        let scale = Double(backdropScale)
        guard scale > 0 else { return false }

        // 从后往前找：数组顺序即 z 序，上层文字优先被命中。
        for annotation in editorState.annotations.reversed() {
            guard case let .text(origin, _, font, _, _, _) = annotation.kind else {
                continue
            }

            let box = annotation.hitBoundingRect
            let rect = CGRect(
                x: box.origin.x / scale,
                y: box.origin.y / scale,
                width: max(box.size.width / scale, 12),
                height: max(box.size.height / scale, 12)
            )
            let topLeft = PixelPoint(
                x: origin.x,
                y: origin.y - TextMetrics.ascent(for: font)
            )

            // 命中框略外扩，细字也好点中。
            if rect.insetBy(dx: -4, dy: -3).contains(point) {
                editorState.clearAnnotationSelection()
                editorState.beginTextEditing(
                    annotation: annotation,
                    topLeft: topLeft,
                    scaleFactor: backdropScale
                )
                syncTextEditor()
                return true
            }
        }
        return false
    }

    /// 双击命中已有编号标注时弹出轻量内联输入框直接修改数字。
    private func beginEditingExistingNumbering(at point: CGPoint) -> Bool {
        guard let editorState else { return false }
        let sx = backdropScaleX
        let sy = backdropScaleY
        guard sx > 0, sy > 0 else { return false }
        let pixel = pixelPoint(from: point)
        let tolerance = Double(Self.annotationHitTolerance) * Double(sx)

        for annotation in editorState.annotations.reversed() {
            guard case let .numbering(center, radius, index, _, _, _) = annotation.kind,
                  annotation.hitTest(pixel, tolerance: tolerance) else {
                continue
            }
            commitNumberingEditing()
            editorState.selectAnnotation(id: annotation.id)
            let fieldWidth: CGFloat = 46
            let fieldHeight: CGFloat = 24
            let cx = CGFloat(center.x) / sx
            let cy = CGFloat(center.y) / sy
            let field = NSTextField(frame: CGRect(
                x: (cx - fieldWidth / 2).rounded(),
                y: (cy - fieldHeight / 2).rounded(),
                width: fieldWidth,
                height: fieldHeight
            ))
            field.stringValue = "\(index)"
            field.alignment = .center
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.target = self
            field.action = #selector(numberingEditorDidSubmit)
            addSubview(field)
            window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
            numberingEditorField = field
            editingNumberingAnnotationID = annotation.id
            _ = radius
            return true
        }
        return false
    }

    @objc private func numberingEditorDidSubmit() {
        commitNumberingEditing()
    }

    /// 提交当前编号数字编辑。
    private func commitNumberingEditing() {
        guard let field = numberingEditorField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let editingID = editingNumberingAnnotationID
        field.removeFromSuperview()
        numberingEditorField = nil
        editingNumberingAnnotationID = nil
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        if let editingID, let newValue = Int(text), newValue >= 1 {
            editorState?.selectAnnotation(id: editingID)
            _ = editorState?.updateSelectedNumberingIndex(newValue)
        }
    }

    /// 放弃当前编号数字编辑。
    private func cancelNumberingEditing() {
        guard let field = numberingEditorField else { return }
        field.removeFromSuperview()
        numberingEditorField = nil
        editingNumberingAnnotationID = nil
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
    }

    /// 取消请求的触发来源（用于双按 `Esc` 防误关提示文案区分）。
    enum CancelTriggerSource {
        case escapeKey
        case rightClick
        case toolbar
    }

    /// 统一取消收口：若画有已提交标注且用户开启防误关保护，首次触发给轻量提醒，1.8 秒内再次触发才真正退出。
    func requestCancel(source: CancelTriggerSource) {
        if numberingEditorField != nil {
            cancelNumberingEditing()
            return
        }
        let hasAnnotations = !(editorState?.annotations.isEmpty ?? true)
        let shouldGuard = hasAnnotations && (appSettings?.confirmCancelWithAnnotations == true)
        if shouldGuard {
            let now = ContinuousClock.now
            if let last = lastCancelPromptTime, (now - last) < .milliseconds(1800) {
                lastCancelPromptTime = nil
                onCancel?()
                return
            }
            lastCancelPromptTime = now
            let hint: String
            switch source {
            case .escapeKey:
                hint = "再按一次 Esc 退出并放弃标注"
            case .rightClick:
                hint = "再点一次右键退出并放弃标注"
            case .toolbar:
                hint = "再点一次 ✕ 退出并放弃标注"
            }
            ToastPresenter.show(hint, on: window?.screen)
            return
        }
        lastCancelPromptTime = nil
        onCancel?()
    }

    // MARK: - 鼠标事件

    override func mouseDown(with event: NSEvent) {
        flushPendingNudgeTransaction()
        let point = convert(event.locationInWindow, from: nil)
        // 新手势从「没有改动几何」开始；真正改动发生在 `mouseDragged`。
        selectionGestureChangedGeometry = false
        pendingDrawingHitAnnotationID = nil
        pendingDrawingDownPoint = nil
        resizingInitialRect = nil
        preCreatingSelectionRect = nil

        // 选取模式下的按下不作决定：它是「点击锁定目标」的前半段，由 `mouseUp` 落实。
        if recordingPick.isActive {
            recordingPick.markGestureDown()
            _ = updateRecordingPick(at: point)
            return
        }

        // 准备阶段（面板已弹出）：截图侧的一切交互暂停。
        if isRecordSetupActive { return }

        // 独立窗体捕获模式：在鼠标抬起时提交窗口捕获，按下阶段仅刷新光标下候选。
        if isWindowPickerMode {
            updateWindowPicker(at: point, resetIndex: false)
            return
        }

        // 按下即取消挂起的后台 AX 控件查询，防止滞后结果覆写用户开始拖拽的选区。
        detectionSession?.cancelPendingControlLookup()

        // 点工具栏是设置操作，不应顺手把刚输入的文字提交掉。
        if isPointInsideToolbar(point) {
            return
        }

        // 点击画布时自动收起取色面板并归还焦点。
        if colorPicker.isPresented {
            dismissColorPanel()
        }

        // 左下角快捷微提示与 `?` 速查卡命中：优先处理，不穿透到画布。
        if let hudHit = OverlayShortcutHUD.hitTest(point, state: shortcutHUDState()) {
            switch hudHit {
            case .toggleCheatSheet:
                isShortcutCheatSheetVisible.toggle()
            case .toggleHintVisibility:
                let current = appSettings?.showOverlayShortcutHint ?? true
                appSettings?.setShowOverlayShortcutHint(!current)
                if current {
                    // 选择不再显示左下角提示后顺手收起速查卡并告知随时可按 ? 再次打开。
                    isShortcutCheatSheetVisible = false
                    ToastPresenter.show(
                        AnShotLocalization.isEnglish
                            ? "Hint hidden (press ? anytime for shortcuts)"
                            : "已隐藏底部提示（随时按 ? 查看快捷键）",
                        on: window?.screen
                    )
                } else {
                    needsDisplay = true
                }
            case .cheatSheetBody:
                break
            }
            updateCursor(at: point)
            return
        }

        // 速查卡展开时点击画布其余任意处先自动收起。
        if isShortcutCheatSheetVisible {
            isShortcutCheatSheetVisible = false
        }

        // 点击编号数字输入框外部时自动提交数字编辑。
        if let numField = numberingEditorField, !numField.frame.contains(point) {
            commitNumberingEditing()
        }

        // 点击输入控件之外时先结束编辑（与常见文本输入行为一致）。
        if editorState?.isEditingText == true, !isPointInTextEditor(point) {
            commitTextEditing()
        }

        // 静默首帧下双击空白处：快捷选中整屏并确认。
        if effectiveSelection == nil, !isSelectionConfirmed, event.clickCount >= 2,
           bounds.width >= decoration.minimumSelectionSize,
           bounds.height >= decoration.minimumSelectionSize {
            selectionRect = bounds
            onSelectionChanged?(bounds)
            onSelectionCommitted?(bounds)
            return
        }

        // 候选选区上的按下：先不做决定。
        if let selection = effectiveSelection,
           selection.contains(point),
           !isSelectionConfirmed {
            pendingCandidate = (selection, currentDetectionTarget)
            interaction = .pending(anchor: point)
            NSCursor.crosshair.set()
            return
        }

        // 确认态下按住 Space 拖动选区内部：随时平移整个选区（无论当前使用何种绘图工具）。
        if isSelectionConfirmed, isSpaceKeyPressed,
           let selection = effectiveSelection, selection.contains(point) {
            interaction = .moving(
                grabOffset: CGPoint(x: point.x - selection.minX, y: point.y - selection.minY)
            )
            NSCursor.closedHand.set()
            return
        }

        // 绘制优先 + 无缝直编（确认态全工具统一生效，判定顺序与 `updateCursor` 严格一致）：
        // 1) 命中当前选中标注的控制手柄（不受选区边界裁切，保证贴边控点 360° 可拖）；
        // 2) 选区内双击文字 / 编号直接就地编辑；
        // 3) 命中可直接拖动的标注（刚画好/已选中的标注含空心框内部、非背景型已有标注、或按住 ⌘/⌃）直接选中并平移；
        // 4) 命中截图选区 8 个边角缩放手柄（即使在绘图工具下也可顺手微调截图边界）；
        // 5) 选区内其余区域：绘图工具新建标注，指针工具拖动选区；
        // 6) 选区外暗区：已有标注时仅取消选中并保护原选区，尚无标注时进入 `.pendingRecreate` 防误点清空。
        if let selection = effectiveSelection, isSelectionConfirmed {
            if let editorState {
                if let annoHandle = annotationControlHandle(at: point) {
                    editorState.beginEditTransaction()
                    interaction = .resizingAnnotation(handle: annoHandle)
                    return
                }

                let inSelection = selection.contains(point)
                if inSelection, event.clickCount >= 2 {
                    if beginEditingExistingText(at: point) { return }
                    if beginEditingExistingNumbering(at: point) { return }
                }

                let pixel = pixelPoint(from: point)
                let tolerance = Double(Self.annotationHitTolerance) * Double(backdropScale)
                let flags = event.modifierFlags
                let forceMove = flags.contains(.command) || flags.contains(.control)

                if inSelection || editorState.hasSelectedAnnotation,
                   let moveTarget = editorState.directMoveTarget(
                       at: pixel,
                       tolerance: tolerance,
                       forceMove: forceMove
                   ) {
                    editorState.selectAnnotation(id: moveTarget.id)
                    toolbar.expandPanelForInteraction()
                    editorState.beginEditTransaction()
                    interaction = .movingAnnotation(lastPixel: pixel)
                    NSCursor.closedHand.set()
                    return
                }

                // 选区 8 个调整手柄：未命中标注控点及可直接拖动标注时，绘图工具下也可直接缩放截图选区。
                if let hit = handle(at: point, in: selection) {
                    resizingInitialRect = selection
                    interaction = .resizing(handle: hit)
                    SelectionCursor.cursor(for: hit).set()
                    return
                }

                // 选区外侧「尺寸胶囊」平移把手（严格在选区边角缩放手柄之后，绝不抢占改选区大小）：
                // 任意标注工具下按住尺寸胶囊即可直接平移整个截图框，无需切回指针或按住 Space。
                if let labelRect = sizeLabelDragRect(), labelRect.contains(point) {
                    isDraggingSizeLabel = true
                    interaction = .moving(
                        grabOffset: CGPoint(x: point.x - selection.minX, y: point.y - selection.minY)
                    )
                    NSCursor.closedHand.set()
                    return
                }

                if inSelection {
                    if editorState.tool == .pointer {
                        editorState.clearAnnotationSelection()
                        // 指针态双击选区内空白直接复制完成。
                        if event.clickCount >= 2 {
                            performExport(.copy)
                            return
                        }
                        interaction = .moving(
                            grabOffset: CGPoint(x: point.x - selection.minX, y: point.y - selection.minY)
                        )
                        NSCursor.closedHand.set()
                        return
                    }

                    // 绘图工具下双击空白区域（未命中任何标注，且非文字/编号工具）直接复制完成。
                    let hitExisting = editorState.annotation(at: pixel, tolerance: tolerance)
                    if event.clickCount >= 2, hitExisting == nil, editorState.tool != .text, editorState.tool != .numbering {
                        performExport(.copy)
                        return
                    }

                    if editorState.tool == .text {
                        guard !editorState.isEditingText else { return }
                        toolbar.collapsePanelForDrawing()
                        editorState.clearAnnotationSelection()
                        editorState.beginTextEditing(at: pixel)
                        syncTextEditor()
                        return
                    }

                    if editorState.tool.isDraggable {
                        // 记录潜在点击选中目标：若松手位移 < 3pt 则不建空草稿而是选中已有标注。
                        if let hitExisting {
                            pendingDrawingHitAnnotationID = hitExisting.id
                            pendingDrawingDownPoint = point
                        }
                        editorState.beginDraft(at: pixel, scaleFactor: backdropScale)
                        return
                    }
                } else {
                    // 点击已确认选区外暗区：先取消标注选中；若已有标注则锁定选区防误清，无标注时允许拖动重框。
                    editorState.clearAnnotationSelection()
                    if !editorState.annotations.isEmpty {
                        updateCursor(at: point)
                        return
                    }
                    interaction = .pendingRecreate(anchor: point, previousSelection: selection)
                    NSCursor.crosshair.set()
                    return
                }
            } else {
                // 无编辑器（如早期诊断视图）保留原有选区手柄/移动/重框路径。
                if let hit = handle(at: point, in: selection) {
                    resizingInitialRect = selection
                    interaction = .resizing(handle: hit)
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
        }

        // 其余位置（无选区或未确认候选之外）开始新建选区。
        interaction = .creating(anchor: point)
        NSCursor.crosshair.set()
        selectionRect = CGRect(origin: point, size: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = SelectionGeometry.clamp(convert(event.locationInWindow, from: nil), to: bounds)

        if updateRecordingPick(at: point) { return }
        if isRecordSetupActive || isWindowPickerMode { return }

        let isShiftPressed = event.modifierFlags.contains(.shift)

        switch interaction {
        case .idle:
            // 绘制模式下的拖拽不改变选区，只更新未提交的草稿；将点夹在当前选区内，防止标注越界画进暗区。
            if editorState?.hasDraft == true {
                toolbar.collapsePanelForDrawing()
                let clampedPoint = effectiveSelection.map { SelectionGeometry.clamp(point, to: $0) } ?? point
                editorState?.updateDraft(to: pixelPoint(from: clampedPoint), isShiftPressed: isShiftPressed)
            }
            return

        case .movingAnnotation(let lastPixel):
            let current = pixelPoint(from: point)
            let delta = PixelPoint(x: current.x - lastPixel.x, y: current.y - lastPixel.y)
            guard delta != PixelPoint.zero else { return }
            toolbar.collapsePanelForDrawing()
            editorState?.moveSelected(by: delta)
            interaction = .movingAnnotation(lastPixel: current)
            return

        case .resizingAnnotation(let handle):
            toolbar.collapsePanelForDrawing()
            editorState?.updateSelectedControlHandle(
                handle,
                to: pixelPoint(from: point),
                isShiftPressed: isShiftPressed
            )
            return

        case .pending(let anchor):
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            guard hypot(dx, dy) >= pendingDragThreshold else { return }
            interaction = .creating(anchor: anchor)
            let target = Self.constrainedSelectionPoint(point, from: anchor, in: bounds, isShiftPressed: isShiftPressed)
            selectionRect = SelectionGeometry.normalizedRect(from: anchor, to: target)
            selectionGestureChangedGeometry = true

        case .pendingRecreate(let anchor, let previousSelection):
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            guard hypot(dx, dy) >= pendingDragThreshold else { return }
            preCreatingSelectionRect = previousSelection
            interaction = .creating(anchor: anchor)
            let target = Self.constrainedSelectionPoint(point, from: anchor, in: bounds, isShiftPressed: isShiftPressed)
            selectionRect = SelectionGeometry.normalizedRect(from: anchor, to: target)
            selectionGestureChangedGeometry = true

        case .creating(let anchor):
            let target = Self.constrainedSelectionPoint(point, from: anchor, in: bounds, isShiftPressed: isShiftPressed)
            selectionRect = SelectionGeometry.normalizedRect(from: anchor, to: target)
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
            var resized = SelectionGeometry.resizedRect(
                current,
                handle: handle,
                to: point,
                minimumSize: decoration.minimumSelectionSize
            )
            // Shift 等比缩放选区：拖动四角手柄时严格保持起始选区宽高比。
            if isShiftPressed, SelectionHandleLayout.isCorner(handle),
               let initial = resizingInitialRect, initial.height > 0 {
                let aspect = initial.width / initial.height
                resized = Self.aspectConstrainedResizedRect(
                    resized,
                    anchorRect: initial,
                    handle: handle,
                    aspect: aspect,
                    minimumSize: decoration.minimumSelectionSize,
                    in: bounds
                )
            }
            selectionRect = resized
            selectionGestureChangedGeometry = true
        }

        updateLoupe(at: point)

        if let selection = effectiveSelection {
            onSelectionChanged?(selection)
        }
    }

    /// 选区四角手柄按 `Shift` 等比缩放时的矩形约束（以对角锚点为固定基准）。
    private static func aspectConstrainedResizedRect(
        _ proposed: CGRect,
        anchorRect: CGRect,
        handle: SelectionHandle,
        aspect: CGFloat,
        minimumSize: CGFloat,
        in bounds: CGRect
    ) -> CGRect {
        guard aspect > 0 else { return proposed }
        let anchorX = handle.movesLeftEdge ? anchorRect.maxX : anchorRect.minX
        let anchorY = handle.movesTopEdge ? anchorRect.maxY : anchorRect.minY

        let widthFromHeight = proposed.height * aspect
        var width: CGFloat
        var height: CGFloat
        if proposed.width >= widthFromHeight {
            width = max(minimumSize, proposed.width)
            height = max(minimumSize, width / aspect)
        } else {
            height = max(minimumSize, proposed.height)
            width = max(minimumSize, height * aspect)
        }

        let maxW = handle.movesLeftEdge ? (anchorX - bounds.minX) : (bounds.maxX - anchorX)
        let maxH = handle.movesTopEdge ? (anchorY - bounds.minY) : (bounds.maxY - anchorY)
        let scale = min(1, maxW / max(1, width), maxH / max(1, height))
        width = max(minimumSize, width * scale)
        height = max(minimumSize, height * scale)

        let originX = handle.movesLeftEdge ? (anchorX - width) : anchorX
        let originY = handle.movesTopEdge ? (anchorY - height) : anchorY
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    override func mouseUp(with event: NSEvent) {
        if recordingPick.consumeGestureDown() {
            if recordingPick.isActive {
                let point = convert(event.locationInWindow, from: nil)
                let target = recordingPick.accept(hitTarget(at: point))
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

        if isRecordSetupActive {
            if let editorState, editorState.hasDraft {
                editorState.discardDraft()
            }
            return
        }

        // 独立窗体模式：单击即捕获当前高亮窗口，按住 `⌥` 反转阴影设置。
        if isWindowPickerMode {
            let point = convert(event.locationInWindow, from: nil)
            if windowPickerCandidates.isEmpty {
                updateWindowPicker(at: point, resetIndex: true)
            }
            if windowPickerIndex < windowPickerCandidates.count {
                let target = windowPickerCandidates[windowPickerIndex]
                onWindowPickerCommit?(target, event.modifierFlags.contains(.option))
            } else {
                NSSound.beep()
            }
            return
        }

        // 拖动标注或控制手柄：松手时将整段连续改动合并提交为单条撤销记录。
        switch interaction {
        case .movingAnnotation, .resizingAnnotation:
            editorState?.commitEditTransaction()
            interaction = .idle
            updateCursor(at: convert(event.locationInWindow, from: nil))
            return
        default:
            break
        }

        let point = convert(event.locationInWindow, from: nil)

        // 绘制优先 + 无缝直编：绘图工具下单击位移 < 3pt 且按下时命中了已有标注 → 丢弃空草稿并选中该标注。
        if let editorState, editorState.hasDraft {
            if let hitID = pendingDrawingHitAnnotationID,
               let downPoint = pendingDrawingDownPoint,
               hypot(point.x - downPoint.x, point.y - downPoint.y) < 3 {
                pendingDrawingHitAnnotationID = nil
                pendingDrawingDownPoint = nil
                editorState.discardDraft()
                editorState.selectAnnotation(id: hitID)
                toolbar.expandPanelForInteraction()
                updateCursor(at: point)
                return
            }
            pendingDrawingHitAnnotationID = nil
            pendingDrawingDownPoint = nil

            if effectiveSelection == nil {
                editorState.discardDraft()
            } else if !editorState.commitDraft() {
                // 空白处轻点（未拖出有效新标注）：清除当前选中态，避免残留虚线框。
                editorState.clearAnnotationSelection()
            }
            updateCursor(at: point)
            return
        }

        let wasPending: Bool = {
            if case .pending = interaction { return true }
            return false
        }()
        let wasPendingRecreate: Bool = {
            if case .pendingRecreate = interaction { return true }
            return false
        }()
        let wasCreating = isCreating
        let previousConfirmedSelection = preCreatingSelectionRect
        preCreatingSelectionRect = nil
        resizingInitialRect = nil
        isDraggingSizeLabel = false
        interaction = .idle
        updateCursor(at: point)
        updateLoupe(at: point)

        if wasPendingRecreate {
            return
        }

        if wasPending {
            pendingCandidate = nil
            editorState?.confirmSelection()
            if let confirmed = effectiveSelection {
                onSelectionCommitted?(confirmed)
            }
            return
        }

        guard let selection = effectiveSelection,
              selection.width >= decoration.minimumSelectionSize,
              selection.height >= decoration.minimumSelectionSize else {
            if wasCreating {
                if let candidate = pendingCandidate {
                    selectionRect = candidate.rect
                    currentDetectionTarget = candidate.target
                    pendingCandidate = nil
                    onSelectionChanged?(candidate.rect)
                } else if let previousConfirmedSelection {
                    selectionRect = previousConfirmedSelection
                    onSelectionChanged?(previousConfirmedSelection)
                } else {
                    selectionRect = nil
                    onSelectionChanged?(nil)
                }
            }
            return
        }

        if selectionGestureChangedGeometry {
            currentDetectionTarget = nil
        }
        pendingCandidate = nil
        onSelectionChanged?(selection)
        onSelectionCommitted?(selection)
    }

    override func rightMouseDown(with event: NSEvent) {
        if recordingPick.isActive {
            endRecordingTargetPick()
            onRecordingPickCancel?()
            return
        }
        if isRecordSetupActive {
            onRecordSetupCancel?()
            return
        }

        // 无缝直编：任意工具下右击已有标注均弹出层级/复制/删除上下文菜单。
        let point = convert(event.locationInWindow, from: nil)
        if let editorState,
           isSelectionConfirmed,
           let selection = effectiveSelection,
           selection.contains(point) {
            let pixel = pixelPoint(from: point)
            let tolerance = Double(Self.annotationHitTolerance) * Double(backdropScale)
            if editorState.selectAnnotation(at: pixel, tolerance: tolerance) {
                presentAnnotationContextMenu(for: event)
                return
            }
        }

        requestCancel(source: .rightClick)
    }

    /// 滚轮交互：
    /// - 未确认选区且悬停命中控件时：沿当前 AX 父级链逐层放大/缩小吸附范围（如 按钮 ↔ 卡片 ↔ 面板 ↔ 窗口）；
    /// - 已确认选区时：有选中标注调整其线宽/字号/模糊强度/压暗度/半径，无选中调整当前工具默认参数；
    /// - 独立图片/长截图滚动编辑窗内：普通滚轮交由 `NSScrollView` 浏览长图，按住 `⌥ + 滚轮` 调参。
    override func scrollWheel(with event: NSEvent) {
        if enclosingScrollView != nil, !event.modifierFlags.contains(.option) {
            super.scrollWheel(with: event)
            return
        }

        // 未确认候选态：滚轮在 AX 控件层级链上逐层扩大 / 缩小吸附范围。
        if !isSelectionConfirmed,
           !isInteracting,
           !isWindowPickerMode,
           !isRecordSetupActive,
           !recordingPick.isActive,
           let session = detectionSession,
           session.controlHierarchyCount > 1 {
            let rawDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : (event.scrollingDeltaY * 10)
            guard abs(rawDelta) > 0.01 else { return }
            let stepDirection: Double?
            if event.hasPreciseScrollingDeltas {
                wheelDeltaAccumulator += rawDelta
                guard abs(wheelDeltaAccumulator) >= 14 else { return }
                stepDirection = wheelDeltaAccumulator > 0 ? 1.0 : -1.0
                wheelDeltaAccumulator = 0
            } else {
                stepDirection = rawDelta > 0 ? 1.0 : -1.0
            }
            if let dir = stepDirection,
               let nextTarget = session.stepControlHierarchy(expand: dir > 0) {
                applyDetectionTarget(nextTarget)
            }
            return
        }

        guard let editorState,
              isSelectionConfirmed,
              !isRecordSetupActive,
              !recordingPick.isActive,
              !editorState.isEditingText,
              numberingEditorField == nil else {
            super.scrollWheel(with: event)
            return
        }

        let rawDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : (event.scrollingDeltaY * 10)
        guard abs(rawDelta) > 0.01 else { return }

        if event.hasPreciseScrollingDeltas {
            wheelDeltaAccumulator += rawDelta
            let threshold: CGFloat = 10
            guard abs(wheelDeltaAccumulator) >= threshold else { return }
            let step = wheelDeltaAccumulator > 0 ? 1.0 : -1.0
            wheelDeltaAccumulator = 0
            _ = editorState.adjustParameterByScrollWheel(delta: step, scaleFactor: backdropScale)
        } else {
            let step = rawDelta > 0 ? 1.0 : -1.0
            _ = editorState.adjustParameterByScrollWheel(delta: step, scaleFactor: backdropScale)
        }
    }

    /// 弹出选中标注的层级与操作上下文菜单。
    private func presentAnnotationContextMenu(for event: NSEvent) {
        let menu = NSMenu(title: "标注操作")
        let bringToFront = NSMenuItem(
            title: "置于顶层",
            action: #selector(contextBringToFront),
            keyEquivalent: ""
        )
        bringToFront.target = self
        let sendToBack = NSMenuItem(
            title: "置于底层",
            action: #selector(contextSendToBack),
            keyEquivalent: ""
        )
        sendToBack.target = self
        let duplicate = NSMenuItem(
            title: "复制标注",
            action: #selector(contextDuplicateAnnotation),
            keyEquivalent: "d"
        )
        duplicate.keyEquivalentModifierMask = [.command]
        duplicate.target = self
        let delete = NSMenuItem(
            title: "删除标注",
            action: #selector(contextDeleteAnnotation),
            keyEquivalent: ""
        )
        delete.target = self

        menu.addItem(bringToFront)
        menu.addItem(sendToBack)
        menu.addItem(.separator())
        menu.addItem(duplicate)
        menu.addItem(delete)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextBringToFront() {
        _ = editorState?.bringSelectedToFront()
    }

    @objc private func contextSendToBack() {
        _ = editorState?.sendSelectedToBack()
    }

    @objc private func contextDuplicateAnnotation() {
        _ = editorState?.duplicateSelected()
    }

    @objc private func contextDeleteAnnotation() {
        _ = editorState?.deleteSelected()
    }

    /// Shift 拖拽新建选区时的正方形约束，限制在视图边界内。
    private static func constrainedSelectionPoint(
        _ point: CGPoint,
        from anchor: CGPoint,
        in bounds: CGRect,
        isShiftPressed: Bool
    ) -> CGPoint {
        guard isShiftPressed else { return point }
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let rawSide = max(abs(dx), abs(dy))
        let maxWidth = dx >= 0 ? (bounds.maxX - anchor.x) : (anchor.x - bounds.minX)
        let maxHeight = dy >= 0 ? (bounds.maxY - anchor.y) : (anchor.y - bounds.minY)
        let side = min(rawSide, max(0, min(maxWidth, maxHeight)))
        return CGPoint(
            x: anchor.x + (dx >= 0 ? side : -side),
            y: anchor.y + (dy >= 0 ? side : -side)
        )
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

        // 文字编辑或编号数字编辑期间键盘归输入控件。
        if editorState?.isEditingText == true || numberingEditorField != nil {
            if event.keyCode == 53, numberingEditorField != nil {
                cancelNumberingEditing()
                return
            }
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags
        let hasCommandLike = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)

        // 49 = Space：
        // - 未确认选区态（非拖拽）：在「区域框选」与「独立窗体捕获」之间切换；
        // - 已确认选区态：按住空格进入临时抓手平移选区（不打断当前标注工具）。
        if event.keyCode == 49, !hasCommandLike, !event.isARepeat {
            if !isSelectionConfirmed, !isInteracting {
                let next = !isWindowPickerMode
                isWindowPickerMode = next
                onWindowPickerModeChanged?(next)
                if next, let window {
                    let mousePoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                    updateWindowPicker(at: mousePoint, resetIndex: true)
                    NSCursor.pointingHand.set()
                } else {
                    clearPreviewCandidate()
                    if let window {
                        let mousePoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                        updateCursor(at: mousePoint)
                        updateDetection(at: mousePoint)
                        updateLoupe(at: mousePoint)
                    }
                }
                return
            }
            if isSelectionConfirmed {
                isSpaceKeyPressed = true
                if let window {
                    let mousePoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                    updateCursor(at: mousePoint)
                }
                return
            }
        }

        // 48 = Tab：独立窗体模式下在光标下方全部叠放窗口间循环穿透（⇧Tab 反向）。
        if event.keyCode == 48, isWindowPickerMode, !hasCommandLike {
            _ = cycleWindowPickerCandidate(reverse: flags.contains(.shift))
            return
        }

        // 窗体模式下回车直接捕获当前高亮窗口。
        if isWindowPickerMode, (event.keyCode == 36 || event.keyCode == 76) {
            if windowPickerIndex < windowPickerCandidates.count {
                onWindowPickerCommit?(windowPickerCandidates[windowPickerIndex], flags.contains(.option))
            } else {
                NSSound.beep()
            }
            return
        }

        // 速查卡展开时按 Esc 优先收起速查卡，不误退出截图。
        if isShortcutCheatSheetVisible, event.keyCode == 53 {
            isShortcutCheatSheetVisible = false
            return
        }

        // `?`（含中文输入法下 `？`）切换完整快捷键速查卡。
        if !flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
           let chars = event.characters, chars == "?" || chars == "？" {
            isShortcutCheatSheetVisible.toggle()
            return
        }

        // Delete / Backspace 删除选中的标注（任意工具下只要有选中即生效）。
        if let editorState, editorState.hasSelectedAnnotation,
           event.keyCode == 51 || event.keyCode == 117 {
            editorState.deleteSelected()
            return
        }

        #if DEBUG
        let exportKeyCode = event.keyCode == 36 || event.keyCode == 76
        let isCommandS = flags.contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "s"
        let isCommandC = flags.contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "c"
        if exportKeyCode || isCommandS || isCommandC {
            logger.notice("""
                overlay keyDown: keyCode=\(event.keyCode, privacy: .public) \
                chars=\(event.charactersIgnoringModifiers ?? "-", privacy: .public) \
                editingText=\(self.editorState?.isEditingText == true, privacy: .public)
                """)
        }
        #endif

        // 专职取色键：C 复制 #HEX，⇧C 复制 RGB(r, g, b)（已解除与曲线箭头快捷键的冲突）。
        if !hasCommandLike,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copyColorUnderPointer(asRGB: flags.contains(.shift))
            return
        }

        // 命令识别与执行分开：识别在 `OverlayKeyCommand`（纯查表，可独立断言），
        // 这里只做执行。上面几段已经决定了「键盘属于谁」，到这里仍是本视图的。
        guard let command = OverlayKeyCommand.parse(event) else {
            super.keyDown(with: event)
            return
        }
        guard command == .cancel || editorState != nil else {
            super.keyDown(with: event)
            return
        }
        performCommand(command)
    }

    override func resignFirstResponder() -> Bool {
        clearSpaceKeyState()
        return super.resignFirstResponder()
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, isSpaceKeyPressed {
            isSpaceKeyPressed = false
            if let window {
                let mousePoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                updateCursor(at: mousePoint)
            }
            return
        }
        super.keyUp(with: event)
    }

    /// 候选态取色：复制当前光标下像素的 `#RRGGBB` 或 `RGB(r, g, b)` 色值到剪贴板并弹 Toast。
    private func copyColorUnderPointer(asRGB: Bool = false) {
        let sample: LoupeSample?
        if let cached = lastLoupeSample {
            sample = cached
        } else if let backdrop, let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            sample = OverlayLoupeSampler.sample(from: backdrop, at: point, scaleFactor: backdropScale)
        } else {
            sample = nil
        }

        guard let sample else {
            NSSound.beep()
            return
        }
        let text = asRGB ? sample.rgbText : sample.hexString
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.setString(text, forType: .string)
        if ok {
            ToastPresenter.show("已复制色值 \(text)", on: window?.screen)
        } else {
            NSSound.beep()
        }
    }

    /// 执行一条按键命令。
    func performCommand(_ command: OverlayKeyCommand) {
        guard command == .cancel || editorState != nil else { return }
        // 非微调命令执行前先落盘挂起的键盘微调事务，保证撤销/导出/复制读取到一致历史。
        switch command {
        case .nudge, .resizeSelection:
            break
        default:
            flushPendingNudgeTransaction()
        }
        switch command {
        case .cancel:
            requestCancel(source: .escapeKey)
        case .save:
            performExport(.save)
        case .copy:
            performExport(.copy)
        case .pin:
            performExport(.pin)
        case .duplicate:
            if editorState?.duplicateSelected() != true {
                NSSound.beep()
            }
        case .nudge(let dx, let dy):
            performNudge(dx: dx, dy: dy)
        case .resizeSelection(let dw, let dh):
            performResizeSelection(dw: dw, dh: dh)
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
            // 候选态按单键切工具时自动锁定当前候选选区，无需额外先点一次。
            if !isSelectionConfirmed, let selection = effectiveSelection {
                editorState?.confirmSelection()
                onSelectionCommitted?(selection)
            }
            editorState?.select(tool)
            if tool != .pointer || editorState?.hasSelectedAnnotation == true {
                toolbar.expandPanelForInteraction()
            }
            if colorPicker.isPresented,
               editorState?.style.color(for: tool) == nil {
                dismissColorPanel()
            }
            if let window {
                let mousePoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                updateCursor(at: mousePoint)
                updateLoupe(at: mousePoint)
            }
        }
    }

    /// 将键盘连续微调（方向键移动标注或微调选区）合并提交为单条撤销记录。
    private func flushPendingNudgeTransaction() {
        nudgeCommitWorkItem?.cancel()
        nudgeCommitWorkItem = nil
        if editorState?.isInEditTransaction == true {
            editorState?.commitEditTransaction()
        }
        if let pendingRect = pendingSelectionNudgeRect {
            pendingSelectionNudgeRect = nil
            onSelectionCommitted?(pendingRect)
        }
    }

    private func scheduleNudgeTransactionCommit() {
        nudgeCommitWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushPendingNudgeTransaction()
        }
        nudgeCommitWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// 方向键微调选中标注或当前选区（单位：1px，Shift 为 10px；400ms 内连续按键合并为单条撤销记录）。
    private func performNudge(dx: Int, dy: Int) {
        guard let editorState else { return }
        if editorState.hasSelectedAnnotation {
            if !editorState.isInEditTransaction {
                editorState.beginEditTransaction()
            }
            editorState.moveSelected(by: PixelPoint(x: Double(dx), y: Double(dy)))
            scheduleNudgeTransactionCommit()
            return
        }
        guard let selection = effectiveSelection else { return }
        if !isSelectionConfirmed {
            editorState.confirmSelection()
        }
        let scale = max(1, pixelsPerPoint)
        let moved = CGRect(
            x: selection.minX + CGFloat(dx) / scale,
            y: selection.minY + CGFloat(dy) / scale,
            width: selection.width,
            height: selection.height
        )
        let clamped = SelectionGeometry.clamp(moved, to: bounds)
        selectionRect = clamped
        pendingSelectionNudgeRect = clamped
        onSelectionChanged?(clamped)
        scheduleNudgeTransactionCommit()
    }

    /// `⌥ + 方向键`（配 `⇧` 为 5px）精准微调当前选区宽/高（连续按键合并为单条撤销记录）。
    private func performResizeSelection(dw: Int, dh: Int) {
        guard let editorState, let selection = effectiveSelection else { return }
        if !isSelectionConfirmed {
            editorState.confirmSelection()
        }
        let scale = max(1, pixelsPerPoint)
        let minSize = decoration.minimumSelectionSize
        let maxW = max(minSize, bounds.maxX - selection.minX)
        let maxH = max(minSize, bounds.maxY - selection.minY)
        let nextWidth = min(max(minSize, selection.width + CGFloat(dw) / scale), maxW)
        let nextHeight = min(max(minSize, selection.height + CGFloat(dh) / scale), maxH)
        let resized = CGRect(
            x: selection.minX,
            y: selection.minY,
            width: nextWidth,
            height: nextHeight
        )
        selectionRect = resized
        pendingSelectionNudgeRect = resized
        onSelectionChanged?(resized)
        scheduleNudgeTransactionCommit()
    }
}

// MARK: - 覆盖层窗口

/// 铺满单块显示器的非激活面板。
final class OverlayWindow: NSPanel, NSWindowDelegate {

    /// 用户点击系统关闭按钮（红叉）或通过 `performClose` 关窗时的回调。
    var onWindowWillClose: (() -> Void)?

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
    /// 是否为全屏冻结覆盖层（区别于独立图片/窗体编辑窗口）。
    private let isFullScreenOverlay: Bool

    /// 图片编辑模式的窗口。
    ///
    /// 与截图覆盖层共用同一套 `OverlayView`（选区、标注、工具栏、导出），
    /// 区别只在窗口尺寸与层级：这里不是铺满一块屏，而是围着图片本身；
    /// 通过居中 `NSScrollView` 承载严格等比的 `OverlayView`，既避免小图被单边拉扁，
    /// 又让超长截图可以按 1:1 清晰度滚轮浏览与精准标注。
    private var scrollBoundsObserver: NSObjectProtocol?

    init(imageFrame: NSRect, canvasSize: CGSize? = nil, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.isFullScreenOverlay = false
        let effectiveCanvasSize = canvasSize ?? imageFrame.size
        self.overlayView = OverlayView(
            frame: NSRect(origin: .zero, size: effectiveCanvasSize),
            displayID: displayID
        )

        super.init(
            contentRect: imageFrame,
            // 图片编辑器需要可见的关闭按钮：它不像截图覆盖层那样按 ESC 就走，
            // 用户可能在这里停留很久。标题栏同时给出「这是一张图」的身份。
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        title = "编辑图片"
        isOpaque = true
        backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        level = .floating
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // 图片编辑器允许被外部录屏看到：用户可能正是在给教程录素材。
        sharingType = .readOnly
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = false
        contentMinSize = CGSize(
            width: min(360, imageFrame.width),
            height: min(240, imageFrame.height)
        )
        collectionBehavior = [.fullScreenAuxiliary, .stationary]
        delegate = self

        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: imageFrame.size))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        scrollView.hasVerticalScroller = effectiveCanvasSize.height > imageFrame.height + 1
        scrollView.hasHorizontalScroller = effectiveCanvasSize.width > imageFrame.width + 1
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let clipView = CenteredClipView(frame: scrollView.bounds)
        clipView.drawsBackground = true
        clipView.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        clipView.postsBoundsChangedNotifications = true
        scrollView.contentView = clipView
        scrollView.documentView = overlayView
        // 初始定位到顶部，超长截图打开后从最上方开始阅读与标注。
        overlayView.scroll(.zero)

        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak overlayView] _ in
            MainActor.assumeIsolated {
                overlayView?.refreshToolbar()
            }
        }

        contentView = scrollView
    }

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.isFullScreenOverlay = true
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
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
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

    /// 全屏冻结覆盖层原样保持 `screen.frame`，杜绝 macOS 避让菜单栏把窗口向下推 24–37pt 造成的画面跳动。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if isFullScreenOverlay {
            return frameRect
        }
        return super.constrainFrameRect(frameRect, to: screen)
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

    /// 非文字编辑态下优先响应覆盖层画布级快捷键，避免被常驻 Edit 主菜单吞掉 ⌘C / ⌘Z。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !overlayView.isEditingText,
           !overlayView.isRecordSetupActive,
           !overlayView.isRecordingPickActive,
           event.modifierFlags.contains(.command),
           let command = OverlayKeyCommand.parse(event) {
            overlayView.performCommand(command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func windowWillClose(_ notification: Notification) {
        overlayView.clearSpaceKeyState()
        if let observer = scrollBoundsObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollBoundsObserver = nil
        }
        onWindowWillClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        overlayView.clearSpaceKeyState()
    }

    func windowDidResize(_ notification: Notification) {
        overlayView.refreshToolbar()
    }
}

/// 当文档视图尺寸小于滚动视口时自动居中的 `NSClipView`（用于独立图片编辑窗口展示小图不拉伸）。
private final class CenteredClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrained }
        let docFrame = documentView.frame
        if constrained.width > docFrame.width {
            constrained.origin.x = -((constrained.width - docFrame.width) / 2).rounded()
        }
        if constrained.height > docFrame.height {
            constrained.origin.y = -((constrained.height - docFrame.height) / 2).rounded()
        }
        return constrained
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

