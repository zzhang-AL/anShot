//
//  PinWindow.swift
//  AnShotUI
//
//  固定截图（Pin）：把一张截图钉在屏幕上，可拖动、缩放（按钮/滚轮）、
//  调透明度、取消固定、关闭。
//
//  ── 出口必须长在卡片上 ──────────────────────────────────
//
//  「隐藏」与「关闭」原先只出现在右键菜单里，而右键菜单**没有任何提示**：
//  卡片能收起、能关掉这件事只能靠试。
//
//  现在卡片右上角常驻四个按钮，它们描述三个不同的维度：
//
//  * 图钉（`pin.fill` / `pin.slash`）= 「这张图我留着吗」：固定 / 取消固定，
//    **不改变可见性**（用户明确要求「取消固定先不隐藏」）；
//  * ✕ = 「现在收起来」：固定中只是**隐藏**（位图保留，菜单栏可恢复），
//    已取消固定才**隐藏并释放位图**。
//    于是「关闭」永远不会悄悄丢掉用户要求保留的图：要销毁必须先按图钉；
//  * ＋ / － = 缩放（每次 10%，等比）。**滚轮也能缩**，但滚轮能否到达本窗口
//    取决于系统把它投给谁，所以「能不能放大」不能只挂在滚轮上。
//
//  这四个按钮在同一状态下外观几乎一样，接反了只会往「想找回那张图时发现它
//  已经没了」或「点了没反应」才暴露，所以 `-diagnosePin` 直接点它们，
//  再查尺寸、位图与管理列表。
//
//  ── 与内存纪律的关系 ──────────────────────────────────────
//
//  M1 的规则是「会话结束立即释放位图」。Pin 是这条规则**唯一的显式例外**：
//  用户要求「留着」，所以它必须常驻。例外必须有边界，否则规则等于失效：
//
//  * 每个 Pin 持有**一份完整位图**，数量因此有硬上限；
//  * 上限来自设置而非写死的常量——各机器内存与用法差异很大，
//    写死一个数字要么太小（用户被无端挡住）要么太大（悄悄吃掉内存）；
//  * 达到上限时**拒绝**新的 Pin，把「关掉哪张」的决定权交还用户。
//    早期版本会静默关闭最旧的一张，用户看到的是「刚钉的还在，
//    之前那张凭空消失」——丢的是他明确要求保留的东西；
//  * 「隐藏」保留位图（可恢复）；「关闭」在**固定中**也只是隐藏（可恢复），
//    只有先「取消固定」再关闭才释放位图。三者必须分开，否则用户会丢掉
//    他明确要求保留的东西。
//
//  ── 窗口层级 ──────────────────────────────────────────────
//
//  契约要求「浮动在普通窗口之上，但不遮挡全屏应用」。所以用 `.floating`
//  而**不是**截图覆盖层那种 `.screenSaver + 1`，也不加 `.fullScreenAuxiliary`
//  ——后者会让 Pin 出现在别人的全屏应用上面。
//
//  ── 为什么图像视图必须自定义（拖动失效的根因）──────────────
//
//  `isMovableByWindowBackground = true` 只对「未被阻挡的区域」生效。
//  `NSImageView` 继承 `NSControl`，后者把 `mouseDownCanMoveWindow` 定为
//  `false` 并且自己消费 `mouseDown`。图像铺满整个窗口，于是可拖区域为**空**，
//  背景拖动完全失效——「Pin 拖不动」的根因在这里，不在窗口配置。
//
//  实测证据（编译真实 `PinWindow.swift` 后调用 AppKit 自身的
//  `-_draggableFrame` 与 `-_regionForOpaqueViewsBlockingDraggableFrame`）：
//  图像视图铺满时 blockingRegion 非空、可拖区域为空；把
//  `mouseDownCanMoveWindow` 改真或接管 `mouseDown` 都能翻转结论；
//  换成「普通 NSView 容器 + 铺满的图像视图」**仍然**不可拖。
//
//  因此两条修正同时给上：`performDrag` 走 AppKit 官方拖拽路径
//  （跨屏与系统边界行为都由系统负责），`mouseDownCanMoveWindow` 让 AppKit
//  的拖动区域计算也不再把图像当作障碍。
//

import AnShotCore
import AppKit

private let logger = AnShotLog.pin
/// 可拖动的图像视图。
///
/// 存在的唯一理由是让背景拖动重新生效，见文件头的根因说明。
final class PinImageView: NSImageView {

    /// 接管左键：交给 AppKit 的官方拖拽。
    ///
    /// 不能调用 `super`：`NSControl.mouseDown` 会把它当成一次控件跟踪消费掉，
    /// 事件到不了窗口的背景拖动逻辑。
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        // `performDrag` 在**拖动结束时才返回**（它内部跑一个事件跟踪循环），
        // 所以这一行就是「松手之后」。在这里检查最及时，
        // 不必等 `didMove` 的防抖计时器。
        (window as? PinWindow)?.pullBackIfFullyOffscreen()
    }

    /// 让 AppKit 的区域计算也认为这块区域可以拖动。
    ///
    /// 与 `mouseDown` 是**互补**关系而非重复：前者管事件路径，后者管
    /// server-side 拖动的区域判定（鼠标落在圆角或透明边缘时是它兜底）。
    override var mouseDownCanMoveWindow: Bool { true }
}

/// 卡片右上角的小按钮。
///
/// 自绘而非复用系统控件外观，理由与录制控制条同源：卡片浮在任意内容之上，
/// 浅色/深色系统控件在浅底与深底上都可能对比度不足；固定用深色半透明底 +
/// 白色符号，在任何截图内容上都看得清。
final class PinCardButton: NSButton {

    /// 按钮边长。缩放卡片时**不变**——按钮是控件不是图像的一部分。
    static let side: CGFloat = 22

    /// 两个按钮之间的距离。
    static let spacing: CGFloat = 6

    /// 按钮与卡片上/右边缘的距离。
    static let inset: CGFloat = 8

    /// 底色的常态与悬停态。
    ///
    /// 常态就足够看清（半透明深底 + 白色符号），悬停只是提亮。
    /// 刻意**不做**「悬停才出现」：入口被藏起来正是右键菜单的问题，
    /// 换个方式藏起来等于没解决。
    private static let idleBackground = NSColor(calibratedWhite: 0.12, alpha: 0.72).cgColor
    private static let hoveredBackground = NSColor(calibratedWhite: 0.12, alpha: 0.95).cgColor

