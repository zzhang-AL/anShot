//
//  FirstFrameCollectorTests.swift
//  AnShotCaptureTests
//

import CoreGraphics
import Foundation
import Testing
@testable import AnShotCapture

@Suite("单帧捕获首帧等待")
struct FirstFrameCollectorTests {

    @Test("没有帧时超时返回，不会永久等待 continuation")
    func timeoutReturns() async {
        let collector = FirstFrameCollector()
        do {
            _ = try await collector.waitForFirstFrame(timeout: 0.05)
            Issue.record("没有帧时应超时")
        } catch CaptureError.timedOut {
            // 预期结果。
        } catch {
            Issue.record("应报告首帧超时，实际为 \(error)")
        }
    }

    @Test("首帧早于等待开始时仍能返回")
    func earlyFrameIsRetained() async throws {
        let context = try #require(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let collector = FirstFrameCollector()
        collector.finish(with: .success(image))

        let captured = try await collector.waitForFirstFrame(timeout: 0.1)
        #expect(captured.width == 2)
        #expect(captured.height == 2)
    }
}
