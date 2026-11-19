//
//  AutoScrollDriver.swift
//  AnShotCapture
//
//  长截图可选像素级自动平滑翻页引擎。
//
//  ── 设计原则 ──────────────────────────────────────────────────
//
//  1. **合成与人工严格隔离**：发出的每个像素级无惯性滚轮 `CGEvent` 都写入唯一
//     `syntheticScrollEventTag = 0x4153_4C53`（`"ASLS"`），全局监听收到任意不含该标记的
//     滚轮/触控板事件时 0 延迟暂停自动滚屏并交给现有双向世界坐标手动管线无缝接管；
//  2. **零权限中断降级**：无辅助功能权限时绝不阻塞长截图会话，立即降级为手动滚动，
//     并每 1 秒轮询 `AXIsProcessTrusted()`，用户授权切回后自动开滚；
//  3. **悬停防抖与自动触底**：鼠标移入控制栏自动暂停防抖；连续静止自动判触底停滚；
//     遇页面未渲染完或配准失稳时自适应降步长并延迟重试。
//

import AnShotCore
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 自动翻页速度档位（持久化键 `settings.longshotAutoScrollSpeed`）。
public enum AutoScrollSpeed: String, CaseIterable, Sendable {
    case slow
    case normal
    case fast

    public var displayName: String {
        switch self {
        case .slow: return "慢速"
        case .normal: return "标准"
        case .fast: return "快速"
        }
    }

    /// 每次微步滚轮投递的基准像素量（负值表示内容向下滚动）。
    public var stepPixels: Int32 {
        switch self {
        case .slow: return 24
        case .normal: return 46
        case .fast: return 78
        }
    }

    /// 两次微步滚轮事件之间的基准间隔（秒）。
    public var intervalSeconds: TimeInterval {
        switch self {
        case .slow: return 0.050
        case .normal: return 0.036
        case .fast: return 0.026
        }
    }

    /// 供循环切换按钮使用的下一档速度。
    public var next: AutoScrollSpeed {
        switch self {
        case .slow: return .normal
        case .normal: return .fast
        case .fast: return .slow
        }
    }
}

/// 自动翻页运行状态。
public enum AutoScrollState: Equatable, Sendable {
    /// 尚未启用或已关闭自动滚屏（纯手动模式）。
    case idle
    /// 正在平滑自动滚屏。
    case running
    /// 用户按 `Space` 或主动滚动滚轮/触控板暂停（无缝由手动管线接管）。
    case pausedByUser
    /// 鼠标悬停在控制栏上临时防抖暂停（移出自动恢复）。
    case pausedForHover
    /// 缺少辅助功能权限，已降级为手动滚动（授权切回后自动启动）。
    case needsAccessibilityPermission
    /// 连续多拍画面无推进，已自动判定触底并停止滚屏。
    case reachedBottom
}

/// 长截图自动平滑翻页驱动器。
@MainActor
public final class AutoScrollDriver {

    /// 合成滚轮事件的唯一 `eventSourceUserData` 标记（ASCII `"ASLS"`）。
    public static let syntheticScrollEventTag: Int64 = 0x4153_4C53

    /// 连续多少次抓帧判定无新位移后自动触底停止。
    public static let defaultStillBottomThreshold = 10