    private var hoverArea: NSTrackingArea?

    /// 造一个图标按钮。
    ///
    /// - Parameters:
    ///   - symbol: SF Symbol 名。取不到时退回文字标题（macOS 13 起应始终可取到）。
    ///   - fallbackTitle: 符号不可用时显示的短文字。
    ///   - toolTip: 鼠标停留时的说明，同时作为无障碍标签。
    ///     图标本身说不清「按下后是隐藏还是释放」——这句话是这两个按钮唯一的语义入口。
    static func make(symbol: String, fallbackTitle: String, toolTip: String) -> PinCardButton {
        let button = PinCardButton(frame: CGRect(x: 0, y: 0, width: side, height: side))
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = idleBackground
        button.setSymbol(symbol, fallbackTitle: fallbackTitle, toolTip: toolTip)
        return button
    }

    /// 统一造符号图。
    ///
    /// 字号固定 11pt：两个按钮的图标大小必须一致，切换状态时也不能变。
    static func symbolImage(_ name: String, description: String?) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
    }

    /// 换图标与说明（两个按钮各带两种状态）。
    ///
    /// 说明必须跟着状态一起换：它决定「下次点关闭会不会释放内存」，
    /// 不能在状态里静默地变。
    func setSymbol(_ name: String, fallbackTitle: String, toolTip: String) {
        self.toolTip = toolTip
        setAccessibilityLabel(toolTip)
        if let image = Self.symbolImage(name, description: toolTip) {
            self.image = image
            imagePosition = .imageOnly
            // 上一次可能停在文字回退态，残留的标题会与图标重叠。
            title = ""
        } else {
            title = fallbackTitle
            imagePosition = .noImage
            font = .systemFont(ofSize: 10, weight: .semibold)
        }
    }

    // MARK: - 悬停反馈

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        // `.activeAlways`：卡片所在的应用多半不是活跃应用（本应用是 `.accessory`），
        // 用 `.activeInKeyWindow` 会让悬停反馈在真实使用中永不触发。
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    private func setHovered(_ hovered: Bool) {
        layer?.backgroundColor = hovered ? Self.hoveredBackground : Self.idleBackground
    }
}

/// 一张钉在屏幕上的截图。
@MainActor
final class PinWindow: NSWindow {

    /// 稳定标识（从 1 开始递增）。菜单项用它指代「同一张图」——
    /// 窗口对象会随隐藏/恢复而换引用，序号不会。
    let pinID: Int

    /// 钉住的时刻。菜单项与管理界面据此排序与显示。
    let createdAt = Date()

    /// 显示的图像；关闭时置空以释放位图。
    ///
    /// 隐藏**不**清空它——这正是「隐藏可恢复」与「关闭即释放」的分界。
    private(set) var contentImage: CGImage?

    /// 用户关闭了这个 Pin（真正释放）。隐藏不触发它。
    var onClose: (() -> Void)?

    /// 当前缩放比例（1.0 = 原始像素 1:1，屏幕是 2x 时逻辑尺寸为像素的一半）。
    private(set) var scale: Double = 1

    /// 用户主动隐藏（位图仍保留）。
    private(set) var isUserHidden = false

    /// 用户是否已取消固定。
    ///
    /// 取消固定**不改变可见性**（用户明确要求「先不隐藏」），它解除的是
    /// 「这张图我留着」的承诺：位图此刻仍在、仍计入上限，但「关闭」会释放它。
    /// 因此这个状态直接决定下次点 ✕ 会不会销毁位图。
    private(set) var isUnpinned = false

    private let imageView: PinImageView

    /// 卡片右上角的一排控制按钮。
    ///
    /// **图钉**：切换「固定 / 取消固定」，**不改变可见性**。取消固定解除的是
    /// 「这张图我留着」的承诺：位图此刻仍在、仍计入上限，但此后的「关闭」会释放它。
    /// **✕**：固定中只**隐藏**（位图保留，菜单栏可恢复）；已取消固定才
    /// **隐藏并释放**。
    /// **＋ / －**：放大 / 缩小（每次 10%，等比）。
    ///
    /// 缩放为什么必须有按钮，而不能只靠滚轮：滚动事件能否到达本窗口取决于系统把
    /// 它投给谁，而按钮点击在本项目里已经验证过（含「首次点击即生效」）。把「能不
    /// 能放大」系在一件自己无法保证的事上，正是用户觉得「不能缩放」的那类根源。
    ///
    /// 不是 `private`：诊断直接点它们（`performClick`），这是唯一能区分
    /// 「两个按钮接的是不是同一个动作」的办法——看外观分不出来。
    private(set) var pinButton = PinCardButton.make(
        symbol: "pin.fill",
        fallbackTitle: "取消固定",
        toolTip: pinButtonTipWhenPinned
    )
    private(set) var closeButton = PinCardButton.make(
        symbol: "xmark",
        fallbackTitle: "关闭",
        toolTip: closeButtonTipWhenPinned
    )
    private(set) var plusButton = PinCardButton.make(
        symbol: "plus",
        fallbackTitle: "放大",
        toolTip: plusButtonTip
    )
    private(set) var minusButton = PinCardButton.make(
        symbol: "minus",
        fallbackTitle: "缩小",
        toolTip: minusButtonTip
    )

    /// 原始像素尺寸与所在屏幕缩放：缩放操作需要它们把「窗口逻辑尺寸」算回来。
    private let pixelSize: CGSize
    private let screenScale: CGFloat

