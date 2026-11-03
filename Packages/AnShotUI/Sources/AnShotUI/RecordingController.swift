//
//  RecordingController.swift
//  AnShotUI
//
//  录制会话的界面层封装：启动、停止、暂停、计时与状态广播。
//
//  ── 职责边界 ────────────────────────────────────────────────
//
//  本类型**不碰**捕获细节（那是 `SCStreamRecorder` 的职责），只负责：
//
//  * 收集一次录制所需的配置（范围、音频、输出路径）
//  * 把状态与时长以「可观察」的形式暴露给菜单栏与控制条
//  * 保证在任意时刻最多只有一个会话
//
//  ── 计时为何取自统计而非墙钟 ────────────────────────────────
//
//  时长以 `SCStreamRecorder.statistics.duration` 为准（不含暂停），
//  而不是自行按墙钟累加。后者必然与文件里的真实时长产生偏差
//  （暂停补偿、启动延迟都不在墙钟的语义内），用户在控制条上看到的
//  数字就会与实际录到的不一致。
//

import AnShotCapture
import AnShotCore
import AppKit
import Foundation

// MARK: - 通知

extension Notification.Name {
    /// 请求开始录制。`userInfo` 携带 `CaptureScope`。
    ///
    /// 用通知而非直接引用：覆盖层只负责捕获用户意图，
    /// 「谁来执行录制」属于装配层的决定，两者不应相互依赖。
    public static let anShotStartRecording = Notification.Name("com.anshot.startRecording")
}

/// 通知 `userInfo` 的键。
public enum NotificationUserInfoKey {
    public static let captureScope = "captureScope"
    /// 录制区域在 **AppKit 屏幕坐标**下的矩形，用于摆放控制条。
    public static let recordingRect = "recordingRect"
    /// 用户在准备面板中确认的音频设置。
    public static let audioSettings = "audioSettings"
    /// 用户在准备面板中选定的输出格式（`RecordingOutputChoice`）。
    public static let outputChoice = "recordingOutputChoice"
}

private let recordingUILogger = AnShotLog.recordingUI
/// 录制会话的界面层控制器。
@MainActor
public final class RecordingController {

    /// 一次会话的结束方式。
    public enum Outcome: Sendable {

        /// 正常产出。
        ///
        /// - Parameters:
        ///   - url: 产物路径（GIF 输出时就是 GIF 本身）。
        ///   - duration: 时长（秒，不含暂停）。
        ///   - reachedLimit: 是否因到达 GIF 时长上限而**自动停止**。
        ///     界面必须据此说明原因，否则用户会遇到「录着录着它自己停了」。
        case finished(URL, TimeInterval, reachedLimit: Bool)

        /// 用户主动取消，会话没有任何产出。
        ///
        /// 与 `.failed` 分开：取消不是失败。用户在「准备中」点停止（或授权等待
        /// 期间关闭窗口）时录制器以 `RecordingError.cancelled` 结束会话，
        /// 若照旧折成失败，用户会得到一个自己刚刚要求的「录制失败」弹窗。
        case cancelled

        /// 失败。
        ///
        /// - Parameters:
        ///   - message: 面向用户的原因。
        ///   - kept: 失败时保留下来的产物。nil 表示此次确实没有可保留的东西。
        ///   - missingPermission: 权限类失败时缺的是哪一项。界面据此决定是否
        ///     提供「打开系统设置」——不同权限对应不同的隐私面板，
        ///     让界面去匹配文案是不可靠的。
        case failed(String, kept: KeptRecording?, missingPermission: MissingPermission?)
    }

    /// 失败时缺少的系统权限。
    public enum MissingPermission: Sendable {
        case screenRecording
        case microphone
    }

    // MARK: 可观察状态

    public private(set) var state: RecordingState = .idle

    /// 已录时长（秒，不含暂停）。
    public private(set) var elapsed: TimeInterval = 0

    /// 暂停累计次数（仅用于界面反馈）。
    public private(set) var pauseCount = 0

    /// 状态或时长变化时回调（在主 actor 上）。
    public var onUpdate: ((RecordingState, TimeInterval) -> Void)?

    /// 会话结束时回调（在主 actor 上）。
    public var onFinish: ((Outcome) -> Void)?

