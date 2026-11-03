import AnShotCapture
import AnShotCore
import AppKit

/// 录制范围框：录制期间在屏幕上标出「正在录哪一块」。
///
/// **为什么需要它**：录制开始后截图的覆盖层就被收起了，屏幕上不再有任何东西
/// 告诉用户录制区域的边界。用户一旦切到别的窗口或拖动了内容，就无从判断
/// 这一帧到底有没有被录进去；等到停止才发现录错范围，代价是一整段素材。
///
/// 三条设计约束：
///
/// 1. **不保留截图的冻结底图与暗色遮罩。** 录制期间用户要正常操作桌面，
///    本框只画边框，其余区域完全透明。
/// 2. **鼠标穿透。** `ignoresMouseEvents` 必须为真，否则边框会挡住它覆盖的
///    那一圈界面元素（标题栏、缩放角），用户点不到自己正在录的内容。
/// 3. **不激活、不出现在所有 Space 之外。** 与录制控制条同一套 chrome 约定。
@MainActor
public final class RecordingRegionFrame {

    private let panel: NSPanel
    private let frameView: FrameView

    public init(excludedFromCapture: Bool = false) {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        frameView = FrameView()
        panel.contentView = frameView

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // 与准备面板同理：预览范围框要在截图覆盖层**之上**显示。
        // 覆盖层是 `.screenSaver`，低于它的窗口一律看不见。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 鼠标穿透：录制期间用户必须能正常操作被录的内容
        panel.ignoresMouseEvents = true
        // 声明「本窗口不可被屏幕捕获」。
        //
        // 两条使用路径对它的需求不同，所以做成参数：
        //
        // * **录制**传 false。录制按 `windowID` 在**捕获之后**过滤掉范围框，
        //   不需要这个声明；而不声明才能让诊断自拍/人工截图看到它——
        //   那个诊断的价值就在于让人看清三种状态的颜色差异。
        // * **滚动截图**传 true。它的抓帧是固定区域（`CaptureScope.region`），
        //   **无法按窗口排除**，而选区框正好压在选区边界上——不声明的话
        //   每一帧都会把那条蓝边拼进长图（长图两端各多一道线）。
        if excludedFromCapture {
            panel.sharingType = .none
        }
    }

    /// 边框的外观。
    public enum Appearance: String {
        /// 预览：准备面板已弹出，尚未开始录制（蓝色——「将要录制这一块」）。
        case preview
        /// 候选：正在选取录制目标，鼠标下那个对象的范围（蓝色**虚线**）。
        ///
        /// 与 `.preview` 的区别不在颜色而在「是否已落定」：候选跟着鼠标跑，
        /// 松开/单击之前都不能当作已选的录制范围。
        case candidate
        /// 录制中（红）。
        case recording
        /// 暂停（琥珀）。
        case paused

        /// 滚动截图进行中（蓝色实线——「正在截取这一块」）。
        ///
        /// 与录制的区别在于「用户要不要动手」：录制期间用户去操作别的东西，
        /// 得先把范围框标清楚、还得防他动错；滚动截图则直接要求用户**在该区域内滚动**，
        /// 所以用与选区一致的蓝色，让它读起来是「我选的那一块」而不是另一个新东西。
        case scrollshot

        /// 该状态对应的边框颜色。
        ///
        /// 颜色是唯一能区分三种状态的手段——边框位置在三种状态下可以完全相同。
        /// 具体取值统一在 `CaptureFrameStyle`，与截图选框同源。
        var color: RGBAColor {
            switch self {
            case .preview, .candidate, .scrollshot: return CaptureFrameStyle.selection
            case .recording: return CaptureFrameStyle.recording
            case .paused: return CaptureFrameStyle.paused
            }
        }

        /// 是否用虚线绘制。
        var dash: [CGFloat]? {
            self == .candidate ? CaptureFrameStyle.candidateDashPattern : nil
        }
    }

    /// 边框是否可见。
    public var isVisible: Bool { panel.isVisible }

    /// 边框当前外观（不可见时为 nil），供诊断核对「候选与已选定画法不同」。
    public var currentAppearance: Appearance? {
        panel.isVisible ? frameView.frameAppearance : nil
    }