    init(
        pinID: Int,
        image: CGImage,
        logicalSize: CGSize,
        at origin: CGPoint,
        screenScale: CGFloat
    ) {
        self.pinID = pinID
        contentImage = image
        self.pixelSize = CGSize(width: image.width, height: image.height)
        self.screenScale = screenScale
        imageView = PinImageView(frame: CGRect(origin: .zero, size: logicalSize))
        imageView.image = NSImage(cgImage: image, size: logicalSize)
        imageView.imageScaling = .scaleProportionallyUpOrDown

        super.init(
            contentRect: CGRect(origin: origin, size: logicalSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // **必须显式关掉**：`NSWindow.isReleasedWhenClosed` 默认为 true，
        // 在 ARC 下 `close()` 会造成过度释放（诊断实测直接崩在关闭之后）。
        // 本项目其它窗口（录制范围框、准备面板、进度浮层）都设了这一项。
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // 浮动在普通窗口之上，但不进别人的全屏空间（契约 §6）。
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isMovableByWindowBackground = true
        // 无边框窗口默认不能成为 key window，改为可接受鼠标事件即可。
        acceptsMouseMovedEvents = true
        contentView = imageView
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        installCardButtons()

        // 窗口移动结束后的防丢检查。
        //
        // 为什么还需要它：`performDrag` 那条路径已经会检查，但
        // server-side 拖动（`mouseDownCanMoveWindow` 兜底的那条）不经过
        // 我们的 `mouseDown`，而程序式移动（如缩放）也不经过。
        // 三种路径共用同一个出口，才不会漏。
        //
        // 用 selector 式注册：闭包式会在 Swift 6 严格并发下要求
        // 在主 actor 隔离的闭包里捕获非 Sendable 的 self。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    @objc private func windowDidMove(_ notification: Notification) {
        schedulePullBackCheck()
    }

    // MARK: - 卡片按钮

    /// 把「取消固定」与「关闭」装到卡片右上角。
    ///
    /// 为什么不新加一层容器视图：`contentView` **必须**是 `PinImageView`
    /// 才吃得到那套拖动修复（见文件头），另加容器会让图像不再铺满内容视图，
    /// 把已经修好的拖动重新弄坏。按钮直接挂在图像视图上。
    private func installCardButtons() {
        // 贴住右上角：左、下边距可变，右、上边距固定。
        for button in cardButtons {
            button.autoresizingMask = [.minXMargin, .minYMargin]
            imageView.addSubview(button)
        }
        pinButton.target = self
        pinButton.action = #selector(togglePinFromCard)
        closeButton.target = self
        closeButton.action = #selector(closeFromCard)
        plusButton.target = self
        plusButton.action = #selector(zoomInFromCard)
        minusButton.target = self
        minusButton.action = #selector(zoomOutFromCard)
        layoutCardButtons()
        // 初始文案与状态同源：不在这里刷一次，就会出现「初始文字与切换后文字」
        // 两套写法，而它们必须逐字一致。
        refreshCardButtons()
    }

    /// 卡片上的四个按钮（依序：图钉、关闭、放大、缩小）。
    ///
    /// 布局、安装与「全部落在卡片内」的检查都遍历它：以后再添/删按钮时
    /// 只需改这一处，不会漏掉某个环节。
    var cardButtons: [PinCardButton] { [pinButton, closeButton, plusButton, minusButton] }

    /// 按固定状态刷新图标与说明。
    ///
    /// 图钉必须一眼看得出「这张卡片现在还固定着吗」：它不仅决定下一次点 ✕ 会
    /// 不会释放内存，也是用户唯一的判断依据；✕ 的说明也要跟着改。
    private func refreshCardButtons() {
        if isUnpinned {
            pinButton.setSymbol(
                "pin.slash",
                fallbackTitle: "重新固定",
                toolTip: pinButtonTipWhenUnpinned
            )
            closeButton.setSymbol(
                "xmark",
                fallbackTitle: "关闭",
                toolTip: closeButtonTipWhenUnpinned
            )
        } else {
            pinButton.setSymbol(
                "pin.fill",
                fallbackTitle: "取消固定",
                toolTip: pinButtonTipWhenPinned
            )
            closeButton.setSymbol(
                "xmark",
                fallbackTitle: "关闭",
                toolTip: closeButtonTipWhenPinned
            )
        }
    }

    /// 一种按钮排布。`rows == 1` 时四个按钮横排（从右到左：✕、图钉、＋、－）；
    /// `rows == 2` 时出口在上排、缩放在下排。
    private struct ButtonArrangement {
        let side: CGFloat
        let spacing: CGFloat
        let inset: CGFloat
        let rows: Int

        /// 四个按钮按这个排布共需多大（含贴边距）。
        var requiredSize: CGSize {
            let columns = rows == 1 ? 4 : 2
            return CGSize(
                width: CGFloat(columns) * side + CGFloat(columns - 1) * spacing + inset,
                height: CGFloat(rows) * side + CGFloat(rows - 1) * spacing + inset
            )
        }

        func fits(in size: CGSize) -> Bool {
            let needed = requiredSize
            return needed.width <= size.width && needed.height <= size.height
        }
    }

    /// 排布候选：从「最舒服」到「最将就」，取第一个放得下的。
    ///
    /// 卡片能被缩小，而按钮是控件、不跟着缩——所以排布必须自适应：
    /// 一排放不下就缩到 18/16pt，再放不下改两排。
    /// `imageView.layer.masksToBounds` 会把超出卡片的按钮直接剪掉，被剪掉的按钮
    /// 等于不存在：最坏的情况是「＋」被剪掉，用户把自己锁在一张再也放不大的小图里。
    /// 真正拦住那个死角的是 `applyScale` 里的最小卡片尺寸，这里是它的下界来源。
    private static let buttonArrangements: [ButtonArrangement] = [
        ButtonArrangement(
            side: PinCardButton.side,
            spacing: PinCardButton.spacing,
            inset: PinCardButton.inset,
            rows: 1
        ),
        ButtonArrangement(side: 18, spacing: 4, inset: 6, rows: 1),
        ButtonArrangement(side: 16, spacing: 4, inset: 6, rows: 1),
        ButtonArrangement(side: 16, spacing: 4, inset: 6, rows: 2)
    ]

    /// 四个按钮的位置：整体贴右上角，出口（✕、图钉）永远在最右、永远在第一排。
    ///
    /// 「✕ 在最右」与系统窗口的标题栏按钮一致（破坏性动作在最右），
    /// 同时让图钉不至于被误点成关闭——位置固定不变，肌肉记忆才成立。
    /// 缩放的「－」在「＋」左侧，与放大缩小控件的通用顺序一致。
    private func layoutCardButtons() {
        let bounds = imageView.bounds
        // 都放不下时用最后一种（两排）：它的要求最小，是「必然能放」的兜底。
        // 真到连它也放不下，说明卡片小于最小卡片尺寸——那时按钮会被裁，
        // 由 `applyScale` 的下限拦住，而不是在这里硬塞。
        let arrangement = Self.buttonArrangements.first { $0.fits(in: bounds.size) }
            ?? Self.buttonArrangements[Self.buttonArrangements.count - 1]

        let side = arrangement.side
        let spacing = arrangement.spacing
        let inset = arrangement.inset
        let closeX = bounds.maxX - inset - side
        let topY = bounds.maxY - inset - side
        func square(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: x, y: y, width: side, height: side)
        }

        closeButton.frame = square(closeX, topY)
        pinButton.frame = square(closeX - (spacing + side), topY)
        if arrangement.rows == 1 {
            plusButton.frame = square(closeX - 2 * (spacing + side), topY)
            minusButton.frame = square(closeX - 3 * (spacing + side), topY)
        } else {
            let secondY = topY - (spacing + side)
            plusButton.frame = square(closeX, secondY)
            minusButton.frame = square(closeX - (spacing + side), secondY)
        }
        // 圆角按边长成比例：16pt 的按钮用小圆角，否则会被看成圆点。
        for button in cardButtons {
            button.layer?.cornerRadius = (side * 0.27).rounded()
        }
    }

    /// 防抖：拖动过程中 `didMove` 会连续触发，逐次纠正会跟用户“抢”窗口。
    private var pullBackTask: Task<Void, Never>?

    private func schedulePullBackCheck() {
        pullBackTask?.cancel()
        pullBackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.pullBackIfFullyOffscreen()
        }
    }

