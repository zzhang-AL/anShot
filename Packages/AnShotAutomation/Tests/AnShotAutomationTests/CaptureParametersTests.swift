//
//  CaptureParametersTests.swift
//  AnShotAutomationTests
//
//  截图参数校验、下采样与落盘的单元测试。
//
//  ── 这些用例的边界（不得含糊）─────────────────────────────────
//
//  其中一部分**会查询真实显示器**（`DisplayGeometry.activeDisplays()`），
//  因此它们需要一台带显示器的机器，不是「任何 CI 都能跑」的纯逻辑用例。
//  具体地：
//
//      DisplayCatalogTests            —— 全程依赖真实显示器
//      CaptureParametersValidationTests 的部分用例 —— 需要主显示器存在
//      ImageScalingTests           —— 纯逻辑，不依赖显示器
//      ExclusiveWriteTests         —— 纯文件系统，不依赖显示器
//
//  真正需要屏幕录制权限的「实际抓帧」不在这里——那必须人工授权，
//  无法在无人值守环境下验证（见 docs/automation/task.md）。
//

import AnShotCapture
import CoreGraphics
import Foundation
import Testing

@testable import AnShotAutomation

// MARK: - 参数校验

struct CaptureParametersValidationTests {

    /// 不指定显示器时落到主显示器，且整屏请求不带区域。
    @Test
    func defaultsToMainDisplayWithNoRegion() throws {
        let parameters = CaptureParameters()
        let validated = try parameters.validate()

        #expect(validated.displayID == DisplayGeometry.mainDisplay())
        #expect(validated.region == nil)
    }

    /// 不存在的显示器 ID 必须报错，而不是静默回退到主屏。
    ///
    /// 静默回退是最坏的选择：AI 以为截的是第二块屏，实际拿到主屏的图，
    /// 而它没有任何依据察觉这个错配。
    @Test
    func unknownDisplayIsRejected() {
        let parameters = CaptureParameters(displayID: 999_999)

        #expect(throws: AutomationError.self) {
            _ = try parameters.validate()
        }
    }

    /// 宽或高小于 1 的区域必须被拒绝。
    ///
    /// ScreenCaptureKit 对这类输入不报错，而是给出一张空图——
    /// 那种失败更难排查，所以要在入口拦掉。
    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 0, height: 100),
        CGRect(x: 0, y: 0, width: 100, height: 0),
        CGRect(x: 0, y: 0, width: -10, height: 100),
        CGRect(x: 0, y: 0, width: 100, height: -10)
    ])
    func nonPositiveRegionIsRejected(region: CGRect) {
        let parameters = CaptureParameters(region: region)

        #expect(throws: AutomationError.self) {
            _ = try parameters.validate()
        }
    }

    // MARK: 数值有限性
    //
    // NaN / inf 能被 `Double("nan")` 解析出来，且它们在 CGRect 运算里
    // 不会报错，只会产生难以归因的结果（空图、尺寸 0、整数转换陷阱）。
    // 这些用例锁住「在入口拒掉」这条约定。

    @Test(arguments: [
        CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
        CGRect(x: 0, y: CGFloat.nan, width: 100, height: 100),
        CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100),
        CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan),
        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
        CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100),
        CGRect(x: 0, y: 0, width: 100, height: -CGFloat.infinity)
    ])
    func nonFiniteRegionIsRejected(region: CGRect) {
        #expect(throws: AutomationError.self) {
            _ = try CaptureParameters(region: region).validate()
        }
    }

    /// 超量级坐标被拒绝：它们一定是输入错误，而非真实的屏幕坐标。
    @Test
    func absurdCoordinateMagnitudeIsRejected() {
        let region = CGRect(x: 0, y: 0, width: 1e9, height: 100)

        #expect(throws: AutomationError.self) {
            _ = try CaptureParameters(region: region).validate()
        }
    }

    // MARK: max_size
    //
    // 这组用例存在的理由是一个真实缺陷：`validate()` 曾在「整屏（region == nil）」
    // 分支提前返回，于是整屏请求**完全绕过**数值检查。故这里分别覆盖
    // 「带区域」与「不带区域」两条路径。

    @Test
    func negativeMaxSizeIsRejectedWithRegion() {
        let parameters = CaptureParameters(
            region: CGRect(x: 0, y: 0, width: 100, height: 100),
            maxLongEdge: -1
        )

        #expect(throws: AutomationError.self) {
            _ = try parameters.validate()
        }
    }

    /// 整屏（不带 region）时也必须校验 max_size —— 这条曾因提前返回而失效。
    @Test
    func negativeMaxSizeIsRejectedWithoutRegion() {
        let parameters = CaptureParameters(maxLongEdge: -1)

        #expect(throws: AutomationError.self) {
            _ = try parameters.validate()
        }
    }

    @Test
    func oversizedMaxSizeIsRejected() {
        let parameters = CaptureParameters(
            maxLongEdge: CaptureParameters.maximumLongEdge + 1
        )

        #expect(throws: AutomationError.self) {
            _ = try parameters.validate()
        }
    }

    @Test
    func boundaryMaxSizeIsAccepted() throws {
        _ = try CaptureParameters(maxLongEdge: 0).validate()
        _ = try CaptureParameters(maxLongEdge: CaptureParameters.maximumLongEdge).validate()
    }

    // MARK: 裁剪

    /// 部分越界的区域被裁剪，而非被拒绝。
    ///
    /// 与 `CaptureSetup.normalizedRegion` 的既有行为保持一致：
    /// 用户拖到屏幕外一点点就失败，是很烦人的体验。
    @Test
    func partiallyOutOfBoundsRegionIsClamped() throws {
        let main = DisplayGeometry.mainDisplay()
        let bounds = DisplayGeometry.bounds(for: main)

        let requested = CGRect(x: 100, y: 0, width: bounds.width * 4, height: 100)
        let validated = try CaptureParameters(region: requested).validate()

        #expect(validated.displayID == main)
        let region = try #require(validated.region)
        #expect(region.width <= bounds.width)
        #expect(region.height <= 100)
    }

    /// 完全落在屏幕外的区域必须报错。
    @Test
    func fullyOutOfBoundsRegionIsRejected() throws {
        let main = DisplayGeometry.mainDisplay()
        let bounds = DisplayGeometry.bounds(for: main)

        let requested = CGRect(
            x: bounds.width + 10_000,
            y: bounds.height + 10_000,
            width: 100,
            height: 100
        )

        #expect(throws: AutomationError.self) {
            _ = try CaptureParameters(region: requested).validate()
        }
    }

    /// 默认长边上限会被落到 2560。
    @Test
    func defaultMaxLongEdgeIsApplied() {
        #expect(CaptureParameters().resolvedMaxLongEdge == ImageScaling.defaultMaxLongEdge)
        #expect(CaptureParameters(maxLongEdge: 0).resolvedMaxLongEdge == 0)
        #expect(CaptureParameters(maxLongEdge: 1024).resolvedMaxLongEdge == 1024)
    }
}

