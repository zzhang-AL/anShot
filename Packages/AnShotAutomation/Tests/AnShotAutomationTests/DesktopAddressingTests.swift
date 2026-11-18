//
//  DesktopAddressingTests.swift
//  AnShotAutomationTests
//

import Foundation
import Testing
@testable import AnShotAutomation

@Suite("桌面寻址")
struct DesktopAddressingTests {

    @Test("桌面列表动作可被启动模式和命令行识别")
    func listDesktopsIsRecognized() throws {
        let arguments = ["anShot", "--list-desktops"]
        #expect(try AutomationRunner.detect(from: arguments) == .commandLine(arguments))
        #expect(try CommandLineInterface.parse(arguments: arguments).action == .listDesktops)
    }

    @Test("桌面 ID 被解析并经 IPC 请求透传给截图子进程")
    func desktopIDIsForwarded() throws {
        let outcome = try CommandLineInterface.parse(
            arguments: ["anShot", "--capture", "--space", "42", "--switch-desktop"]
        )
        guard case .capture(let parameters) = outcome.action else {
            Issue.record("应解析为截图")
            return
        }
        #expect(parameters.spaceID == 42)
        #expect(parameters.allowDesktopSwitch)

        let workspace = try OutOfProcessCapture.createPrivateWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let requestURL = workspace.appendingPathComponent("request.json")
        let request = IPCRequest(
            action: .capture(parameters),
            outputPath: workspace.appendingPathComponent("transfer.png").path,
            reportPath: workspace.appendingPathComponent("report.json").path,
            pidFilePath: workspace.appendingPathComponent("child.pid").path,
            watchdogTimeoutSeconds: 60
        )
        try request.write(to: requestURL)
        let decoded = try IPCRequest.load(from: requestURL.path)
        guard case .capture(let forwarded) = decoded.action else {
            Issue.record("期望解码为 .capture")
            return
        }
        #expect(forwarded.spaceID == 42)
        #expect(forwarded.allowDesktopSwitch)
    }

    @Test("无效桌面 ID 与窗口寻址混用被拒绝")
    func invalidDesktopAddressingIsRejected() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(arguments: ["anShot", "--capture", "--space", "0"])
        }
        #expect(throws: AutomationError.self) {
            _ = try CaptureParameters(spaceID: 2, windowID: 1).resolveTarget()
        }
        #expect(throws: AutomationError.self) {
            _ = try CaptureParameters(spaceID: 2, applicationName: "Example").resolveTarget()
        }
        #expect(throws: AutomationError.self) {
            _ = try CaptureParameters(allowDesktopSwitch: true).resolveTarget()
        }
    }
}
