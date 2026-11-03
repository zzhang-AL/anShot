import AppKit
import AnShotCapture
import AnShotCore

/// 可选的录制范围类型。
///
/// 面板的选项与覆盖层的「目标选取」共用这一套标识：两处各定义一个等价枚举，
/// 接线时就要写一层转换，而枚举的对应关系恰恰是最容易写错、又最难被发现的地方
/// （写错时表现是「选了窗口却按应用录」）。
public enum RecordingScopeKind: String, CaseIterable, Sendable {
    /// 当前截图选区。
    case region
    /// 单个窗口。
    case window
    /// 一个应用在本显示器内的全部窗口。
    case application
    /// 整块显示器。
    case display

    /// 界面提示用的中文名。
    public var displayName: String {
        switch self {
        case .region: return "区域"
        case .window: return "窗口"
        case .application: return "应用"
        case .display: return "全屏"
        }
    }

    /// 是否需要用户点选一个具体目标（窗口 / 应用）才能成立。
    ///
    /// 区域与全屏的几何是现成的；窗口与应用必须先拿到**身份**
    /// （`windowID` / `processID`），而身份只能从一次命中测试里得到。
    public var requiresTarget: Bool {
        self == .window || self == .application
    }
}

/// 录制准备面板：在开始录制前确认「录哪块区域」与「录不录音」。
///
/// **为什么需要它**：截图工具栏的录制按钮只表达「我要录制」，
/// 而录制的两个关键参数——范围与音频——必须由用户确认：
///
/// - 范围：选区可能只是为一个截图而画的，不一定是用户想录的区域；
///   自动识别出的窗口/应用也需要用户明确选中才算数。
/// - 音频：系统内录与麦克风旁白各自独立开关（用户要求「可各自开关」），
///   且**首次使用的默认值是两个都勾选**——录屏一般都希望带声音，需要静音时
///   在面板上取消即可。之后按上次的选择恢复（`RecordingPreferencesStore`）；
///   输出格式同理。这三项都摆在面板上，所以「记住」不构成看不见的隐状态。
///
/// ── 面板不持有几何与身份 ──────────────────────────────────────
///
/// 面板只表达「选了哪种范围、目标选定了没有、音频开关是什么」，并把事件抛给
/// 控制器。原因有两层：
///
/// 1. 窗口/应用目标的矩形只在**命中那一刻**有效，且要经覆盖层窗口换算成
///    AppKit 屏幕坐标。面板既看不到 `DetectionTarget`，也拿不到那个换算。
/// 2. 曾经把 `CaptureScope` 与预览矩形一起存在选项里，于是「开始录制」时
///    带着的是**打开面板那一刻**算好的矩形——用户切到「全屏」后预览框虽然变了，
///    正式录制框仍回到旧区域。几何只有一个来源就不会出现这种错配。
///
/// 面板不抢键盘焦点（`nonactivatingPanel`），与录制控制条同一套 chrome 约定。
@MainActor
public final class RecordingSetupPanel: NSObject {

    /// 一个可选的录制范围。
    public struct ScopeOption {
        /// 范围类型。
        public let kind: RecordingScopeKind
        /// 按钮标题，如「区域」「窗口」「应用」「全屏」。
        public let title: String

        public init(kind: RecordingScopeKind, title: String) {
            self.kind = kind
            self.title = title
        }
    }

    /// 用户确认后的选择。
    ///
    /// 只带「范围类型」而不带 `CaptureScope`：范围与矩形由控制器按当前状态
    /// 现算（见类型注释末尾的说明）。同理只带「输出格式」而不带路径。
    public struct Outcome {
        public let kind: RecordingScopeKind
        public let audio: AudioSettings
        public let output: RecordingOutputChoice

        public init(kind: RecordingScopeKind, audio: AudioSettings, output: RecordingOutputChoice) {
            self.kind = kind
            self.audio = audio
            self.output = output
        }
    }

    /// 点击「开始录制」。
    public var onStart: ((Outcome) -> Void)?
    /// 点击「取消」。
    public var onCancel: (() -> Void)?
    /// 用户切换了范围类型：控制器据此决定是否进入目标选取。
    public var onKindChanged: ((RecordingScopeKind) -> Void)?
    /// 用户要求（重新）选取目标。参数为需要选目标的那个范围类型。
    public var onPickRequested: ((RecordingScopeKind) -> Void)?