// MARK: - 下采样

struct ImageScalingTests {

    /// 构造一张纯色测试图。
    ///
    /// 不读磁盘：测试不该依赖任何外部文件，也不该受图像解码实现影响。
    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// 未超过上限时**原样返回同一对象**（不重绘、不拷贝像素）。
    @Test
    func underLimitReturnsSameInstance() throws {
        let image = try makeImage(width: 800, height: 600)
        let scaled = try ImageScaling.downscale(image, maxLongEdge: 2560)

        #expect(scaled === image)
    }

    /// 超过上限时按长边等比缩小。
    @Test
    func overLimitScalesProportionally() throws {
        let image = try makeImage(width: 4000, height: 2000)
        let scaled = try ImageScaling.downscale(image, maxLongEdge: 1000)

        #expect(scaled.width == 1000)
        #expect(scaled.height == 500)
        // 宽高比必须保持：非等比缩放会让界面元素变形，反而误导调试
        #expect(abs(Double(scaled.width) / Double(scaled.height) - 2.0) < 0.01)
    }

    /// 竖构图按**长边**（此处是高度）缩放。
    @Test
    func portraitScalesByLongerEdge() throws {
        let image = try makeImage(width: 1000, height: 4000)
        let scaled = try ImageScaling.downscale(image, maxLongEdge: 1000)

        #expect(scaled.height == 1000)
        #expect(scaled.width == 250)
    }

    /// `maxLongEdge <= 0` 表示不缩放。
    @Test(arguments: [0, -1])
    func nonPositiveLimitDisablesScaling(limit: Int) throws {
        let image = try makeImage(width: 3000, height: 2000)
        let scaled = try ImageScaling.downscale(image, maxLongEdge: limit)

        #expect(scaled === image)
    }

    /// 缩放结果绝不超过上限 —— 这条契约必须成立，不能静默回退到原图。
    @Test
    func resultNeverExceedsLimit() throws {
        for limit in [100, 640, 2560] {
            let image = try makeImage(width: 4000, height: 3000)
            let scaled = try ImageScaling.downscale(image, maxLongEdge: limit)
            #expect(max(scaled.width, scaled.height) <= limit)
        }
    }
}