    /// 松手后把「完全离开所有屏幕」的窗口拉回可见区。
    ///
    /// 判据是**完全离开**而不是「部分越界」：把图挪到屏幕边缘、让它一半
    /// 贴在外面是一种正常摆法（用户就是这么看长图的）；只有整个窗口
    /// 都不在任何屏幕的可见区里时，他才真的再也点不到它了。
    ///
    /// 不会与拖动打架：调用点要么是拖动结束（`performDrag` 返回），
    /// 要么是移动停止 250ms 之后。
    func pullBackIfFullyOffscreen() {
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else {
            return
        }
        let target = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rescued = PinManager.clampOrigin(frame.origin, size: frame.size, into: target)
        setFrameOrigin(rescued)
        // 多行字符串里的属性访问会要求显式 `self`；先取值，顺带让日志更短。
        let position = "\(Int(rescued.x)),\(Int(rescued.y))"
        logger.notice("pin pulled back from offscreen to \(position, privacy: .public)")
    }

    /// 菜单项与日志用的单行描述。
    ///
    /// 用窗口的**逻辑**尺寸而非像素尺寸：用户在屏幕上看到的就是这个大小，
    /// 菜单里写像素值会与眼睛看到的不一致（2x 屏上差一倍）。
    var descriptor: String {
        let time = DateFormatter.pinTime.string(from: createdAt)
        return "#\(pinID) · \(Int(pixelSize.width))×\(Int(pixelSize.height)) · \(time)"
    }

    /// 菜单项缩略图。
    ///
    /// 只把已有的 `CGImage` 包一层 `NSImage` 并给定显示尺寸，**不复制像素**；
    /// 菜单每次展开都会重建，所以这一步必须便宜。
    func menuThumbnail(maxHeight: CGFloat = 18) -> NSImage? {
        guard let image = contentImage, image.height > 0 else { return nil }
        let ratio = maxHeight / CGFloat(image.height)
        return NSImage(
            cgImage: image,
            size: CGSize(width: CGFloat(image.width) * ratio, height: maxHeight)
        )
    }

    /// 调整透明度（契约要求「可调透明度」）。
    func setAlpha(_ alpha: Double) {
        self.alphaValue = CGFloat(min(1, max(0.2, alpha)))
    }

    /// 按比例缩放（以窗口中心为锚点，避免缩放时位置乱跑）。
    ///
    /// 缩放的下限由**最小卡片尺寸**决定，而不是写死 0.15：卡片小到放不下按钮时，
    /// 超出的按钮会被 `masksToBounds` 剪掉，最坏情况是「＋」被剪掉——用户把图缩到
    /// 很小，却再也点不到放大（实测旧下限 0.15 时，一张 200×150 的卡片只剩 30pt 宽，
    /// 四个按钮都放不下）。基准尺寸本身比最小卡片还小时（铉的是一个小图标）
    /// **不强制放大**，只是不能再缩小。
    func applyScale(_ newScale: Double, pixelSize: CGSize, screenScale: CGFloat) {
        let lower = Self.minimumScale(pixelSize: pixelSize, screenScale: screenScale)
        let clamped = min(Self.maximumScale, max(lower, newScale))
        scale = clamped
        let logical = CGSize(
            width: pixelSize.width / screenScale * CGFloat(clamped),
            height: pixelSize.height / screenScale * CGFloat(clamped)
        )
        let center = CGPoint(x: frame.midX, y: frame.midY)
        setFrame(
            CGRect(
                x: center.x - logical.width / 2,
                y: center.y - logical.height / 2,
                width: logical.width,
                height: logical.height
            ),
            display: true
        )
        imageView.frame = CGRect(origin: .zero, size: logical)
        // 按钮自己不会跟着变大：它们是控件，位置贴右上角即可。
        // autoresizing 也会算一次，这里显式再算一次是为了让结果与
        // 「窗口刚创建」时的路径完全一致（同一段代码，不依赖 AppKit 的时机）。
        layoutCardButtons()
    }

    /// 最大缩放：再大只是把图变成马赛克，还占满屏幕。
    static let maximumScale: Double = 3

    /// 绝对下限（与卡片尺寸无关的那条）。
    static let absoluteMinimumScale: Double = 0.15

    /// 卡片的最小边长：再小就放不下按钮了（详见 `buttonArrangements` 与 `applyScale`）。
    ///
    /// 取 64 而不是刚好放下的 42：小卡片上除了按钮还要留得下**可拖动的区域**，
    /// 否则卡片就成了一块只能点按钮、不能挪动的面板。
    static let minimumCardSide: CGFloat = 64

    /// 当前图片在本屏上的缩放下限。
    ///
    /// - Parameters:
    ///   - pixelSize: 图像像素尺寸。
    ///   - screenScale: 图像所在屏幕的缩放。
    /// - Returns: 不小于 `absoluteMinimumScale`、且不会让卡片小于
    ///   `minimumCardSide` 的比例；图片本来就小到低于该尺寸时返回 1（不强制放大）。
    static func minimumScale(pixelSize: CGSize, screenScale: CGFloat) -> Double {
        let shortSide = min(pixelSize.width, pixelSize.height) / max(1, screenScale)
        guard shortSide > 0 else { return absoluteMinimumScale }
        let toFitButtons = Double(minimumCardSide / shortSide)
        return min(1, max(absoluteMinimumScale, toFitButtons))
    }

