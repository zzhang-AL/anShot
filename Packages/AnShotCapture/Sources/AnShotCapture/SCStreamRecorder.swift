//
//  SCStreamRecorder.swift
//  AnShotCapture
//
//  macOS 13.0+ 的录制实现，基于 SCStream 的持续输出。
//
//  ── 与 `StreamCapturer`（单帧）的关键差异 ────────────────────
//
//  前者抓首帧后立即停流，追求「快进快出」；本实现维持长时间的活动流，
//  因此复杂度全部集中在**生命周期**上：
//
//  | 关注点 | 单帧 | 录制 |
//  |---|---|---|
//  | 完成时机 | 首帧到达 | 用户停止或出错 |
//  | 等待方 | 首帧 continuation | 会话 continuation |
//  | 失败路径 | 超时、流错误 | 超时、流错误、写入器错误、用户停止 |
//  | 资源释放 | 一次 | 必须覆盖全部失败路径，且可能被并发触发 |
//
//  ── 为何不照搬 `FirstFrameCollector` ──────────────────────────
//
//  该实现（M1）有两个生命周期隐患：
//
//  1. 首帧回调可能早于 continuation 注册，此时 `waitForFirstFrame` 直接以
//     超时结束——帧已经收到却被判超时。
//  2. `withThrowingTaskGroup` 中的超时子任务抛出后，任务组会取消其它子任务，
//     但**不会自动唤醒**那个挂在 `withCheckedThrowingContinuation` 上的子任务，
//     需依赖外部的 `collector.cancel()` 显式收尾。
//
//  本实现改为单一入口模型：**会话 continuation 在起流之前就已安装**，
//  首帧、启动失败、delegate 错误、超时、用户停止五条路径全部汇聚到
//  同一个 `conclude()`，由它在锁内取走 continuation 并恰好 resume 一次。
//
//  ── 并发模型 ────────────────────────────────────────────────
//
//  * 控制方法（record/pause/resume/stop）可从任意线程调用，会话状态由一把
//    `NSLock` 串行化。全部锁操作使用**作用域形式** `withLock`：
//    Swift 6 禁止在 async 上下文中直接 `lock()/unlock()`（跨越 await 持有锁
//    会死锁），作用域形式让编译器能证明锁不会跨过挂起点。
//  * 帧回调固定在 `outputQueue`（串行）上，与 sink 的交付**同线程**，
//    因此 sample buffer 从不跨并发域，无需 `@unchecked Sendable` 包装。
//  * 收尾由 `isFinalizing` 单一裁决：抢到的一方负责停流、排空输出队列与
//    给出最终结果；后续的错误只登记原因，不再重复收尾。
//

import AnShotCore
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

private let recorderLogger = AnShotLog.recording
public final class SCStreamRecorder: NSObject, ScreenRecording, @unchecked Sendable {

    /// 会话终结的产物。只有取到它的一方负责 resume。
    private struct TerminalOutcome {
        let continuation: CheckedContinuation<RecordingResult, Error>
        let writer: MovieWriter?
        let statistics: RecordingStatistics
        let finalState: RecordingState
        let failure: RecordingError?
    }

    // MARK: - 依赖

    /// 等待首帧的超时（秒）。
    ///
    /// 超时意味着流启动异常，而非「屏幕无变化」——正常启动的流即使在画面完全静止时
    /// 也持续投递样本（实测 6 秒静止画面收到 186 个样本，其中 49 个是
    /// `SCFrameStatus.idle`）。
    private let firstFrameTimeout: TimeInterval

    /// 流输出的串行队列。屏幕帧与音频样本共用同一条队列。
    ///
    /// 必须串行：sink（写入器）因此无需自己再加锁，样本的时间顺序也天然正确。
    private let outputQueue = DispatchQueue(label: "com.anshot.recording.stream-output")

    // MARK: - 会话状态（由 lock 保护）

    private let lock = NSLock()
    private var machine = RecordingStateMachine()
    private var pendingContinuation: CheckedContinuation<RecordingResult, Error>?
    private var pendingFailure: RecordingError?
    private var stream: SCStream?
    private var timeoutTask: Task<Void, Never>?
    private var durationLimitTask: Task<Void, Never>?
    private var stopRequested = false
    private var writer: MovieWriter?
    private var microphone: MicrophoneCapturer?

    /// 收尾权的唯一裁决。
    ///
    /// 不能依赖状态机的转换结果充当收尾权：`(.finishing, .fail)` 是合法转换，
    /// 于是「用户停止中」与「流报错」会各自认为自己该收尾，
    /// 导致重复停流，甚至在其中一条路径尚未停流时就提前给出终结结果。
    private let finalizeGate = FinalizeGate()

