//
//  ScrollshotTickGateTests.swift
//  AnShotUITests
//
//  定时抓帧的**单飞闸门**：并发 `tick` 不得交错。
//
//  ── 为什么需要这一层测试 ──────────────────────────────────
//
//  `ScrollshotController.tick()` 在抓帧与配准期间会让出 MainActor，而驱动它的
//  `Timer` 不看这个——间隔一到就再起一个 `Task`。配准一旦慢于帧间隔，就会出现
//  两个 tick 同时在路上：抓帧顺序与 `submit` 顺序不一致，`lastObserved` /
//  `observedOffset` 被交替改写，世界坐标整体错位。
//
//  这类缺陷的症状是「长图接缝处内容跳变（断层）」，且**只在慢帧时出现**——
//  靠人工滚屏几乎不可能稳定复现，只能在这里把闸门本身钉住。
//
//  ── 如何隔离 Timer ────────────────────────────────────────
//
//  用例注入 `frameInterval: 3600`，使定时器在断言窗口内不可能触发；
//  于是「抓帧次数」的变化只可能来自本用例自己发起的两次 `tick`。
//  没有这一步，定时器的合法调用会让计数失去意义。
//

import CoreGraphics
import Foundation
import os
import Testing

@testable import AnShotCapture
@testable import AnShotCore
@testable import AnShotUI

@Suite("长截图抓帧 · 单飞闸门")
@MainActor
struct ScrollshotTickGateTests {

    // MARK: - 用例

    @Test("预取器在首帧之后失败时应结束会话，不得空转重试")
    func bufferedCaptureFailureStopsSession() async throws {
        let buffered = ScrollshotFrameCapturer(capturer: FailsAfterFirstCapture())
        let controller = ScrollshotController(
            capturer: buffered,
            selection: PixelRect(origin: PixelPoint(x: 0, y: 0), size: PixelSize(width: 120, height: 120)),
            displayID: 1, scaleFactor: 1
        )
        var result: ScrollshotController.Outcome?
        controller.onFinish = { result = $0 }
        controller.start()
        try await waitUntil { result != nil }
        let failure = result?.failure ?? ""
        #expect(failure.contains("屏幕录制权限"))
        #expect(!controller.isTicking)
    }

    @Test("首帧抓取期间取消，不得再发出就绪或进度回调")
    func cancelledInitialCaptureCannotBecomeReady() async throws {
        let capturer = GatedCapturer(delay: .milliseconds(120))
        let controller = makeController(capturer: capturer)
        var ready = false
        var progress = false
        controller.onReady = { ready = true }
        controller.onProgress = { _, _ in progress = true }
        controller.start()
        try await waitUntil { capturer.captureCount == 1 }
        controller.cancel()
        try await Task.sleep(for: .milliseconds(180))
        #expect(!ready)
        #expect(!progress)
        #expect(capturer.captureCount == 1)
    }

    @Test("并发调用 tick：第二个被闸门拦下，只抓一帧")
    func concurrentTicksRunOnlyOne() async throws {
        let capturer = GatedCapturer(delay: .milliseconds(120))
        let controller = makeController(capturer: capturer)
        controller.start()
        try await waitUntil { capturer.captureCount >= 1 }
        try await Task.sleep(for: .milliseconds(250))
        let baseline = capturer.captureCount

        // 两个 tick 同时在路上：第一个执行到 `await captureFrame` 让出，
        // 第二个进入时 `isTicking` 仍为 true，必须直接返回。
        async let first: Void = controller.tick()
        async let second: Void = controller.tick()
        _ = await (first, second)

        let captured = capturer.captureCount - baseline
        #expect(captured == 1, "并发 tick 应只抓一帧，实际抓了 \(captured) 帧")
        controller.cancel()
    }

    @Test("串行调用 tick：两次都真实执行（闸门必须能重新打开）")
    func serialTicksBothRun() async throws {
        let capturer = GatedCapturer(delay: .milliseconds(20))
        let controller = makeController(capturer: capturer)
        controller.start()
        try await waitUntil { capturer.captureCount >= 1 }
        try await Task.sleep(for: .milliseconds(250))
        let baseline = capturer.captureCount

        await controller.tick()
        await controller.tick()

        let captured = capturer.captureCount - baseline
        #expect(captured == 2, "串行 tick 应各抓一帧，实际抓了 \(captured) 帧")
        controller.cancel()
    }

    // MARK: - 夹具

    private func makeController(capturer: GatedCapturer) -> ScrollshotController {
        ScrollshotController(
            capturer: capturer,
            selection: PixelRect(
                origin: PixelPoint(x: 0, y: 0),
                size: PixelSize(width: 120, height: 120)
            ),
            displayID: 1,
            scaleFactor: 2,
            // 远大于用例时长：让 Timer 在断言窗口内不参与计数。
            frameInterval: 3600
        )
    }

    /// 轮询等待条件成立（避免依赖固定 sleep 的脆弱性）。
    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("等待条件超时")
    }
}

private actor FailsAfterFirstCapture: ScreenCapturing {
    private var count = 0
    func captureFrame(scope: CaptureScope) async throws -> CapturedFrame {
        count += 1
        if count > 1 { throw CaptureError.permissionDenied }
        let context = CGContext(data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 480,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CapturedFrame(image: context.makeImage()!, displayID: 1, scaleFactor: 1)
    }
}

// MARK: - 捕获器桩

/// 会**真实挂起**的捕获器桩：`captureFrame` 在返回前等待 `delay`，
/// 制造出「tick 在 await 处让出 MainActor」的时序，闸门缺陷才会暴露。
private final class GatedCapturer: ScreenCapturing, @unchecked Sendable {
    /// 用 `OSAllocatedUnfairLock` 而不是 `NSLock`：后者的 `lock()` / `unlock()`
    /// 在 Swift 6 下被标为 async 上下文不可用（跨 `await` 持锁就是死锁），
    /// 而这里的计数需要在 async 方法里同步、短促地改一下。
    private let counter = OSAllocatedUnfairLock(initialState: 0)
    private let delay: Duration
    private let image: CGImage

    init(delay: Duration) {
        self.delay = delay
        self.image = Self.makeImage()
    }

    /// 已发生的 `captureFrame` 调用次数（含尚未返回的）。
    var captureCount: Int {
        counter.withLock { $0 }
    }

    func captureFrame(scope: CaptureScope) async throws -> CapturedFrame {
        counter.withLock { $0 += 1 }

        try await Task.sleep(for: delay)
        return CapturedFrame(image: image, displayID: 1, scaleFactor: 2)
    }

    /// 一张有纹理的图：`ScrollshotImage` 的摊平与变化检测都需要真实像素。
    private static func makeImage() -> CGImage {
        let width = 120
        let height = 120
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1))
        // 逐行错开的方块：给变化检测提供足够差异，避免被当成「画面没变」跳过。
        for row in stride(from: 0, to: height, by: 6) {
            let inset = (row / 6) % 3 * 4
            context.fill(CGRect(x: 8 + inset, y: row, width: 40, height: 3))
        }
        return context.makeImage()!
    }
}