    /// 按倍率缩放（等比）。按钮与滚轮共用，两条入口的手感因此同源。
    ///
    /// 用**乘性**而不是加性：0.15 + 0.1 是 +67%，3.0 + 0.1 只有 +3%——
    /// 同一句加法在两端的手感差 20 倍。
    func scaleBy(_ factor: Double) {
        applyScale(scale * factor, pixelSize: pixelSize, screenScale: screenScale)
    }

    // MARK: - 显示 / 隐藏 / 关闭

    /// 隐藏（**保留位图**，可恢复）。
    ///
    /// 用 `orderOut` 而不是 `setIsVisible(false)`：前者同时把它移出窗口层级，
    /// 不会参与其它窗口的合成。
    func hidePin() {
        guard !isUserHidden else { return }
        isUserHidden = true
        orderOut(nil)
    }

    /// 重新显示。位置、缩放、透明度都保持隐藏前的样子
    /// ——用户隐藏只是想「先挪开」，不是重置。
    func showPin() {
        guard isUserHidden else { return }
        isUserHidden = false
        // `orderFrontRegardless`：本应用是 `.accessory`，窗口可能不是 key，
        // 用 `makeKeyAndOrderFront` 会抢焦点（用户只是在看，不想切应用）。
        orderFrontRegardless()
    }

    /// 切换显示/隐藏。
    func toggleVisibility() {
        if isUserHidden {
            showPin()
        } else {
            hidePin()
        }
    }

    // MARK: - 交互

    /// 缩放与透明度的**输入**。
    ///
    /// 把「事件 → 语义」的翻译从「语义 → 效果」里分开，是为了可测：
    /// 手势事件（`magnify`）没有公开的构造方式，合成不出来，
    /// 所以诊断只能喂这一层；事件分发那一层薄到看一眼就能确认。
    enum CardInput: Equatable {
        /// 滚轮：`delta` 是 `scrollingDeltaY`，`precise` 是 `hasPreciseScrollingDeltas`。
        case scroll(delta: Double, precise: Bool)
        /// 触控板双指捏合：`amount` 是 `magnification`。
        case pinch(amount: Double)
    }

    /// 处理缩放/透明度输入。
    ///
    /// 修饰键的语义：**⌃（或 ⌥）→ 透明度，其余 → 缩放**。
    /// ⌃ 是用户指定的（与多数看图应用的「⌃+滚轮」惯例一致），⌥ 保留为别名：
    /// 两者都不需要额外记忆，且不会与系统手势冲突到不可用。
    func applyCardInput(_ input: CardInput, transparency: Bool) {
        switch input {
        case .scroll(let delta, let precise):
            guard delta != 0 else { return }
            if transparency {
                setAlpha(Double(alphaValue) + delta * (precise ? 0.004 : 0.03))
            } else {
                scaleBy(Self.zoomFactor(forScrollDelta: delta, precise: precise))
            }
        case .pinch(let amount):
            guard amount != 0 else { return }
            if transparency {
                // 捏合的 amount 量级比滚动小得多（一次手势常累计 0.1～0.5），
                // 所以系数比滚轮大：0.1 的手势 → 透明度 5%。
                setAlpha(Double(alphaValue) + amount * 0.5)
            } else {
                // 捏合是「倍率增量」，用**指数映射**而不是 `1 + amount`：
                //
                // * `1 + amount` 不可逆：捏出 0.2 再捏回 -0.2 得到 ×1.2 × 0.8 = ×0.96，
                //   连捏几下就会莫名缩小（诊断里第一版就是这么写的，被断言当场抓住）；
                // * `amount` 小于 -1 时 `1 + amount` 会变成负倍率，图上会直接翻转/归零。
                //
                // `exp(amount)` 天然可逆（+0.2 与 -0.2 互为倒数）、恒为正，
                // 且「捏得越多、变得越多」连续成立。
                scaleBy(Foundation.exp(amount))
            }
        }
    }

