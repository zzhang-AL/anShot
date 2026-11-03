import CoreGraphics
import Foundation
import Testing
@testable import AnShotCapture

@Suite("长截图 · 有界预取")
struct ScrollshotFrameCapturerTests {
    @Test("消费者暂停时仍采集中间帧，队列有界且交付顺序不变")
    func preservesIntermediateFrames() async throws {
        let source = NumberedCapturer()
        let capturer = ScrollshotFrameCapturer(capturer: source, interval: .milliseconds(2), capacity: 3)
        let first = try await capturer.captureFrame(scope: .display(1))
        #expect(first.displayID == 1)
        let deadline = ContinuousClock.now + .seconds(3)
        while await source.count < 8, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let count = await source.count
        #expect(count >= 8, "未读取下一帧时，生产者也必须继续运行")
        let pending = await capturer.stopAndDrain()
        let identifiers = pending.map(\.displayID)
        #expect(identifiers == [2, 3, 4])
        #expect(await capturer.peakBufferedFrames == 3)
        #expect(await capturer.droppedFrames > 0)
        try await Task.sleep(for: .milliseconds(20))
        let stoppedCount = await source.count
        try await Task.sleep(for: .milliseconds(20))
        #expect(await source.count == stoppedCount)
    }

    @Test("底层抓帧失败会唤醒等待者，而不是永久等待")
    func forwardsCaptureFailure() async {
        let capturer = ScrollshotFrameCapturer(capturer: FailingCapturer())
        do {
            _ = try await capturer.captureFrame(scope: .display(1))
            Issue.record("预期捕获权限失败")
        } catch CaptureError.permissionDenied {
            // 正常传播具体错误，不能把等待者留在队列中。
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
        let pending = await capturer.stopAndDrain()
        #expect(pending.isEmpty)
    }
}

private actor NumberedCapturer: ScreenCapturing {
    private(set) var count = 0
    func captureFrame(scope: CaptureScope) async throws -> CapturedFrame {
        count += 1
        let identifier = count
        try await Task.sleep(for: .milliseconds(1))
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CapturedFrame(image: context.makeImage()!, displayID: CGDirectDisplayID(identifier), scaleFactor: 1)
    }
}

private struct FailingCapturer: ScreenCapturing {
    func captureFrame(scope: CaptureScope) async throws -> CapturedFrame { throw CaptureError.permissionDenied }
}
