import AnShotCore
import Foundation

/// 长截图专用的有界预取。采集独立于主线程上的配准，按拍摄顺序交付中间帧。
public actor ScrollshotFrameCapturer: ScreenCapturing {
    private let underlying: any ScreenCapturing
    private let interval: Duration
    private let capacity: Int
    private var scope: CaptureScope?
    private var frames: [CapturedFrame] = []
    private var waiter: CheckedContinuation<CapturedFrame, any Error>?
    private var producer: Task<Void, Never>?
    private var stopped = false
    private var failure: (any Error)?
    public private(set) var droppedFrames = 0
    public private(set) var peakBufferedFrames = 0

    public init(capturer: any ScreenCapturing, interval: Duration = .seconds(1.0 / 30), capacity: Int = 8) {
        underlying = capturer
        self.interval = interval
        self.capacity = max(1, capacity)
    }

    public func captureFrame(scope requestedScope: CaptureScope) async throws -> CapturedFrame {
        guard !stopped else { throw failure ?? CancellationError() }
        if let scope, scope != requestedScope { throw CaptureError.unsupportedScope("长截图采集期间选区不能改变") }
        if producer == nil {
            scope = requestedScope
            producer = Task { [weak self] in await self?.produce(scope: requestedScope) }
        }
        if !frames.isEmpty { return frames.removeFirst() }
        guard waiter == nil else { throw CaptureError.underlying("长截图帧必须按顺序读取") }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    private func produce(scope: CaptureScope) async {
        while !stopped, !Task.isCancelled {
            let began = ContinuousClock.now
            do {
                let frame = try await underlying.captureFrame(scope: scope)
                guard !stopped, !Task.isCancelled else { return }
                if let waiter {
                    self.waiter = nil
                    waiter.resume(returning: frame)
                } else if frames.count < capacity {
                    frames.append(frame)
                    peakBufferedFrames = max(peakBufferedFrames, frames.count)
                } else {
                    // 保留队列中的连续旧帧，不能静默用最新画面覆盖尚未匹配的中间帧。
                    droppedFrames += 1
                }
                let remaining = interval - began.duration(to: .now)
                if remaining > .zero { try await Task.sleep(for: remaining) }
            } catch {
                guard !stopped else { return }
                if !(error is CancellationError) {
                    AnShotLog.capture.error("scrollshot capture failed: \(error.localizedDescription, privacy: .public)")
                }
                failure = error
                stopped = true
                waiter?.resume(throwing: error)
                waiter = nil
            }
        }
    }

    /// 收尾时取走已拍摄但尚未匹配的帧，释放缓冲并唤醒等待者。
    public func stopAndDrain() -> [CapturedFrame] {
        stopped = true
        producer?.cancel()
        producer = nil
        waiter?.resume(throwing: CancellationError())
        waiter = nil
        let pending = frames
        frames.removeAll()
        return pending
    }
}