    /// 滚轮缩放；按住 ⌃（或 ⌥）调透明度。
    ///
    /// 透明度是调整一次就完事的，缩放是高频操作，所以高频的那件不需要修饰键。
    ///
    /// 幅度必须**按设备区分**，否则总有一类手感是错的：触控板/妙控鼠标给的是精确像素
    /// （一次滑动常有几十点），普通滚轮给的是行数（每格 ±1）。旧实现一律按「2% × delta」
    /// 算——鼠标滚一格只变 2%，用户的结论是「滚轮根本不能缩放」。
    override func scrollWheel(with event: NSEvent) {
        applyCardInput(
            .scroll(delta: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas),
            transparency: event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option)
        )
    }

    /// 触控板双指捏合：缩放；按住 ⌃（或 ⌥）调透明度。
    ///
    /// ⚠️ 这条路径只在**本应用活跃、且这张卡片是指针下的窗口**时才生效：
    /// 手势事件（`magnify`）不像滚动那样会投递给非活跃应用的窗口。
    /// 非活跃时的捏合由 `PinManager` 的**全局监视器**接手（见那里的说明）。
    /// 两条路径天然互斥：全局监视器收不到发给本进程的事件。
    override func magnify(with event: NSEvent) {
        notePinchBegan(source: "window", amount: Double(event.magnification))
        applyCardInput(
            .pinch(amount: Double(event.magnification)),
            transparency: event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option)
        )
    }

    /// 记一条「捏合开始」。
    ///
    /// 一次连续捏合会连续到达几十个事件，逐个记日志会把日志刷没；这里只记首次，
    /// 停手 400ms 后才允许再记。日志的价值在于回答「事件到底有没有到达」——
    /// 那是「捏合没反应」时唯一能把「系统没投递」与「我们没处理」分开的证据。
    func notePinchBegan(source: String, amount: Double) {
        pinchLogTask?.cancel()
        if !isPinching {
            isPinching = true
            logger.notice("""
                pinch began; source=\(source, privacy: .public) amount=\(amount, privacy: .public)
                """)
        }
        pinchLogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.isPinching = false
        }
    }

    private var isPinching = false
    private var pinchLogTask: Task<Void, Never>?

    // MARK: - 键盘

    /// 键盘：ESC = 关闭。
    ///
    /// 规则与 ✕ **完全相同**（`performClose`）：固定中只隐藏（位图保留），
    /// 已取消固定才隐藏并释放。两个入口共用同一个方法，否则迟早会出现
    /// 「按 ESC 丢了一张，点 ✕ 只是收起」这类不一致，而它只会以「我的图怎么没了」暴露。
    ///
    /// 前提是窗口能成为 key window（见 `canBecomeKey`）：本应用不活跃时，
    /// ESC 属于当前活跃应用，我们无权截获（截获键盘需要辅助功能权限，本项目刻意不要）。
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == Self.escapeKeyCode else {
            super.keyDown(with: event)
            return
        }
        logger.notice("pin #\(self.pinID, privacy: .public) escape pressed")
        performClose(from: "escape key")
    }

    /// ESC 的键码。与覆盖层用的是同一个（`OverlayWindow.keyDown`）。
    static let escapeKeyCode: UInt16 = 53

    /// 无边框窗口默认不能成为 key window，而**收不到 keyDown 就收不到 ESC**。
    ///
    /// 成为 key 的时机是用户点过这张卡片（点击会激活本应用，那已是既有行为）；
    /// 不点它、在别的应用里按 ESC，事件与我们无关——那是系统边界，不是缺陷。
    override var canBecomeKey: Bool { true }

    /// 但不必成为 main window：卡片不参与「应用的主窗口」语义（没有菜单栏归属）。
    override var canBecomeMain: Bool { false }

    /// 一次滚动的缩放倍率。
    ///
    /// 系数来自手感而非数学：精确滚动的 100 点 ≈ ×1.35（一次长滑约放大三分之一），
    /// 普通滚轮一格 ≈ ×1.08、两格 ≈ ×1.17。系数写成幂函数是为了让「滑得越多、变越多」
    /// 连续成立，而不是按格跳。
    static func zoomFactor(forScrollDelta delta: Double, precise: Bool) -> Double {
        precise ? pow(1.003, delta) : pow(1.08, delta)
    }

    /// 右键菜单：只剩调整项（原始大小、恢复不透明）。
    ///
    /// 「隐藏」与「关闭」**不再出现在这里**：它们是这张卡片的主出口，
    /// 藏在只有试过才发现的右键菜单里等于没有入口，已移到卡片右上角的按钮
    /// （契约 §6）。留下的两项是调整，随手可用即可，不必占据卡片上的位置。
    override func rightMouseDown(with event: NSEvent) {
        if let view = contentView {
            NSMenu.popUpContextMenu(cardAdjustmentMenu(), with: event, for: view)
        }
    }

    /// 右键菜单的内容。
    ///
    /// 抽成方法是为了让诊断能直接断言「隐藏/关闭确实不在菜单里」——
    /// 只靠人工右键确认的事，迟早会在某次重构里悄悄回退。
    func cardAdjustmentMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "原始大小", action: #selector(resetScale), keyEquivalent: "")
        menu.addItem(withTitle: "不透明", action: #selector(resetAlpha), keyEquivalent: "")
        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    /// 图钉：切换固定状态。**不动可见性**（用户要求「取消固定先不隐藏」）。
    @objc private func togglePinFromCard() {
        isUnpinned.toggle()
        refreshCardButtons()
        let state = isUnpinned ? "unpinned" : "pinned"
        logger.notice("pin #\(self.pinID, privacy: .public) \(state, privacy: .public) from card")
    }

    /// 关闭：固定中只隐藏（位图保留），已取消固定才隐藏并释放。
    ///
    /// 于是「关闭」永远不会悄悄丢掉用户要求保留的图：要销毁必须先按图钉
    /// （用户给的规则）。
    @objc private func closeFromCard() {
        performClose(from: "card button")
    }

    /// 「关闭」的规则（✕ 与 ESC 共用）。
    ///
    /// - Parameter source: 触发来源，只用于日志——两个入口在日志里必须分得清。
    func performClose(from source: String) {
        if isUnpinned {
            logger.notice("""
                pin #\(self.pinID, privacy: .public) closed from \(source, privacy: .public) (releasing bitmap)
                """)
            closeAndRelease()
        } else {
            hidePin()
            logger.notice("""
                pin #\(self.pinID, privacy: .public) hidden from \(source, privacy: .public) (bitmap kept)
                """)
        }
    }

    /// 放大：每次 10%，等比。
    ///
    /// 选 1.1 而不是 1.05：按钮是**离散**操作，点五下才变大一半会让用户以为按钮没反应。
    @objc private func zoomInFromCard() {
        scaleBy(Self.buttonZoomStep)
    }

    /// 缩小：每次 10%，等比；到达最小卡片尺寸时会自然停住。
    @objc private func zoomOutFromCard() {
        scaleBy(1 / Self.buttonZoomStep)
    }

    /// 缩放按钮每次点击的倍率。
    static let buttonZoomStep: Double = 1.1

    @objc private func resetScale() {
        applyScale(1, pixelSize: pixelSize, screenScale: screenScale)
    }

    @objc private func resetAlpha() {
        setAlpha(1)
    }

    /// 关闭并**释放位图**。这是释放位图的唯一实现。
    ///
    /// 两个调用点：卡片上的 ✕（只在**已取消固定**时走这里）、菜单栏「全部关闭」
    /// （带确认框，一次释放全部）。
    func closeAndRelease() {
        // 先置空位图：即使后续 AppKit 侧出现异常，内存也已经交还。
        contentImage = nil
        imageView.image = nil
        isUserHidden = false
        isUnpinned = false
        orderOut(nil)
        close()
        onClose?()
    }
}

// MARK: - 卡片文案

/// 图钉按钮在「固定中」的说明：写明它**不动可见性**，并预告关闭会怎样。
///
/// 两个按钮两种状态共四句，集中在这里：它们是用户唯一能读到「这次点击会不会
/// 释放内存」的地方，初始状态与切换后的文案必须逐字一致——分开写迟早会出现
/// 状态与文案互相矛盾，而那正是本功能最难排查的一类缺陷。
private let pinButtonTipWhenPinned = "取消固定（卡片继续显示；取消后再点关闭才会释放内存）"

