//
//  RecordingScopeComposer.swift
//  AnShotUI
//
//  录制准备阶段的**范围组装**与**预览矩形**决策。
//
//  ── 为什么必须同源 ────────────────────────────────────────
//
//  录制范围与它的屏幕矩形必须从同一份当前状态现算。此前矩形是打开面板时算好、
//  存进选项里的，于是「区域 → 全屏」之后预览框跟着变了，正式录制框却仍用旧区域
//  的矩形。把两件事放进同一个函数，二者就不可能各说各话。
//
//  ── 为什么是纯函数 ────────────────────────────────────────
//
//  这里不持有面板、预览窗口与识别会话：输入是「选了哪类范围、锁定了什么目标、
//  选区在哪块屏」，输出是范围与矩形。因此「切范围会不会串台」这类问题
//  可以脱离界面断言——它正是上面那个缺陷的成因。
//

import AnShotCapture
import AnShotCore
import AppKit

/// 准备阶段已锁定的录制目标（窗口 / 应用）。
///
/// 键是范围类型：同一时刻只会有一个「窗口」目标与一个「应用」目标。
/// 矩形必须与身份一起记住——身份只在命中测试那一刻有效，
/// 事后由窗口 ID 反查矩形会拿到一个已经移动过的位置。
struct SetupTarget {
    /// 识别身份（含 `windowID` / `processID`）。
    let target: DetectionTarget
    /// 目标在 **AppKit 屏幕坐标**下的矩形，用于预览框与录制范围框。
    let screenRect: CGRect
}

/// 范围组装与预览矩形。
enum RecordingScopeComposer {

    /// 一次决策所需的全部输入。
    struct State {
        /// 面板当前选择的范围类型；nil 表示面板没开或未选。
        var kind: RecordingScopeKind?
        /// 已锁定的目标（窗口 / 应用）。
        var targets: [RecordingScopeKind: SetupTarget] = [:]
        /// 准备阶段打开时的选区（视图逻辑点坐标）。
        var selectionRect: CGRect?
        /// 选区所在显示器。
        var selectionDisplayID: CGDirectDisplayID?
        /// 选区所在显示器对应的屏幕矩形（AppKit 屏幕坐标）。
        var selectionScreenRect: CGRect?
        /// 选中显示器（或首屏）的整屏矩形，供全屏范围使用。
        var displayScreenRect: CGRect?
    }

    /// 预览范围框应显示的矩形；nil 表示应当收起。
    ///
    /// 这是预览框的**唯一**决策点：已锁定目标 > 当前范围的固有矩形 > 收起。
    /// 分散在各分支里写会让「切范围」与「选目标」两条路径相互被覆掉。
    static func previewRect(_ state: State) -> CGRect? {
        switch state.kind {
        case .window, .application:
            // 没锁定目标时不能退回选区矩形：那会画出一个并非录制范围的框。
            return state.kind.flatMap { state.targets[$0]?.screenRect }

        case .region:
            return state.selectionScreenRect

        case .display:
            return state.displayScreenRect

        case nil:
            return nil
        }
    }

    /// 组装录制范围与它的屏幕矩形；范围不成立时返回 nil。
    ///
    /// 调用方**不得**在失败时静默继续：范围不成立（例如目标只有矩形没有身份）
    /// 意味着构造不出过滤器，只能不发出录制请求。
    static func compose(_ state: State) -> (scope: CaptureScope, screenRect: CGRect)? {
        switch state.kind {
        case .region:
            guard let rect = state.selectionRect,
                  let displayID = state.selectionDisplayID,
                  let screenRect = state.selectionScreenRect else { return nil }
            return (.region(displayID, rect: rect), screenRect)

        case .window:
            guard let picked = state.targets[.window],
                  let windowID = picked.target.windowID else { return nil }
            return (.window(windowID), picked.screenRect)

        case .application:
            guard let picked = state.targets[.application],
                  let pid = picked.target.processID else { return nil }
            // 应用过滤是**以显示器为范围**的（`CaptureScope.application` 的契约），
            // 因此显示器必须取自目标自己，而不是当前鼠标在哪块屏。
            return (.application(pid, on: picked.target.displayID), picked.screenRect)

        case .display:
            guard let displayID = state.selectionDisplayID,
                  let screenRect = state.displayScreenRect else { return nil }
            return (.display(displayID), screenRect)

        case nil:
            return nil
        }
    }

    /// 目标的**捕获范围**在屏幕上的矩形（AppKit 屏幕坐标）。
    ///
    /// 不能直接用 `DetectionTarget.rect`：那是截图语义（已裁进当前显示器），
    /// 而录制范围不是——窗口按整个窗口录（可跨屏），应用按整块显示器录。
    /// 拿错会在跨屏窗口上少一圈、在应用录制上画出一块比成片小得多的框。
    ///
    /// - Parameter localConvert: 目标缺少全局几何时的兜底换算（由调用方的窗口提供）。
    ///
    /// 标 `@MainActor` 的依据：跨屏分支要读 `NSScreen.screens`，而 `NSScreen`
    /// 与 `OverlayWindow` 都是主线程隔离的 AppKit 类型。
    ///
    /// 之前未标注时，编译器把它当作 nonisolated，于是调用主线程隔离的 API
    /// 会产生 `#ActorIsolatedCall` 告警。那不是误报：它在指出「这个函数
    /// 其实必须在主线程上跑」。标注出来才是真实契约。
    @MainActor
    static func captureScreenRect(
        for target: DetectionTarget,
        localConvert: (CGRect) -> CGRect
    ) -> CGRect {
        guard let global = target.globalRect else {
            // 调用方没提供全局几何（旧路径）：至少用显示器内的矩形，框会落在正确的屏上。
            return localConvert(target.rect)
        }
        return OverlayWindow.appKitScreenRect(forGlobalRect: global)
    }
}