    /// 边框当前所在的矩形（**AppKit 屏幕坐标**）；不可见时为 nil。
    public var currentRect: CGRect? {
        panel.isVisible ? panel.frame : nil
    }

    /// 范围框的窗口号，用于让捕获过滤器把它排除在成片之外。
    /// 同样只有 `orderFront` 之后才有值。
    public var windowID: CGWindowID? {
        let number = panel.windowNumber
        return number > 0 ? CGWindowID(number) : nil
    }

    /// 显示或移动边框。
    ///
    /// - Parameters:
    ///   - rect: 录制区域，**AppKit 屏幕坐标**。
    ///   - appearance: 外观（预览 / 候选 / 录制中 / 暂停）。
    public func show(rect: CGRect, appearance: Appearance) {
        // 重复设置相同的位置与外观会重新 orderFront 一次，在随鼠标悬停
        // 高频刷新候选时表现为闪烁。
        if panel.isVisible, panel.frame == rect, frameView.frameAppearance == appearance {
            return
        }
        frameView.frameAppearance = appearance
        // 与屏幕四角贴合所需的屏幕几何：屏幕自己的圆角半径 + 屏幕 frame。
        frameView.screenGeometry = Self.screenGeometry(for: rect)
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
        frameView.needsDisplay = true
    }

    /// 本框所在显示器的屏幕几何（frame 与四角半径）。
    ///
    /// **取包含关系而不是「中心点落在哪块屏」**：跨度大的框中心点可能落在一块屏上、
    /// 而它的角贴在另一块屏上，只看中心会把别的屏幕的边缘误判成本框的贴合目标。
    /// 多块屏都有交集时取交集面积最大的那块。
    ///
    /// 屏幕圆角可能取不到（系统不提供）：此时半径为 nil，框退回普通圆角——
    /// 不把「读不到」当作「屏幕是直角」。
    private static func screenGeometry(for rect: CGRect) -> ScreenGeometry {
        let matches = NSScreen.screens.compactMap { screen -> (NSScreen, CGFloat)? in
            let overlap = screen.frame.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            return area > 0 ? (screen, area) : nil
        }
        guard let (screen, _) = matches.max(by: { $0.1 < $1.1 }) else {
            return ScreenGeometry(frame: nil, radii: nil)
        }
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return ScreenGeometry(frame: screen.frame, radii: nil)
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        return ScreenGeometry(
            frame: screen.frame,
            radii: DisplayCornerGeometry.radii(for: displayID)
        )
    }

    /// 边框所在的屏幕几何。
    struct ScreenGeometry {
        /// 屏幕在 AppKit 全局坐标下的 frame；nil 表示取不到（不做贴合）。
        let frame: CGRect?
        /// 屏幕四角半径；nil 表示系统不提供（保留普通圆角）。
        let radii: DisplayCornerRadii?
    }

    /// 只更新外观，不移动。
    public func update(appearance: Appearance) {
        guard frameView.frameAppearance != appearance else { return }
        frameView.frameAppearance = appearance
        frameView.needsDisplay = true
    }

    /// 更新位置与外观。窗口录制跟随窗口移动时使用。
    public func update(rect: CGRect, appearance: Appearance? = nil) {
        if let appearance, frameView.frameAppearance != appearance {
            frameView.frameAppearance = appearance
        }
        // 位置变了，贴的是哪个屏角也跟着变（例如从屏幕中间移到屏幕顶端）。
        frameView.screenGeometry = Self.screenGeometry(for: rect)
        panel.setFrame(rect, display: true)
        frameView.needsDisplay = true
    }

    /// 关闭并释放边框。
    public func hide() {
        panel.orderOut(nil)
    }

    /// 只画边框的视图。
    private final class FrameView: NSView {
        /// 命名上避开 `appearance`——`NSView` 已有同名的 `NSAppearance?` 属性，
        /// 同名声明会被编译器判为非法覆盖。
        var frameAppearance: Appearance = .recording

        /// 本框所在屏幕的几何，由 `RecordingRegionFrame.show/update` 算好。
        var screenGeometry = ScreenGeometry(frame: nil, radii: nil)

        override var isOpaque: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }

