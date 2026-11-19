//
//  Phase4ScrollshotUXTests.swift
//  AnShotUITests
//
//  Phase 4 专项单元测试：
//    - 会话级 Carbon 瞬态热键 `TransientHotKeySet` 注册、精准分发与 `invalidateAll()` 清理；
//    - `ScrollshotProgressBar` 42pt 药丸主控制栏、浅/深色跟随系统、避让 Dock 与侧边预览卡定位、
//      折叠/展开与穿透切换、无权限内联状态及实时宽高显示；
//    - `AppSettings` 自动翻页开关与速度持久化；
//    - `ScrollshotController` 首帧静默兜底、完成出口传递与 `⌘Z` 分段撤销回退。
//

import AppKit
import CoreGraphics
import Foundation
import os
import Testing

@testable import AnShotCapture
@testable import AnShotCore
@testable import AnShotUI

@Suite("Phase 4 · 长截图瞬态热键、控制栏与撤销闭环", .serialized)
@MainActor
struct Phase4ScrollshotUXTests {

    private func makeTestSettings() -> AppSettings {
        let suiteName = "com.anshot.tests.phase4.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(store: defaults)
    }

    // MARK: - 1. Carbon 瞬态热键集合

    @Test("TransientHotKeySet 注册 8 个默认瞬态键位，精准分发且 invalidateAll 后完全失效")
    func transientHotKeySetRegistersDispatchesAndInvalidates() {
        var triggered: [TransientScrollshotKey] = []
        let hotKeys = TransientHotKeySet(installSystemHooks: false) { key in
            triggered.append(key)
        }

        #expect(hotKeys.registeredKeys == Set(TransientScrollshotKey.allCases))
        #expect(hotKeys.registeredKeys.count == 8)

        hotKeys.dispatchForTesting(.space)
        hotKeys.dispatchForTesting(.commandZ)
        hotKeys.dispatchForTesting(.shiftCommandS)
        hotKeys.dispatchForTesting(.escape)
        #expect(triggered == [.space, .commandZ, .shiftCommandS, .escape])

        hotKeys.invalidateAll()
        #expect(hotKeys.registeredKeys.isEmpty)

        // 反注册后再派发不得再次触发回调
        hotKeys.dispatchForTesting(.returnKey)
        hotKeys.dispatchForTesting(.commandC)
        #expect(triggered == [.space, .commandZ, .shiftCommandS, .escape])
    }

    // MARK: - 2. 轻量 42pt 药丸主控制栏与独立侧边预览卡

    @Test("主控制栏严格维持 42pt 高度并跟随系统浅/深主题，支持折叠与鼠标穿透切换")
    func progressBarContractAndPreviewToggles() {
        let bar = ScrollshotProgressBar()
        defer { bar.hide() }

        #expect(bar.controlBarHeightForTesting == ScrollshotProgressBar.controlBarHeight)
        #expect(ScrollshotProgressBar.controlBarHeight == 42)

        let selection = CGRect(x: 200, y: 240, width: 520, height: 420)
        bar.show(near: selection)
        #expect(bar.isVisible)
        #expect(bar.isPreviewVisible)
        #expect(bar.isPreviewCardWindowVisibleForTesting)
        #expect(!bar.isPreviewCardClickThroughForTesting)

        // 切换鼠标穿透
        bar.setPreviewClickThrough(true)
        #expect(bar.isPreviewClickThrough)
        #expect(bar.isPreviewCardClickThroughForTesting)

        // 折叠预览卡
        bar.setPreviewVisible(false)
        #expect(!bar.isPreviewVisible)
        #expect(!bar.isPreviewCardWindowVisibleForTesting)

        // 重新展开预览卡时自动退出穿透，确保用户可直接拖动预览定位框
        bar.setPreviewVisible(true)
        #expect(bar.isPreviewVisible)
        #expect(bar.isPreviewCardWindowVisibleForTesting)
        #expect(!bar.isPreviewCardClickThroughForTesting)

        // 切换无权限与触底态后控制栏高度仍稳定在 42pt
        bar.updateAutoScrollState(.needsAccessibilityPermission, speed: .slow)
        #expect(bar.controlBarHeightForTesting == 42)
        #expect(bar.guideTextForDiagnostics == ScrollshotProgressBar.guideNeedsAccessibility)

        bar.updateAutoScrollState(.reachedBottom, speed: .fast)
        #expect(bar.controlBarHeightForTesting == 42)
        #expect(bar.guideTextForDiagnostics == ScrollshotProgressBar.guideReachedBottom)
    }

