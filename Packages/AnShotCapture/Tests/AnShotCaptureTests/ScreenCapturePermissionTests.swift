//
//  ScreenCapturePermissionTests.swift
//  AnShotCaptureTests
//
//  权限状态判定是纯逻辑，不依赖真实系统权限，因此可完整覆盖。
//  这正是把 CoreGraphics 调用抽象到 ScreenCaptureAccessProviding 的目的。
//

import Foundation
import Testing
@testable import AnShotCapture

/// 可控的假实现，用于注入任意 preflight / request 结果组合。
private struct FakeAccess: ScreenCaptureAccessProviding {
    var preflightResult: Bool
    var requestResult: Bool

    func preflight() -> Bool { preflightResult }
    func request() -> Bool { requestResult }
}

@Suite("屏幕录制权限状态判定")
struct ScreenCapturePermissionTests {

    /// 每个测试使用独立且干净的 UserDefaults suite，避免相互污染。
    private func freshStore() -> UserDefaults {
        let suite = "com.anshot.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("preflight 为 true → granted（即使从未记录过请求）")
    func grantedWhenPreflightTrue() {
        let service = ScreenCapturePermissionService(
            access: FakeAccess(preflightResult: true, requestResult: true),
            store: freshStore()
        )
        #expect(service.current() == .granted)
        #expect(service.current().allowsCapture)
    }

    @Test("preflight 为 false 且从未请求 → notRequested")
    func notRequestedWhenNeverAsked() {
        let service = ScreenCapturePermissionService(
            access: FakeAccess(preflightResult: false, requestResult: false),
            store: freshStore()
        )
        #expect(service.current() == .notRequested)
        #expect(!service.current().allowsCapture)
    }

    @Test("preflight 为 false 且已请求过 → notGranted（不得误判为 notRequested）")
    func notGrantedAfterRequest() {
        let store = freshStore()
        let service = ScreenCapturePermissionService(
            access: FakeAccess(preflightResult: false, requestResult: false),
            store: store
        )
        _ = service.requestAccess()
        #expect(service.current() == .notGranted)
    }

    @Test("requestAccess 后若已授权则为 granted")
    func requestGranted() {
        let service = ScreenCapturePermissionService(
            access: FakeAccess(preflightResult: false, requestResult: true),
            store: freshStore()
        )
        #expect(service.requestAccess() == .granted)
    }

    @Test("requestAccess 返回 false 只表示「此刻未获授权」，状态记为 notGranted")
    func requestNotGrantedYet() {
        let service = ScreenCapturePermissionService(
            access: FakeAccess(preflightResult: false, requestResult: false),
            store: freshStore()
        )
        // 注意：这不代表用户拒绝——授权可能是异步的、仍在等待
        #expect(service.requestAccess() == .notGranted)
    }

    @Test("曾授权后又被撤销（preflight 转 false）应判为 notGranted，而非 notRequested")
    func revokedAfterGrant() {
        let store = freshStore()
        let service = ScreenCapturePermissionService(
            access: FakeAccess(preflightResult: true, requestResult: true),
            store: store
        )
        _ = service.requestAccess()
        #expect(service.current() == .granted)

        // 用户在系统设置中关闭了开关，或授权被重置
        let afterRevoke = ScreenCapturePermissionService(
            access: FakeAccess(preflightResult: false, requestResult: false),
            store: store
        )
        #expect(afterRevoke.current() == .notGranted)
    }

    @Test("hasRequestedBefore 如实反映本地记录")
    func hasRequestedFlag() {
        let store = freshStore()
        let service = ScreenCapturePermissionService(
            access: FakeAccess(preflightResult: false, requestResult: false),
            store: store
        )
        #expect(!service.hasRequestedBefore)
        _ = service.requestAccess()
        #expect(service.hasRequestedBefore)
    }

    @Test("resetRequestRecord 后回到 notRequested")
    func resetRecord() {
        let store = freshStore()
        let service = ScreenCapturePermissionService(
            access: FakeAccess(preflightResult: false, requestResult: false),
            store: store
        )
        _ = service.requestAccess()
        #expect(service.current() == .notGranted)

        service.resetRequestRecord()
        #expect(service.current() == .notRequested)
    }
}
