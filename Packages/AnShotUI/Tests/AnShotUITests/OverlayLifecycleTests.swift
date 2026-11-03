import AppKit
import Foundation
import Testing

@testable import AnShotCapture
@testable import AnShotCore
@testable import AnShotUI

@Suite("普通截图会话隔离", .serialized)
@MainActor
struct OverlayLifecycleTests {
    @Test("取消后立即重开，迟到的旧抓帧不得清理新会话")
    func cancelledCaptureCannotTearDownNextSession() async throws {
        _ = NSApplication.shared
        let screenCount = NSScreen.screens.count
        try #require(screenCount > 0)
        let capturer = SuspendedBackdropCapturer()
        let controller = OverlayController(capturer: capturer)
        defer { controller.dismiss() }

        controller.present()
        let oldTask = try #require(controller.sessionTask)
        try await waitUntil { await capturer.pendingCount(round: 0) == screenCount }
        controller.dismiss()

        await capturer.advanceRound()
        controller.present()
        let newTask = try #require(controller.sessionTask)
        try await waitUntil { await capturer.pendingCount(round: 1) == screenCount }
        let newEditor = try #require(controller.editorState)

        // 先让新会话完成，再让不响应取消的旧 SDK 请求返回。
        await capturer.release(round: 1)
        await newTask.value
        let newWindow = try #require(controller.primaryOverlayWindow)
        await capturer.release(round: 0)
        await oldTask.value

        #expect(controller.isPresenting)
        let keepsWindow = controller.primaryOverlayWindow === newWindow
        let keepsEditor = controller.editorState === newEditor
        #expect(keepsWindow)
        #expect(keepsEditor)
        #expect(newWindow.isVisible)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw WaitError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum WaitError: Error { case timedOut }
}

private actor SuspendedBackdropCapturer: ScreenCapturing {
    private struct Request {
        let displayID: CGDirectDisplayID
        let continuation: CheckedContinuation<CapturedFrame, Never>
    }

    private var round = 0
    private var pending: [Int: [Request]] = [:]

    func advanceRound() { round += 1 }
    func pendingCount(round: Int) -> Int { pending[round, default: []].count }

    func captureFrame(scope: CaptureScope) async throws -> CapturedFrame {
        guard case .display(let displayID) = scope else { throw CaptureError.scopeUnavailable }
        return await withCheckedContinuation { continuation in
            pending[round, default: []].append(Request(displayID: displayID, continuation: continuation))
        }
    }

    func release(round: Int) {
        let requests = pending.removeValue(forKey: round) ?? []
        for request in requests {
            let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                    bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            request.continuation.resume(returning: CapturedFrame(
                image: context.makeImage()!, displayID: request.displayID, scaleFactor: 1
            ))
        }
    }
}
