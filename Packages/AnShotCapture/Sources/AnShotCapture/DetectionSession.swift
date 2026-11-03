//
//  DetectionSession.swift
//  AnShotCapture
//
//  一次识别会话：持有窗口快照，按鼠标位置输出应当选中的区域。
//
//  窗口列表在一次会话内只枚举一次。原因有二：
//  1. 枚举要跨进程拿 ScreenCaptureKit 数据，鼠标每移动一像素都枚举一次不可接受；
//  2. 会话期间窗口的位置变化对「截图」这个瞬时动作没有意义——
//     用户看到的是冻结的底图，识别结果必须与那张底图对齐。
//

import AnShotCore
import AppKit
import CoreGraphics
import Foundation

/// 修饰键决定的识别层级偏好。
public enum DetectionLayerPreference: Equatable, Sendable {
    /// 自动：由内到外取第一个命中（控件 → 窗口 → 显示器）。
    case automatic
    /// 强制窗口级（跳过控件级）。
    case window
    /// 强制应用级（该应用在本显示器内的全部窗口）。
    case application
    /// 不识别：手动拖拽模式。
    case disabled
}

/// 识别会话。
///
/// 标注为 `@MainActor`：它持有可变的窗口快照，且只被覆盖层在鼠标事件里使用。
/// 与其加锁，不如把并发约束写进类型——识别本来就是纯 UI 交互路径。
@MainActor
public final class DetectionSession {
    private let detector: ScreenElementDetecting
    private let displayID: CGDirectDisplayID
    private let displayBounds: CGRect

    /// 当前窗口快照，**已按可能的 z 序（前到后）排列**。
    private var windows: [DetectedWindow] = []
    private var isLoaded = false

    public init(
        detector: ScreenElementDetecting,
        displayID: CGDirectDisplayID,
        displayBounds: CGRect
    ) {
        self.detector = detector
        self.displayID = displayID
        self.displayBounds = displayBounds
    }

    /// 是否具备组件级识别能力。
    public var canDetectControls: Bool {
        detector.hasAccessibilityPermission
    }

    /// 已载入的窗口数（诊断用）。
    public var windowCount: Int {
        windows.count
    }

    /// 重新枚举窗口。会话开始时调用一次；枚举失败时保持空列表。
    ///
    /// 失败不抛给调用方：识别是便利功能，取不到就不识别，
    /// 不该让「按热键截图」这条主路径因为窗口枚举失败而中断。
    public func load() async {
        do {
            windows = try await detector.windows(onDisplay: displayID)
        } catch {
            windows = []
        }
        isLoaded = true
    }

    /// 指定全局点应当选中的区域。
    ///
    /// - Parameters:
    ///   - point: **全局左上原点**点坐标（来自鼠标位置）
    ///   - preference: 修饰键决定的层级偏好
    /// - Returns: 识别结果；无命中或关闭识别时为 `nil`（调用方保持现选区）
    public func target(
        atGlobalPoint point: CGPoint,
        preference: DetectionLayerPreference
    ) -> DetectionTarget? {
        guard preference != .disabled, isLoaded else {
            return nil
        }

        switch preference {
        case .disabled:
            return nil

        case .automatic:
            // 由内到外：控件 → 窗口 → 显示器。
            if let control = controlTarget(atGlobalPoint: point) {
                return control
            }
            if let window = windowTarget(atGlobalPoint: point) {
                return window
            }
            return displayTarget()

        case .window:
            return windowTarget(atGlobalPoint: point) ?? displayTarget()

        case .application:
            return applicationTarget(atGlobalPoint: point)
                ?? windowTarget(atGlobalPoint: point)
                ?? displayTarget()
        }
    }

    /// 诊断：在某点直接尝试控件命中，绕过「窗口尺寸判断」。
    ///
    /// 正常流程里，命中元素若覆盖整个窗口会被视为非控件而退回窗口层；
    /// 诊断需要看到那个原始结果，否则无法区分
    /// 「AX 没命中控件」与「命中了但被判定为窗口本身」。
    public func rawControlHitForDiagnostics(
        atGlobalPoint point: CGPoint
    ) -> (role: String?, frame: CGRect, windowTitle: String?)? {
        guard let window = windows.first(where: { $0.frame.contains(point) }) else {
            return nil
        }
        guard let hit = detector.control(
            atGlobalPoint: point,
            inApplication: window.processID
        ) else {
            return nil
        }
        return (hit.role, hit.frame, window.title)
    }

    // MARK: - 各层

    /// 显示器整屏。
    private func displayTarget() -> DetectionTarget? {
        let local = DetectionGeometry.localRect(
            fromGlobal: displayBounds,
            displayBounds: displayBounds
        )
        guard local.width >= 1, local.height >= 1 else {
            return nil
        }
        return DetectionTarget(
            layer: .display,
            rect: local,
            displayID: displayID,
            title: nil,
            globalRect: displayBounds
        )
    }

