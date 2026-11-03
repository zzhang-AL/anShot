//
//  CaptureExecutionTests.swift
//  AnShotAutomationTests
//
//  「截图由谁执行」的单元测试。
//
//  这是本项目最容易出错、且出错时**最难察觉**的一处：权限归属错了不会编译失败，
//  也不会有明显异常，只表现为「明明 anShot 已经授权，工具却说要授权」，
//  而且错误信息还会把用户指向错误的授权对象（宿主而不是 anShot）。
//
//  所以这里断言的是两件事：
//    1. 默认值必须是「复用 anShot 自己的授权」——不是可选项，是默认；
//    2. 传给子实例的参数必须能防住自我启动递归，且不丢语义（`--max-size 0` 与
//       「未指定」是两回事）。
//
//  本文件不依赖显示器，也不依赖屏幕录制权限，只做参数与字符串构造的断言。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotAutomation

// MARK: - 执行位置的选择

@Suite("截图执行位置")
struct CaptureExecutionSelectionTests {

    @Test("默认复用 anShot 已有的屏幕录制授权")
    func defaultIsReuseApplicationAuthorization() throws {
        let outcome = try CommandLineInterface.parse(arguments: ["anShot", "--capture"])
        #expect(outcome.execution == .reuseApplicationAuthorization)
    }

    @Test("默认值与显式写 --via-app 完全等价")
    func viaAppEqualsDefault() throws {
        let implicit = try CommandLineInterface.parse(arguments: ["anShot", "--capture"])
        let explicit = try CommandLineInterface.parse(
            arguments: ["anShot", "--capture", "--via-app"]
        )
        #expect(explicit.execution == .reuseApplicationAuthorization)
        #expect(explicit.execution == implicit.execution)
        #expect(explicit.action == implicit.action)
    }

    @Test("--direct 才把授权要求落到当前进程")
    func directSelectsCurrentProcess() throws {
        let outcome = try CommandLineInterface.parse(
            arguments: ["anShot", "--capture", "--direct", "--out", "/tmp/a.png"]
        )
        #expect(outcome.execution == .currentProcess)
    }

    @Test("两个含义相反的标志同时给出必须报错，而不是静默取其一")
    func conflictingFlagsAreRejected() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(
                arguments: ["anShot", "--capture", "--direct", "--via-app"]
            )
        }
        // 反序也一样
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(
                arguments: ["anShot", "--capture", "--via-app", "--direct"]
            )
        }
    }

    @Test("重复给出同一个标志不算冲突")
    func repeatedSameFlagIsAccepted() throws {
        let outcome = try CommandLineInterface.parse(
            arguments: ["anShot", "--capture", "--direct", "--direct"]
        )
        #expect(outcome.execution == .currentProcess)
    }

    @Test("--list-displays 不接受执行位置标志")
    func listDisplaysRejectsExecutionFlags() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(
                arguments: ["anShot", "--list-displays", "--direct"]
            )
        }
    }

    @Test("执行位置标志被启动模式识别接受，不会被当 GUI 启动")
    func executionFlagsAreRecognisedByDetector() throws {
        for flag in ["--direct", "--via-app"] {
            let mode = try AutomationRunner.detect(
                from: ["anShot", "--capture", flag]
            )
            guard case .commandLine = mode else {
                Issue.record("\(flag) 未被识别为命令行模式，实际为 \(String(describing: mode))")
                return
            }
        }
    }

    @Test("帮助不再把 open -n 当作需要用户手动选择的例外做法")
    func usageDescribesDefaultAsAutomatic() {
        let usage = CommandLineInterface.usage
        #expect(usage.contains("--direct"))
        #expect(usage.contains("--via-app"))
        #expect(usage.contains("默认"))
    }
}

// MARK: - 传给子实例的参数

@Suite("子实例参数构造")
struct ChildArgumentTests {

    private func arguments(
        displayID: CGDirectDisplayID? = nil,
        region: CGRect? = nil,
        maxLongEdge: Int? = nil
    ) -> [String] {
        let parameters = CaptureParameters(
            displayID: displayID,
            region: region,
            maxLongEdge: maxLongEdge,
            savePath: nil
        )
        return OutOfProcessCapture.childArguments(
            parameters: parameters,
            outputURL: URL(fileURLWithPath: "/tmp/transfer.png"),
            reportURL: URL(fileURLWithPath: "/tmp/report.json")
        )
    }

