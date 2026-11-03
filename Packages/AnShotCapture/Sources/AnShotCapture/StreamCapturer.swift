//
//  StreamCapturer.swift
//  AnShotCapture
//
//  macOS 13.0 的单帧捕获实现，基于 SCStream 抓首帧。
//
//  ── 为何 13.0 需要它 ─────────────────────────────────────────
//
//  SCScreenshotManager 是 macOS 14.0+，13.0 上拿不到，只能走连续流 API。
//  这条路径即用户批准的「双实现」方案中的基线实现（见 plan.md §3.1 选项 C）。
//
//  与 `ScreenshotCapturer` 共用 `CaptureSetup` 的过滤器与配置构造，
//  确保两个实现抓出的图在尺寸与坐标上完全一致。
//
//  ── 复杂度所在 ───────────────────────────────────────────────
//
//  SCStream 是为「持续产出帧」设计的，抓单帧需要在它之上补出
//  「启动 → 等首帧 → 停止」的完整生命周期，且必须保证：
//
//    1. 只完成一次（continuation 不得重复 resume）
//    2. 超时可终止（流启动失败或屏幕无变化时不能永久挂起）
//    3. 无论成功失败都要停止并释放流
//    4. 只接受「完整帧」——SCStream 首批回调可能给出不完整的帧内容
//
//  第 4 点尤为重要：直接取第一个回调的 sampleBuffer 可能拿到内容不完整的图，
//  必须检查帧状态附件是否为 `.complete`。
//

import AnShotCore
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

private let streamLogger = AnShotLog.capture
public struct StreamCapturer: ScreenCapturing {

    /// 等待首帧的超时时间（秒）。
    ///
    /// 默认 3 秒：正常情况首帧在数百毫秒内到达，超时意味着流启动异常或屏幕长时间无变化。
    private let timeout: TimeInterval

    /// 复用的 CIContext。CIContext 构造开销大且线程安全，不应每次捕获都新建。
    // `CIContext` 本身是线程安全的，但 CoreImage 在旧 SDK 上没有为它声明
    // `Sendable`；Xcode 16 的严格并发检查会把 static 存储判成数据竞争。
    // 这里明确承担「跨线程共享」的语义，而不是每帧新建一个昂贵上下文。
    //
    // 新 SDK 已把 `CIContext` 标成 Sendable，此时再加 `nonisolated(unsafe)`
    // 会反过来被诊断为「不必要」。按编译器版本二选一，两个工具链都零告警。
    #if swift(>=6.2)
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    #else
    private nonisolated(unsafe) static let ciContext = CIContext(
        options: [.useSoftwareRenderer: false]
    )
    #endif

    public init(timeout: TimeInterval = 3.0) {
        self.timeout = timeout
    }

    public func captureFrame(scope: CaptureScope) async throws -> CapturedFrame {
        let t0 = Date()

        try CaptureSetup.requirePermission()

        let target = try CaptureSetup.resolveSingleFrameTarget(scope)

        let t1 = Date()
        let content = try await CaptureSetup.fetchShareableContent(for: target)
        let t2 = Date()

        // 与 `ScreenshotCapturer` 共用同一份构造：两个实现若各自成型，
        // 「同一个请求在 13 与 14 上产出不同尺寸的图」这类缺陷只在旧系统暴露。
        let setup = try CaptureSetup.makeSingleFrameSetup(
            target: target,
            scope: scope,
            content: content,
            showsCursor: false
        )

        let image = try await captureFirstFrame(
            filter: setup.filter,
            configuration: setup.configuration
        )
        let t3 = Date()

        streamLogger.notice("""
            stream timing: setup=\(Self.ms(t1.timeIntervalSince(t0)), privacy: .public)ms \
            shareableContent=\(Self.ms(t2.timeIntervalSince(t1)), privacy: .public)ms \
            streamLifecycle=\(Self.ms(t3.timeIntervalSince(t2)), privacy: .public)ms \
            total=\(Self.ms(t3.timeIntervalSince(t0)), privacy: .public)ms
            """)

        return CapturedFrame(
            image: image,
            displayID: setup.displayID,
            scaleFactor: setup.scaleFactor,
            window: setup.windowInfo
        )
    }