    /// GIF 导出进度回调（0…1，整百分比量化后，在主 actor 上）。
    ///
    /// 与 `onUpdate` 分开：进度是同一状态内的连续值，不是会话生命周期的一部分。
    /// 合并进 `onUpdate` 会把「状态变化」与「导出期间一秒十几次的进度」压进同一根管子。
    public var onExportProgress: ((Double) -> Void)?

    // MARK: 内部

    private var recorder: SCStreamRecorder?
    private var sessionTask: Task<Void, Never>?
    private var tickingTask: Task<Void, Never>?
    private var outputURL: URL?

    public init() {}

    /// 是否处于会话进行中（含收尾）。
    ///
    /// 判定依据是**本次会话任务是否还在**，而不是 `state.isActive`：
    /// 后者把 `.finishing` 视为非活跃，于是收尾期间界面会放行新的开始，
    /// 而旧流还在清理——两个会话同时操作捕获资源。
    /// 只有 `record()` 真正返回、收尾任务结束，才允许下一次开始。
    public var isActive: Bool {
        sessionTask != nil
    }

    // MARK: - 控制

    /// 开始录制。
    ///
    /// - Parameters:
    ///   - scope: 录制范围（四种之一）。
    ///   - audio: 音频设置。GIF 输出时会被归零（GIF 无音轨）。
    ///   - output: 输出格式与档位。路径由 `outputURL` 单独给出。
    ///   - outputURL: 输出文件位置（应已过 `OutputPath.unique`）。
    public func start(
        scope: CaptureScope,
        audio: AudioSettings,
        output: RecordingOutputChoice,
        excludedWindowIDs: [CGWindowID] = [],
        outputURL: URL
    ) {
        guard !isActive else {
            recordingUILogger.error("已有会话在进行中，忽略重复开始")
            return
        }

        self.outputURL = outputURL
        // 起步即标为 preparing：从此刻到首帧到达之间，界面上应显示「准备中」
        state = .preparing
        elapsed = 0
        pauseCount = 0
        onUpdate?(state, elapsed)

        let configuration = RecordingConfiguration(
            scope: scope,
            video: VideoSettings(),
            // GIF 无音轨：在配置成型时就把音频归零，
            // 否则「选 GIF 后两个音频开关是置灰的、但状态仍是勾选」会把麦克风权限
            // 实打实地申请一次（用户被问一个本次录制根本用不上的权限）。
            audio: output.effectiveAudio(audio),
            output: output.output(at: outputURL),
            excludedWindowIDs: excludedWindowIDs
        )
        let recorder = SCStreamRecorder()
        self.recorder = recorder
        // 进度回调来自导出线程，这里折到主 actor 再转发给界面。
        // 量化已在 `GIFExporter` 内完成，所以这次转发就是「可见变化」的频率。
        recorder.onExportProgress = { [weak self] value in
            Task { @MainActor in
                self?.onExportProgress?(value)
            }
        }

        sessionTask = Task { [weak self] in
            do {
                let result = try await recorder.record(configuration: configuration)
                // 时长以结果为准：它是收尾时定格的权威值，
                // 不依赖录制器后续的状态（见 SCStreamRecorder.statistics 的说明）。
                self?.elapsed = result.duration
                self?.finish(.finished(
                    result.url,
                    result.duration,
                    reachedLimit: recorder.didReachDurationLimit
                ))
            } catch {
                let recordingError = error as? RecordingError
                // 取消不是失败：安静收尾，不记录故障也不弹窗。
                // 判定必须依据错误类型，不能看界面状态——「准备中」时用户点停止
                // 得到的也是 cancelled，而那正是他想要的结果。
                if recordingError == .cancelled {
                    self?.finish(.cancelled)
                    return
                }
                let message = recordingError?.errorDescription
                    ?? error.localizedDescription
                // 「是否告知用户产物还在」由契约裁决，不在这里自行判断。
                let keepable = recordingError?.shouldKeepPartialOutput ?? false
                let missingPermission: MissingPermission?
                if recordingError == .permissionDenied {
                    missingPermission = .screenRecording
                } else if recordingError == .microphonePermissionDenied {
                    missingPermission = .microphone
                } else {
                    missingPermission = nil
                }
                self?.finish(.failed(
                    message,
                    kept: keepable ? recorder.keptOutput : nil,
                    missingPermission: missingPermission
                ))
            }
        }
        startTicking()
    }

