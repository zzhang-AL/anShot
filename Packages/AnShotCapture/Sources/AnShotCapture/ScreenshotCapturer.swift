//
//  ScreenshotCapturer.swift
//  AnShotCapture
//
//  macOS 14.0+ 的单帧捕获实现，基于 SCScreenshotManager。
//
//  它是 Apple 为「截一张图」设计的专用 API，不需要建立持续流，
//  因此没有 SCStream 的启停成本与帧队列驻留。
//  两个实现（本文件与 `StreamCapturer`）共用 `CaptureSetup` 的
//  过滤器与配置构造，保证抓出的图在尺寸与坐标上完全一致。
//

import AnShotCore
import CoreGraphics
import Foundation
import ScreenCaptureKit

private let screenshotLogger = AnShotLog.capture
@available(macOS 14.0, *)
public struct ScreenshotCapturer: ScreenCapturing {

    public init() {}

    public func captureFrame(scope: CaptureScope) async throws -> CapturedFrame {
        let t0 = Date()

        try CaptureSetup.requirePermission()

        let target = try CaptureSetup.resolveSingleFrameTarget(scope)

        let t1 = Date()
        let content = try await CaptureSetup.fetchShareableContent(for: target)
        let t2 = Date()

        // 构造（过滤器 / 配置 / 归属元数据）与另一实现共用同一份代码：
        // 两个实现各自成型会让「同一个请求在 13 与 14 上产出不同尺寸的图」
        // 这类缺陷只在旧系统暴露，而开发机看不到。
        let setup = try CaptureSetup.makeSingleFrameSetup(
            target: target,
            scope: scope,
            content: content,
            showsCursor: false
        )

        let t3 = Date()

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: setup.filter,
                configuration: setup.configuration
            )
            let t4 = Date()

            screenshotLogger.notice("""
                screenshot timing: setup=\(Self.ms(t1.timeIntervalSince(t0)), privacy: .public)ms \
                shareableContent=\(Self.ms(t2.timeIntervalSince(t1)), privacy: .public)ms \
                filter+config=\(Self.ms(t3.timeIntervalSince(t2)), privacy: .public)ms \
                capture=\(Self.ms(t4.timeIntervalSince(t3)), privacy: .public)ms \
                total=\(Self.ms(t4.timeIntervalSince(t0)), privacy: .public)ms
                """)

            return CapturedFrame(
                image: image,
                displayID: setup.displayID,
                scaleFactor: setup.scaleFactor,
                window: setup.windowInfo
            )
        } catch {
            throw CaptureSetup.mapError(error)
        }
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds * 1000)
    }
}