    // MARK: - 流生命周期

    /// 建立流、取首帧、停止流。
    ///
    /// 生命周期严格闭环：任何路径（成功、超时、错误）都会停止流，
    /// 且 continuation 恰好被 resume 一次。
    private func captureFirstFrame(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        let collector = FirstFrameCollector()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let outputQueue = DispatchQueue(label: "com.anshot.capture.stream-output")

        do {
            try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: outputQueue)
        } catch {
            throw CaptureSetup.mapError(error)
        }

        do {
            try await stream.startCapture()
        } catch {
            throw CaptureSetup.mapError(error)
        }

        do {
            let image = try await collector.waitForFirstFrame(timeout: timeout)

            // 先停止流再处理数据：停止是异步的，尽早发起以减少占用
            do {
                try await stream.stopCapture()
            } catch {
                // 停止失败不覆盖已取得的帧，仅记录
                streamLogger.error("stopCapture failed: \(String(describing: error), privacy: .public)")
            }

            return image

        } catch {
            // 失败路径：先让悬挂的 continuation 归位，再停流
            collector.cancel()
            do {
                try await stream.stopCapture()
            } catch {
                streamLogger.error("stopCapture failed during cleanup: \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    /// 从 sampleBuffer 取出图像。
    ///
    /// 在回调内立即调用：`CMSampleBuffer` 不能跳并发域传递
    /// （它在 macOS 上不满足 `Sendable`），因此帧一到达就转成 `CGImage`，
    /// 只让 `CGImage` 进入等待方。
    fileprivate static func makeImage(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds * 1000)
    }
}

// MARK: - 首帧收集

/// 收集流输出的第一个**完整**帧。
///
/// 线程模型：`SCStreamOutput` 的回调在 `outputQueue` 上发生，
/// 而等待方在 Swift 并发域上，故用锁保护共享状态。
final class FirstFrameCollector: NSObject, SCStreamOutput, @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var result: Result<CGImage, Error>?

    /// 等待首帧，超时抛 `CaptureError.timedOut`。
    func waitForFirstFrame(timeout: TimeInterval) async throws -> CGImage {
        try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask { [self] in
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        lock.lock()
                        if let result {
                            // 首帧可能早于 startCapture 返回，必须保留它。
                            lock.unlock()
                            continuation.resume(with: result)
                            return
                        }
                        if Task.isCancelled {
                            lock.unlock()
                            continuation.resume(throwing: CaptureError.timedOut)
                            return
                        }
                        self.continuation = continuation
                        lock.unlock()
                    }
                } onCancel: {
                    // 超时分支取消本任务时必须恢复 continuation，任务组才能退出。
                    self.cancel()
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CaptureError.timedOut
            }

            defer { group.cancelAll() }

            guard let first = try await group.next() else {
                throw CaptureError.timedOut
            }
            return first
        }
    }

    /// 主动结束等待。用于超时或错误路径，确保没有悬挂的 continuation。
    func cancel() {
        finish(with: .failure(CaptureError.timedOut))
    }

    // MARK: SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        // 只接受完整帧：首批回调可能给出内容不完整的帧
        guard CaptureSetup.isCompleteFrame(sampleBuffer) else { return }
        // 立即转成 CGImage——CMSampleBuffer 不能跳并发域
        guard let image = StreamCapturer.makeImage(from: sampleBuffer) else { return }
        finish(with: .success(image))
    }

    // MARK: 内部

    func finish(with result: Result<CGImage, Error>) {
        lock.lock()
        guard self.result == nil else {
            // exactly-once：重复回调是正常的（流在停止前可能继续产帧）
            lock.unlock()
            return
        }
        self.result = result
        let pending = continuation
        continuation = nil
        lock.unlock()

        pending?.resume(with: result)
    }
}
