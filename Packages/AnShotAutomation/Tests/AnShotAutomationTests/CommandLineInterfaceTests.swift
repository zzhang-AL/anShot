//
//  CommandLineInterfaceTests.swift
//  AnShotAutomationTests
//
//  命令行解析、启动模式识别与报告落盘的单元测试。
//
//  解析器是「外部输入进入系统的第一个环节」，也是最容易出静默错误的地方：
//  一个被忽略的选项不会报错，只会让结果偏离调用方的意图。
//  因此这里的用例重点在**错误路径**，而不只是正常路径。
//
//  本文件不依赖显示器，也不依赖屏幕录制权限。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotAutomation

// MARK: - 参数解析

struct CommandLineParsingTests {

    @Test
    func helpIsReturnedWhenNoArguments() throws {
        #expect(try CommandLineInterface.parse(arguments: ["anShot"]).action == .help)
    }

    @Test(arguments: ["--help", "-h"])
    func helpFlagIsRecognized(flag: String) throws {
        #expect(try CommandLineInterface.parse(arguments: ["anShot", flag]).action == .help)
    }

    @Test
    func listDisplaysIsParsed() throws {
        #expect(
            try CommandLineInterface.parse(arguments: ["anShot", "--list-displays"]).action
                == .listDisplays
        )
    }

    /// `--list-displays` 混入其它选项时必须报错，而不是忽略。
    @Test
    func listDisplaysRejectsExtraOptions() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(
                arguments: ["anShot", "--list-displays", "--out", "a.png"]
            )
        }
    }

    /// 裸 `--capture` 采用全部默认值（输出路径在运行时才补默认值）。
    @Test
    func bareCaptureUsesDefaults() throws {
        let outcome = try CommandLineInterface.parse(arguments: ["anShot", "--capture"])

        guard case .capture(let parameters) = outcome.action else {
            Issue.record("期望 .capture，实际 \(outcome.action)")
            return
        }

        #expect(parameters.displayID == nil)
        #expect(parameters.region == nil)
        #expect(parameters.maxLongEdge == nil)
        #expect(parameters.savePath == nil)
    }

    /// 全选项一起给出时逐项落位。
    @Test
    func allOptionsAreParsed() throws {
        let outcome = try CommandLineInterface.parse(arguments: [
            "anShot", "--capture",
            "--display", "1",
            "--region", "10,20,300,400",
            "--max-size", "0",
            "--out", "/tmp/anshot-test.png"
        ])

        guard case .capture(let parameters) = outcome.action else {
            Issue.record("期望 .capture，实际 \(outcome.action)")
            return
        }

        #expect(parameters.displayID == 1)
        #expect(parameters.region == CGRect(x: 10, y: 20, width: 300, height: 400))
        #expect(parameters.maxLongEdge == 0)
        #expect(parameters.savePath == "/tmp/anshot-test.png")
    }

    /// region 允许小数（逻辑点未必是整数）。
    @Test
    func fractionalRegionIsAccepted() throws {
        let outcome = try CommandLineInterface.parse(arguments: [
            "anShot", "--capture", "--region", "1.5,2.5,30.5,40.5"
        ])

        guard case .capture(let parameters) = outcome.action else {
            Issue.record("期望 .capture，实际 \(outcome.action)")
            return
        }

        #expect(parameters.region == CGRect(x: 1.5, y: 2.5, width: 30.5, height: 40.5))
    }

    // MARK: 值与职责分层

    /// `--max-size -1` 在**解析**阶段通过，由 `validate()` 拒绝。
    ///
    /// 这是在锁定分层约定：解析器只把字符串变成数字，
    /// 所有值域规则集中在 `CaptureParameters.validate()`，
    /// 从而 CLI 与 MCP 不可能出现「一个能过一个过不了」的分歧。
    @Test
    func negativeMaxSizePassesParsingAndIsRejectedByValidation() throws {
        let outcome = try CommandLineInterface.parse(
            arguments: ["anShot", "--capture", "--max-size", "-1"]
        )

        guard case .capture(let parameters) = outcome.action else {
            Issue.record("期望 .capture，实际 \(outcome.action)")
            return
        }

        #expect(parameters.maxLongEdge == -1)
        #expect(throws: AutomationError.self) {
            _ = try parameters.validate()
        }
    }

    /// NaN / inf 在解析阶段就被拒（它们是语法上「像数字」的陷阱值）。
    @Test(arguments: ["nan,0,100,100", "0,inf,100,100", "0,0,100,inf"])
    func nonFiniteRegionIsRejectedAtParsing(region: String) {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(
                arguments: ["anShot", "--capture", "--region", region]
            )
        }
    }

    // MARK: json-out

    /// `--json-out` 对截图与列表两种动作都生效。
    @Test(arguments: [
        ["anShot", "--list-displays", "--json-out", "/tmp/a.json"],
        ["anShot", "--capture", "--json-out", "/tmp/a.json"]
    ])
    func jsonOutIsParsedForBothActions(arguments: [String]) throws {
        let outcome = try CommandLineInterface.parse(arguments: arguments)
        #expect(outcome.jsonOutPath == "/tmp/a.json")
    }

    @Test
    func jsonOutDefaultsToNil() throws {
        let outcome = try CommandLineInterface.parse(arguments: ["anShot", "--list-displays"])
        #expect(outcome.jsonOutPath == nil)
    }

    @Test
    func jsonOutWithoutValueIsRejected() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(
                arguments: ["anShot", "--list-displays", "--json-out"]
            )
        }
    }

    /// `--out` 与 `--json-out` 指向同一文件时必须拒绝。
    ///
    /// 不拦的后果很隐蔽：PNG 先写成功，紧接着 JSON 把它覆盖掉，
    /// 调用方拿到一个后缀是 `.png` 却装着 JSON 的文件，而退出码是 0。
    @Test
    func identicalOutAndJsonOutIsRejected() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(arguments: [
                "anShot", "--capture",
                "--out", "/tmp/same.png",
                "--json-out", "/tmp/same.png"
            ])
        }
    }

    /// 路径比较按解析后的绝对路径进行，`~` 与冗余分隔符不影响判定。
    @Test
    func pathComparisonIsNormalized() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(arguments: [
                "anShot", "--capture",
                "--out", "/tmp/same.png",
                "--json-out", "/tmp/./same.png"
            ])
        }
    }

    @Test
    func differentOutAndJsonOutIsAccepted() throws {
        let outcome = try CommandLineInterface.parse(arguments: [
            "anShot", "--capture",
            "--out", "/tmp/a.png",
            "--json-out", "/tmp/a.json"
        ])
        #expect(outcome.jsonOutPath == "/tmp/a.json")
    }

    // MARK: 错误路径

    @Test
    func unknownOptionIsRejected() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(arguments: ["anShot", "--capture", "--bogus"])
        }
    }

    @Test
    func missingOptionValueIsRejected() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(arguments: ["anShot", "--capture", "--out"])
        }
    }

    /// 选项被当成值时必须报错。
    ///
    /// 若不拦，`--out --max-size` 会把字面量 `--max-size` 当作路径，
    /// 错误会推迟到落盘时才以「路径奇怪」的形式暴露，排查成本高得多。
    @Test
    func optionAsValueIsRejected() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(
                arguments: ["anShot", "--capture", "--out", "--max-size"]
            )
        }
    }

    @Test(arguments: [
        "1,2,3",          // 少了分量
        "1,2,3,4,5",      // 多了分量
        "a,b,c,d",        // 非数字
        "1,2,3,"          // 尾随逗号导致空分量
    ])
    func malformedRegionIsRejected(region: String) {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(
                arguments: ["anShot", "--capture", "--region", region]
            )
        }
    }

    @Test
    func nonNumericMaxSizeIsRejected() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(
                arguments: ["anShot", "--capture", "--max-size", "big"]
            )
        }
    }

    @Test
    func nonNumericDisplayIsRejected() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(
                arguments: ["anShot", "--capture", "--display", "main"]
            )
        }
    }

    /// `--mcp` 混入 CLI 动作必须报错。
    @Test
    func mcpMixedWithCaptureIsRejected() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(
                arguments: ["anShot", "--mcp", "--capture"]
            )
        }
    }

    /// 没有任何动作时必须报错。
    @Test
    func missingActionIsRejected() {
        #expect(throws: AutomationError.self) {
            _ = try CommandLineInterface.parse(arguments: ["anShot", "--display", "1"])
        }
    }
}