    private let panel: NSPanel
    private let scopeControl: NSSegmentedControl
    private let outputControl: NSSegmentedControl
    private let durationPopup: NSPopUpButton
    private let dimensionPopup: NSPopUpButton
    private let gifNoSoundLabel: NSTextField
    private let systemAudioToggle: NSButton
    private let microphoneToggle: NSButton
    private let statusLabel: NSTextField
    private let pickButton: NSButton
    private let startButton: NSButton
    private var options: [ScopeOption] = []

    /// 已锁定的目标标题（窗口 / 应用）。缺项表示该范围尚未选定目标。
    private var lockedTitles: [RecordingScopeKind: String] = [:]
    /// 选取过程中的候选目标标题（鼠标下的对象）。
    private var candidateTitle: String?
    /// 是否正在等待用户点选目标。
    private var isPicking = false

    /// GIF 参数行。每次 `layout` 重建，故为可选。
    /// 持有它只为了诊断能断言「参数行确实随格式显隐」。
    private var gifParameterRow: NSStackView?

    /// 当前内容栈。同样只为诊断服务：面板高度是两个手算常量，
    /// 而「手算的值到底够不够」只能靠拿真实内容高度去比（否则就是本次的缺陷：
    /// 常量写小了，栈视图溢出到面板下缘之外，底部按钮被窗口裁掉、点不到）。
    private var contentStack: NSStackView?

    /// 面板内容区的上下内边距（与 `layout` 里的约束常量一致）。
    private static let contentVerticalInset: CGFloat = 14

    /// 面板是否可见。
    public var isVisible: Bool { panel.isVisible }

    /// 当前选中的范围类型。
    public var selectedKind: RecordingScopeKind? {
        guard !options.isEmpty else { return nil }
        let index = min(max(0, scopeControl.selectedSegment), options.count - 1)
        return options[index].kind
    }

    /// 两个面板尺寸。
    ///
    /// ⚠️ **高度不再手算，而是由内容决定**（见 `layout`）。以下是**下限**，
    /// 只在内容异常矮时才生效，避免面板塔陷。
    ///
    /// ── 为什么改掉固定的手算常量 ──────────────────────────────
    ///
    /// 首版把高度硬编码为 208 / 284。加入「输出格式」一行后内容涨到 214，
    /// 而常量仍是 208：**底部 34pt 溢出窗口，large 尺寸的「开始录制」被截掉**
    /// ——看得见但点不到（用户验收时实测报的缺陷）。
    /// 关键在于旧断言只比对窗口高度常量（`height == 208`），对裁切完全免疫：
    /// 断言的是「我们写下的数字」，而不是「用户能不能点到」。
    /// 现在的断言改成「内容余量 ≥ 0」与「按钮完整落在面板内」。
    private static let panelMinSize = CGSize(width: 320, height: 208)

    public override init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelMinSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        scopeControl = NSSegmentedControl()
        outputControl = NSSegmentedControl()
        durationPopup = NSPopUpButton()
        dimensionPopup = NSPopUpButton()
        gifNoSoundLabel = NSTextField(labelWithString: "GIF 无声音")
        systemAudioToggle = NSButton(checkboxWithTitle: "系统声音", target: nil, action: nil)
        microphoneToggle = NSButton(checkboxWithTitle: "麦克风", target: nil, action: nil)
        statusLabel = NSTextField(labelWithString: "")
        pickButton = NSButton(title: "选取目标", target: nil, action: nil)
        startButton = NSButton(title: "开始录制", target: nil, action: nil)
        super.init()

