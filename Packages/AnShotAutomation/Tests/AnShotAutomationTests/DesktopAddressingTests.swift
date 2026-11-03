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

    @Test("桌面 ID 被解析并透传给截图子进程")
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
        let args = OutOfProcessCapture.childArguments(
            parameters: parameters,
            outputURL: URL(fileURLWithPath: "/tmp/transfer.png"),
            reportURL: URL(fileURLWithPath: "/tmp/report.json")
        )
        #expect(args.firstIndex(of: "--space").map { args[$0 + 1] } == "42")
        #expect(args.contains("--switch-desktop"))
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
