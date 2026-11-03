//
//  DesktopTransactionTests.swift
//  AnShotAutomationTests
//

import Foundation
import Testing
@testable import AnShotAutomation

@Suite("桌面截图事务")
struct DesktopTransactionTests {

    @Test("默认拒绝切换其他桌面，且不执行抓帧")
    func switchingRequiresExplicitOptIn() async {
        let desktop = FakeDesktop()
        var didCapture = false
        do {
            let _: Int = try await DesktopTransaction.perform(
                target: 2,
                allowSwitch: false,
                current: { desktop.active },
                switchTo: { desktop.switches.append($0) },
                capture: { didCapture = true; return 42 }
            )
            Issue.record("默认应拒绝桌面切换")
        } catch {
            #expect(!didCapture)
            #expect(desktop.switches.isEmpty)
            #expect(desktop.active == 1)
        }
    }

    @Test("成功截图后恢复原桌面")
    func restoresAfterCapture() async throws {
        let desktop = FakeDesktop()
        let value = try await desktop.capture {
            #expect(desktop.active == 2)
            return 42
        }
        #expect(value == 42)
        #expect(desktop.switches == [2, 1])
        #expect(desktop.active == 1)
    }

    @Test("截图失败后仍恢复原桌面")
    func restoresAfterCaptureFailure() async {
        let desktop = FakeDesktop()
        do {
            let _: Int = try await desktop.capture { throw AutomationError.captureFailed("测试失败") }
            Issue.record("应报告截图失败")
        } catch {
            #expect(desktop.switches == [2, 1])
            #expect(desktop.active == 1)
        }
    }

    @Test("切换已生效后报错也要恢复")
    func restoresAfterPartialSwitchFailure() async {
        let desktop = FakeDesktop()
        desktop.failAfterTargetSwitch = true
        do {
            let _: Int = try await desktop.capture { 42 }
            Issue.record("应报告切换失败")
        } catch {
            #expect(desktop.switches == [2, 1])
            #expect(desktop.active == 1)
        }
    }

    @Test("用户自行切换到第三个桌面时不强行切回")
    func doesNotOverrideUserSwitch() async {
        let desktop = FakeDesktop()
        do {
            let _: Int = try await desktop.capture {
                desktop.active = 3
                return 42
            }
            Issue.record("桌面发生变化时应丢弃截图")
        } catch {
            #expect(desktop.active == 3)
            #expect(desktop.switches == [2])
        }
    }

    @Test("恢复失败不能返回成功截图")
    func restoreFailureIsReported() async {
        let desktop = FakeDesktop()
        desktop.failRestore = true
        do {
            let _: Int = try await desktop.capture { 42 }
            Issue.record("恢复失败时不应报告截图成功")
        } catch {
            #expect(error.localizedDescription.contains("恢复原桌面失败"))
        }
    }
}

private final class FakeDesktop {
    var active: UInt64 = 1
    var switches: [UInt64] = []
    var failAfterTargetSwitch = false
    var failRestore = false

    func capture<T>(_ operation: () async throws -> T) async throws -> T {
        try await DesktopTransaction.perform(
            target: 2,
            allowSwitch: true,
            current: { self.active },
            switchTo: { id in
                self.switches.append(id)
                if id == 1 && self.failRestore { throw AutomationError.captureFailed("测试恢复失败") }
                self.active = id
                if id == 2 && self.failAfterTargetSwitch { throw AutomationError.captureFailed("测试切换失败") }
            },
            capture: operation
        )
    }
}