    /// `--direct` 缺了就会无限自我启动：父进程 open 子进程，子进程再 open 孙进程…
    /// 每一层都看似正常，表现为 cpu 被吃光。
    @Test("必定带 --direct 以切断自我启动递归")
    func alwaysIncludesDirect() {
        for args in [arguments(), arguments(region: CGRect(x: 1, y: 2, width: 3, height: 4))] {
            #expect(args.contains("--direct"))
            #expect(args.contains("--capture"))
            // 只能出现一次，重复无意义但也不该出现
            #expect(args.filter { $0 == "--direct" }.count == 1)
        }
    }

    @Test("0 与「未指定」必须区分开：0 表示不缩放")
    func zeroMaxSizeIsPreserved() {
        let zero = arguments(maxLongEdge: 0)
        #expect(zero.contains("--max-size"))
        #expect(zero.firstIndex(of: "--max-size").map { zero[$0 + 1] } == "0")

        let unspecified = arguments(maxLongEdge: nil)
        #expect(!unspecified.contains("--max-size"))
    }

    @Test("其余参数原样传递")
    func passesThroughOptions() {
        let args = arguments(
            displayID: 3,
            region: CGRect(x: 10, y: 20, width: 300, height: 400),
            maxLongEdge: 1280
        )
        #expect(args.firstIndex(of: "--display").map { args[$0 + 1] } == "3")
        #expect(args.firstIndex(of: "--region").map { args[$0 + 1] } == "10,20,300,400")
        #expect(args.firstIndex(of: "--max-size").map { args[$0 + 1] } == "1280")
        #expect(args.firstIndex(of: "--out").map { args[$0 + 1] } == "/tmp/transfer.png")
        #expect(args.firstIndex(of: "--json-out").map { args[$0 + 1] } == "/tmp/report.json")
    }

    @Test("整数区域不带多余小数位，小数区域保留精度")
    func regionFormatting() {
        #expect(OutOfProcessCapture.number(0) == "0")
        #expect(OutOfProcessCapture.number(800) == "800")
        #expect(OutOfProcessCapture.number(-12) == "-12")
        #expect(OutOfProcessCapture.number(0.5) == "0.5000")
        #expect(OutOfProcessCapture.number(12.25) == "12.2500")
    }

    /// 某些区域设置的小数点是逗号，那会与「四个分量」的逗号分隔符混成同一个字符，
    /// 于是子实例解析出的区域要么报错、要么完全错位。
    @Test("数字格式不随区域设置变化，小数点恒为点号")
    func numberFormattingIsLocaleIndependent() {
        let fractional = OutOfProcessCapture.number(1.5)
        #expect(fractional.contains("."))
        #expect(!fractional.contains(","))

        let region = OutOfProcessCapture.regionArgument(
            CGRect(x: 0.5, y: 1.5, width: 2.5, height: 3.5)
        )
        #expect(region == "0.5000,1.5000,2.5000,3.5000")
        // 逗号恰好三个，全部是分量分隔符
        #expect(region.filter { $0 == "," }.count == 3)
    }

    /// 单测与 `swift run` 都不在 .app 内，此时没有可启动的 app，
    /// 只能退回就地截图。这条断言把这个前置条件钉住：
    /// 若某天它变成非 nil，说明测试环境变了，路由结论也要跟着复核。
    @Test("测试进程不在 .app 内，因此走不到跨进程路径")
    func testProcessHasNoApplicationBundle() {
        #expect(OutOfProcessCapture.currentAppURL == nil)
    }
}

// MARK: - 落盘的复用

@Suite("统一落盘")
struct UnifiedSaveTests {

    @Test("落盘沿用排他编号，绝不覆盖已有文件")
    func saveNeverOverwrites() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("shot.png")
        let first = try CaptureService.save(Data([0x01]), to: target.path)
        let second = try CaptureService.save(Data([0x02]), to: target.path)

        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data([0x01]))
        #expect(try Data(contentsOf: second) == Data([0x02]))
    }

    /// 跨进程路径下这条保护最容易丢：子实例不知道父进程的报告路径。
    /// 若哪天有人把落盘挪回子实例，这个用例就是它重新变成缺陷的证据。
    @Test("保留路径仍被避开，报告的落点不会被截图占用")
    func reservedPathStillAvoided() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let target = directory.appendingPathComponent("shot.png")
        let reserved = directory.appendingPathComponent("shot-2.png")
        _ = try CaptureService.save(Data([0x01]), to: target.path)

        let saved = try CaptureService.save(
            Data([0x02]),
            to: target.path,
            reservedPaths: [PathIdentity.canonical(reserved.path)]
        )
        #expect(PathIdentity.canonical(saved.path) != PathIdentity.canonical(reserved.path))
    }
}