// MARK: - 默认输出路径

struct DefaultOutputPathTests {

    /// 默认路径落在 `~/Pictures/anShot/`，且带时间戳。
    ///
    /// 选 Pictures 而非临时目录：调试截图通常要回头再看，
    /// 而临时目录会被系统清理。
    @Test
    func defaultPathIsTimestampedUnderPictures() {
        let path = CommandLineInterface.defaultOutputPath()

        #expect(path.contains("/Pictures/anShot/"))
        #expect(path.hasSuffix(".png"))
        // 形如 anshot-20260916-173100.png
        let name = (path as NSString).lastPathComponent
        #expect(name.hasPrefix("anshot-"))
        #expect(name.count == "anshot-20260916-173100.png".count)
    }
}

// MARK: - 路径同一性

struct PathIdentityTests {

    /// `.` 与冗余分隔符必须被折叠。
    @Test
    func redundantComponentsAreFolded() {
        #expect(PathIdentity.areSame("/tmp/a.png", "/tmp/./a.png"))
        #expect(PathIdentity.areSame("/tmp/a.png", "/tmp//a.png"))
    }

    /// 符号链接必须被解析。
    ///
    /// macOS 上 `/tmp` 本身就是指向 `/private/tmp` 的链接，
    /// 所以这条不是理论情形——不解析就会漏判，而漏判的后果是
    /// 报告覆盖掉刚写好的截图。
    @Test
    func symlinksAreResolved() throws {
        // 同一个基名：real 与 link 必须是「同目录下的真身与链接」，
        // 用两个不同的 UUID 就不构成链接关系了。
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anshot-link-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let link = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let viaLink = link.appendingPathComponent("shot.png").path
        let viaReal = real.appendingPathComponent("shot.png").path

        #expect(PathIdentity.areSame(viaLink, viaReal))
    }