/// 图钉按钮在「已取消固定」的说明。
private let pinButtonTipWhenUnpinned = "重新固定（恢复为「关闭只隐藏、不释放」）"

/// 关闭按钮在「固定中」的说明：这一次点击只隐藏。
private let closeButtonTipWhenPinned = "关闭：隐藏但不释放（可从菜单栏恢复）"

/// 关闭按钮在「已取消固定」的说明：这一次点击会释放内存。
private let closeButtonTipWhenUnpinned = "关闭：隐藏并释放内存（不可恢复）"

/// 放大按钮的说明。写明步长与「滚轮也能用」两条入口——
/// 按钮是给「不知道有滚轮」的人准备的。
private let plusButtonTip = "放大（每次 10%；滚轮或双指滑动也能缩放）"

/// 缩小按钮的说明。
private let minusButtonTip = "缩小（每次 10%；滚轮或双指滑动也能缩放）"

/// 一次钉图的结果。
///
/// 刻意不用「返回可选窗口」表达失败：调用方需要区分「成功」与
/// 「因为达到上限而没做」，后者要给出带上限数字的提示。
enum PinResult {
    /// 已创建，窗口已显示在屏幕上。
    case created(PinWindow)
    /// 已达上限，**未**创建，也没有关掉任何已有的 Pin。
    case limitReached(limit: Int)
}

/// 所有 Pin 的管理者：数量上限、显示状态与释放路径都在这里。
@MainActor
final class PinManager {

    /// 上限的默认值。与设置里的默认值**同源**，避免两处各写一个数字。
    static var defaultMaximumPins: Int { AppSettings.defaultPinMaximumCount }

    /// 上限的来源。
    ///
    /// 用设置对象而不是复制一份整数：复制会让「设置里改了上限，
    /// 管理器还在用旧值」这种状态分叉成为可能。
    private let settings: AppSettings?

    /// 当前上限。设置缺失（诊断构造）时退回默认值。
    var maximumPins: Int {
        max(1, settings?.pinMaximumCount ?? Self.defaultMaximumPins)
    }

    /// 当前管理的卡片。
    ///
    /// 捏合监视器跟着它装卸：没有卡片时监视全系统的捏合毫无意义，
    /// 却要为每一个捏合事件起一个主 actor 任务。
    private(set) var pins: [PinWindow] = [] {
        didSet { updatePinchMonitor() }
    }

    /// Pin 序号的分配器。隐藏后重新显示不改变它，因此菜单项不会跳号。
    private var nextPinID = 1

    /// 触控板捏合的全局监视器（见 `installPinchMonitor`）。
    ///
    /// `nonisolated(unsafe)`：`NSEvent.removeMonitor` 不访问本对象的其它状态，
    /// 与 `GlobalHotKey` 里的 Carbon 句柄同理。
    nonisolated(unsafe) private var pinchMonitor: Any?

    init(settings: AppSettings? = nil) {
        self.settings = settings
    }

    /// 有卡片时装上捏合监视器，没有时卸下。
    private func updatePinchMonitor() {
        if pins.isEmpty {
            if let pinchMonitor {
                NSEvent.removeMonitor(pinchMonitor)
                self.pinchMonitor = nil
                logger.notice("pinch monitor removed; no pins left")
            }
        } else {
            installPinchMonitor()
        }
    }

    deinit {
        if let pinchMonitor {
            NSEvent.removeMonitor(pinchMonitor)
        }
    }

