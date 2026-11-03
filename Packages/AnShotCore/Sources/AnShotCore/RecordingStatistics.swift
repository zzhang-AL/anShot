//
//  RecordingStatistics.swift
//  AnShotCore
//
//  录制会话的产出统计与会话摘要。
//
//  ── 为何 M2-0 先有统计而没有结果契约 ──────────────────────────
//
//  `model.md` §5 的 `RecordingResult` 以输出文件为核心（url / fileSize / pixelSize），
//  而 M2-0 的验收目标是「起流 → 收帧 → 停止」这条链路本身，
//  此时写入器尚不存在。若提前定义带 URL 的结果类型，就得在诊断里伪造一个
//  并不存在的文件，把「链路通了」误报成「录出文件了」。
//
//  故 M2-0 只交付**可观测的真实数据**（帧数、时长、丢弃数），
//  `RecordingResult` 在接入 `AVAssetWriter` 的 M2-1 与写入器一同定义。
//

import Foundation

/// 录制会话的统计数据。
///
/// 全部字段都在**交付给消费端之后**记账：被丢弃的帧不计入 `videoFrameCount`，
/// 因此该值可以直接用于验证「流确实在产出有效帧」。
public struct RecordingStatistics: Sendable, Equatable {

    /// 成功交付给消费端的视频帧数。
    public var videoFrameCount: Int

    /// 收到的**全部**视频样本数（含不完整帧）。用于区分「流已死」与「画面无变化」：
    /// 前者一个样本都没有，后者会持续收到 `idle` / `blank` 等状态帧。
    public var totalVideoSampleCount: Int

    /// 被丢弃的帧数。来源：暂停期间、流未就绪期间的不完整帧、消费端拒绝。
    public var discardedFrameCount: Int

    /// 交付给消费端的系统音频缓冲数。
    public var systemAudioBufferCount: Int

    /// 交付给消费端的麦克风缓冲数。
    public var microphoneBufferCount: Int

    /// 从首帧到停止的时长（秒）。
    ///
    /// M2-0 记录的是**墙钟时长**。暂停补偿（按已写入总时长重设时间戳）
    /// 属于写入器的时间轴职责，在 M2-1 与 `AVAssetWriter` 一同实现。
    public var duration: TimeInterval

    public init(
        videoFrameCount: Int = 0,
        totalVideoSampleCount: Int = 0,
        discardedFrameCount: Int = 0,
        systemAudioBufferCount: Int = 0,
        microphoneBufferCount: Int = 0,
        duration: TimeInterval = 0
    ) {
        self.videoFrameCount = videoFrameCount
        self.totalVideoSampleCount = totalVideoSampleCount
        self.discardedFrameCount = discardedFrameCount
        self.systemAudioBufferCount = systemAudioBufferCount
        self.microphoneBufferCount = microphoneBufferCount
        self.duration = duration
    }

    /// 实际平均帧率。掉帧时低于设定值；时长过短时返回 nil（分母不可信）。
    public var averageFrameRate: Double? {
        guard duration > 0.01, videoFrameCount > 0 else { return nil }
        return Double(videoFrameCount) / duration
    }

    /// 是否真的收到了有效帧。用于区分「链路通了」与「起了流但一帧没收」。
    public var hasReceivedFrames: Bool {
        videoFrameCount > 0
    }
}

/// 一次录制会话的摘要。
///
/// 与统计的区别：摘要额外记录**会话是如何结束的**，因为「用户停止」
/// 「首帧超时」「流报错」三种结束方式在统计上可能都是零帧，但处置完全不同。
public struct RecordingSessionSummary: Sendable, Equatable {

    /// 会话最终状态。只可能是 `finished` 或 `failed`。
    public let finalState: RecordingState

    /// 统计数据。
    public let statistics: RecordingStatistics

    /// 会话被受理的时刻。
    public let startedAt: Date

    /// 会话彻底结束的时刻。
    public let endedAt: Date

    public init(
        finalState: RecordingState,
        statistics: RecordingStatistics,
        startedAt: Date,
        endedAt: Date
    ) {
        self.finalState = finalState
        self.statistics = statistics
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

// MARK: - 结果

/// 一次录制会话的产出结果。
///
/// 与 `RecordingStatistics` 的分工：统计是**过程数据**（会话中随时可读），
/// 结果是**落盘产物**（只在收尾完成后才有意义）。
public struct RecordingResult: Sendable, Equatable {

    /// 输出文件位置。
    public let url: URL

    /// 实际时长（秒），不含暂停。
    public let duration: TimeInterval

    /// 输出像素尺寸。
    public let pixelSize: CGSize

    /// 实际平均帧率。掉帧时低于设定值。
    public let frameRate: Double

    /// 是否包含系统声音。
    public let hasSystemAudio: Bool

    /// 是否包含麦克风旁白。
    public let hasMicrophone: Bool

    /// 文件字节数。
    public let fileSize: Int64

    public init(
        url: URL,
        duration: TimeInterval,
        pixelSize: CGSize,
        frameRate: Double,
        hasSystemAudio: Bool,
        hasMicrophone: Bool,
        fileSize: Int64
    ) {
        self.url = url
        self.duration = duration
        self.pixelSize = pixelSize
        self.frameRate = frameRate
        self.hasSystemAudio = hasSystemAudio
        self.hasMicrophone = hasMicrophone
        self.fileSize = fileSize
    }
}

/// 会话失败时被保留下来的产物。
///
/// ── 为什么需要它 ──────────────────────────────────────────────
///
/// 「东西录到了，但会话失败了」是真实场景（流中断、转码失败）。
/// 而收尾路径会把结果直接丢弃（`continuation.resume(throwing:)`），
/// 于是磁盘上明明躺着一个可用文件，用户却只知道「录制失败」——
/// 文件的存在只有日志知道，而日志不是给用户看的。
///
/// 它也不该被塞进失败原因：原因本身仍是原来的错误（错误契约不变，
/// 调用方无需解包两层），而「留下了什么」是会话的附属事实。
public struct KeptRecording: Sendable, Equatable {

    /// 文件当前位置。
    public let url: URL

    /// 是否已落在目标目录。
    ///
    /// `false` 表示移动失败、文件仍在系统临时目录（随时可能被清理）。
    /// 界面必须据此换措辞——把「还在临时目录」说成「已保留」，
    /// 等于给了用户一个会消失的承诺。
    public let isAtRequestedLocation: Bool

    public init(url: URL, isAtRequestedLocation: Bool) {
        self.url = url
        self.isAtRequestedLocation = isAtRequestedLocation
    }
}