    @Test
    func differentPathsAreNotSame() {
        #expect(!PathIdentity.areSame("/tmp/a.png", "/tmp/a.json"))
        #expect(!PathIdentity.areSame("/tmp/a.png", "/tmp/b.png"))
    }
}

// MARK: - 报告落盘

struct ReportWritingTests {

    /// 解析失败时仍能取到 `--json-out` 的路径。
    ///
    /// 这是「解析失败也要落盘取证」的实现基础：文档承诺 `--json-out`
    /// 在成功或失败时都写，而参数错误恰恰最需要留证据
    /// （`open -n` 那种调用方式下 stdout/stderr 都会被丢掉）。
    @Test
    func bestEffortPathIsFoundEvenWhenParsingWouldFail() {
        let path = CommandLineInterface.bestEffortJSONOutPath(arguments: [
            "anShot", "--capture", "--bogus-option",
            "--json-out", "/tmp/report.json"
        ])
        #expect(path == "/tmp/report.json")
    }

    @Test
    func bestEffortPathIsNilWhenMissingOrValueless() {
        #expect(
            CommandLineInterface.bestEffortJSONOutPath(arguments: ["anShot", "--capture"]) == nil
        )
        #expect(
            CommandLineInterface.bestEffortJSONOutPath(
                arguments: ["anShot", "--capture", "--json-out"]
            ) == nil
        )
        // 下一个参数是选项而非值 → 视为没有值
        #expect(
            CommandLineInterface.bestEffortJSONOutPath(
                arguments: ["anShot", "--json-out", "--capture"]
            ) == nil
        )
    }

    /// 路径冲突必须是**可识别**的独立错误类型。
    ///
    /// 失败处理依赖它来决定「不要把报告写到那个危险目标上」——
    /// 若它退化成普通的 `invalidArgument`，失败处理就会去写那个文件，
    /// 把「拒绝覆盖」的初衷破坏掉。
    @Test
    func pathConflictIsDistinguishableFromOtherArgumentErrors() {
        var conflict: Error?
        do {
            _ = try CommandLineInterface.parse(arguments: [
                "anShot", "--capture",
                "--out", "/tmp/same.png",
                "--json-out", "/tmp/same.png"
            ])
        } catch {
            conflict = error
        }

        let error = conflict
        #expect(error != nil)
        #expect(CommandLineInterface.isPathConflict(conflict!))

        // 对照：另一种参数错误不应被识别为路径冲突
        var other: Error?
        do {
            _ = try CommandLineInterface.parse(arguments: ["anShot", "--capture", "--region", "1,2"])
        } catch {
            other = error
        }
        #expect(other != nil)
        #expect(!CommandLineInterface.isPathConflict(other!))
    }
}