    @Test("主控制栏与侧边预览卡定位避让 Dock 且绝不重叠常规选区")
    func progressBarAndPreviewCardPlacementAvoidDockAndSelection() {
        // 模拟底部存在 68pt Dock 的屏幕可见区
        let visible = CGRect(x: 0, y: 68, width: 1440, height: 807)
        let barSize = CGSize(width: 660, height: 42)
        let cardSize = ScrollshotProgressBar.previewCardSize

        // 1. 选区位于屏幕中部：控制栏落选区下方居中，预览卡落选区右侧，两者均不盖选区
        let midSelection = CGRect(x: 260, y: 260, width: 520, height: 400)
        let barBelow = ScrollshotProgressBar.preferredControlBarFrame(
            near: midSelection,
            barSize: barSize,
            visibleFrame: visible
        )
        #expect(barBelow.maxY <= midSelection.minY)
        #expect(barBelow.minY >= visible.minY)
        #expect(!barBelow.intersects(midSelection))

        let cardRight = ScrollshotProgressBar.preferredPreviewCardFrame(
            near: midSelection,
            cardSize: cardSize,
            visibleFrame: visible
        )
        #expect(cardRight.minX >= midSelection.maxX)
        #expect(!cardRight.intersects(midSelection))

        // 2. 选区贴近 Dock 底部：控制栏下方放不下时自动翻到选区上方，严禁落入 Dock 区
        let bottomSelection = CGRect(x: 300, y: 76, width: 520, height: 320)
        let barAbove = ScrollshotProgressBar.preferredControlBarFrame(
            near: bottomSelection,
            barSize: barSize,
            visibleFrame: visible
        )
        #expect(barAbove.minY >= bottomSelection.maxY)
        #expect(barAbove.minY >= visible.minY)
        #expect(!barAbove.intersects(bottomSelection))

        // 3. 选区靠右缘：右侧放不下 300pt 预览卡时自动翻到左侧，不盖选区
        let rightSelection = CGRect(x: 960, y: 260, width: 440, height: 380)
        let cardLeft = ScrollshotProgressBar.preferredPreviewCardFrame(
            near: rightSelection,
            cardSize: cardSize,
            visibleFrame: visible
        )
        #expect(cardLeft.maxX <= rightSelection.minX)
        #expect(!cardLeft.intersects(rightSelection))
    }

    // MARK: - 3. AppSettings 自动翻页持久化

    @Test("AppSettings 正确读写自动翻页开关与速度档位默认值")
    func appSettingsPersistsAutoScrollPreferences() {
        let suiteName = "com.anshot.tests.phase4.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = AppSettings(store: defaults)
        #expect(settings.longshotAutoScrollEnabled == true)
        #expect(settings.longshotAutoScrollSpeed == .normal)

        settings.setLongshotAutoScrollEnabled(false)
        settings.setLongshotAutoScrollSpeed(.fast)

        let reloaded = AppSettings(store: defaults)
        #expect(reloaded.longshotAutoScrollEnabled == false)
        #expect(reloaded.longshotAutoScrollSpeed == .fast)
    }

    // MARK: - 4. ScrollshotController 首帧兜底与分段撤销

    @Test("ScrollshotController 仅抓首帧直接完成时静默输出首帧并保留 FinishMode")
    func controllerSingleFrameFallbackPreservesFinishMode() async throws {
        let page = makeTexturedPage(width: 220, height: 600)
        let first = sliceVertical(page, offset: 0, height: 140)
        let capturer = Phase4SequenceCapturer(frames: [makeCGImage(first)])

        let controller = ScrollshotController(
            capturer: capturer,
            selection: PixelRect(origin: PixelPoint(x: 0, y: 0), size: PixelSize(width: 220, height: 140)),
            displayID: 1,
            scaleFactor: 1,
            frameInterval: 3600
        )

        var outcome: ScrollshotController.Outcome?
        controller.onFinish = { outcome = $0 }

        controller.start()
        try await waitUntil { capturer.captureCount >= 1 }
        try await Task.sleep(for: .milliseconds(80))

        await controller.finish(mode: .copy)

        let resolved = try #require(outcome)
        #expect(resolved.failure == nil)
        #expect(resolved.finishMode == .copy)
        let image = try #require(resolved.image)
        #expect(image.width == 220)
        #expect(image.height == 140)
    }

