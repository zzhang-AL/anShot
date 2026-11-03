//
//  ScreenRecording.swift
//  AnShotCapture
//
//  录制层抽象。与 `ScreenCapturing`（单帧捕获）**并列**，不合并。
//
//  ── 为何不复用一个协议 ────────────────────────────────────────
//
//  单帧捕获的产物是「一张图」，生命周期是「调用 → 返回」；
//  录制的生命周期是「启动 → 持续产出 → 停止 → 收尾」，
//  且必须承载暂停、计时、错误中断等状态。
//  把两者塞进一个协议只会得到一个谁都不好用的万能接口
//  （M1 已确立「不做万能接口」的取向）。
//
//  ── 为何协议不暴露 CMSampleBuffer ─────────────────────────────
//
//  帧数据的消费方式是本层的**实现细节**：调用方只声明「开始/暂停/继续/停止」，
//  数据经由 `RecordingSampleSink` 在流的输出队列上被同步交付。
//  若把 `CMSampleBuffer` 放进异步接口（AsyncStream / 回调 + Task），
//  每帧都要跨并发域，而 `CMSampleBuffer` 不满足 `Sendable`，
//  只能靠 `@unchecked Sendable` 包装掩盖问题——那是在骗编译器，不是在保证安全。
//

import AnShotCore
import CoreMedia
import CoreVideo
import Foundation

// MARK: - 配置

/// 一次录制会话的完整配置。
///
/// 与 `AnShotCore.RecordingSettings` 的分工：后者是与框架无关的设置值，
/// 本类型则是**含录制范围**的完整配置。范围（`CaptureScope`）定义在本模块，
/// 故完整配置也只能放在本模块——否则 `AnShotCore` 必须反向依赖本模块，形成循环。
public struct RecordingConfiguration: Sendable, Equatable {

    /// 录制范围（四种之一）。
    public var scope: CaptureScope

    /// 视频设置。
    public var video: VideoSettings

    /// 音频设置。
    public var audio: AudioSettings

    /// 输出目标。
    public var output: RecordingOutput

    /// 必须从画面中排除的窗口（本应用自己的录制 UI）。
    ///
    /// 范围框、控制条、准备面板都浮在被录内容之上，若不排除就会被录进成片——
    /// 用户会看到自己的录制边框出现在视频里。**不能只靠** `nonactivatingPanel`、
    /// 窗口层级或 `sharingType`：这些都不影响 `SCStream` 是否采集该窗口，
    /// 必须由捕获过滤器明确排除。
    ///
    /// `.window` 范围无法排除（该过滤器只接受一个目标窗口），
    /// 但那种情况下录制的是用户指定的别的窗口，本应用 UI 只在重叠时才可能入镜。
    public var excludedWindowIDs: [CGWindowID]

    public init(
        scope: CaptureScope,
        video: VideoSettings = VideoSettings(),
        audio: AudioSettings = AudioSettings(),
        output: RecordingOutput,
        excludedWindowIDs: [CGWindowID] = []
    ) {
        self.scope = scope
        self.video = video
        self.audio = audio
        self.output = output
        self.excludedWindowIDs = excludedWindowIDs
    }

    /// 按输出格式归一化：GIF 无音轨，音频一律归零。
    ///
    /// ── 为何必须有这一步 ──────────────────────────────────────
    ///
    /// 面板在 GIF 模式下把两个音频开关**置灰**，但置灰不改写它们的勾选状态
    /// （面板弹出时默认都勾选）。若把原始音频设置原样带进来，GIF 录制会：
    ///
    /// 1. 去**申请一次麦克风权限**——用户被问一个本次录制根本用不上的权限；
    /// 2. 让流白跑一路系统声音捕获，而产物里一轨都不会有。
    ///
    /// 建写入器的那一层（`makeWriter`）早已把 GIF 的音频关掉，但那太晚了：
    /// 权限请求与流配置都发生在它之前。归一化必须早于**任何输入被建立**。
    public func normalizedForOutput() -> RecordingConfiguration {
        guard output.isGIF, audio.isAnyEnabled else { return self }
        var normalized = self
        normalized.audio = AudioSettings(
            systemAudio: false,
            microphone: false,
            sampleRate: audio.sampleRate,
            channelCount: audio.channelCount,
            excludesOwnAudio: audio.excludesOwnAudio
        )
        return normalized
    }

    /// 启动前预检。
    ///
    /// 契约（`model.md` §6）：不受支持的组合必须在**启动前**拒绝，
    /// 而不是录到一半才失败。
    ///
    /// - Throws: `RecordingError.unsupportedConfiguration`
    public func validate() throws {
        let frameRate = video.frameRate
        guard frameRate > 0, frameRate <= 120 else {
            throw RecordingError.unsupportedConfiguration("帧率 \(frameRate) 超出 1–120 的范围")
        }
        guard audio.sampleRate > 0, audio.channelCount > 0 else {
            throw RecordingError.unsupportedConfiguration("音频采样率或声道数非法")
        }
        if case .gif(_, let settings) = output {
            guard settings.frameRate > 0, settings.maximumPixelDimension > 0 else {
                throw RecordingError.unsupportedConfiguration("GIF 帧率或最大边长非法")
            }
        }
    }
}