    // MARK: - 统计（同由 lock 保护）

    private var stats = RecordingStatistics()
    private var sessionStartedAt: Date?
    private var activeConfiguration: RecordingConfiguration?
    private var firstFrameAt: Date?
    private var pausedSince: Date?
    private var accumulatedPause: TimeInterval = 0

    /// - Parameter firstFrameTimeout: 等待首帧的超时。默认 3 秒。
    public init(firstFrameTimeout: TimeInterval = 3.0) {
        self.firstFrameTimeout = firstFrameTimeout
        super.init()
    }

    // MARK: - 回调与附属事实

    /// GIF 导出进度回调（0…1），在任意线程调用。
    ///
    /// **不进状态机**：进度是同一状态内的连续值，而状态机描述的是生命周期，
    /// 它的转移表正被穷尽性单测验证着（见 `model.md` §3）。
    /// 界面层负责把它折到主 actor；`GIFExporter` 已把进度量化成整百分比，
    /// 所以这里的调用频率就是「可见的变化」的频率。
    public var onExportProgress: (@Sendable (Double) -> Void)?

    /// 会话失败时被保留下来的产物（若有）。
    ///
    /// 只在会话失败时有意义：成功时产物就是 `RecordingResult.url`。
    /// 只有写入器已正常收尾才会被设置——`finish()` 自身失败时文件可能是半截的，
    /// 把它称作可用产物比不给路径更糟。
    public private(set) var keptOutput: KeptRecording?

    /// 会话是否因到达 GIF 时长上限而自动停止。
    ///
    /// 由 `scheduleAutoStop` 置位。界面据此说明停止原因，
    /// 而不是用「时长≈上限」去反推——后者在「用户恰好在上限前一刻手停」
    /// 这类情形下会给出错误结论。
    public private(set) var didReachDurationLimit = false

    // MARK: - ScreenRecording

    public var state: RecordingState {
        lock.withLock { machine.state }
    }

    public var statistics: RecordingStatistics {
        lock.withLock {
            var snapshot = stats
            // ⚠️ 只在会话**进行中**重算时长。
            //
            // `currentDuration` 依赖 `firstFrameAt` / `pausedSince`，而收尾时这两者会被清空；
            // 若结束后仍重算，会得到 0 并覆盖掉收尾时已定格的正确值——实测该缺陷使
            // 界面层在会话结束后读到 `elapsed = 0.00s`（而产出文件的实际时长是 2.62s）。
            //
            // 进行中才重算的理由：时长是「到目前为止」的实时值，不写回 stats，
            // 否则每次读取都变成写操作，纯读的调用点也要付锁竞争代价。
            if machine.state.isActive {
                snapshot.duration = currentDuration(now: Date())
            }
            return snapshot
        }
    }

    public func record(
        configuration: RecordingConfiguration
    ) async throws -> RecordingResult {
        guard !Task.isCancelled, !lock.withLock({ stopRequested }) else {
            throw RecordingError.cancelled
        }
        // GIF 无音轨：在**建立任何输入之前**把音频归零（详见 `normalizedForOutput`）。
        // 放在 validate 之前，使「GIF + 麦克风」这种组合不会先去申请一次权限。
        let configuration = configuration.normalizedForOutput()
        try configuration.validate()

        guard CGPreflightScreenCaptureAccess() else {
            throw RecordingError.permissionDenied
        }

        // ⚠️ 麦克风权限在**建立任何资源之前**处理。
        // 它可能需要用户点击系统弹窗（可能等待数十秒），若放在起流之后，
        // 这段等待会卡在会话启动路径上：会话迟迟进不了 recording，
        // 调用方会以为启动失败。权限是前置条件，不是启动步骤。
        if configuration.audio.microphone {
            try await ensureMicrophonePermission()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let rejection = lock.withLock { () -> RecordingError? in
                // 停止可能发生在等待麦克风授权期间，不能在授权返回后重新启动。
                guard !stopRequested, !Task.isCancelled else { return .cancelled }
                guard machine.apply(.start).didApply else { return .alreadyRunning }
                sessionStartedAt = Date()
                activeConfiguration = configuration
                // ⚠️ continuation 必须在任何异步步骤之前安装。
                // 若推迟到起流之后，期间的失败（枚举异常、startCapture 抛错、
                // 用户停止）将找不到等待方，record() 永久挂起。
                pendingContinuation = continuation
                return nil
            }

            if let rejection {
                continuation.resume(throwing: rejection)
                return
            }

            // 强引用 self：整个会话期间录制器必须存活，否则 continuation 永远不会被
            // resume。任务在会话终结后自行结束，不构成循环引用（self 不持有该任务）。
            Task {
                do {
                    try await self.prepareAndStart(configuration: configuration)
                } catch {
                    self.noteFailure(Self.recordingError(from: error))
                }
            }
        }
    }