        configurePanel()
    }

    // MARK: - 对外接口

    /// 显示面板。
    ///
    /// 范围与目标每次都从零开始（由本次选区与 `preferredIndex` 决定）；
    /// 输出格式与音频开关则恢复用户上一次的选择（`RecordingPreferencesStore`）。
    ///
    /// - Parameters:
    ///   - rect: 打开面板的依据矩形（**AppKit 屏幕坐标**），用于就近摆放；
    ///     nil 时居中。
    ///   - options: 可选范围。数量决定分段控件的段数；为 1 时隐藏分段控件。
    ///   - preferredIndex: 默认选中的范围，越界时回退到第 0 项。
    public func show(near rect: CGRect?, options: [ScopeOption], preferredIndex: Int = 0) {
        guard !options.isEmpty else { return }
        self.options = options
        // 每次弹出都是一次全新的准备：上一个会话的目标与候选一律作废，
        // 否则上一轮的「已选定：某窗口」会以未选目标的状态残留下来。
        lockedTitles = [:]
        candidateTitle = nil
        isPicking = false
        // 音频开关与输出格式取自上一次的选择（`RecordingPreferencesStore`）。
        //
        // 这两项在两次录制之间几乎不变：习惯录 GIF 的人次次都要关掉音频，
        // 习惯带旁白的人次次都要确认麦克风。而面板是**常驻实例**，
        // 每次弹出都复位成「MP4 + 双开」，等于让用户把同一个决定重复表达一遍。
        //
        // 恢复不会制造隐状态：格式与两个开关都摆在面板上，开始录制前一眼可见，
        // 与「弹出后核对一遍」的成本相同。范围与目标仍然每次重置（见上）——
        // 它们属于「这一次录哪块」，选区与窗口身份每次都可能不同，不是长期偏好。
        restorePreferences()

        // 分段控件按需重建：范围选项随是否存在选区而变化，段数不固定。
        scopeControl.segmentCount = options.count
        for (index, option) in options.enumerated() {
            scopeControl.setLabel(option.title, forSegment: index)
            scopeControl.setWidth(0, forSegment: index)
        }
        scopeControl.isHidden = options.count <= 1
        scopeControl.selectedSegment = min(max(0, preferredIndex), options.count - 1)

        layout(in: panel.contentView)
        refreshOutputControls()
        refreshStatus()
        position(near: rect)
        panel.orderFrontRegardless()
    }

    /// 关闭面板。
    public func close() {
        panel.orderOut(nil)
    }

    // MARK: - 控制器 → 面板

    /// 告知某个范围的目标状态。`title` 为 nil 表示尚未选定（或已清除）。
    public func setTarget(kind: RecordingScopeKind, title: String?) {
        if let title {
            lockedTitles[kind] = title
        } else {
            lockedTitles.removeValue(forKey: kind)
        }
        refreshStatus()
    }

    /// 告知正在选取时的候选目标（鼠标下的对象）。nil 表示指针不在有效目标上。
    ///
    /// 去重在这里做：鼠标每移动一点就会上报一次，而只有标题真变了才需要重排状态行。
    /// 放在视图里做会变成「每个视图各记一份」，跨屏来回移动时预览会停在旧候选上。
    public func setCandidateTitle(_ title: String?) {
        guard candidateTitle != title else { return }
        candidateTitle = title
        refreshStatus()
    }

    /// 告知是否正在等待用户点选目标。
    public func setPicking(_ picking: Bool) {
        isPicking = picking
        if !picking { candidateTitle = nil }
        refreshStatus()
    }

    // MARK: - 构建

    private func configurePanel() {
        // **必须显式指定深色外观。** 面板背景是深色的，若外观仍是浅色（Aqua），
        // 系统控件会按浅色绘制——分段控件、按钮都会变成「深底深字」或「浅底浅字」，
        // 糊成一片（实测截图确认）。指定外观后控件才与背景一致。
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // **必须高于截图覆盖层。** 覆盖层用 `.screenSaver` 才能盖住菜单栏，
        // 面板若用 `.floating` 会被它整个遮住——用户完全看不到面板（实测截图确认：
        // 面板存在、isVisible 为真，但屏幕上什么都看不见）。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        let container = NSView(frame: NSRect(origin: .zero, size: Self.panelMinSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        panel.contentView = container

        // 默认**都勾选**：用户要的是「录屏默认带声音」，需要静音时再手动取消。
        // 两项都仍需显式取消才能关闭，故不会出现「以为没录声音却录了」的意外——
        // 开关就摆在面板上，开始前一眼可见。
        //
        // 这里的 `.on` 只是「没有任何记忆时」的初始状态：`show` 会用
        // `RecordingPreferencesStore` 里的值覆盖它。
        for toggle in [systemAudioToggle, microphoneToggle] {
            toggle.font = .systemFont(ofSize: 13)
            toggle.state = .on
            toggle.target = self
            toggle.action = #selector(audioChanged)
        }

        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        scopeControl.segmentStyle = .rounded

        // 输出格式只有两段，与旁边的「录制范围」同一套视觉语言：一次点击即达。
        outputControl.segmentCount = 2
        outputControl.setLabel("MP4", forSegment: 0)
        outputControl.setLabel("GIF", forSegment: 1)
        outputControl.setWidth(0, forSegment: 0)
        outputControl.setWidth(0, forSegment: 1)
        outputControl.segmentStyle = .rounded
        outputControl.selectedSegment = 0
        outputControl.target = self
        outputControl.action = #selector(outputChanged)

        configurePopups()

        // GIF 模式下两个音频开关置灰并给出理由。
        // 不隐藏：开关突然消失、切回 MP4 又出现，比置灰更让人困惑；
        // 也不保持可勾选：勾了不生效就是静默丢弃用户明确表达的要求。
        gifNoSoundLabel.font = .systemFont(ofSize: 11)
        gifNoSoundLabel.textColor = .secondaryLabelColor

        // 状态行：既要说明「现在该做什么」，也要说明「已经选了什么」。
        // 它与分段控件是两回事——分段控件只说范围类型，目标要单独表达。
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        pickButton.bezelStyle = .rounded
        pickButton.controlSize = .small
        pickButton.font = .systemFont(ofSize: 11)
        pickButton.target = self
        pickButton.action = #selector(pickTapped)

        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startTapped)
    }

    /// 用栈视图排版。面板高度固定、内容不多，避免手算坐标出错。
    private func layout(in container: NSView?) {
        guard let container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }

        let isGIF = selectedOutput.isGIF

        // 面板尺寸：宽度固定，**高度按内容算**（栈视图排完再量）。
        // 先给一个下限尺寸把控件摆好，量出内容高度后再定稿。
        panel.setContentSize(Self.panelMinSize)
        container.frame = NSRect(origin: .zero, size: Self.panelMinSize)

        let statusRow = makeStatusRow()
        let gifParameterRow = makeGIFParameterRow(isGIF: isGIF)
        let audioRow = makeAudioRow(isGIF: isGIF)
        let buttonRow = makeButtonRow()

        // 行序：范围 → 输出格式 → GIF 参数 → 音频 → 按钮。
        // 参数行**紧贴**它作用的格式行，不隔着音频行——
        // 隔着的话「这参数管的是录的范围还是录的格式」就变成要猜的事。
        let stack = NSStackView(views: [
            Self.sectionLabel("录制范围"), scopeControl, statusRow,
            Self.sectionLabel("输出格式"), outputControl, gifParameterRow,
            Self.sectionLabel("音频"), audioRow, buttonRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(6, after: scopeControl)
        stack.setCustomSpacing(14, after: statusRow)
        stack.setCustomSpacing(14, after: gifParameterRow)
        stack.setCustomSpacing(14, after: audioRow)
        self.contentStack = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.contentVerticalInset)
        ])
        scopeControl.translatesAutoresizingMaskIntoConstraints = false
        scopeControl.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        // ── 高度按内容定稿 ────────────────────────────────────────
        //
        // 先按下限尺寸摆好（上面已 `setContentSize(panelMinSize)`），再量内容真实高度，
        // 最后把面板高度改为「内容 + 上下内边距」，且不低于下限。
        //
        // 为何用手算常量替换成实测：一个常量写小了就是「按钮被窗口裁掉、点不到」，
        // 而它**只在特定内容组合下**才暴露（本次就是 MP4 模式，而 GIF 模式刚好够用），
        // 手算的估算值很容易在加了一行后静默失效。
        container.layoutSubtreeIfNeeded()
        let contentHeight = stack.fittingSize.height
        let neededHeight = Self.contentVerticalInset * 2 + contentHeight
        let finalHeight = max(Self.panelMinSize.height, neededHeight.rounded(.up))
        let finalSize = CGSize(width: Self.panelMinSize.width, height: finalHeight)
        panel.setContentSize(finalSize)
        container.frame = NSRect(origin: .zero, size: finalSize)
        container.layoutSubtreeIfNeeded()
    }

    /// 分组标题的统一外观。
    ///
    /// 深色外观下用次要标签色，保证与背景有足够对比又不过分抢眼。
    ///
    /// 由 `layout` 的局部函数提升为类型方法：拆分成多个区块方法后，
    /// 局部函数已无法被它们共用。
    private static func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// 「当前目标 + 选择按钮」行。
    private func makeStatusRow() -> NSStackView {
        let statusRow = NSStackView(views: [statusLabel, pickButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        // 文案先让位：目标标题可能很长，按钮的位置比文字末尾更重要。
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return statusRow
    }

    /// GIF 参数行：时长上限与最大边长并排一行。
    ///
    /// 必须给下拉设显式宽度：`NSPopUpButton` 会按候选里的最长标题自动加宽，
    /// 不约束就会把 288 的内容宽撑爆——这正是「一行放不下」的实际成因，
    /// 它是可以用宽度约束消除的，不必靠多占一行来解决。
    private func makeGIFParameterRow(isGIF: Bool) -> NSStackView {
        durationPopup.widthAnchor.constraint(equalToConstant: 68).isActive = true
        dimensionPopup.widthAnchor.constraint(equalToConstant: 78).isActive = true

        let durationGroup = NSStackView(views: [Self.sectionLabel("时长上限"), durationPopup])
        durationGroup.orientation = .horizontal
        durationGroup.spacing = 6
        let dimensionGroup = NSStackView(views: [Self.sectionLabel("最大边长"), dimensionPopup])
        dimensionGroup.orientation = .horizontal
        dimensionGroup.spacing = 6

        let gifParameterRow = NSStackView(views: [durationGroup, dimensionGroup])
        gifParameterRow.orientation = .horizontal
        gifParameterRow.spacing = 16
        gifParameterRow.isHidden = !isGIF
        self.gifParameterRow = gifParameterRow
        return gifParameterRow
    }

    /// 音频行。
    ///
    /// 「GIF 无声音」跟着音频行：说明就长在它作用的对象旁边。
    /// 放在面板底部或其他行都会让它变成一句无主的提示。
    private func makeAudioRow(isGIF: Bool) -> NSStackView {
        let audioRow = NSStackView(views: [systemAudioToggle, microphoneToggle, gifNoSoundLabel])
        audioRow.orientation = .horizontal
        audioRow.spacing = 16
        gifNoSoundLabel.isHidden = !isGIF
        return audioRow
    }

    /// 取消 / 开始按钮行。
    private func makeButtonRow() -> NSStackView {
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [cancelButton, startButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        return buttonRow
    }

    /// 面板应该出现在哪块屏幕上。
    ///
    /// **不能用 `NSScreen.main`**：它是「键盘焦点所在的屏幕」，与选区无关——
    /// 多屏时对着副屏拉选区，面板会被钳到主屏上去。
    /// 判据与录制控制条一致（重叠面积最大），见 `RecordingControlBar.screen(overlapping:)`。
    private func screen(containing rect: CGRect?) -> NSScreen? {
        rect.flatMap(RecordingControlBar.screen(overlapping:)) ?? NSScreen.screens.first
    }

    /// 就近选区摆放；空间不足时落到选区下方。
    ///
    /// 一律用**当前** `panel.frame.size` 计算，不用尺寸常量：
    /// 格式切换会改变面板高度，若仍按旧尺寸算，切换后面板就会被钳错位置
    /// （贴边时表现为被裁掉一截，而不贴边时看不出来）。
    private func position(near rect: CGRect?) {
        guard let visible = screen(containing: rect)?.visibleFrame else {
            panel.center()
            return
        }

        let size = panel.frame.size
        var origin: CGPoint
        if let rect, rect.width > 1 {
            let gap: CGFloat = 12
            let above = CGPoint(
                x: rect.midX - size.width / 2,
                y: rect.maxY + gap
            )
            let below = CGPoint(
                x: rect.midX - size.width / 2,
                y: rect.minY - size.height - gap
            )
            origin = (above.y + size.height <= visible.maxY) ? above : below
        } else {
            origin = CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
        }

        // 钳制在可见区域内，避免贴边时被裁掉
        origin.x = min(
            max(visible.minX + 8, origin.x),
            visible.maxX - size.width - 8
        )
        origin.y = min(
            max(visible.minY + 8, origin.y),
            visible.maxY - size.height - 8
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - 输出格式

    /// 当前选中的输出格式。
    public var selectedOutput: RecordingOutputChoice {
        guard outputControl.selectedSegment == 1 else { return .movie }
        return .gif(GIFSettings(
            maximumDuration: Self.durationOptions[clampedSelection(of: durationPopup)],
            maximumPixelDimension: Self.pixelDimensionOptions[clampedSelection(of: dimensionPopup)]
        ))
    }

    /// 下拉当前选中项，越界（未选中时为 -1）时回退到第 0 项。
    ///
    /// `indexOfSelectedItem` 在「一个都没选」时返回 -1，直接拿它取数组
    /// 就是一次越界崩溃——而面板是常驻实例，崩溃发生在弹面板这一步。
    private func clampedSelection(of popup: NSPopUpButton) -> Int {
        let index = popup.indexOfSelectedItem
        return index >= 0 ? index : 0
    }

    /// 界面展示的档位与契约档位**同源**：直接引用 `GIFSettings` 的常量，
    /// 而不是在界面层再写一份字面量——两份一旦漂移，表现是界面给出了一个
    /// 后台会拒绝的档位（用户点开始才报错）。
    private static let durationOptions = GIFSettings.durationOptions
    private static let pixelDimensionOptions = GIFSettings.pixelDimensionOptions

    private func configurePopups() {
        for (index, seconds) in Self.durationOptions.enumerated() {
            durationPopup.addItem(withTitle: "\(Int(seconds)) 秒")
            durationPopup.item(at: index)?.tag = index
        }
        for (index, pixels) in Self.pixelDimensionOptions.enumerated() {
            dimensionPopup.addItem(withTitle: "\(pixels) px")
            dimensionPopup.item(at: index)?.tag = index
        }
        for popup in [durationPopup, dimensionPopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 11)
            popup.target = self
            popup.action = #selector(outputChanged)
        }
    }

    /// 把两个下拉对齐到给定档位（不在档位集合内时回退到第 0 项）。
    private func syncPopups(to settings: GIFSettings) {
        let durationIndex = Self.durationOptions.firstIndex(of: settings.maximumDuration) ?? 0
        let dimensionIndex = Self.pixelDimensionOptions.firstIndex(of: settings.maximumPixelDimension) ?? 0
        durationPopup.selectItem(at: min(max(0, durationIndex), Self.durationOptions.count - 1))
        dimensionPopup.selectItem(at: min(max(0, dimensionIndex), Self.pixelDimensionOptions.count - 1))
    }

    /// 把上一次的输出格式与音频开关放回控件。
    ///
    /// 只读存储、不在这里写回：`show` 是读路径，若把「存储里原本是什么」
    /// 再写一遍，写路径就分不清「用户刚改过」与「面板刚弹出」，
    /// 以后想基于「改动」做别的事（例如诊断复位）就失去了判据。
    private func restorePreferences() {
        let preferences = RecordingPreferencesStore.shared
        let output = preferences.output
        if case .gif(let settings) = output {
            outputControl.selectedSegment = 1
            syncPopups(to: settings)
        } else {
            outputControl.selectedSegment = 0
            // MP4 下 GIF 档位不参与本次录制，面板也把它收起；
            // 复位成默认档位，避免用户切到 GIF 时看到的是「上一次」的档位
            // 却以为那是这次已经确认过的参数。
            syncPopups(to: GIFSettings())
        }
        systemAudioToggle.state = preferences.systemAudio ? .on : .off
        microphoneToggle.state = preferences.microphone ? .on : .off
    }

    /// 刷新与输出格式相关的可用性。
    ///
    /// **置灰而非隐藏**：开关突然消失、切回 MP4 又出现，比一个置灰且注明理由的
    /// 控件更让人困惑；也不能保持可勾选——勾了不生效就是静默丢弃用户明确表达的要求。
    private func refreshOutputControls() {
        let isGIF = selectedOutput.isGIF
        systemAudioToggle.isEnabled = !isGIF
        microphoneToggle.isEnabled = !isGIF
        gifNoSoundLabel.isHidden = !isGIF
    }

    @objc private func outputChanged() {
        // 换格式要重排（高度与参数行可见性都变），但**不能重新按锚点摆放**：
        // 面板可以被用户拖到任意位置，每次切格式都把它拽回选区旁边，
        // 用户会以为面板自己跳了。只调整高度，并让顶边保持不动。
        let topEdge = panel.frame.maxY
        // 以面板当前所在的屏幕做钳制依据：此时它才是用户看到的位置。
        let hostScreen = screen(containing: panel.frame)
        layout(in: panel.contentView)
        refreshOutputControls()
        var frame = panel.frame
        frame.origin.y = topEdge - frame.height
        // 高度变大后底边可能被挤出屏幕，钳回可见区域（顶边此时不得不让位）。
        if let visible = hostScreen?.visibleFrame {
            frame.origin.y = min(
                max(visible.minY + 8, frame.origin.y),
                visible.maxY - frame.height - 8
            )
        }
        panel.setFrame(frame, display: true)
        // 用户改了格式或 GIF 档位就立即记住：下次弹出直接还原，不再复位成 MP4。
        // 写的是控件此刻的真实状态（`selectedOutput`），而不是「用户点了哪一段」
        // ——换格式与改档位走同一个 action，两边都该记住。
        RecordingPreferencesStore.shared.output = selectedOutput
    }

    // MARK: - 状态

    /// 重算状态行文案、选取按钮与开始按钮的可用性。
    ///
    /// **可用性只在这里判定**：目标没选定时「开始录制」必须点不动，
    /// 否则用户会得到一个「窗口范围但不知道录哪个窗口」的请求。
    private func refreshStatus() {
        guard let kind = selectedKind else {
            statusLabel.stringValue = ""
            pickButton.isHidden = true
            startButton.isEnabled = false
            return
        }

        guard kind.requiresTarget else {
            // 提示与分段控件的用词必须同一套：控件写「区域」「全屏」，
            // 提示就不能写「选区」「整块显示器」——同一个东西两个叫法，
            // 用户得在脑子里先做一次映射。
            statusLabel.stringValue = kind == .region ? "录制所选区域" : "录制全屏"
            pickButton.isHidden = true
            startButton.isEnabled = true
            return
        }

        // 需要选目标的两种范围（窗口 / 应用）：提示里必须把它说清楚。
        // 只写「目标」等于没说——用户不知道鼠标该去找窗口还是找应用。
        let noun = kind.displayName
        let locked = lockedTitles[kind]
        if isPicking {
            statusLabel.stringValue = candidateTitle.map { "候选：\($0)　单击以选定" }
                ?? "移动鼠标到要录的\(noun)，单击以选定"
        } else if let locked {
            // 类型写在标题**前面**：窗口标题可能很长，末尾会被截断，
            // 类型不能跟着一起丢——否则用户看不出选的是窗口还是应用。
            statusLabel.stringValue = "已选定\(noun)：\(locked)"
        } else {
            statusLabel.stringValue = "尚未选定\(noun)，点「开始选取」"
        }

        // 选取过程中不给「重新选择」——按钮此时按下去没有新含义。
        pickButton.isHidden = isPicking
        pickButton.title = locked == nil ? "开始选取" : "重新选择"
        // **选取期间一律禁止开始，即使已经锁定过旧目标。**
        // 画面上此刻显示的是候选（可能已经是另一个窗口），若还允许开始，
        // 用户会按着一个看得见的候选录到另一个目标上。
        startButton.isEnabled = locked != nil && !isPicking
    }

    /// 执行「开始录制」，等价于用户点击开始按钮。
    ///
    /// 供覆盖层的回车键调用：可用性只在面板这一处判定，
    /// 调用方不得自行判断后绕过。（诊断也走这里，避免出现第二条旁路。）
    func activateStart() {
        startTapped()
    }

    // MARK: - 动作

    /// 切换范围：把新的范围类型通知出去，由控制器决定是否进入目标选取、
    /// 以及预览框该画在哪。
    @objc private func scopeChanged() {
        guard let kind = selectedKind else { return }
        // 换范围即作废上一个范围的候选：它是上一个范围的对象。
        candidateTitle = nil
        refreshStatus()
        onKindChanged?(kind)
    }

    /// 音频开关改动：立即记住。
    ///
    /// 生效值仍以控件为准（`startTapped` 从复选框读），存储只是**副本**：
    /// 这样即使存储写失败，本次录制也按用户眼前看到的开关走，
    /// 不会出现「取消勾选了却还带声音」。
    @objc private func audioChanged() {
        let preferences = RecordingPreferencesStore.shared
        preferences.systemAudio = systemAudioToggle.state == .on
        preferences.microphone = microphoneToggle.state == .on
    }

    @objc private func pickTapped() {
        guard let kind = selectedKind, kind.requiresTarget else { return }
        onPickRequested?(kind)
    }

    @objc private func startTapped() {
        // 目标未选定时按钮本就不可点，这里再挡一次：诊断与键盘回车都走这条路，
        // 绕过按钮状态就会发出一个没有目标的录制请求。
        guard startButton.isEnabled, let kind = selectedKind else {
            NSSound.beep()
            return
        }
        let audio = AudioSettings(
            systemAudio: systemAudioToggle.state == .on,
            microphone: microphoneToggle.state == .on
        )
        panel.orderOut(nil)
        onStart?(Outcome(kind: kind, audio: audio, output: selectedOutput))
    }

    @objc private func cancelTapped() {
        panel.orderOut(nil)
        onCancel?()
    }

    #if DEBUG
    /// 诊断用：以当前控件状态触发「开始录制」，等价于用户点击开始按钮。
    ///
    /// 走的是与真实点击**同一个** `startTapped`，而不是另写一条旁路，
    /// 否则诊断通过也不能说明按钮可用。
    public func confirmForDiagnostics() {
        startTapped()
    }

    /// 诊断用：触发「取消」，等价于用户点取消按钮。
    ///
    /// 用于在验证完选项后干净地收起面板——**不能**改用 `confirmForDiagnostics`，
    /// 那会真的发出录制请求并让覆盖层 dismiss，污染同一次诊断里的后续断言。
    public func cancelForDiagnostics() {
        cancelTapped()
    }

    /// 诊断用：读取当前两个音频开关的状态。
    public var currentAudioForDiagnostics: AudioSettings {
        AudioSettings(
            systemAudio: systemAudioToggle.state == .on,
            microphone: microphoneToggle.state == .on
        )
    }

    /// 诊断用：直接设置系统声音开关，等价于用户点击复选框。
    public func setSystemAudioForDiagnostics(_ on: Bool) {
        systemAudioToggle.state = on ? .on : .off
        // 与真实点击走同一条写路径：开关现在会记忆，若诊断绕过它，
        // 「诊断通过」就不能说明用户点完之后会被记住。
        audioChanged()
        refreshStatus()
    }

    /// 诊断用：切换到指定范围，等价于用户点击分段控件。
    public func selectScopeForDiagnostics(index: Int) {
        guard options.indices.contains(index) else { return }
        scopeControl.selectedSegment = index
        scopeChanged()
    }

    /// 诊断用：可选范围数量。
    public var scopeOptionCountForDiagnostics: Int { options.count }

    /// 诊断用：可选范围的类型列表。
    public var scopeOptionKindsForDiagnostics: [RecordingScopeKind] {
        options.map(\.kind)
    }

    /// 诊断用：「开始录制」此刻是否可点。
    public var startEnabledForDiagnostics: Bool { startButton.isEnabled }

    /// 诊断用：是否正在等待点选目标。
    public var isPickingForDiagnostics: Bool { isPicking }

    /// 诊断用：状态行文案，用于核对提示与状态一致。
    public var statusTextForDiagnostics: String { statusLabel.stringValue }

    /// 诊断用：当前候选目标标题。
    public var candidateTitleForDiagnostics: String? { candidateTitle }

    /// 诊断用：切换到指定输出格式，等价于用户点击格式分段控件。
    ///
    /// 走的是与真实点击**同一个** `outputChanged`，而不是另写一条旁路——
    /// 否则诊断通过也不能说明面板会正确重排。
    public func selectOutputForDiagnostics(_ isGIF: Bool) {
        outputControl.selectedSegment = isGIF ? 1 : 0
        outputChanged()
    }

    /// 诊断用：当前输出选择（含档位），用于核对「面板选了什么就会传出什么」。
    public var currentOutputForDiagnostics: RecordingOutputChoice { selectedOutput }

    /// 诊断用：直接设定 GIF 档位，等价于用户操作两个下拉。
    ///
    /// 同样走真实下拉的 `outputChanged`（同步档位 → 重排 → 记住），
    /// 只改控件状态而不同步存储，会让「面板显示的档位」与「下次恢复的档位」
    /// 静默分叉，诊断却看不出来。
    public func setGIFSettingsForDiagnostics(_ settings: GIFSettings) {
        syncPopups(to: settings)
        outputChanged()
    }

    /// 诊断用：音频开关此刻是否可用（GIF 下应为 false）。
    public var audioControlsEnabledForDiagnostics: Bool {
        systemAudioToggle.isEnabled && microphoneToggle.isEnabled
    }

    /// 诊断用：「GIF 无声音」说明是否可见。
    public var gifNoSoundNoticeVisibleForDiagnostics: Bool { !gifNoSoundLabel.isHidden }

    /// 诊断用：GIF 参数行是否可见。
    public var gifParameterRowVisibleForDiagnostics: Bool {
        !(gifParameterRow?.isHidden ?? true)
    }

    /// 诊断用：面板当前高度（断言 MP4 / GIF 两个尺寸互不干扰）。
    public var panelHeightForDiagnostics: CGFloat { panel.frame.height }

    /// 诊断用：内容栈的真实高度。
    public var contentFittingHeightForDiagnostics: CGFloat {
        contentStack?.fittingSize.height ?? 0
    }

    /// 诊断用：面板高度减去「内容 + 上下内边距」的余量。
    ///
    /// **必须 ≥ 0**：为负说明内容溢出窗口下缘，底部按钮会被裁掉。
    /// 这个读数存在的理由就是它的缺席——首版把两个高度手算成 208 / 284，
    /// 实际内容装不下，于是「开始录制」被窗口边缘截掉、点不到，
    /// 而当时的断言只比对了窗口高度常量，对这种裁切完全免疫。
    public var contentClearanceForDiagnostics: CGFloat {
        panel.frame.height - (Self.contentVerticalInset * 2 + contentFittingHeightForDiagnostics)
    }

    /// 诊断用：「开始录制」按钮在面板内容坐标系下的矩形。
    ///
    /// 这才是「点得到」的**直接**判据：越出内容区就意味着越出窗口，
    /// 而窗口外的控件是画得出来却点不到的（实测报的就是这个缺陷）。
    public var startButtonRectForDiagnostics: CGRect {
        guard let content = panel.contentView else { return .zero }
        return startButton.convert(startButton.bounds, to: content)
    }

    /// 诊断用：面板内容区边界。
    public var contentBoundsForDiagnostics: CGRect {
        panel.contentView?.bounds ?? .zero
    }
    #endif
}