// MARK: - 收尾权

/// 收尾权的唯一裁决。
///
/// 一次会话的收尾（停流 → 排空输出队列 → 给出最终结果）必须恰好发生一次。
/// 不能拿状态机的转换结果充当收尾权：`(.finishing, .fail) → .failed` 是合法转换，
/// 于是「用户正在停止」与「流恰好报错」会各自认为自己该收尾——
/// 结果是重复停流，甚至在其中一条路径尚未停流时就提前给出终结结果。
public final class FinalizeGate: @unchecked Sendable {

    private let lock = NSLock()
    private var claimed = false
    /// 正在执行的收尾任务。第一个调用者创建它，后来者等待它。
    private var ongoingTask: Task<Void, Never>?

    public init() {}

    /// 尝试获得收尾权。
    ///
    /// - Returns: 第一个调用者得到 `true` 并负责收尾；其余一律得到 `false`。
    ///
    /// - Important: 只拿到收尾权**不等于**收尾已经完成。需要「返回时收尾已结束」
    ///   这一保证的调用方应当使用 ``runOrWait(_:)``。
    public func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    /// 第一次调用执行 `body`；之后的调用**等待同一次 `body` 完成**。
    ///
    /// 这比 `claim()` 多一条契约：无论第几次进入，返回时都保证收尾已经结束。
    /// 只有「唯一收尾权」而没有「等待」时，重复的 `stop()` 会立即返回——
    /// 调用方据此关闭界面就会提前，甚至在上一个会话仍在清理时就放行新会话。
    /// 两者是不同的契约，必须由类型本身提供，否则调用方无从判断该不该等。
    public func runOrWait(_ body: @escaping @Sendable () async -> Void) async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let existing = ongoingTask {
                return existing
            }
            // 与 claim() 共享同一份状态：无论走哪个入口，收尾都只发生一次。
            self.claimed = true
            let created = Task { await body() }
            self.ongoingTask = created
            return created
        }
        await task.value
    }
}

// MARK: - 数据消费

/// 录制数据的消费端。
///
/// **这是模块内部接口**：数据如何落盘是录制的实现细节，调用方只声明「录制到哪个文件」。
///
/// **线程模型（必须遵守）**：全部方法在录制器的固定串行队列上被**同步**调用。
/// 由此产生三条硬约束：
///
/// 1. 不得阻塞。输出队列同时承载屏幕帧与音频样本，阻塞会直接造成丢帧。
/// 2. 不得持有 `sampleBuffer`。它在调用返回后即失效，需要留存必须自行拷贝。
/// 3. 不得从本方法内部回调录制器的控制方法并等待（会死锁）。
///
/// 返回值表示是否接受：返回 `false` 时录制器计入丢弃统计，而不是静默丢弃。
/// 这使「写入器跟不上」成为**可观测**的事实，而不是靠猜。
protocol RecordingSampleSink: AnyObject {

    /// 消费一个视频帧。
    ///
    /// - Returns: 是否已接受。返回 `false` 表示未消费（如写入器尚未就绪或已失败）。
    @discardableResult
    func consumeVideo(_ sampleBuffer: CMSampleBuffer) -> Bool

    /// 消费一个系统音频缓冲。
    @discardableResult
    func consumeSystemAudio(_ sampleBuffer: CMSampleBuffer) -> Bool

    /// 消费一个麦克风音频缓冲。
    @discardableResult
    func consumeMicrophone(_ sampleBuffer: CMSampleBuffer) -> Bool
}

// MARK: - 协议

/// 录制器抽象。
///
/// 实现须为 `Sendable`，且**会话实例不可复用**：一次会话结束后应新建实例。
/// 状态机把 `finished` / `failed` 定义为终态，正是为了在类型层面拒绝复用
/// （复用意味着要重建流、写入器与时间基准，把三者一起重置的复杂度远高于新建）。
public protocol ScreenRecording: Sendable {

    /// 当前会话状态。读取是线程安全的。
    var state: RecordingState { get }

    /// 当前会话的实时统计。可用于 UI 计时与诊断。
    var statistics: RecordingStatistics { get }

    /// 启动会话。
    ///
    /// 该调用在**整个会话结束后**才返回：正常停止返回落盘结果；
    /// 失败或首帧超时抛 `RecordingError`（此时可通过 `statistics` 读取已录数据）。
    ///
    /// 数据如何落盘（容器、编码器、时间轴）由 `configuration.output` 决定，
    /// 调用方不接触帧数据。
    ///
    /// 停止、暂停、恢复必须从**另一个任务**调用本方法（见 `stop()`）。
    ///
    /// - Parameter configuration: 完整配置，会先经过 `validate()`。
    func record(configuration: RecordingConfiguration) async throws -> RecordingResult

    /// 请求暂停。不对应任何状态时为空操作。
    func pause() async

    /// 请求恢复。不对应任何状态时为空操作。
    func resume() async

    /// 请求停止。幂等：重复调用、或在终态上调用都是空操作。
    func stop() async
}