    /// 请求暂停。
    ///
    /// **门控契约**：状态变更与帧交付在同一串行队列（`outputQueue`）上裁决，
    /// 因此 `pause()` 返回之后到达的帧**不可能**再被写入文件。
    /// 若像早期实现那样「取出 sink 后释放锁再调用」，就会留下一帧的窗口：
    /// 调用方已经收到「已暂停」，文件里却多出一帧。
    /// 语义上，`pause()` 返回**之前**已开始处理的帧仍会写入，这是正确的。
    public func pause() async {
        await withCheckedContinuation { continuation in
            outputQueue.async {
                let applied = self.lock.withLock { () -> Bool in
                    guard self.machine.apply(.pause).didApply else { return false }
                    self.pausedSince = Date()
                    return true
                }
                if applied {
                    self.writer?.notePauseStarted()
                }
                continuation.resume()
            }
        }
    }

    public func resume() async {
        await withCheckedContinuation { continuation in
            outputQueue.async {
                self.lock.withLock {
                    guard self.machine.apply(.resume).didApply else { return }
                    if let since = self.pausedSince {
                        self.accumulatedPause += Date().timeIntervalSince(since)
                        self.pausedSince = nil
                    }
                }
                continuation.resume()
            }
        }
    }

    public func stop() async {
        let hasStarted = lock.withLock {
            stopRequested = true
            return machine.state != .idle
        }
        // 尚未登记 continuation 时不能消耗唯一收尾权；record() 会看到取消标记。
        guard hasStarted else { return }
        // runOrWait 而非 claim：重复 stop() 必须**等待同一次收尾完成**。
        // 只拿收尾权就返回的话，调用方会以为已经停止，界面提前关闭，
        // 甚至在上一个会话仍在清理时就放行新会话。
        await finalizeGate.runOrWait { [weak self] in
            guard let self else { return }
            _ = self.lock.withLock { self.machine.apply(.stop) }
            await self.cleanupStream()
            await self.finalizeSession()
        }
    }

    // MARK: - 启动流程

    /// 构造过滤器与配置、建立流并启动，随后安排首帧超时。
    private func prepareAndStart(configuration: RecordingConfiguration) async throws {
        let content = try await CaptureSetup.fetchShareableContent()

        // 枚举期间用户可能已经停止。此处提前返回，不建立任何资源。
        guard isActive else { return }

        // 目标解析在**同一次查询**里完成：过滤器、输出尺寸、缩放系数必须同源。
        // 窗口会随其移动改变 frame，分两次查询就会出现「按旧尺寸输出新位置画面」。
        let target = try CaptureSetup.prepareRecordingTarget(
            scope: configuration.scope,
            content: content,
            excludedWindowIDs: configuration.excludedWindowIDs
        )
        recorderLogger.notice("录制目标：\(target.description, privacy: .public) 输出=\(Int(target.pixelSize.width), privacy: .public)x\(Int(target.pixelSize.height), privacy: .public)px")

        let streamConfiguration = CaptureSetup.makeRecordingConfiguration(
            sourceRect: target.sourceRect,
            outputPixelSize: target.pixelSize,
            video: configuration.video,
            audio: configuration.audio
        )

        // 写入器必须在起流**之前**建好：它要先建立编码轨道，
        // 失败也应当早于任何捕获活动发生，而不是录了几秒才发现写不了。
        let movieWriter = try makeWriter(configuration: configuration, pixelSize: target.pixelSize)
        guard install(writer: movieWriter) else { return }

        let newStream = SCStream(
            filter: target.filter,
            configuration: streamConfiguration,
            delegate: self
        )
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        if configuration.audio.systemAudio {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        }

        // 装上流之前再确认一次：若已停止，`stop()` 已经走完收尾，此时启动将无人停止。
        guard install(stream: newStream) else { return }

        recorderLogger.notice("startCapture 发起")
        try await newStream.startCapture()
        recorderLogger.notice("startCapture 返回")

        // 启动完成后是否需要把这条流当作废弃流清理掉。
        let abandoned = lock.withLock { () -> Bool in
            guard let registered = stream else { return true }
            return Self.shouldAbandonAfterStart(
                registeredStreamIsCurrent: registered === newStream,
                state: machine.state
            )
        }
        if abandoned {
            recorderLogger.notice("启动完成后判定为废弃流，停止它")
            do {
                try await newStream.stopCapture()
            } catch {
                recorderLogger.error(
                    "abandoned stream stop failed: \(String(describing: error), privacy: .public)"
                )
            }
            return
        }

        // 麦克风最后启动：`AVCaptureSession.startRunning()` 是阻塞调用（可能数百毫秒），
        // 且它的时间戳需要与已建立的视频时间轴对齐，故不参与时间原点的确定。
        if configuration.audio.microphone {
            try await startMicrophone()
        }

        scheduleFirstFrameTimeout()

        // GIF 的时长上限：到期自动停止（契约 model.md §4.5 的 maximumDuration）
        if case .gif(_, let gifSettings) = configuration.output {
            scheduleAutoStop(after: gifSettings.maximumDuration)
        }
    }

