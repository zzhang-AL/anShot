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
import os

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

    /// 当前窗口快照，**已按权威 z 序（前到后）排列**。
    private var windows: [DetectedWindow] = []
    private var isLoaded = false
    /// 在 `load()` 时缓存的辅助功能权限状态，避免鼠标移动高频触发跨进程检查。
    private var cachedAccessibilityPermission: Bool
    /// 后台控件去抖查询代际号与当前任务。
    private var controlLookupGeneration: UInt64 = 0
    private var controlLookupTask: Task<Void, Never>?

    public init(
        detector: ScreenElementDetecting,
        displayID: CGDirectDisplayID,
        displayBounds: CGRect
    ) {
        self.detector = detector
        self.displayID = displayID
        self.displayBounds = displayBounds
        self.cachedAccessibilityPermission = detector.hasAccessibilityPermission
    }

    /// 是否具备组件级识别能力。
    public var canDetectControls: Bool {
        cachedAccessibilityPermission
    }

    /// 刷新已缓存的辅助功能权限状态。
    public func refreshAccessibilityPermission() {
        cachedAccessibilityPermission = detector.hasAccessibilityPermission
    }

    /// 已载入的窗口数（诊断用）。
    public var windowCount: Int {
        windows.count
    }

    /// 重新枚举窗口并缓存辅助功能权限。会话开始时调用一次；枚举失败时保持空列表。
    ///
    /// 失败不抛给调用方：识别是便利功能，取不到就不识别，
    /// 不该让「按热键截图」这条主路径因为窗口枚举失败而中断。
    public func load() async {
        cachedAccessibilityPermission = detector.hasAccessibilityPermission
        do {
            windows = try await detector.windows(onDisplay: displayID)
        } catch {
            windows = []
        }
        isLoaded = true
    }

    /// 同步识别指定全局点应当选中的区域（保留旧有调用契约）。
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

    /// 阶段一零阻塞即时命中：仅使用内存中的窗口快照，不发起跨进程 AX 查询。
    public func immediateTarget(
        atGlobalPoint point: CGPoint,
        preference: DetectionLayerPreference
    ) -> DetectionTarget? {
        guard preference != .disabled, isLoaded else {
            return nil
        }
        switch preference {
        case .disabled:
            return nil
        case .automatic, .window:
            return windowTarget(atGlobalPoint: point) ?? displayTarget()
        case .application:
            return applicationTarget(atGlobalPoint: point)
                ?? windowTarget(atGlobalPoint: point)
                ?? displayTarget()
        }
    }

    /// 异步识别指定全局点应当选中的区域：控件级 AX IPC 在后台执行，不阻塞主线程。
    public func resolveTargetAsync(
        atGlobalPoint point: CGPoint,
        preference: DetectionLayerPreference
    ) async -> DetectionTarget? {
        guard preference != .disabled, isLoaded else {
            return nil
        }
        guard preference == .automatic else {
            return immediateTarget(atGlobalPoint: point, preference: preference)
        }
        guard cachedAccessibilityPermission,
              let window = windows.first(where: { $0.frame.contains(point) }) else {
            return windowTarget(atGlobalPoint: point) ?? displayTarget()
        }

        let detector = self.detector
        let pid = window.processID
        let hit = await Task.detached(priority: .userInitiated) {
            detector.control(atGlobalPoint: point, inApplication: pid)
        }.value

        if let hit, let control = makeControlTarget(from: hit, in: window) {
            return control
        }
        return windowTarget(atGlobalPoint: point) ?? displayTarget()
    }

    /// 阶段二后台去抖查询控件：主线程可先用 `immediateTarget` 瞬时响应，再由本方法异步收窄到控件框。
    ///
    /// 每次调用会自动取消前一次尚未完成或仍在去抖窗口内的查询，确保只有最新坐标的控件结果回填。
    public func scheduleControlTarget(
        atGlobalPoint point: CGPoint,
        preference: DetectionLayerPreference,
        debounce: Duration = .milliseconds(20),
        onUpdate: @escaping @MainActor (DetectionTarget?) -> Void
    ) {
        cancelPendingControlLookup()
        guard preference == .automatic, isLoaded, cachedAccessibilityPermission,
              let window = windows.first(where: { $0.frame.contains(point) }) else {
            return
        }

        controlLookupGeneration &+= 1
        let generation = controlLookupGeneration
        let detector = self.detector
        let pid = window.processID

        controlLookupTask = Task { [weak self] in
            do {
                if debounce > .zero {
                    try await Task.sleep(for: debounce)
                }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            let hit = await Task.detached(priority: .userInitiated) {
                detector.control(atGlobalPoint: point, inApplication: pid)
            }.value

            guard !Task.isCancelled, let self else { return }
            guard self.controlLookupGeneration == generation, self.isLoaded else { return }
            let controlTarget = hit.flatMap { self.makeControlTarget(from: $0, in: window) }
            onUpdate(controlTarget)
        }
    }

    /// 取消挂起的后台控件查询。
    public func cancelPendingControlLookup() {
        controlLookupGeneration &+= 1
        controlLookupTask?.cancel()
        controlLookupTask = nil
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
        guard cachedAccessibilityPermission,
              let window = windows.first(where: { $0.frame.contains(point) }),
              let hit = detector.control(
                  atGlobalPoint: point,
                  inApplication: window.processID
              ) else {
            return nil
        }
        return makeControlTarget(from: hit, in: window)
    }

    /// 将 AX 控件命中结果收敛为有效的控件级 `DetectionTarget`。
    private func makeControlTarget(from hit: ControlHit, in window: DetectedWindow) -> DetectionTarget? {
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

    /// 监听辅助功能授权状态变更（支持分布式通知与前台激活刷新）。
    static func accessibilityPermissionUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let initial = AXIsProcessTrusted()
            let lastLock = OSAllocatedUnfairLock<Bool>(initialState: initial)
            continuation.yield(initial)

            @Sendable func publishIfChanged() {
                let current = AXIsProcessTrusted()
                let changed = lastLock.withLock { prev -> Bool in
                    guard current != prev else { return false }
                    prev = current
                    return true
                }
                if changed {
                    continuation.yield(current)
                }
            }

            let distCenter = DistributedNotificationCenter.default()
            let distBox = NotificationTokenBox(token: distCenter.addObserver(
                forName: NSNotification.Name("com.apple.accessibility.api"),
                object: nil,
                queue: nil
            ) { _ in
                publishIfChanged()
            })

            let appCenter = NotificationCenter.default
            let activeBox = NotificationTokenBox(token: appCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { _ in
                publishIfChanged()
            })

            continuation.onTermination = { _ in
                DistributedNotificationCenter.default().removeObserver(distBox.token)
                NotificationCenter.default.removeObserver(activeBox.token)
            }
        }
    }
}