            // 窗口尺寸理论上远大于描边（范围框尺寸来自选区），但极小值必须防住：
            // 固定内缩会把矩形压成空尺寸（边框整个消失），固定线宽会盖满整个窗口。
            // 线宽不超过短边的八分之一，因而短边小于 24pt 时自动收窄。
            let shortSide = min(bounds.width, bounds.height)
            guard shortSide > 0 else { return }
            let lineWidth = min(CaptureFrameStyle.recordingStrokeWidth, shortSide / 8)

            // 内缩半个最外层线宽：窗口边缘是硬裁剪，越界的绘制不是被压暗
            // 而是直接不存在，边框会缺段。夹取在短边的一半以内，保证矩形非空。
            let outermostWidth = lineWidth + CaptureFrameStyle.contrastExtraWidth
            let inset = min(
                CaptureFrameStyle.strokeInset(lineWidth: outermostWidth),
                shortSide * 0.45
            )
            let rect = bounds.insetBy(dx: inset, dy: inset)

            CaptureFrameStyle.drawBorder(
                in: rect,
                color: frameAppearance.color,
                lineWidth: lineWidth,
                radii: cornerRadii(forDecorated: rect, inset: inset),
                dash: frameAppearance.dash,
                in: context
            )
        }

        /// 逐角半径：本框的角与屏幕的物理屏角重合时，用该屏幕角的实际半径；
        /// 其余角用基准半径。
        ///
        /// **坐标对应容易搞反**：`FrameView` 用的是 AppKit 默认坐标系（y 向上），
        /// 所以视图的 minY 侧对应屏幕**下方**——与截图覆盖层（左上原点）正好相反。
        /// 这里按屏幕语义取 topLeft/bottomLeft，不做额外的上下翻转。
        ///
        /// 只有「两条边都贴」才采用屏幕轮廓：整屏录制（四角全贴）是最常见的受益场景。
        private func cornerRadii(forDecorated rect: CGRect, inset: CGFloat) -> CaptureFrameStyle.CornerRadii {
            var radii = CaptureFrameStyle.cornerRadii(for: rect.size)
            guard let screenFrame = screenGeometry.frame,
                  let screen = screenGeometry.radii else {
                return CaptureFrameStyle.clamped(radii, to: rect.size)
            }
            // 视图与窗口等大，窗口在屏幕上的原点就是视图与屏幕的偏移。
            let origin = window?.frame.origin ?? .zero
            let screenMinX = origin.x + bounds.minX
            let screenMaxX = origin.x + bounds.maxX
            let screenMinY = origin.y + bounds.minY
            let screenMaxY = origin.y + bounds.maxY
            let minXGap = screenMinX - screenFrame.minX
            let maxXGap = screenFrame.maxX - screenMaxX
            let minYGap = screenMinY - screenFrame.minY      // 视图 minY 侧 = 屏幕**下方**
            let maxYGap = screenFrame.maxY - screenMaxY      // 视图 maxY 侧 = 屏幕**上方**

            // **本视图是 AppKit 默认坐标系（左下原点）**：minY 侧是屏幕下方、
            // maxY 侧是屏幕上方——与截图覆盖层（左上原点）正好相反。
            // 所以 `.minXMinY ↔ 屏幕左下角`、`.minXMaxY ↔ 屏幕左上角`。
            func apply(
                _ corner: CaptureFrameStyle.Corner,
                _ screenRadius: CGFloat
            ) -> CaptureFrameStyle.CornerRadii {
                guard CaptureFrameStyle.isCornerAligned(
                    corner,
                    minXGap: minXGap, maxXGap: maxXGap, minYGap: minYGap, maxYGap: maxYGap
                ) else { return radii }
                return CaptureFrameStyle.alignedRadius(
                    for: corner, in: radii, screenRadius: screenRadius, strokeInset: inset
                )
            }

            radii = apply(.minXMinY, screen.bottomLeft)
            radii = apply(.maxXMinY, screen.bottomRight)
            radii = apply(.minXMaxY, screen.topLeft)
            radii = apply(.maxXMaxY, screen.topRight)
            return CaptureFrameStyle.clamped(radii, to: rect.size)
        }
    }
}