    /// 安排「达到时长上限后自动停止」。
    ///
    /// 只对设置了上限的输出（GIF）使用。停止是幂等的，因此即使与用户的停止
    /// 同时发生也不会造成两次收尾（收尾权由 `FinalizeGate` 唯一裁决）。
    private func scheduleAutoStop(after seconds: TimeInterval) {
        let limit = max(0.1, seconds)
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let delay = self.lock.withLock { () -> TimeInterval? in
                    guard self.machine.state.isActive, !self.stopRequested else { return nil }
                    let remaining = max(0, limit - self.currentDuration(now: Date()))
                    if self.machine.state == .recording, remaining <= 0 {
                        self.didReachDurationLimit = true
                        return 0
                    }
                    // 上限只累计已录时长；准备与暂停阶段保持等待。
                    return self.machine.state == .recording ? max(0.01, min(0.1, remaining)) : 0.1
                }
                guard let delay else { return }
                if delay == 0 {
                    recorderLogger.notice("达到时长上限 \(seconds, privacy: .public)s，自动停止")
                    await self.stop()
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        lock.withLock {
            guard machine.state.isActive, !stopRequested else {
                task.cancel()
                return
            }
            durationLimitTask = task
        }
    }

    /// 确保麦克风权限已授予。权限不足时**如实报错而非静默降级**——
    /// 用户明确要求了旁白，静默录出无声文件比报错更糟。
    ///
    /// 麦克风有真实的授权状态 API，能区分「未询问」与「已拒绝」：
    /// 未询问时**应当发起请求**（系统弹窗），这正是它不需要 M1 那套
    /// UserDefaults 推断的原因。
    private func ensureMicrophonePermission() async throws {
        var status = MicrophonePermission.status
        recorderLogger.notice("麦克风权限状态：\(String(describing: status), privacy: .public)")
        if status == .notDetermined {
            let start = Date()
            let granted = await MicrophonePermission.request()
            let elapsed = Date().timeIntervalSince(start)
            recorderLogger.notice("""
                麦克风权限请求返回：granted=\(granted, privacy: .public) \
                耗时=\(String(format: "%.1f", elapsed), privacy: .public)s
                """)
            status = MicrophonePermission.status
        }
        guard status.allowsCapture else {
            recorderLogger.error("麦克风权限未授予：\(String(describing: status), privacy: .public)")
            // 单独的错误类型：界面要据此把用户带到「麦克风」隐私面板，
            // 而不是屏幕录制那一页。
            throw RecordingError.microphonePermissionDenied
        }
    }

    /// 启动麦克风采集（权限已在 `record()` 入口确认）。
    private func startMicrophone() async throws {
        let capturer = MicrophoneCapturer()

        // ⚠️ **先登记实例，再等待启动**。若像原先那样等 `start()` 返回后才登记，
        // 启动期间发生的停止（用户立刻取消、或流报错）就找不到这个实例，
        // 麦克风会一直运行到进程结束——设备指示灯长亮。
        guard lock.withLock({ () -> Bool in
            guard machine.state.isActive else { return false }
            microphone = capturer
            return true
        }) else {
            return
        }

        do {
            try await capturer.start(on: outputQueue) { [weak self] sampleBuffer in
                self?.handleMicrophoneSample(sampleBuffer)
            }
        } catch {
            lock.withLock {
                if microphone === capturer { microphone = nil }
            }
            throw error
        }

        // 启动是异步且可能耗时的：返回后会话可能已经结束，
        // 此时不能再把它挂在活跃会话上，必须立即停掉。
        let stillNeeded = lock.withLock { machine.state.isActive && microphone === capturer }
        if !stillNeeded {
            await capturer.stop()
            lock.withLock {
                if microphone === capturer { microphone = nil }
            }
            recorderLogger.notice("麦克风启动完成时会话已结束，已直接停止")
        }
    }

    /// 判断启动完成后是否需要把这条流当作**废弃流**清理掉。
    ///
    /// ⚠️ 判定条件**不能**写成 `state != .preparing`。
    /// 首帧回调在输出队列上并发执行，常常在 `startCapture()` 返回**之前**到达，
    /// 那时状态已合法地变为 `.recording`。旧实现正是用 preparing 判断的，
    /// 于是把**正常启动的流主动停掉**，症状为「投递首帧后彻底沉默」+
    /// 「停止时报 -3808（流已停止或不存在）」，并随回调时序呈现间歇性
    /// （实测 4 轮中 2 轮命中，日志显示正是「首帧到达 → startCapture 返回」的顺序）。
    ///
    /// - Parameters:
    ///   - registeredStreamIsCurrent: 当前登记的流是否就是刚启动的这一条。
    ///   - state: 启动完成时刻的会话状态。
    /// - Returns: true 表示这条流已无人认领，必须立即停止。
    static func shouldAbandonAfterStart(
        registeredStreamIsCurrent: Bool,
        state: RecordingState
    ) -> Bool {
        guard registeredStreamIsCurrent else { return true }
        return !state.isActive
    }

    /// 按输出配置创建写入器。
    private func makeWriter(
        configuration: RecordingConfiguration,
        pixelSize: CGSize
    ) throws -> MovieWriter {
        switch configuration.output {
        case .movie(let url, let container):
            return try MovieWriter(
                url: url,
                container: container,
                video: configuration.video,
                audio: configuration.audio,
                pixelSize: pixelSize
            )
        case .gif:
            // GIF 走两段式：先落盘临时影片，收尾时再逐帧转换为 GIF。
            // 这样录制的峰值内存与时长无关（见 GIFExporter 文件头说明）。
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("anshot-gif-source-\(UUID().uuidString).mp4")
            // GIF 无音频轨，因此不建立任何音频输入
            return try MovieWriter(
                url: temporaryURL,
                container: .mp4,
                video: configuration.video,
                audio: AudioSettings(systemAudio: false, microphone: false),
                pixelSize: pixelSize
            )
        }
    }

    /// 把临时影片转换为 GIF，并清理临时文件。
    private func convertToGIF(
        movie: RecordingResult,
        finalURL: URL,
        settings: GIFSettings
    ) async throws -> RecordingResult {
        recorderLogger.notice("开始导出 GIF：上限 \(settings.maximumDuration, privacy: .public)s / \(settings.maximumPixelDimension, privacy: .public)px")
        let exported = try await GIFExporter.export(
            movieURL: movie.url,
            to: finalURL,
            settings: settings,
            progress: { [weak self] value in self?.onExportProgress?(value) }
        )
        // 临时影片已无用；删除失败不影响导出结果
        try? FileManager.default.removeItem(at: movie.url)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: exported.url.path)[.size] as? Int64) ?? 0
        return RecordingResult(
            url: exported.url,
            duration: movie.duration,
            pixelSize: exported.pixelSize,
            frameRate: movie.duration > 0.01 ? Double(exported.frameCount) / movie.duration : 0,
            hasSystemAudio: false,
            hasMicrophone: false,
            fileSize: fileSize
        )
    }

    /// 把临时影片交给用户（GIF 未能产出时的回退）。
    ///
    /// **移动而非复制**：临时文件放在系统临时目录、会被系统清理，
    /// 复制过去再留下原件等于留了一个必然失效的第二份。
    ///
    /// 移动失败时**不谎称已保留**：返回 `isAtRequestedLocation: false`
    /// 并带上临时目录里的原路径，由界面如实说明「未能移动」。
    /// 也绝不在这里静默删文件——那是用户花时间录下的、唯一的一份内容。
    ///
    /// - Returns: 保留结果；临时影片本身不存在时返回 nil（无物可保留）。
    private func rescueMovie(at temporaryURL: URL, gifURL: URL) -> KeptRecording? {
        guard FileManager.default.fileExists(atPath: temporaryURL.path) else {
            recorderLogger.error("GIF 未产出，但没有可保留的影片：\(temporaryURL.path, privacy: .public)")
            return nil
        }

        let target = OutputPath.unique(base: OutputPath.fallbackMovie(forGIFAt: gifURL))
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: target)
            recorderLogger.notice("GIF 未产出，影片已保留：\(target.path, privacy: .public)")
            return KeptRecording(url: target, isAtRequestedLocation: true)
        } catch {
            recorderLogger.error("""
                影片保留失败：move \(temporaryURL.path, privacy: .public) → \
                \(target.path, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)
                """)
            return KeptRecording(url: temporaryURL, isAtRequestedLocation: false)
        }
    }

    /// 在会话仍进行时登记写入器。
    private func install(writer newWriter: MovieWriter) -> Bool {
        lock.withLock {
            guard machine.state.isActive else { return false }
            writer = newWriter
            return true
        }
    }

    /// 在会话仍进行时登记流。
    private func install(stream newStream: SCStream) -> Bool {
        lock.withLock {
            guard machine.state.isActive else { return false }
            stream = newStream
            return true
        }
    }

    private var isActive: Bool {
        lock.withLock { machine.state.isActive }
    }

    /// 安排首帧超时。
    ///
    /// 用独立 `Task` 而非任务组：任务组的超时分支抛出后不会唤醒挂在
    /// continuation 上的兄弟任务（见文件头的隐患 2），独立定时器则直接调用
    /// `noteFailure`，由统一的收尾路径唤醒等待方。
    private func scheduleFirstFrameTimeout() {
        let delay = firstFrameTimeout
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.noteFailure(.timedOut)
        }

        lock.withLock {
            if machine.state == .preparing {
                timeoutTask = task
            } else {
                // 首帧已到达：不再需要超时
                task.cancel()
            }
        }
    }

    // MARK: - 收尾

    /// 记录失败原因；若收尾尚未启动则一并启动收尾。
    ///
    /// 若已有收尾在跑（用户停止或另一次失败），这里**只登记原因**：
    /// 收尾方会在 `conclude()` 读到 `pendingFailure` 并据此判定最终状态。
    private func noteFailure(_ error: RecordingError) {
        lock.withLock {
            if pendingFailure == nil {
                pendingFailure = error
            }
        }

        // 启动收尾但不等待：本方法由输出队列或委托回调触发，阻塞会连带影响采样投递。
        // 需要结果的调用方走 stop()（等待同一次收尾）或 record() 的返回值。
        // 若 stop() 已启动收尾，这里只会等待同一个任务，不会重复收尾。
        Task { [weak self] in
            guard let self else { return }
            await self.finalizeGate.runOrWait { [weak self] in
                guard let self else { return }
                _ = self.lock.withLock { self.machine.apply(.fail) }
                await self.cleanupStream()
                await self.finalizeSession()
            }
        }
    }

    /// 停止流并**排空输出队列**。
    ///
    /// 排空不可省略：`stopCapture()` 返回后，队列里可能仍有已入队的帧回调，
    /// 不清空就会出现「会话已结束后统计还在增长」这类难以复现的偏差。
    private func cleanupStream() async {
        // 先停麦克风：它是独立的采集会话，不属于 SCStream
        let microphoneToStop = lock.withLock { () -> MicrophoneCapturer? in
            let capturer = microphone
            microphone = nil
            return capturer
        }
        await microphoneToStop?.stop()

        let streamToStop = lock.withLock { () -> SCStream? in
            let registered = stream
            stream = nil
            return registered
        }

        if let streamToStop {
            do {
                try await streamToStop.stopCapture()
            } catch {
                // 停止失败不改变会话结论：已录内容仍然有效
                recorderLogger.error(
                    "stopCapture failed: \(String(describing: error), privacy: .public)"
                )
            }
        }

        outputQueue.sync { }
    }

    /// 影片写完之后，把「输出目标」这一步做完。
    ///
    /// 三条路径的区别只在「要不要转码」与「失败时留下什么」：
    ///
    /// | 情况 | 转码 | 保留的产物 |
    /// |---|---|---|
    /// | 影片，无失败 | — | 产物即结果 |
    /// | 影片，已有失败 | — | 最终路径上的影片（`KeptRecording`） |
    /// | GIF，无失败 | 转 | 转出的 GIF；转码失败则回退为临时影片 |
    /// | GIF，已有失败 | **不转** | 临时影片 |
    ///
    /// GIF 在「已有失败」时不转码是刻意的：那是一次可能要花数分钟的逐帧转码，
    /// 而它面对的影片可能已经不完整；用户此刻真正需要的是「我录到的东西还在」——
    /// 而影片比 GIF 更完整（无缩放、无时长上限）。
    private func settleOutput(
        movie: RecordingResult,
        failure: inout RecordingError?,
        result: inout RecordingResult?
    ) async {
        guard case .gif(let finalURL, let gifSettings) = activeConfiguration?.output else {
            if failure == nil {
                result = movie
            } else {
                // 影片本就写在最终路径上。如实登记它，是否告知用户
                // 由 `shouldKeepPartialOutput` 在界面层裁决。
                keptOutput = KeptRecording(url: movie.url, isAtRequestedLocation: true)
            }
            return
        }

        guard failure == nil else {
            keptOutput = rescueMovie(at: movie.url, gifURL: finalURL)
            return
        }

        do {
            result = try await convertToGIF(movie: movie, finalURL: finalURL, settings: gifSettings)
        } catch let error as RecordingError {
            failure = error
            keptOutput = rescueMovie(at: movie.url, gifURL: finalURL)
        } catch {
            failure = .gifExportFailed(error.localizedDescription)
            keptOutput = rescueMovie(at: movie.url, gifURL: finalURL)
        }
    }

    /// 唯一的终结路径：推进状态、完成写入器、取走 continuation、恰好 resume 一次。
    ///
    /// 幂等：第二个到达者会发现 continuation 已被取走而直接返回。
    ///
    /// 方法名不用 `finalize`——`NSObject` 上存在同名的 ObjC 遗留方法，
    /// 同名声明会被编译器判为覆盖。
    private func finalizeSession() async {
        guard let outcome = takeTerminalOutcome() else { return }

        var result: RecordingResult?
        var failure = outcome.failure

        if let movieWriter = outcome.writer {
            var movieResult: RecordingResult?
            do {
                movieResult = try await movieWriter.finish(duration: outcome.statistics.duration)
            } catch let error as RecordingError {
                if failure == nil { failure = error }
            } catch {
                if failure == nil { failure = .writerFailed(error.localizedDescription) }
            }

            if let movieResult {
                await settleOutput(movie: movieResult, failure: &failure, result: &result)
            }
        } else if failure == nil {
            failure = .writerFailed("会话未建立写入器")
        }

        // 终态在此发布：writer 收尾与 GIF 转换都已完成，此时宣布结果才是真的。
        // 失败原因存在则一律判为 failed（流在收尾过程中报错是真实场景：
        // flush 时才暴露写入失败）。放在日志之前是为了让日志记录真实终态。
        let publishedState = lock.withLock { () -> RecordingState in
            if !machine.state.isTerminal {
                machine.apply(failure == nil ? .finishSucceeded : .fail)
            }
            return machine.state
        }

        recorderLogger.notice("""
            session ended: state=\(publishedState.rawValue, privacy: .public) \
            samples=\(outcome.statistics.totalVideoSampleCount, privacy: .public) \
            frames=\(outcome.statistics.videoFrameCount, privacy: .public) \
            discarded=\(outcome.statistics.discardedFrameCount, privacy: .public) \
            duration=\(String(format: "%.2f", outcome.statistics.duration), privacy: .public)s \
            file=\(result.map { String(format: "%.1fMB", Double($0.fileSize) / 1_048_576) } ?? "无", privacy: .public)
            """)

        if let failure {
            outcome.continuation.resume(throwing: failure)
        } else if let result {
            outcome.continuation.resume(returning: result)
        } else {
            outcome.continuation.resume(throwing: RecordingError.writerFailed("收尾未产出结果"))
        }
    }

    /// 在锁内推进到终态并取走 continuation。返回 nil 表示已被其它路径取走。
    private func takeTerminalOutcome() -> TerminalOutcome? {
        lock.withLock {
            guard let continuation = pendingContinuation else { return nil }

            // **状态推进不在这里做。** 本方法在锁内被调用，而它之后还有
            // writer 收尾与 GIF 转换；若在此推进到终态，调用方会在文件写完之前
            // 就看到 .finished。真正的发布在 finalizeSession() 收尾完成之后。

            let endedAt = Date()
            if let since = pausedSince {
                accumulatedPause += endedAt.timeIntervalSince(since)
                pausedSince = nil
            }
            stats.duration = currentDuration(now: endedAt)

            let outcome = TerminalOutcome(
                continuation: continuation,
                writer: writer,
                statistics: stats,
                finalState: machine.state,
                failure: pendingFailure
            )

            pendingContinuation = nil
            pendingFailure = nil
            writer = nil
            stream = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            durationLimitTask?.cancel()
            durationLimitTask = nil
            sessionStartedAt = nil
            firstFrameAt = nil

            return outcome
        }
    }

    /// 计算不含暂停的会话时长。
    ///
    /// 必须同时减去**历史暂停累计**与**当前这一段暂停**：
    /// 只减后者会让「录 1s → 暂停 1s → 录 1s」得到 3s 而不是 2s，
    /// 暂停补偿完全失效（该缺陷由 `-diagnoseRecording` 实测抓出）。
    ///
    /// 必须在锁内调用（读取 `firstFrameAt` / `pausedSince` / `accumulatedPause`）。
    private func currentDuration(now: Date) -> TimeInterval {
        guard let first = firstFrameAt else { return 0 }
        var total = now.timeIntervalSince(first)
        total -= accumulatedPause
        if let pausedSince {
            total -= now.timeIntervalSince(pausedSince)
        }
        return max(0, total)
    }

    // MARK: - 辅助

    #if DEBUG
    /// 诊断专用：流引用是否仍被持有。
    ///
    /// 用于验证「停止后资源已释放」——仅凭 `state == .finished` 无法区分
    /// 「状态已推进」与「流确实被放手」。
    public var hasActiveStreamForDiagnostics: Bool {
        lock.withLock { stream != nil }
    }
    #endif

    private static func recordingError(from error: Error) -> RecordingError {
        if let recordingError = error as? RecordingError {
            return recordingError
        }
        if let captureError = error as? CaptureError {
            switch captureError {
            case .permissionDenied:
                return .permissionDenied
            case .displayUnavailable, .scopeUnavailable:
                return .scopeUnavailable
            case .unsupportedScope(let detail):
                return .unsupportedConfiguration(detail)
            case .timedOut:
                return .timedOut
            case .emptyResult:
                return .streamFailed("捕获返回空结果")
            case .underlying(let detail):
                return .streamFailed(detail)
            }
        }
        if let streamError = error as? SCStreamError, streamError.code == .userDeclined {
            return .permissionDenied
        }
        return .streamFailed(error.localizedDescription)
    }
}