    /// 装上「指针落在卡片上就认领捏合」的全局监视器。
    ///
    /// ── 为什么不是窗口里的 `magnify(with:)` ──
    ///
    /// 手势事件（`magnify`）**不会投递给非活跃应用的窗口**，而滚动事件会——
    /// 用户实测「指针放在卡片上双指捏合没反应」，而同一位置的滚轮是好的。
    /// 卡片绝大多数时间都处在「别的应用在前台」的状态，所以只靠窗口那是行不通的。
    ///
    /// 全局监视器能看到**发往任何应用**的这类事件（手势不属于需要辅助功能权限的键盘类，
    /// 所以不需要任何新权限），于是按指针位置把落在卡片上的那些认领过来。
    ///
    /// **不消费、不阻断**：我们只是观察者，事件照常投递给它原本的目标应用。
    private func installPinchMonitor() {
        guard pinchMonitor == nil else { return }
        pinchMonitor = NSEvent.addGlobalMonitorForEvents(matching: .magnify) { [weak self] event in
            // 立刻取出值类型：`NSEvent` 不是 Sendable，把它跨到主 actor 会被并发检查拦住。
            let amount = Double(event.magnification)
            let transparency = event.modifierFlags.contains(.control)
                || event.modifierFlags.contains(.option)
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handlePinchFromMonitor(amount: amount, transparency: transparency, at: location)
            }
        }
        logger.notice("pinch monitor installed; available=\(self.pinchMonitor != nil, privacy: .public)")
    }

    private func handlePinchFromMonitor(amount: Double, transparency: Bool, at location: CGPoint) {
        guard amount != 0, let target = pin(at: location) else { return }
        target.notePinchBegan(source: "global monitor", amount: amount)
        target.applyCardInput(.pinch(amount: amount), transparency: transparency)
    }

    /// 捏合监视器是否已装上（诊断用：它是非活跃应用下捏合的唯一路径）。
    var isPinchMonitorInstalled: Bool { pinchMonitor != nil }

    /// 屏幕坐标（左下原点，与 `NSWindow.frame` 同系）下指针所在的卡片。
    ///
    /// 从后往前找：后钉的在窗口层级上更新，重叠时命中的应该是用户看到的那一张。
    /// 隐藏的卡片不参与——它们已从窗口层级移出，指针不可能在它们上面。
    func pin(at location: CGPoint) -> PinWindow? {
        pins.last { !$0.isUserHidden && $0.frame.contains(location) }
    }

    /// 当前显示中的 Pin 数量。
    var visibleCount: Int { pins.filter { !$0.isUserHidden }.count }

    /// 当前隐藏的 Pin 数量。
    var hiddenCount: Int { pins.filter(\.isUserHidden).count }

    /// 是否至少有一张正显示着。「一键隐藏/显示」的切换依据。
    var hasVisiblePin: Bool { pins.contains { !$0.isUserHidden } }

    /// 是否已达上限。菜单栏据此显示提示行。
    var isAtLimit: Bool { pins.count >= maximumPins }

    /// 当前持有位图的估算字节数（诊断与菜单展示用）。
    var estimatedBytes: Int {
        pins.reduce(0) { total, pin in
            guard let image = pin.contentImage else { return total }
            return total + image.width * image.height * 4
        }
    }

    /// 钉一张图。
    ///
    /// - Parameters:
    ///   - image: 要钉住的图（完整位图）。
    ///   - screenScale: 图像所在屏幕的缩放，用于把像素尺寸换算成窗口的逻辑尺寸。
    ///   - topLeft: 期望位置的**左上角**屏幕坐标（通常是原截图选区的位置）。
    ///     nil 表示由管理器挑一个位置（历史记录重钉走这条路）。
    /// - Returns: 成功时携带新窗口；达到上限时返回 `.limitReached`。
    @discardableResult
    func pin(
        image: CGImage,
        screenScale: CGFloat,
        topLeft: CGPoint? = nil
    ) -> PinResult {
        let limit = maximumPins
        guard pins.count < limit else {
            return .limitReached(limit: limit)
        }

        let pixelSize = CGSize(width: image.width, height: image.height)
        let logical = CGSize(
            width: pixelSize.width / screenScale,
            height: pixelSize.height / screenScale
        )
        let window = PinWindow(
            pinID: nextPinID,
            image: image,
            logicalSize: logical,
            at: resolveOrigin(topLeft: topLeft, size: logical),
            screenScale: screenScale
        )
        nextPinID += 1
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.pins.removeAll { $0 === window }
        }
        window.orderFrontRegardless()
        pins.append(window)
        return .created(window)
    }

    /// 隐藏全部。
    func hideAll() {
        for pin in pins {
            pin.hidePin()
        }
    }

    /// 显示全部。
    func showAll() {
        for pin in pins {
            pin.showPin()
        }
    }

    /// 一键切换：有可见的就全隐，全隐了就全显。
    ///
    /// 这个语义是为了让一个热键同时承担「腾空屏幕」与「都拿回来」两件事。
    /// 混合状态（有的显示有的隐藏）按「还有可见的」处理——用户按它的
    /// 第一诉求几乎总是「屏幕上太乱了」。
    func toggleAllVisibility() {
        if hasVisiblePin {
            hideAll()
        } else {
            showAll()
        }
    }

    /// 切换某一张的显示状态。
    func toggleVisibility(of pin: PinWindow) {
        pin.toggleVisibility()
    }

    /// 关闭全部 Pin（用户一键清除或应用退出）。
    func closeAll() {
        for pin in pins {
            pin.onClose = nil
            pin.closeAndRelease()
        }
        pins.removeAll()
    }

    // MARK: - 位置

    /// 决定新 Pin 的窗口位置（AppKit 坐标的窗口左下角）。
    ///
    /// 三条规则，按优先级：
    ///   1. 首选「原截图选区左上角」——「钉住」的心智就是把刚才那块留在原处，
    ///      出现在别处会让人先去找它；
    ///   2. 与已有 Pin 重叠时向**右下**级联偏移，直到不重叠或尝试用尽；
    ///      否则连钉几张会完全叠在一起，看起来像只钉了一次；
    ///   3. 最后把窗口整体夹回屏幕可见区，避免出现拖不回来的「丢窗口」。
    private func resolveOrigin(topLeft: CGPoint?, size: CGSize) -> CGPoint {
        let screen = Self.screen(containing: topLeft) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let base: CGPoint
        if let topLeft {
            // 传入的是左上角，而窗口坐标记的是左下角。
            base = CGPoint(x: topLeft.x, y: topLeft.y - size.height)
        } else {
            base = CGPoint(x: visible.minX + 40, y: visible.maxY - size.height - 40)
        }

        let step: CGFloat = 24
        for index in 0..<Self.cascadeAttempts {
            let candidate = CGPoint(
                x: base.x + step * CGFloat(index),
                y: base.y - step * CGFloat(index)
            )
            let frame = CGRect(origin: candidate, size: size)
            if !pins.contains(where: { $0.frame.intersects(frame) }) {
                return Self.clampOrigin(candidate, size: size, into: visible)
            }
        }
        return Self.clampOrigin(base, size: size, into: visible)
    }

    /// 级联的最大尝试次数。12 次足够铺开一屏，再多只是把窗口推出屏幕。
    private static let cascadeAttempts = 12

    /// 找到包含某个点的屏幕。找不到（点在屏幕外或为 nil）时返回 nil。
    private static func screen(containing point: CGPoint?) -> NSScreen? {
        guard let point else { return nil }
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// 把窗口夹进可见区域。
    ///
    /// 比可见区还大的窗口没法整个塞进去，只能选择保留哪一侧。卡片按钮固定在
    /// **右上角**（✕、图钉都在那里），所以竖直方向保留**顶边**、水平方向保留
    /// **右边**：溢出的部分落在屏幕左侧/下方，按钮始终看得见也点得到。
    ///
    /// 不能像旧实现那样对齐「左下角」：AppKit 是左下原点，`y = visible.minY`
    /// 会把超出部分全堆在**顶部**（被菜单栏挡住或伸出屏幕），右上角的按钮
    /// 恰好一起消失——这正是「大贴图关不掉」的缺陷。
    ///
    /// 溢出的部分仍可从可见区域拖动查看，`pullBackIfFullyOffscreen` 也复用
    /// 这个判据，因此拖出去后的拉回落点同样保证按钮可见。
    ///
    /// 不是 private：`PinWindow` 在「拖出屏幕后拉回」时要用同一个判据，
    /// 两处各写一份迟早会出现「新建时夹得住、拖出去夹不住」。
    static func clampOrigin(_ origin: CGPoint, size: CGSize, into visible: CGRect) -> CGPoint {
        let x: CGFloat
        if size.width >= visible.width {
            // 保留右边：右边缘对齐可见区右边缘（窗口左边缘会伸出屏幕）。
            x = visible.maxX - size.width
        } else {
            x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        }
        let y: CGFloat
        if size.height >= visible.height {
            // 保留顶边：窗口顶边 = origin.y + size.height，对齐可见区顶边。
            y = visible.maxY - size.height
        } else {
            y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return CGPoint(x: x, y: y)
    }
}

extension DateFormatter {
    /// Pin 描述里用的时间格式。集中一处，避免各处写出不同精度的时间。
    static let pinTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