    /// 请求停止。幂等。
    public func stop() async {
        guard isActive else { return }
        await recorder?.stop()
    }

    /// 暂停 / 继续。
    ///
    /// 以**录制器**的状态做判断，而不是界面状态：界面每 200ms 才同步一次，
    /// 首帧刚到时界面可能仍显示「准备中」。准备阶段（首帧未到）不能暂停——
    /// 状态机只接受 `.recording → .paused`，这里若照发请求，录制器会静默丢弃，
    /// 用户看到的就是「按了没反应」。
    public func togglePause() async {
        guard let recorder else { return }
        switch recorder.state {
        case .paused:
            await recorder.resume()
        case .recording:
            await recorder.pause()
            // 只统计真正生效的暂停：pause() 与停止/失败并发时可能未被采纳。
            if recorder.state == .paused {
                pauseCount += 1
            }
        default:
            return
        }
        refreshFromRecorder()
    }

    // MARK: - 内部

    private func startTicking() {
        tickingTask?.cancel()
        tickingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                self.refreshFromRecorder()
                if self.state.isTerminal { return }
            }
        }
    }

    /// 从录制器同步状态与时长。
    ///
    /// 时长一律取自录制器的统计：它是唯一与产出文件一致的来源。
    ///
    /// **状态不能让录制器无条件覆盖。** 界面在 `start()` 起步就标为 `.preparing`，
    /// 而录制器此时仍是 `.idle`（麦克风授权等待、首个采样未到），无条件同步会把
    /// 界面打回 `.idle`，`isActive` 随之变 false，用户连点两次就开出两个会话。
    /// 因此只在录制器确实已进入采集（或收尾）时才采纳它的状态。
    private func refreshFromRecorder() {
        guard let recorder else { return }
        let remote = recorder.state
        if state != .preparing || remote == .recording || remote == .paused || remote == .finishing {
            state = remote
        }
        elapsed = recorder.statistics.duration
        onUpdate?(state, elapsed)
    }

    private func finish(_ outcome: Outcome) {
        tickingTask?.cancel()
        tickingTask = nil
        // 顺序要紧：先把状态定格，再释放会话占用。
        // 这里**不调用** refreshFromRecorder()——它会用录制器的状态覆盖结果，
        // 而失败路径上录制器可能已回到 .idle，界面就会把一个失败会话显示成正常结束。
        // 成功路径的 elapsed 已由 record() 的返回值设定（那是收尾时定格的权威值）。
        switch outcome {
        case .finished:
            state = .finished
        case .failed:
            state = .failed
        case .cancelled:
            // 取消后不要停在 .preparing：那会让界面一直显示「准备中」。
            // 回到 .idle 表示会话已彻底结束、资源已释放（与取消的语义一致）。
            state = .idle
        }
        recorder = nil
        sessionTask = nil
        onUpdate?(state, elapsed)
        onFinish?(outcome)
    }
}

// MARK: - 输出位置

extension RecordingController {

    /// 依据设置决定输出路径。
    ///
    /// 录制无法像截图那样在结束时弹保存面板（内容是实时产生的），
    /// 因此 `.ask` 模式下回退到桌面，并在文件名中加入时间戳。
    ///
    /// - Parameters:
    ///   - settings: 保存设置。
    ///   - output: 输出格式。扩展名随它变化（`.mp4` / `.gif`）。
    /// - Returns: **已唯一化**的路径。时间戳只到秒，而两个写入器在遇到同名文件时
    ///   都会先删掉再写——不唯一化就等于无声丢掉上一次的录像（见 `OutputPath`）。
    public static func defaultOutputURL(
        for settings: AppSettings,
        output: RecordingOutputChoice
    ) -> URL {
        let directory: URL
        switch settings.saveDestination {
        case .folder(let url):
            directory = url
        case .ask:
            directory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "anShot-录制-\(formatter.string(from: Date())).\(output.fileExtension)"
        return OutputPath.unique(base: directory.appendingPathComponent(name))
    }
}
