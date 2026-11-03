//
//  ScreenCapturePermission.swift
//  AnShotCapture
//
//  屏幕录制权限的**观测**与请求。
//
//  ── 为何不确定名为「拒绝」─────────────────────────────────────
//
//  `CGPreflightScreenCaptureAccess()` 返回 false 只能说明「当前进程此刻未获授权」，
//  它**无法**区分以下三种情形：
//
//      1. 用户尚未做出选择（授权流程仍在等待）
//      2. 用户明确拒绝
//      3. 用户曾在系统设置中授权，后来又撤销
//
//  因此本模块的状态命名刻意避免「denied」这类断言，只描述可观测的事实：
//  「已授权」「从未请求过」「请求过但未获授权」。
//  UI 文案同理，一律说「尚未授权」而非「已拒绝」。
//
//  ── 为何需要本地记录 ─────────────────────────────────────────
//
//  macOS 没有 API 能区分「从未请求」与「请求过但未获授权」——两者 preflight 都为 false。
//  而这两者需要不同的引导：前者可直接触发系统对话框，后者系统不会再弹窗，
//  只能引导用户去系统设置。故用 UserDefaults 记录「是否曾经请求过」补足这一缺失。
//
//  ── 测试约定（plan.md §3.5）──────────────────────────────────
//
//  验证权限行为必须用 `open anShot.app` 启动。直接执行 bundle 内的二进制时，
//  TCC 的 responsible process 会是终端本身，权限查询据终端权限作答，
//  导致已授权仍恒返回 false。
//

import CoreGraphics
import Foundation

// MARK: - 权限状态

/// 屏幕录制权限的观测状态。
///
/// 只描述**可观测的事实**，不含「用户拒绝」这类无法由 API 判定的推断。
public enum ScreenCapturePermission: Sendable, Equatable {
    /// 当前进程已获授权，可以进行捕获。
    case granted

    /// 当前进程未获授权，且本应用此前**从未请求过**权限。
    ///
    /// 这通常意味着首次运行，可以直接触发系统授权对话框。
    case notRequested

    /// 当前进程未获授权，但本应用此前请求过。
    ///
    /// 系统不会再次弹窗，应引导用户到系统设置检查。
    /// 注意这**不等于**用户拒绝了——也可能授权仍在等待，或用户曾授权后撤销。
    case notGranted

    /// 是否可立即进行捕获。
    public var allowsCapture: Bool {
        self == .granted
    }
}

// MARK: - 系统 API 抽象

/// 屏幕录制权限的系统 API 抽象。
///
/// 存在的唯一目的是可测试性：真实实现直接调用 CoreGraphics，
/// 测试实现可注入任意 preflight / request 结果组合。
public protocol ScreenCaptureAccessProviding: Sendable {
    /// 查询当前是否已授权。**不触发任何弹窗。**
    func preflight() -> Bool

    /// 请求权限。**可能触发系统弹窗**，并会把本应用加入系统设置的授权列表。
    ///
    /// 返回值是**调用瞬间**的授权状态，而非用户后续操作的结果——
    /// 用户的实际操作是异步完成的（需在系统设置中点击开关）。
    func request() -> Bool
}

/// 真实实现，直接调用 CoreGraphics。
public struct SystemScreenCaptureAccess: ScreenCaptureAccessProviding {
    public init() {}

    public func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

// MARK: - 权限服务

/// 权限状态服务。
///
/// `@unchecked Sendable` 的理由：`UserDefaults` 未标注 `Sendable`，
/// 但 Apple 文档明确其为线程安全；本类型无可变状态，
/// 且 `access` 已是 `Sendable`，故可安全跨并发域传递。
public struct ScreenCapturePermissionService: @unchecked Sendable {

    /// UserDefaults 中记录「是否曾经请求过权限」的键。
    private static let hasRequestedKey = "com.anshot.hasRequestedScreenCapturePermission"

    private let access: ScreenCaptureAccessProviding
    private let store: UserDefaults

    /// - Parameters:
    ///   - access: 系统权限 API，默认使用真实实现。
    ///   - store: 状态存储，测试时可注入独立 suite。
    public init(
        access: ScreenCaptureAccessProviding = SystemScreenCaptureAccess(),
        store: UserDefaults = .standard
    ) {
        self.access = access
        self.store = store
    }

    /// 查询当前权限状态。**不触发任何弹窗，可随时调用。**
    ///
    /// 判定规则：
    /// - `preflight() == true` → `.granted`（无论是否记录过请求，
    ///   因为用户可能通过其他途径授予，例如手动在系统设置中添加）
    /// - `preflight() == false` 且从未请求过 → `.notRequested`
    /// - `preflight() == false` 且请求过 → `.notGranted`
    public func current() -> ScreenCapturePermission {
        if access.preflight() {
            return .granted
        }
        return store.bool(forKey: Self.hasRequestedKey) ? .notGranted : .notRequested
    }

    /// 触发系统授权流程。**可能弹出系统对话框。**
    ///
    /// 返回调用瞬间的状态。由于用户的实际操作是异步的，
    /// 调用后应重新用 `current()` 查询，而不是把返回值当作最终结果。
    ///
    /// 无论结果如何都会记录「已请求过」，使后续 `current()`
    /// 能把 false 正确解释为「请求过但未获授权」而非「从未请求」。
    @discardableResult
    public func requestAccess() -> ScreenCapturePermission {
        store.set(true, forKey: Self.hasRequestedKey)
        return access.request() ? .granted : .notGranted
    }

    /// 是否曾经请求过权限。用于 UI 决定引导文案。
    public var hasRequestedBefore: Bool {
        store.bool(forKey: Self.hasRequestedKey)
    }

    /// 清除「已请求」记录。仅用于测试与调试。
    public func resetRequestRecord() {
        store.removeObject(forKey: Self.hasRequestedKey)
    }
}