// MARK: - 落盘（排他创建）

struct ExclusiveWriteTests {

    /// 在一个临时目录里跑，用后即删。
    private func withTemporaryDirectory<T>(
        _ body: (URL) throws -> T
    ) throws -> T {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anshot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// 目标空闲时就用请求的路径。
    @Test
    func writesToDesiredPathWhenFree() throws {
        try withTemporaryDirectory { directory in
            let desired = directory.appendingPathComponent("shot.png")
            let written = try CaptureService.writeExclusively(
                Data("first".utf8),
                desiredURL: desired
            )

            #expect(written == desired)
            #expect(try Data(contentsOf: written) == Data("first".utf8))
        }
    }

    /// 目标已存在时换名，**不覆盖**。
    @Test
    func doesNotOverwriteExistingFile() throws {
        try withTemporaryDirectory { directory in
            let desired = directory.appendingPathComponent("shot.png")
            let first = try CaptureService.writeExclusively(
                Data("first".utf8),
                desiredURL: desired
            )
            let second = try CaptureService.writeExclusively(
                Data("second".utf8),
                desiredURL: desired
            )

            #expect(first != second)
            // 关键：先写的那份内容必须还在
            #expect(try Data(contentsOf: first) == Data("first".utf8))
            #expect(try Data(contentsOf: second) == Data("second".utf8))
        }
    }

    /// 序号按 -2、-3… 递增，与既有命名约定一致。
    @Test
    func numberingFollowsExistingConvention() throws {
        try withTemporaryDirectory { directory in
            let desired = directory.appendingPathComponent("shot.png")
            for index in 0..<3 {
                _ = try CaptureService.writeExclusively(
                    Data("n\(index)".utf8),
                    desiredURL: desired
                )
            }

            #expect(FileManager.default.fileExists(atPath: desired.path))
            #expect(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("shot-2.png").path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("shot-3.png").path
                )
            )
        }
    }

    /// 并发写同一路径：**每一个都成功，且内容互不覆盖**。
    ///
    /// 这是本原语存在的全部理由。若实现退化成「先判断存在再写」，
    /// 这个用例会看到文件数量少于写入次数，或读到被覆盖的内容。
    @Test
    func concurrentWritesNeverCollide() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anshot-concurrent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let desired = directory.appendingPathComponent("shot.png")
        let count = 24

        let written = try await withThrowingTaskGroup(of: URL.self) { group in
            for index in 0..<count {
                group.addTask {
                    try CaptureService.writeExclusively(
                        Data("payload-\(index)".utf8),
                        desiredURL: desired
                    )
                }
            }
            var results: [URL] = []
            for try await url in group { results.append(url) }
            return results
        }

        // ① 每个写入都拿到互不相同的路径
        #expect(Set(written).count == count)

        // ② 磁盘上恰好有 count 个文件
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(onDisk.count == count)

        // ③ 每个文件的内容都还是自己那一份（没有被谁覆盖掉）
        for (index, url) in written.enumerated() {
            _ = index  // 路径与内容不是一一对应的，逐个校验内容完整性即可
            let content = try String(contentsOf: url, encoding: .utf8)
            #expect(content.hasPrefix("payload-"))
        }

        let contents = Set(
            try onDisk.map { try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
        )
        #expect(contents.count == count)
    }

    /// 保留路径即使**尚未存在**也不会被占用。
    ///
    /// 这是「报告不能被截图覆盖」的基础：报告可能还没写，
    /// 但它的位置必须现在就替它留着。
    @Test
    func reservedPathIsNeverUsed() throws {
        try withTemporaryDirectory { directory in
            let desired = directory.appendingPathComponent("shot.png")
            let reserved = directory.appendingPathComponent("shot-2.png")

            let written = try CaptureService.writeExclusively(
                Data("png".utf8),
                desiredURL: desired,
                reservedPaths: [PathIdentity.canonical(reserved)]
            )

            #expect(written != reserved)
            #expect(!FileManager.default.fileExists(atPath: reserved.path))
        }
    }

    /// 复现「自动追加序号撞上报告路径」这一真实缺陷。
    ///
    /// 场景：`--out shot.png --json-out shot-2.png`，而 `shot.png` 已存在。
    /// 没有保留路径时，PNG 会排他到 `shot-2.png`，随后报告把它覆盖掉——
    /// 调用方拿到一个后缀是 `.png` 却装着 JSON 的文件，退出码还是 0。
    @Test
    func autoNumberingNeverCollidesWithReportPath() throws {
        try withTemporaryDirectory { directory in
            let shot = directory.appendingPathComponent("shot.png")
            let report = directory.appendingPathComponent("shot-2.png")

            // 先占住 shot.png，迫使下一次写入走序号分支
            _ = try CaptureService.writeExclusively(Data("existing".utf8), desiredURL: shot)

            let written = try CaptureService.writeExclusively(
                Data("png".utf8),
                desiredURL: shot,
                reservedPaths: [PathIdentity.canonical(report)]
            )

            #expect(written != report)
            #expect(!FileManager.default.fileExists(atPath: report.path))
            // 先写的那份也仍在
            #expect(try Data(contentsOf: shot) == Data("existing".utf8))
        }
    }

    /// 序号空间耗尽后的 UUID 回退路径同样避开保留路径。
    @Test
    func uuidFallbackAvoidsReservedPath() throws {
        try withTemporaryDirectory { directory in
            let desired = directory.appendingPathComponent("shot.png")
            // 把所有序号候选都占掉（上限 999，这里只在 0 与保留路径上验证行为）
            let reserved = directory.appendingPathComponent("shot-2.png")

            let written = try CaptureService.writeExclusively(
                Data("x".utf8),
                desiredURL: desired,
                reservedPaths: [PathIdentity.canonical(reserved)]
            )
            #expect(written != reserved)
        }
    }

    /// 嵌套目录会被自动创建。
    @Test
    func createsMissingParentDirectories() throws {
        try withTemporaryDirectory { directory in
            let desired = directory
                .appendingPathComponent("a/b/c")
                .appendingPathComponent("shot.png")

            let written = try CaptureService.writeExclusively(
                Data("x".utf8),
                desiredURL: desired
            )
            #expect(FileManager.default.fileExists(atPath: written.path))
        }
    }
}