    @Test("ScrollshotController 采纳第二段后支持 undoLastSegment 回退像素高度")
    func controllerUndoLastSegmentRollsBackHeight() async throws {
        let page = makeTexturedPage(width: 240, height: 800)
        let viewportHeight = 140
        let step = 60
        let frames = [0, step, step * 2].map { sliceVertical(page, offset: $0, height: viewportHeight) }
        let capturer = Phase4SequenceCapturer(frames: frames.map(makeCGImage))

        let controller = ScrollshotController(
            capturer: capturer,
            selection: PixelRect(
                origin: PixelPoint(x: 0, y: 0),
                size: PixelSize(width: 240, height: Double(viewportHeight))
            ),
            displayID: 1,
            scaleFactor: 1,
            options: ScrollStitcher.Options(
                unusableTopRows: 0,
                unusableBottomRows: 0,
                allowsSingleFrameFallback: true
            ),
            frameInterval: 3600
        )

        controller.start()
        try await waitUntil { capturer.captureCount >= 1 }
        try await Task.sleep(for: .milliseconds(80))
        #expect(!controller.canUndoSegment)
        let initialHeight = controller.currentOutputPixelSize.height

        await controller.tick()
        #expect(controller.canUndoSegment)
        let heightAfterSecond = controller.currentOutputPixelSize.height
        #expect(heightAfterSecond == initialHeight + step)

        await controller.tick()
        let heightAfterThird = controller.currentOutputPixelSize.height
        #expect(heightAfterThird == initialHeight + step * 2)

        let undoneOnce = await controller.undoLastSegment()
        #expect(undoneOnce)
        #expect(controller.currentOutputPixelSize.height == heightAfterSecond)
        #expect(controller.canUndoSegment)

        let undoneTwice = await controller.undoLastSegment()
        #expect(undoneTwice)
        #expect(controller.currentOutputPixelSize.height == initialHeight)
        #expect(!controller.canUndoSegment)

        controller.cancel()
    }

    // MARK: - 辅助夹具

    private func makeTexturedPage(width: Int, height: Int) -> ScrollshotImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let rowHash = UInt64(y) &* 2_654_435_761
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let pattern = UInt8(((rowHash >> ((x % 16) * 2)) ^ UInt64(x &* 13 + y &* 7)) & 0xFF)
                bytes[offset] = pattern
                bytes[offset + 1] = UInt8((Int(pattern) &+ (y * 3)) & 0xFF)
                bytes[offset + 2] = UInt8((Int(pattern) &+ (x * 5)) & 0xFF)
                bytes[offset + 3] = 255
            }
        }
        return ScrollshotImage(width: width, height: height, data: bytes)!
    }

    private func sliceVertical(_ page: ScrollshotImage, offset: Int, height: Int) -> ScrollshotImage {
        let rowBytes = page.width * 4
        let start = offset * rowBytes
        let end = (offset + height) * rowBytes
        return ScrollshotImage(width: page.width, height: height, data: Array(page.data[start..<end]))!
    }

    private func makeCGImage(_ image: ScrollshotImage) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var buffer = image.data
        return buffer.withUnsafeMutableBytes { raw -> CGImage in
            let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return context.makeImage()!
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("等待条件超时")
                return
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
}

/// Phase 4 专用帧序列桩（线程安全计数）。
private final class Phase4SequenceCapturer: ScreenCapturing, @unchecked Sendable {
    private let frames: [CGImage]
    private let state = OSAllocatedUnfairLock(initialState: 0)

    var captureCount: Int {
        state.withLock { $0 }
    }

    init(frames: [CGImage]) {
        self.frames = frames
    }

    func captureFrame(scope: CaptureScope) async throws -> CapturedFrame {
        let index = state.withLock { count -> Int in
            let current = count
            count += 1
            return min(current, frames.count - 1)
        }
        return CapturedFrame(image: frames[index], displayID: 1, scaleFactor: 1)
    }
}