    public private(set) var state: AutoScrollState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChanged?(state)
        }
    }

    public var speed: AutoScrollSpeed
    public let axis: ScrollAxis

    /// 状态变化通知（驱动控制栏脉冲点与提示语）。
    public var onStateChanged: ((AutoScrollState) -> Void)?
    /// 检测到人工滚轮接管时触发。
    public var onManualTakeover: (() -> Void)?
    /// 连续静止自动触底停止时触发。
    public var onReachedBottom: (() -> Void)?

    /// 供单元测试注入的合成滚轮发送器；为 `nil` 时走真实 `CGEvent.post`。
    public var eventPoster: ((CGPoint, Int32, ScrollAxis, Int64) -> Void)?

    /// 目标滚轮坐标（Quartz 屏幕坐标系，左上原点）。
    private let targetQuartzPoint: CGPoint
    /// 是否跳过真实系统全局滚轮监听与权限检查（供单元测试使用）。
    private let disableSystemHooks: Bool
    private let stillBottomThreshold: Int

    private var timerTask: Task<Void, Never>?
    private var permissionPollTask: Task<Void, Never>?
    nonisolated(unsafe) private var wheelMonitor: Any?

    /// 连续静止观察次数（触底检测用）。
    private var consecutiveStillCount = 0
    /// 遇未渲染完/失配时的自适应步长缩减因子（`0.45...1.0`）。
    public private(set) var adaptiveStepScale: Double = 1.0
    /// 遇未渲染完时的延迟重试冷却截止时刻。
    private var retryCooldownUntil: Date = .distantPast
    /// 是否正处于控制栏悬停状态。
    private var isControlBarHovered = false

    public init(
        selectionAppKitRect: CGRect,
        axis: ScrollAxis = .vertical,
        speed: AutoScrollSpeed = .normal,
        stillBottomThreshold: Int = AutoScrollDriver.defaultStillBottomThreshold,
        disableSystemHooks: Bool = false
    ) {
        self.axis = axis
        self.speed = speed
        self.stillBottomThreshold = max(2, stillBottomThreshold)
        self.disableSystemHooks = disableSystemHooks
        self.targetQuartzPoint = Self.quartzPoint(fromAppKitCenterOf: selectionAppKitRect)
    }

    deinit {
        if let wheelMonitor {
            NSEvent.removeMonitor(wheelMonitor)
        }
    }

    /// 判定某条滚轮事件是否由本驱动器合成发送。
    public static func isSyntheticScrollEvent(userData: Int64) -> Bool {
        userData == syntheticScrollEventTag
    }

    /// 启动自动翻页（若缺辅助功能权限则零中断降级手动并开启权限轮询）。
    public func start() {
        consecutiveStillCount = 0
        adaptiveStepScale = 1.0
        retryCooldownUntil = .distantPast

        if !disableSystemHooks && !AXIsProcessTrusted() {
            state = .needsAccessibilityPermission
            startPermissionPolling()
            return
        }

        installWheelMonitorIfNeeded()
        state = isControlBarHovered ? .pausedForHover : .running
        startScrollLoopIfRunning()
    }

    /// 彻底停止并释放定时器与全局滚轮监听。
    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        permissionPollTask?.cancel()
        permissionPollTask = nil
        if let wheelMonitor {
            NSEvent.removeMonitor(wheelMonitor)
            self.wheelMonitor = nil
        }
        state = .idle
    }

    /// 响应 `Space` 或控制栏暂停/继续按钮。
    public func togglePauseResume() {
        switch state {
        case .running, .pausedForHover:
            timerTask?.cancel()
            timerTask = nil
            state = .pausedByUser
        case .pausedByUser, .reachedBottom, .idle:
            start()
        case .needsAccessibilityPermission:
            if !disableSystemHooks && AXIsProcessTrusted() {
                permissionPollTask?.cancel()
                permissionPollTask = nil
                start()
            }
        }
    }

    /// 鼠标移入/移出控制栏防抖：移入立即暂挂发滚轮事件，移出无缝恢复。
    public func setControlBarHovered(_ hovered: Bool) {
        isControlBarHovered = hovered
        if hovered {
            if state == .running {
                timerTask?.cancel()
                timerTask = nil
                state = .pausedForHover
            }
        } else {
            if state == .pausedForHover {
                state = .running
                startScrollLoopIfRunning()
            }
        }
    }

    /// 处理一条观测到的系统滚轮事件；若非自身合成事件则 0 延迟交由用户手动滚屏。
    ///
    /// - Returns: `true` 表示检测到人工滚动并执行了接管暂停，`false` 表示是自身合成事件或无需处理。
    @discardableResult
    public func handleObservedWheelEvent(userData: Int64) -> Bool {
        guard !Self.isSyntheticScrollEvent(userData: userData) else {
            return false
        }
        guard state == .running || state == .pausedForHover else {
            return false
        }
        timerTask?.cancel()
        timerTask = nil
        state = .pausedByUser
        onManualTakeover?()
        return true
    }

    /// 接收一次抓帧/配准反馈：动态调节步长（防未渲染完）并在连续静止时自动触底停止。
    public func observeFrameFeedback(didAdvance: Bool, isUnresolved: Bool) {
        guard state == .running else { return }

        if isUnresolved {
            // 页面尚未渲染完或滚动跨度过大：自适应降低步长并短暂冷却等待重绘。
            adaptiveStepScale = max(0.45, adaptiveStepScale * 0.72)
            retryCooldownUntil = Date().addingTimeInterval(0.18)
            consecutiveStillCount = 0
            return
        }

        if didAdvance {
            consecutiveStillCount = 0
            adaptiveStepScale = min(1.0, adaptiveStepScale + 0.12)
        } else {
            consecutiveStillCount += 1
            if consecutiveStillCount >= stillBottomThreshold {
                timerTask?.cancel()
                timerTask = nil
                state = .reachedBottom
                onReachedBottom?()
            }
        }
    }

    /// 计算当前生效的单步像素量（已结合自适应缩减因子）。
    public var currentStepPixels: Int32 {
        let scaled = Int32((Double(speed.stepPixels) * adaptiveStepScale).rounded())
        return max(8, scaled)
    }

    /// 发送单步像素级无惯性滚轮事件（供计时循环与测试调用）。
    public func emitScrollStep() {
        guard state == .running else { return }
        if Date() < retryCooldownUntil { return }

        let delta = -currentStepPixels
        if let eventPoster {
            eventPoster(targetQuartzPoint, delta, axis, Self.syntheticScrollEventTag)
            return
        }
        guard !disableSystemHooks else { return }
        Self.postSyntheticScroll(at: targetQuartzPoint, pixelDelta: delta, axis: axis)
    }

    // MARK: - 内部循环与监听

    private func startScrollLoopIfRunning() {
        timerTask?.cancel()
        guard state == .running else { return }
        timerTask = Task { @MainActor [weak self] in
            while let self, self.state == .running, !Task.isCancelled {
                self.emitScrollStep()
                let interval = self.speed.intervalSeconds
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
    }

    private func startPermissionPolling() {
        permissionPollTask?.cancel()
        guard !disableSystemHooks else { return }
        permissionPollTask = Task { @MainActor [weak self] in
            while let self, self.state == .needsAccessibilityPermission, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if AXIsProcessTrusted() {
                    self.permissionPollTask = nil
                    self.start()
                    return
                }
            }
        }
    }

    private func installWheelMonitorIfNeeded() {
        guard !disableSystemHooks, wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let userData = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            Task { @MainActor [weak self] in
                _ = self?.handleObservedWheelEvent(userData: userData)
            }
        }
    }

    /// 通过 `CGEvent(scrollWheelEvent2Source:units:.pixel)` 投递带标记的无惯性滚轮事件。
    private static func postSyntheticScroll(at point: CGPoint, pixelDelta: Int32, axis: ScrollAxis) {
        let wheel1: Int32 = axis == .vertical ? pixelDelta : 0
        let wheel2: Int32 = axis == .horizontal ? pixelDelta : 0
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: axis == .horizontal ? 2 : 1,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: 0
        ) else {
            return
        }
        event.location = point
        event.setIntegerValueField(.eventSourceUserData, value: syntheticScrollEventTag)
        // 显式清空惯性动量阶段，确保停手即停、绝不滑过头。
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.post(tap: .cghidEventTap)
    }

    /// 将 AppKit 屏幕坐标（左下原点）矩形中心换算为 Quartz 全局坐标（主屏左上原点）。
    public static func quartzPoint(fromAppKitCenterOf rect: CGRect) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height
            ?? CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        return CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
    }
}