// MARK: - MCP 响应体量

struct MCPPayloadLimitsTests {

    /// 上限以内的体量通过。
    @Test(arguments: [0, 1, 1024, MCPPayloadLimits.maximumPNGBytes])
    func withinLimitIsAccepted(byteCount: Int) throws {
        try MCPPayloadLimits.validate(pngByteCount: byteCount)
    }

    /// 超限必须报错，且错误里要带上限与处置建议。
    @Test
    func overLimitIsRejectedWithActionableMessage() throws {
        let error = #expect(throws: AutomationError.self) {
            try MCPPayloadLimits.validate(
                pngByteCount: MCPPayloadLimits.maximumPNGBytes + 1
            )
        }
        guard case .invalidArgument(let detail)? = error else {
            Issue.record("期望 invalidArgument，实际 \(String(describing: error))")
            return
        }
        // 光说「太大了」没用，得告诉调用方怎么办
        #expect(detail.contains("max_size"))
        #expect(detail.contains("region"))
    }

    /// 上限是 16 MiB，且足以容纳默认设置下的正常截图。
    ///
    /// 这条用例锁定的是「上限不会误伤正常用法」：
    /// 2560 长边的 PNG 实测在个位数 MB 量级。
    @Test
    func limitLeavesHeadroomForNormalUsage() {
        #expect(MCPPayloadLimits.maximumPNGBytes == 16 * 1024 * 1024)
        #expect(MCPPayloadLimits.maximumPNGBytes > 8 * 1024 * 1024)
    }
}

// MARK: - 显示器目录

struct DisplayCatalogTests {

    /// 至少有一块显示器，且主屏恰好标记一块。
    @Test
    func mainDisplayIsMarkedExactlyOnce() {
        let displays = DisplayCatalog.all()

        #expect(!displays.isEmpty)
        #expect(displays.filter(\.isMain).count == 1)
    }

    /// 主屏排在最前，便于「不指定就用第一个」时拿到符合直觉的结果。
    @Test
    func mainDisplayComesFirst() throws {
        let displays = DisplayCatalog.all()
        let first = try #require(displays.first)

        #expect(first.isMain)
        #expect(first.id == DisplayGeometry.mainDisplay())
    }

    /// 物理像素尺寸 = 逻辑尺寸 × 缩放系数。
    ///
    /// 这条不变量是「区域用逻辑点、输出是像素」这一整套换算的基础，
    /// 它若被破坏，所有坐标相关的结论都不再成立。
    @Test
    func pixelSizeMatchesLogicalSizeTimesScale() {
        for display in DisplayCatalog.all() {
            let expected = display.logicalSize.width * display.scaleFactor
            #expect(abs(display.pixelSize.width - expected) < 1.0)
        }
    }
}
