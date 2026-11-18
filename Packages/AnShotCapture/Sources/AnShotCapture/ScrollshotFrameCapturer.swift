import AnShotCore
import CoreGraphics
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

/// 长截图专用的有界预取。
///
/// 当底层是系统截图实现时，改用单条持续 `SCStream` 推帧（仅启动时查一次
/// `SCShareableContent`，避免每秒 30 次跨进程枚举与 `.notice` 日志刷屏）；
/// 当底层是测试注入的自定义 `ScreenCapturing` 时，保留轮询生产路径。
public actor ScrollshotFrameCapturer: ScreenCapturing {
    private let underlying: any ScreenCapturing
    private let interval: Duration
    private let capacity: Int
    private var scope: CaptureScope?
    private var frames: [CapturedFrame] = []
    private var waiter: (id: UUID, continuation: CheckedContinuation<CapturedFrame, any Error>)?
    private var producer: Task<Void, Never>?
    private var streamRelay: ScrollshotStreamRelay?
    private var hasStarted = false
    private var stopped = false
    private var failure: (any Error)?
    public private(set) var droppedFrames = 0
    public private(set) var peakBufferedFrames = 0

    public init(
        capturer: any ScreenCapturing = CapturerFactory.makeDefault(),
        interval: Duration = .seconds(1.0 / 30),
        capacity: Int = 8
    ) {
        underlying = capturer
        self.interval = interval
        self.capacity = max(1, capacity)
    }

    public func captureFrame(scope requestedScope: CaptureScope) async throws -> CapturedFrame {
        try Task.checkCancellation()
        guard !stopped else { throw failure ?? CancellationError() }
        if let scope, scope != requestedScope {
            throw CaptureError.unsupportedScope("长截图采集期间选区不能改变")
        }
        if !hasStarted {
            hasStarted = true
            scope = requestedScope
            startBackend(scope: requestedScope)
        }
        if !frames.isEmpty {
            return frames.removeFirst()
        }
        guard waiter == nil else {
            throw CaptureError.underlying("长截图帧必须按顺序读取")
        }

        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if stopped {
                    continuation.resume(throwing: failure ?? CancellationError())
                    return
                }
                if !frames.isEmpty {
                    continuation.resume(returning: frames.removeFirst())
                    return
                }
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiter = (id: token, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: token) }
        }
    }

    /// 根据后端类型选择持续流模式或兼容轮询模式。
    private func startBackend(scope: CaptureScope) {
        if Self.shouldUseContinuousStream(for: underlying) {
            producer = Task { [weak self] in
                await self?.produceWithContinuousStream(scope: scope)
            }
        } else {
            producer = Task { [weak self] in
                await self?.produceByPolling(scope: scope)
            }
        }
    }

    private static func shouldUseContinuousStream(for capturer: any ScreenCapturing) -> Bool {
        if capturer is StreamCapturer {
            return true
        }
        if #available(macOS 14.0, *), capturer is ScreenshotCapturer {
            return true
        }
        return false
    }

    // MARK: - 持续 SCStream 生产

    private func produceWithContinuousStream(scope: CaptureScope) async {
        defer {
            streamRelay?.stop()
            streamRelay = nil
            finishProducerIfNeeded()
        }

        do {
            try CaptureSetup.requirePermission()
            let target = try CaptureSetup.resolveSingleFrameTarget(scope)
            let content = try await CaptureSetup.fetchShareableContent(for: target)
            guard !stopped, !Task.isCancelled else { return }

            let setup = try CaptureSetup.makeSingleFrameSetup(
                target: target,
                scope: scope,
                content: content,
                showsCursor: false
            )

            let streamConfig = setup.configuration
            streamConfig.queueDepth = 3
            let seconds = max(1.0 / 120.0, Self.seconds(from: interval))
            streamConfig.minimumFrameInterval = CMTime(seconds: seconds, preferredTimescale: 600)

            let (eventStream, continuation) = AsyncStream<Result<CapturedFrame, Error>>.makeStream(
                bufferingPolicy: .bufferingNewest(max(capacity, 8))
            )
            let relay = ScrollshotStreamRelay(
                displayID: setup.displayID,
                scaleFactor: setup.scaleFactor,
                windowInfo: setup.windowInfo,
                continuation: continuation
            )
            let stream = SCStream(filter: setup.filter, configuration: streamConfig, delegate: relay)
            let outputQueue = DispatchQueue(label: "com.anshot.capture.scrollshot-stream")
            try stream.addStreamOutput(relay, type: .screen, sampleHandlerQueue: outputQueue)

            guard !stopped, !Task.isCancelled else { return }
            relay.attach(stream: stream)
            streamRelay = relay

            try await relay.startCapture()
            guard !stopped, !Task.isCancelled else { return }

            for await event in eventStream {
                guard !stopped, !Task.isCancelled else { break }
                switch event {
                case .success(let frame):
                    acceptProducedFrame(frame)
                case .failure(let error):
                    failProducer(with: error)
                    return
                }
            }
        } catch {
            guard !stopped else { return }
            let mapped = CaptureSetup.mapError(error)
            if !(error is CancellationError) {
                AnShotLog.capture.error("scrollshot stream failed: \(mapped.localizedDescription, privacy: .public)")
            }
            failProducer(with: mapped)
        }
    }

    // MARK: - 轮询生产（兼容注入捕获器）

    private func produceByPolling(scope: CaptureScope) async {
        defer {
            finishProducerIfNeeded()
        }

        while !stopped, !Task.isCancelled {
            let began = ContinuousClock.now
            do {
                let frame = try await underlying.captureFrame(scope: scope)
                guard !stopped, !Task.isCancelled else { return }
                acceptProducedFrame(frame)
                let remaining = interval - began.duration(to: .now)
                if remaining > .zero {
                    try await Task.sleep(for: remaining)
                }
            } catch {
                guard !stopped else { return }
                if !(error is CancellationError) {
                    AnShotLog.capture.error("scrollshot capture failed: \(error.localizedDescription, privacy: .public)")
                }
                failProducer(with: error)
                return
            }
        }
    }

    // MARK: - 帧分发与清理

    private func acceptProducedFrame(_ frame: CapturedFrame) {
        if let currentWaiter = waiter {
            waiter = nil
            currentWaiter.continuation.resume(returning: frame)
        } else if frames.count < capacity {
            frames.append(frame)
            peakBufferedFrames = max(peakBufferedFrames, frames.count)
        } else {
            // 保留队列中的连续旧帧，不能静默用最新画面覆盖尚未匹配的中间帧。
            droppedFrames += 1
        }
    }

    private func failProducer(with error: Error) {
        failure = error
        stopped = true
        if let currentWaiter = waiter {
            waiter = nil
            currentWaiter.continuation.resume(throwing: error)
        }
    }

    private func finishProducerIfNeeded() {
        if let currentWaiter = waiter {
            waiter = nil
            currentWaiter.continuation.resume(throwing: failure ?? CancellationError())
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let currentWaiter = waiter, currentWaiter.id == id else { return }
        waiter = nil
        currentWaiter.continuation.resume(throwing: CancellationError())
    }

    /// 收尾时取走已拍摄但尚未匹配的帧，释放缓冲并唤醒等待者。
    public func stopAndDrain() -> [CapturedFrame] {
        stopped = true
        producer?.cancel()
        producer = nil
        streamRelay?.stop()
        streamRelay = nil
        if let currentWaiter = waiter {
            waiter = nil
            currentWaiter.continuation.resume(throwing: failure ?? CancellationError())
        }
        let pending = frames
        frames.removeAll()
        return pending
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

/// 将持续 `SCStream` 回调桥接到 `AsyncStream` 并统一托管流启停生命周期。
private final class ScrollshotStreamRelay: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let scaleFactor: CGFloat
    private let windowInfo: WindowCaptureInfo?
    private let lock = NSLock()
    private var continuation: AsyncStream<Result<CapturedFrame, Error>>.Continuation?
    private var stream: SCStream?

    init(
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat,
        windowInfo: WindowCaptureInfo?,
        continuation: AsyncStream<Result<CapturedFrame, Error>>.Continuation
    ) {
        self.displayID = displayID
        self.scaleFactor = scaleFactor
        self.windowInfo = windowInfo
        self.continuation = continuation
    }

    func attach(stream: SCStream) {
        lock.withLock { self.stream = stream }
    }

    func startCapture() async throws {
        let currentStream = lock.withLock { stream }
        guard let currentStream else { return }
        try await currentStream.startCapture()
    }

    func stop() {
        let (cont, streamToStop) = lock.withLock { () -> (AsyncStream<Result<CapturedFrame, Error>>.Continuation?, SCStream?) in
            let c = continuation
            continuation = nil
            let s = stream
            stream = nil
            return (c, s)
        }
        cont?.finish()
        if let streamToStop {
            Task { try? await streamToStop.stopCapture() }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        guard CaptureSetup.isCompleteFrame(sampleBuffer) else { return }
        guard let image = StreamCapturer.makeImage(from: sampleBuffer) else { return }
        let frame = CapturedFrame(
            image: image,
            displayID: displayID,
            scaleFactor: scaleFactor,
            window: windowInfo
        )
        let cont = lock.withLock { continuation }
        cont?.yield(.success(frame))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let cont = lock.withLock { () -> AsyncStream<Result<CapturedFrame, Error>>.Continuation? in
            let c = continuation
            continuation = nil
            return c
        }
        cont?.yield(.failure(CaptureSetup.mapError(error)))
        cont?.finish()
    }
}