    /// 鼠标下的窗口。
    ///
    /// 依赖窗口快照的顺序是**前到后**（最上层在前）——与
    /// `CGWindowListCopyWindowInfo` 的语义一致。命中测试取第一个包含该点的窗口。
    private func windowTarget(atGlobalPoint point: CGPoint) -> DetectionTarget? {
        for window in windows where window.frame.contains(point) {
            guard let local = DetectionGeometry.clampedLocalBounds(
                ofGlobalRects: [window.frame],
                displayBounds: displayBounds
            ) else {
                continue
            }
            return DetectionTarget(
                layer: .window,
                rect: local,
                displayID: displayID,
                title: window.title ?? window.applicationName,
                // 身份在命中测试这一刻产生，必须原样带出去：录制需要 windowID 构造过滤器
                windowID: window.windowID,
                processID: window.processID,
                // 捕获范围用**未裁剪**的窗口 frame：窗口录制录的是整个窗口（可跨屏），
                // 而 `local` 已裁进本屏。两者必须都带出去，不能相互替代。
                globalRect: window.frame
            )
        }
        return nil
    }

    /// 鼠标下窗口所属应用在本显示器内的全部窗口。
    private func applicationTarget(atGlobalPoint point: CGPoint) -> DetectionTarget? {
        guard let hit = windows.first(where: { $0.frame.contains(point) }) else {
            return nil
        }

        let siblings = windows.filter { $0.processID == hit.processID }
        guard let box = DetectionGeometry.clampedLocalBounds(
            ofGlobalRects: siblings.map(\.frame),
            displayBounds: displayBounds
        ) else {
            return nil
        }

        return DetectionTarget(
            layer: .application,
            rect: box,
            displayID: displayID,
            // 标题用应用名而不是窗口标题：这一层选中的是整个应用。
            title: hit.applicationName,
            windowID: nil,
            processID: hit.processID,
            // 应用录制**以显示器为范围**（`CaptureScope.application` 的契约），
            // 录出来就是整块显示器，而不是这些窗口的外接矩形。
            // 若这里给外接矩形，录制范围框会画在一块比实际成片小得多的区域上。
            globalRect: displayBounds
        )
    }

    /// 界面控件。
    ///
    /// 顺序是「先找窗口、再在该应用内找控件」，不能反过来：
    /// 覆盖层浮在最顶层，用 system-wide 元素做 AX 命中测试时命中的
    /// 永远是覆盖层自己，控件层会恒等于整屏。详见
    /// `ScreenElementDetecting.control(atGlobalPoint:inApplication:)`。
    private func controlTarget(atGlobalPoint point: CGPoint) -> DetectionTarget? {
        guard let window = windows.first(where: { $0.frame.contains(point) }) else {
            return nil
        }
        guard let hit = detector.control(
            atGlobalPoint: point,
            inApplication: window.processID
        ) else {
            return nil
        }

        // 命中的元素就是窗口本身时，「控件层」与「窗口层」会给出同一个矩形，
        // 这一层就等于没有价值，还多花一次跨进程调用。
        // 用面积占比判断：覆盖窗口九成以上即视为非控件。
        if isEffectivelyWindowSized(hit.frame, windowFrame: window.frame) {
            return nil
        }

        guard let local = DetectionGeometry.clampedLocalBounds(
            ofGlobalRects: [hit.frame],
            displayBounds: displayBounds
        ) else {
            return nil
        }
        return DetectionTarget(
            layer: .control,
            rect: local,
            displayID: displayID,
            title: hit.role,
            globalRect: hit.frame
        )
    }

    /// 命中矩形是否实质上等于整个窗口。
    ///
    /// 用面积比而不是精确相等：窗口边框、阴影与 AX 报告的尺寸常有几像素出入，
    /// 精确比较会把「就是窗口本身」判成控件。
    private func isEffectivelyWindowSized(_ rect: CGRect, windowFrame: CGRect) -> Bool {
        let windowArea = windowFrame.width * windowFrame.height
        guard windowArea > 0 else {
            return true
        }
        let ratio = (rect.width * rect.height) / windowArea
        return ratio >= 0.9
    }
}

// MARK: - 辅助功能权限引导

public extension SystemElementDetector {
    /// 打开系统设置的「辅助功能」面板。
    ///
    /// 用 URL scheme 而不是 `AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt)`：
    /// 后者会弹出系统自带的一次性提示，而本应用已经决定「不在每次会话打扰用户」，
    /// 只在用户主动点击菜单项时跳转。
    static func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
