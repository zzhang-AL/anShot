//
//  WindowAddressingTests.swift
//  AnShotAutomationTests
//
//  窗口寻址（`--window` / `--app`）的参数解析与子实例参数构造。
//
//  ── 这些用例的边界 ────────────────────────────────────────────
//
//  全部是**纯逻辑**用例：只解析参数、拼命令行，不查询真实窗口、
//  不需要屏幕录制权限。真正「按窗口截一张图」必须人工授权，
//  不在这里（见 docs/automation/task.md）。
//
//  ── 为什么它们值得单独存在 ────────────────────────────────────
//
//  窗口寻址有两条容易写错且**不会编译报错**的规则：
//    1. 与 `--display` / `--region` 的互斥——写错就静默截错东西；
//    2. `--list-windows` 必须接受 `--direct`——写错就无限自我启动
//       （父实例启动子实例，子实例又启动孙实例…）。
//  这两条都靠这里的断言锁住。
//

import AnShotCapture
import CoreGraphics
import Foundation
import Testing

@testable import AnShotAutomation

// MARK: - 命令行解析

struct WindowAddressingTests {

    /// `--window` 解析为窗口 ID。
    @Test
    func windowFlagIsParsed() throws {
        let outcome = try CommandLineInterface.parse(
            arguments: ["anShot", "--capture", "--window", "1234"]
        )
        guard case .capture(let parameters) = outcome.action else {
            Issue.record("应解析为截图动作，实际为 \(outcome.action)")
            return
        }
        #expect(parameters.windowID == 1234)
        #expect(parameters.applicationName == nil)
    }

    /// `--app` 解析为应用名（不做任何本地校验，留给解析阶段）。
    @Test
    func appFlagIsParsed() throws {
        let outcome = try CommandLineInterface.parse(
            arguments: ["anShot", "--capture", "--app", "Safari"]
        )
        guard case .capture(let parameters) = outcome.action else {
            Issue.record("应解析为截图动作，实际为 \(outcome.action)")
            return
        }
        #expect(parameters.applicationName == "Safari")
        #expect(parameters.windowID == nil)
    }

    /// `--window` 必须是无符号整数；非数字要报错，而不是当作应用名。
    @Test
    func nonNumericWindowIsRejected() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(
                arguments: ["anShot", "--capture", "--window", "Safari"]
            )
        }
    }

    /// `--window` 与 `--app` 不能同时给：它们是两种寻址方式。
    ///
    /// 注意断言发生在 `resolveTarget()` 而不是 `parse()`：按本项目的既定分工，
    /// `parse` 只把字符串变成数字，互斥与值域一律由 `CaptureParameters` 裁决
    /// ——两条入口（CLI / MCP）共用同一套规则。断言放在 parse 上等于测错了层，
    /// 而且会诱使实现把校验散回各入口。
    @Test
    func windowAndAppAreMutuallyExclusive() throws {
        let parameters = try parsedParameters(
            ["anShot", "--capture", "--window", "1", "--app", "Safari"]
        )
        #expect(throws: AutomationError.self) {
            _ = try parameters.resolveTarget()
        }
    }

    /// 窗口寻址不能与 `--region` 混用：窗口截图没有「显示器内区域」这一说。
    @Test
    func windowAndRegionAreMutuallyExclusive() throws {
        let parameters = try parsedParameters(
            ["anShot", "--capture", "--app", "Safari", "--region", "0,0,10,10"]
        )
        #expect(throws: AutomationError.self) {
            _ = try parameters.resolveTarget()
        }
    }

    /// 窗口寻址不能与 `--display` 混用：窗口自带归属显示器。
    @Test
    func windowAndDisplayAreMutuallyExclusive() throws {
        let parameters = try parsedParameters(
            ["anShot", "--capture", "--window", "1", "--display", "1"]
        )
        #expect(throws: AutomationError.self) {
            _ = try parameters.resolveTarget()
        }
    }

    /// 从命令行参数解析出截图参数；用于「先 parse 再 resolve」的两段式断言。
    private func parsedParameters(_ arguments: [String]) throws -> CaptureParameters {
        let outcome = try CommandLineInterface.parse(arguments: arguments)
        guard case .capture(let parameters) = outcome.action else {
            throw AutomationError.invalidArgument("期望截图动作，实际为 \(outcome.action)")
        }
        return parameters
    }

    // MARK: --list-windows

    /// `--list-windows` 默认「让 app 去枚举」——标题需要屏幕录制权限。
    @Test
    func listWindowsDefaultsToAppExecution() throws {
        let outcome = try CommandLineInterface.parse(arguments: ["anShot", "--list-windows"])
        #expect(outcome.action == .listWindows)
        #expect(outcome.execution == .reuseApplicationAuthorization)
    }

    /// 但必须接受 `--direct`：它由子实例携带，是**防自我递归**的开关。
    ///
    /// 若不接受，`OutOfProcessCapture.listWindows` 传下去的子参数会被
    /// 「不接受其它选项」拒绝，子实例转而走默认路径再启动孙实例，
    /// 形成无限递归——症状是命令永不返回、桌面上堆满 anShot 进程。
    @Test
    func listWindowsAcceptsDirectFlagForRecursionGuard() throws {
        let outcome = try CommandLineInterface.parse(
            arguments: ["anShot", "--list-windows", "--direct"]
        )
        #expect(outcome.action == .listWindows)
        #expect(outcome.execution == .currentProcess)
    }

    /// `--list-displays` 保持原有约定：不接受执行位置标志（它无效果）。
    @Test
    func listDisplaysStillRejectsExecutionFlags() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(
                arguments: ["anShot", "--list-displays", "--direct"]
            )
        }
    }
}

// MARK: - 子实例参数

struct WindowChildArgumentTests {

    private func arguments(_ parameters: CaptureParameters) -> [String] {
        OutOfProcessCapture.childArguments(
            parameters: parameters,
            outputURL: URL(fileURLWithPath: "/tmp/transfer.png"),
            reportURL: URL(fileURLWithPath: "/tmp/report.json")
        )
    }

    /// 窗口 ID 要透传给子实例。
    @Test
    func windowIDIsForwarded() {
        let result = arguments(CaptureParameters(windowID: 4321))
        #expect(result.contains("--window"))
        #expect(result.contains("4321"))
        #expect(result.contains("--direct"))
    }

    /// 应用名要**原样**透传，不在父进程解析成 ID。
    ///
    /// 理由：父进程（被宿主 spawn 的 MCP 进程）通常没有屏幕录制权限，
    /// 就地解析只能看到「无权限视角下」的窗口列表——标题全空，
    /// 选中的窗口因此可能与调用方期望的不一致。
    @Test
    func applicationNameIsForwardedVerbatim() {
        let result = arguments(CaptureParameters(applicationName: "Visual Studio Code"))
        #expect(result.contains("--app"))
        #expect(result.contains("Visual Studio Code"))
    }

    /// 只带窗口 ID 时，子参数里不应出现任何显示器侧参数。
    ///
    /// 反过来也成立：这条约束不是向子实例「隐瞒」什么，而是因为
    /// `windowID` 与 `displayID` 的组合会在 `resolveTarget()` 被拒绝，
    /// 根本走不到这里——本用例锁住的是「不额外附加参数」这件事本身。
    @Test
    func windowOnlyRequestCarriesNoDisplayArguments() {
        let result = arguments(CaptureParameters(windowID: 4321))
        #expect(!result.contains("--display"))
        #expect(!result.contains("--region"))
        #expect(result.contains("--window"))
    }
}