// MARK: - 帧输出

extension SCStreamRecorder: SCStreamOutput {

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .screen:
            handleVideoSample(sampleBuffer)
        case .audio:
            handleSystemAudioSample(sampleBuffer)
        default:
            // `.microphone` 为 macOS 15.0+，按 plan.md §3.1 决策 A 一律不走该路径
            // （麦克风统一由 AVFoundation 采集，保证 13.0 基线全版本一致）。
            break
        }
    }

    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock { stats.totalVideoSampleCount += 1 }

        // 只接受完整帧：首批回调可能给出内容不完整的帧
        guard CaptureSetup.isCompleteFrame(sampleBuffer) else {
            recordDiscardedVideoFrame()
            return
        }

        markFirstFrameIfNeeded()

        // 状态判定与交付都在 outputQueue 上（串行），且 `pause()`/`resume()`
        // 也派发到本队列，因此这里不会与它们交错。
        let activeWriter: MovieWriter? = lock.withLock {
            machine.state == .recording ? writer : nil
        }

        // 暂停或已停止：数据不入输出，计入丢弃而非静默吞掉
        guard let activeWriter else {
            recordDiscardedVideoFrame()
            return
        }

        // 计数放在交付之后：`videoFrameCount` 表示**真正被消费**的帧数。
        let accepted = activeWriter.consumeVideo(sampleBuffer)

        lock.withLock {
            if accepted {
                stats.videoFrameCount += 1
            } else {
                stats.discardedFrameCount += 1
            }
        }
    }

    private func handleMicrophoneSample(_ sampleBuffer: CMSampleBuffer) {
        let activeWriter: MovieWriter? = lock.withLock {
            machine.state == .recording ? writer : nil
        }
        guard let activeWriter else { return }

        if activeWriter.consumeMicrophone(sampleBuffer) {
            lock.withLock { stats.microphoneBufferCount += 1 }
        }
    }

    private func handleSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        let activeWriter: MovieWriter? = lock.withLock {
            machine.state == .recording ? writer : nil
        }
        guard let activeWriter else { return }

        if activeWriter.consumeSystemAudio(sampleBuffer) {
            lock.withLock { stats.systemAudioBufferCount += 1 }
        }
    }

    /// 首帧到达：`preparing` → `recording`，并撤销首帧超时。
    private func markFirstFrameIfNeeded() {
        let pendingTimeout: Task<Void, Never>? = lock.withLock {
            guard machine.state == .preparing else { return nil }
            machine.apply(.sessionReady)
            recorderLogger.notice("首帧到达")
            if firstFrameAt == nil {
                firstFrameAt = Date()
            }
            let pending = timeoutTask
            timeoutTask = nil
            return pending
        }

        pendingTimeout?.cancel()
    }

    private func recordDiscardedVideoFrame() {
        lock.withLock { stats.discardedFrameCount += 1 }
    }
}

// MARK: - 流状态

extension SCStreamRecorder: SCStreamDelegate {

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // 正常停止不会触发此回调；触发即表示流异常中断。
        // 契约（model.md §6）：保留已录内容，提示用户。
        recorderLogger.error(
            "stream stopped with error: \(String(describing: error), privacy: .public)"
        )
        noteFailure(.streamFailed(error.localizedDescription))
    }
}
