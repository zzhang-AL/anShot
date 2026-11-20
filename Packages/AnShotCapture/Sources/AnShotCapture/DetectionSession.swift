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
    /// 最近一次在光标位置收集到的层级候选栈（由内到外：控件 → 语义父容器 → 窗口），供悬停滚轮逐层切换。
    private var hierarchyTargets: [DetectionTarget] = []
    private var hierarchyIndex: Int = 0

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

    /// 在普通区域截图模式下是否抑制最大化窗口（宽 ≥ 92%、高 ≥ 82% 且面积 ≥ 78%）的窗口级吸附。
    ///
    /// 开启后，当光标下最顶层窗口近似全屏/最大化时，既不误吸附该窗口、也不穿透吸附底层半屏窗口；
    /// 若光标下也没有细粒度控件命中，则自然回落至整屏 `displayTarget()` 兜底（点击即选全屏，拖拽仍直接自由框选）。
    /// 独立窗体模式与录制取目标模式关闭此开关，确保所有窗口均可被点选。
    public var suppressesMaximizedWindow: Bool = false

    /// 判定一个窗口在当前显示器内是否近似最大化/全屏。
    ///
    /// 阈值依据：`width >= 92%`、`height >= 82%` 且面积 `>= 78%`。
    nonisolated public static func isMaximizedLike(_ windowFrame: CGRect, in displayBounds: CGRect) -> Bool {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return false }
        let clipped = windowFrame.intersection(displayBounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return false }
        let widthRatio = clipped.width / displayBounds.width
        let heightRatio = clipped.height / displayBounds.height
        let areaRatio = (clipped.width * clipped.height) / (displayBounds.width * displayBounds.height)
        return widthRatio >= 0.92 && heightRatio >= 0.82 && areaRatio >= 0.78
    }

    /// 返回光标下方按权威 Z-order（前到后）排列的全部可见窗口候选，供窗体模式 `Tab` 穿透切换。
    public func windowCandidates(atGlobalPoint point: CGPoint) -> [DetectionTarget] {
        guard isLoaded else { return [] }
        var targets: [DetectionTarget] = []
        for window in windows where window.frame.contains(point) {
            guard let local = DetectionGeometry.clampedLocalBounds(
                ofGlobalRects: [window.frame],
                displayBounds: displayBounds
            ) else {
                continue
            }
            targets.append(DetectionTarget(
                layer: .window,
                rect: local,
                displayID: displayID,
                title: window.title ?? window.applicationName,
                windowID: window.windowID,
                processID: window.processID,
                globalRect: window.frame,
                applicationName: window.applicationName
            ))
        }
        return targets
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
            // 由内到外：控件 → 窗口 → 当前整屏兜底。
            if let control = controlTarget(atGlobalPoint: point) {
                return control
            }
            if let window = windowTarget(atGlobalPoint: point) {
                return window
            }
            return displayTarget()

        case .window:
            if let window = windowTarget(atGlobalPoint: point) {
                return window
            }
            return displayTarget()

        case .application:
            return applicationTarget(atGlobalPoint: point)
                ?? windowTarget(atGlobalPoint: point)
                ?? displayTarget()
        }
    }

    /// 返回光标下方最顶层可见窗口的 `windowID`（不发起 AX 跨进程查询，用于判断光标是否仍在同一窗口内）。
    public func topWindowID(atGlobalPoint point: CGPoint) -> CGWindowID? {
        guard isLoaded else { return nil }
        return windows.first(where: { $0.frame.contains(point) })?.windowID
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
            if let window = windowTarget(atGlobalPoint: point) {
                return window
            }
            return displayTarget()
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
            if let target = windowTarget(atGlobalPoint: point) {
                return target
            }
            return displayTarget()
        }

        let detector = self.detector
        let pid = window.processID
        let hit = await Task.detached(priority: .userInitiated) {
            detector.control(atGlobalPoint: point, inApplication: pid)
        }.value

        if let hit, let control = makeControlTarget(from: hit, in: window, atGlobalPoint: point) {
            return control
        }
        if let target = windowTarget(atGlobalPoint: point) {
            return target
        }
        return displayTarget()
    }

    /// 阶段二后台去抖查询控件：主线程可先用 `immediateTarget` 瞬时响应，再由本方法异步收窄到控件框。
    ///
    /// 每次调用会自动取消前一次尚未完成或仍在去抖窗口内的查询，确保只有最新坐标的控件结果回填；
    /// 同时维护悬停滚轮层级栈（由内到外最终衔接当前整屏），即便未命中细控件也支持「窗口 ↔ 当前整屏」切换。
    public func scheduleControlTarget(
        atGlobalPoint point: CGPoint,
        preference: DetectionLayerPreference,
        debounce: Duration = .milliseconds(45),
        onUpdate: @escaping @MainActor (DetectionTarget?) -> Void
    ) {
        cancelPendingControlLookup()
        guard preference != .disabled, isLoaded else {
            hierarchyTargets = []
            hierarchyIndex = 0
            return
        }

        // 先构造不含 AX 控件的基础层级栈（如 窗口 → 当前整屏，或仅当前整屏），
        // 保证无辅助功能权限、窗口级模式或尚未命中细控件时，悬停滚轮同样可切到整屏。
        let baseHierarchy = makeBaseHierarchy(atGlobalPoint: point, preference: preference)

        guard preference == .automatic, cachedAccessibilityPermission,
              let window = windows.first(where: { $0.frame.contains(point) }) else {
            hierarchyTargets = baseHierarchy
            hierarchyIndex = 0
            return
        }

        // 若当前尚未持有层级栈，先灌入基础层级栈避免去抖窗口内滚轮失效。
        if hierarchyTargets.isEmpty {
            hierarchyTargets = baseHierarchy
            hierarchyIndex = 0
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
            let chain = hit.map { self.makeControlHierarchy(from: $0, in: window, atGlobalPoint: point) } ?? []
            if !chain.isEmpty {
                self.hierarchyTargets = chain
                self.hierarchyIndex = 0
                onUpdate(chain.first)
            } else {
                self.hierarchyTargets = self.makeBaseHierarchy(atGlobalPoint: point, preference: preference)
                self.hierarchyIndex = 0
                onUpdate(nil)
            }
        }
    }

    /// 悬停预框选期间沿当前光标处的 AX 控件层级链放大（`expand == true`）或缩小一层。
    ///
    /// 仅当当前点存在 2 层及以上可选层级（如 按钮 → 卡片 → 面板 → 窗口）时返回新目标；否则返回 `nil`。
    public func stepControlHierarchy(expand: Bool) -> DetectionTarget? {
        guard hierarchyTargets.count > 1 else { return nil }
        let nextIndex = expand
            ? min(hierarchyTargets.count - 1, hierarchyIndex + 1)
            : max(0, hierarchyIndex - 1)
        guard nextIndex != hierarchyIndex else { return nil }
        hierarchyIndex = nextIndex
        return hierarchyTargets[nextIndex]
    }

    /// 当前层级栈深度（用于判断悬停滚轮是否可切换层级）。
    public var controlHierarchyCount: Int {
        hierarchyTargets.count
    }

    /// 清空当前层级候选栈。
    public func clearControlHierarchy() {
        hierarchyTargets = []
        hierarchyIndex = 0
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
            // 普通区域截图模式下，若最顶层命中窗口本身已近似最大化/全屏，
            // 直接停止并返回 nil：既不误吸全屏，也绝不穿透去吸附其背后的半屏窗口。
            if suppressesMaximizedWindow, Self.isMaximizedLike(window.frame, in: displayBounds) {
                return nil
            }
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
                globalRect: window.frame,
                applicationName: window.applicationName
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
        return makeControlTarget(from: hit, in: window, atGlobalPoint: point)
    }

    /// 构造不含 AX 细控件的基础层级栈（如「窗口 → 当前整屏」或「应用 → 当前整屏」或单层「当前整屏」）。
    private func makeBaseHierarchy(
        atGlobalPoint point: CGPoint,
        preference: DetectionLayerPreference
    ) -> [DetectionTarget] {
        guard let immediate = immediateTarget(atGlobalPoint: point, preference: preference) else {
            return []
        }
        var result = [immediate]
        appendDisplayFallback(to: &result)
        return result
    }

    /// 构造从最内层语义控件到外层容器、窗口，最终衔接当前整屏的完整层级链。
    private func makeControlHierarchy(
        from hit: ControlHit,
        in window: DetectedWindow,
        atGlobalPoint point: CGPoint
    ) -> [DetectionTarget] {
        var result: [DetectionTarget] = []
        if let primary = makeValidatedControlTarget(frame: hit.frame, role: hit.role, in: window, atGlobalPoint: point) {
            result.append(primary)
        }
        for ancestor in hit.ancestors {
            if let target = makeValidatedControlTarget(frame: ancestor.frame, role: ancestor.role, in: window, atGlobalPoint: point) {
                if let last = result.last,
                   abs(last.rect.minX - target.rect.minX) <= 2,
                   abs(last.rect.minY - target.rect.minY) <= 2,
                   abs(last.rect.width - target.rect.width) <= 4,
                   abs(last.rect.height - target.rect.height) <= 4 {
                    continue
                }
                result.append(target)
            }
        }
        // 非最大化窗口时，允许滚轮向上先扩到完整窗口本身，再衔接当前整屏。
        if !result.isEmpty,
           !(suppressesMaximizedWindow && Self.isMaximizedLike(window.frame, in: displayBounds)),
           let localWindow = DetectionGeometry.clampedLocalBounds(ofGlobalRects: [window.frame], displayBounds: displayBounds) {
            result.append(DetectionTarget(
                layer: .window,
                rect: localWindow,
                displayID: displayID,
                title: window.title ?? window.applicationName,
                windowID: window.windowID,
                processID: window.processID,
                globalRect: window.frame,
                applicationName: window.applicationName
            ))
        }
        if !result.isEmpty {
            appendDisplayFallback(to: &result)
        }
        return result
    }

    /// 在层级链最顶层衔接「当前整屏」，若末尾目标已与整屏重合（误差 ≤ 4pt）则不重复追加。
    private func appendDisplayFallback(to chain: inout [DetectionTarget]) {
        guard let display = displayTarget() else { return }
        if let last = chain.last {
            if last.layer == .display {
                return
            }
            if abs(last.rect.minX - display.rect.minX) <= 2,
               abs(last.rect.minY - display.rect.minY) <= 2,
               abs(last.rect.width - display.rect.width) <= 4,
               abs(last.rect.height - display.rect.height) <= 4 {
                return
            }
        }
        chain.append(display)
    }

    /// 将 AX 控件命中结果收敛为有效的控件级 `DetectionTarget`。
    private func makeControlTarget(
        from hit: ControlHit,
        in window: DetectedWindow,
        atGlobalPoint point: CGPoint
    ) -> DetectionTarget? {
        makeValidatedControlTarget(frame: hit.frame, role: hit.role, in: window, atGlobalPoint: point)
    }

    /// 校验并构造单个控件级 `DetectionTarget`：
    /// 1. 强不变量：控件矩形必须包含当前鼠标坐标 `point`，彻底杜绝跨位/幽灵 AX 节点（如鼠标在顶上却吸到底部）；
    /// 2. 严格裁剪到所属 `window.frame` 内，防止滚动内容越出窗口边界；
    /// 3. 过滤过碎节点及占窗口 ≥ 85% 的假整窗容器；
    /// 4. 补齐 `windowID` / `processID` / `applicationName`，确保上层粘性保稳准确识别同一窗口。
    private func makeValidatedControlTarget(
        frame: CGRect,
        role: String?,
        in window: DetectedWindow,
        atGlobalPoint point: CGPoint
    ) -> DetectionTarget? {
        guard frame.insetBy(dx: -4, dy: -4).contains(point) else {
            return nil
        }

        let clippedToWindow = frame.intersection(window.frame)
        guard !clippedToWindow.isNull,
              clippedToWindow.insetBy(dx: -4, dy: -4).contains(point),
              SystemElementDetector.isValidControlFrame(clippedToWindow) else {
            return nil
        }

        if isEffectivelyWindowSized(clippedToWindow, windowFrame: window.frame) {
            return nil
        }

        guard let local = DetectionGeometry.clampedLocalBounds(
            ofGlobalRects: [clippedToWindow],
            displayBounds: displayBounds
        ) else {
            return nil
        }
        return DetectionTarget(
            layer: .control,
            rect: local,
            displayID: displayID,
            title: role,
            windowID: window.windowID,
            processID: window.processID,
            globalRect: clippedToWindow,
            applicationName: window.applicationName
        )
    }

    /// 命中矩形是否实质上等于整个窗口（面积占比 ≥ 85% 视为窗口本身而非细控件）。
    private func isEffectivelyWindowSized(_ rect: CGRect, windowFrame: CGRect) -> Bool {
        let windowArea = windowFrame.width * windowFrame.height
        guard windowArea > 0 else {
            return true
        }
        let ratio = (rect.width * rect.height) / windowArea
        return ratio >= 0.85
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