// MARK: - 模式识别（真实入口）

struct AutomationModeDetectionTests {

    @Test
    func plainLaunchIsGuiMode() throws {
        #expect(try AutomationRunner.detect(from: ["/path/to/anShot"]) == nil)
    }

    /// 系统附加的参数不得被误判为 CLI 调用。
    ///
    /// macOS 通过 LaunchServices 启动 app 时会追加 `-psn_...` 之类的参数。
    /// 若把「未知参数」一律当成 CLI，用户双击应用就会得到一个莫名其妙的报错。
    @Test
    func systemLaunchArgumentsAreNotCli() throws {
        #expect(try AutomationRunner.detect(from: ["/path/to/anShot", "-psn_0_12345"]) == nil)
        #expect(
            try AutomationRunner.detect(
                from: ["/path/to/anShot", "-NSDocumentRevisionsDebugMode", "YES"]
            ) == nil
        )
    }

    @Test
    func mcpFlagIsDetected() throws {
        #expect(try AutomationRunner.detect(from: ["/path/to/anShot", "--mcp"]) == .mcp)
    }

    @Test(arguments: [
        ["/path/to/anShot", "--capture"],
        ["/path/to/anShot", "--list-displays"],
        ["/path/to/anShot", "--help"],
        ["/path/to/anShot", "-h"],
        ["/path/to/anShot", "--capture", "--out", "/tmp/a.png"]
    ])
    func cliArgumentsAreDetected(arguments: [String]) throws {
        let mode = try AutomationRunner.detect(from: arguments)
        guard case .commandLine = mode else {
            Issue.record("期望 .commandLine，实际 \(String(describing: mode))")
            return
        }
    }

    /// `--mcp` 与截图类选项混用时，**真实入口**必须拒绝。
    ///
    /// 这条用例覆盖的是曾经的实现缺陷：`detect` 见到 `--mcp` 就返回，
    /// 于是 CLI 解析器里那条「不能混用」的检查永远不可达——
    /// 测试测的是一个生产路径到不了的函数。
    @Test(arguments: [
        ["/path/to/anShot", "--mcp", "--capture"],
        ["/path/to/anShot", "--capture", "--mcp"],
        ["/path/to/anShot", "--mcp", "--list-displays"],
        ["/path/to/anShot", "--mcp", "--help"],
        ["/path/to/anShot", "--mcp", "--out", "/tmp/a.png"]
    ])
    func mcpMixedWithCliIsRejectedAtRealEntry(arguments: [String]) {
        #expect(throws: AutomationError.self) {
            _ = try AutomationRunner.detect(from: arguments)
        }
    }
}

// MARK: - 帮助文本

struct UsageTextTests {

    /// 帮助文本必须同时提到三种能力与权限说明。
    ///
    /// 权限那段尤其不能省：它解释了「为什么授权对象可能不是 anShot.app」，
    /// 缺了它，用户会在系统设置里找不到 anShot 而认为功能坏了。
    @Test
    func usageDocumentsActionsAndPermission() {
        let usage = CommandLineInterface.usage

        #expect(usage.contains("--capture"))
        #expect(usage.contains("--list-displays"))
        #expect(usage.contains("--mcp"))
        #expect(usage.contains("--json-out"))
        #expect(usage.contains("屏幕录制"))
        #expect(usage.contains("逻辑点"))
    }

    /// 帮助里**不得**出现未实现的选项。
    ///
    /// `tools/anshot` 的早期帮助文本提到过 `--json`，而它从未被实现——
    /// 文档承诺一个不存在的开关比不写更糟。
    @Test
    func usageDoesNotAdvertiseUnimplementedFlags() {
        let usage = CommandLineInterface.usage
        #expect(!usage.contains("--json "))
        #expect(!usage.contains("--json\n"))
    }
}
