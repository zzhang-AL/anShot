//
//  ScrollshotController.swift
//  AnShotUI
//
//  滚动截图会话：抓帧循环 → 廉价变化检测 → 世界坐标追踪 → 拼接。
//
//  ── 为什么是「手动滚动」 ──────────────────────────────────
//
//  自动滚动要向系统投递合成的滚轮事件（`CGEvent.post(tap:)`），而那需要
//  **辅助功能权限**；本机实测未授权（见 auto-detect 的实测记录），也不该为了
//  长截图向用户再要一个权限。所以会话由用户自己滚动：
//  我们只负责按帧变化自适应采样，用户滚到哪就采到哪。
//
//  ── 「自适应」的含义 ──────────────────────────────────────
//
//  定时抓帧但不盲目处理：每一帧先与上一帧做**廉价抽样比较**，
//  画面没变就整帧跳过——连配准都不跑。只有真的变了才交给
//  `ScrollshotSession` 做配准与采纳决策。
//
//  ── 「上下滚动不反复采集」由谁保证 ────────────────────────
//
//  不由本文件保证，而是 `ScrollshotSession`：它拿相邻两帧配准出**有符号**的位移，
//  据此维护世界坐标。回滚帧与「回到已覆盖区」的帧在进入输出之前就被拦下，
//  既不会让最终拼接重复跑一遍配准，也不会占像素内存。
//  本文件只负责「按帧变化抓取」与「把结论转成界面」。
//
//  ── 会话期间画面可见性 ────────────────────────────────────
//
//  截图覆盖层必须隐藏：它盖住的是用户要滚的那个窗口，不隐藏就没法滚。
//  进度浮层则要留在屏幕上，且**不抢焦点**（用户还要继续滚下层应用）。
//

import AnShotCapture
import AnShotCore
import AppKit

/// 一次滚动截图会话。
@MainActor
final class ScrollshotController {

    /// 会话结果。
    struct Outcome {
        /// 拼好的长图；失败时为 nil。
        let image: CGImage?
        /// 逐帧决策记录（用于把「哪一帧因为什么被丢」交代给用户）。
        let plan: ScrollStitcher.Plan?
        /// 失败原因；成功时为 nil。
        let failure: String?
        /// 实际**采纳**进长图的帧数（不含被拦下的回滚、重复、瞬态帧）。
        let capturedFrames: Int
        /// 会话期间共抓取并提交了多少帧（含被拦下的）——诊断用，能看出回滚比例。
        let observedFrames: Int
        /// 收尾时是否仍未恢复对齐；已经采集的连续内容仍可保存。
        let stalled: Bool
    }

    /// 会话触到的上限。
    ///
    /// 与 `onStall` 是**两回事**，文案必须分开：
    ///
    /// * **上限**——已经采够了，该收尾（长图可用）；
    /// * **跟丢**——暂停收录，回滚到重叠内容可恢复（已采内容仍可保存）。
    ///
    /// 混成一句会把「可以点完成保存」说成「请重新开始」，让用户白丢一张
    /// 其实能用的长图。
    enum Limit {
        /// 输出高度上限（长图不能无限长：内存是 宽×高×4）。
        case outputHeight(Int)
        /// 抓帧数上限。
        case frameCount(Int)
    }

    /// 进度回调：已采纳帧数、已覆盖高度（像素）。
    var onProgress: ((Int, Int) -> Void)?
    /// 首帧已经抓到，可以开始滚动；避免冷启动时尚未建立基准就滚出一屏。
    var onReady: (() -> Void)?
    /// 预览回调：**整幅长图**的导航缩略图 + 当前位置标记 + 放大栏所需的坐标基准。
    ///
    /// 只在带来新内容、且距上次预览超过节流间隔时触发；首帧之前或生成失败为 nil。
    var onPreview: ((ScrollshotPreviewContent?) -> Void)?
    /// 结束回调（完成或失败）。
    var onFinish: ((Outcome) -> Void)?
    /// 跟丢回调（**会话进行中**，不是结束时的 `Outcome.stalled`）。
    ///
    /// 只在状态变化时上报，提示用户回滚到已采内容。
    var onStall: (() -> Void)?
    /// 重新对齐到已知内容，引导语恢复为正常滚动。
    var onRecovery: (() -> Void)?
    /// 触到上限回调（高度或帧数），每种各报一次。
    ///
    /// 它有存在的必要：高度到顶之后帧虽被拒收，但**配准本身仍然成功**，
    /// 所以这个状态既不会走 `onStall`、也不会让长图增长——用户继续滚却看不到
    /// 任何反应，只能怀疑「是不是卡了」。
    var onLimitReached: ((Limit) -> Void)?

    private let capturer: ScreenCapturing
    private let selection: PixelRect
    private let displayID: CGDirectDisplayID
    private let scaleFactor: CGFloat
    private let options: ScrollStitcher.Options
    /// 增长轴。会话内部永远按**竖直**工作，横向靠出入口转置映射。
    private let axis: ScrollAxis

    /// 世界坐标追踪与采纳决策——会话的唯一状态持有者。
    private var session: ScrollshotSession
    /// 上一提交的帧，用于廉价变化检测。
    private var lastSubmitted: ScrollshotImage?
    private var captureTask: Task<Void, Never>?
    /// 旧会话异步返回时不能提交到取消后重新启动的会话。
    private var sessionGeneration = 0
    private var isRunning = false
    private var isFinishing = false
    private var returnedWhileFinishing: CapturedFrame?
    private var captureFailure: String?
    /// 当前是否有一个 `tick` 正在执行。
    ///
    /// 自动采样与诊断调用都不能交错提交，否则会破坏世界坐标的先后顺序。
    /// `internal` 以便测试直接并发调用两次来验证闸门。
    private(set) var isTicking = false
    /// 当前暂停状态是否已上报；恢复后清零，避免每帧重复提示。
    private var hasReportedStall = false
    /// 高度 / 帧数上限是否已各报过一次。
    private var hasReportedHeightLimit = false
    private var hasReportedFrameLimit = false
    private var lastPreviewAt = Date.distantPast
    private var lastSubmittedAt = ContinuousClock.now
    private var nextCaptureInterval: TimeInterval

    /// 变化检测阈值：抽样比较的平均通道差超过它才进入配准。
    ///
    /// 定得太低会把鼠标悬停动画、光标闪烁这类噪声当成滚动；
    /// 定得太高则会漏掉缓慢滚动。3 是实测下的折中。
    private static let changeThreshold = 3.0

    /// 目标抓帧间隔（秒）。默认最高 30 Hz，实际速率受抓帧与配准耗时约束。
    ///
    /// 实例化而非 `static`：测试需要注入一个远大于用例时长的间隔，
    /// 让自动采样在断言窗口内不触发，从而把「并发调用 `tick`」的影响隔离出来
    /// —— 否则闸门测试会被定时器自己的合法调用污染。
    private let frameInterval: TimeInterval

    /// 抓帧数上限：即使内容一直在变，也不无限抓下去。
    /// 输出本身的硬边界在 `ScrollStitcher.Options.maxOutputHeight`。
    private static let maxFrames = 1200
    /// 回看已采内容不占图像内存，允许更多观察帧，但日志元数据仍有上限。
    private static let maxObservedFrames = 1200

    /// 预览节流间隔。预览要跑一次降采样，比配准便宜，但也没必要每帧都做。
    private static let previewInterval: TimeInterval = 0.15

    /// 导航缩略图的像素框：取进度浮层导航区在 2x 屏上的物理尺寸。
    ///
    /// 缩略图按它**等比 contain**：长图很长时会窄成一条，那是「整幅可见」的必然
    /// 结果，细节由浮层的放大栏按需取原图切片补上（见 `detailImage`）。
    private static let navigatorWidth = Int(ScrollshotProgressBar.navigatorPixelSize.width)
    private static let navigatorHeight = Int(ScrollshotProgressBar.navigatorPixelSize.height)

    init(
        capturer: ScreenCapturing,
        selection: PixelRect,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat,
        options: ScrollStitcher.Options? = nil,
        axis: ScrollAxis = .vertical,
        frameInterval: TimeInterval = 1.0 / 30
    ) {
        self.capturer = capturer
        self.selection = selection
        self.displayID = displayID
        self.scaleFactor = scaleFactor
        self.axis = axis
        self.frameInterval = frameInterval
        self.nextCaptureInterval = frameInterval
        // 保留完整选区，在对齐的重叠内容中接缝；不自动裁掉侧栏或窗口界面。
        let resolved = options ?? ScrollStitcher.Options(joinsInsideOverlap: true, retainsSourceFrames: false)
        self.options = resolved
        self.session = ScrollshotSession(options: resolved)
    }

    /// 开始会话：先抓首帧，然后按间隔轮询。
    func start() {
        guard !isRunning else { return }
        isRunning = true
        captureFailure = nil
        sessionGeneration += 1
        let generation = sessionGeneration
        // 日志分段：一次长截图 == 一次会话，异常时能把多次会话区分开。
        ScrollshotLogStore.shared.beginSession()
        captureTask = Task { [weak self] in
            guard let self else { return }
            await self.captureInitialFrame()
            guard self.isRunning, self.sessionGeneration == generation, !Task.isCancelled else { return }
            // 首次续抓也遵守注入的间隔，避免与就绪回调后的诊断调用争用闸门。
            do {
                try await Task.sleep(for: .seconds(self.frameInterval))
            } catch {
                return
            }
            // 串行续抓，不让慢帧碰到定时器刻度后再额外空等一个周期。
            while self.isRunning, self.sessionGeneration == generation, !Task.isCancelled {
                let began = ContinuousClock.now
                await self.tick()
                let remaining = (self.capturer is ScrollshotFrameCapturer ? .zero : Duration.seconds(self.nextCaptureInterval))
                    - began.duration(to: ContinuousClock.now)
                if remaining > .zero {
                    do {
                        try await Task.sleep(for: remaining)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    /// 结束并拼接。
    func finish(waitForCaptureTask: Bool = true) async {
        guard isRunning else { return }
        let generation = sessionGeneration
        isFinishing = true
        isRunning = false
        let activeTask = captureTask
        captureTask?.cancel()
        captureTask = nil

        if let buffered = capturer as? ScrollshotFrameCapturer {
            let pending = await buffered.stopAndDrain()
            if waitForCaptureTask { await activeTask?.value }
            guard sessionGeneration == generation else { return }
            let frames = (returnedWhileFinishing.map { [$0] } ?? []) + pending
            returnedWhileFinishing = nil
            for frame in frames where session.decisions.count < Self.maxObservedFrames {
                processCapturedFrame(frame, began: Date())
            }
            let dropped = await buffered.droppedFrames
            ScrollshotLogStore.shared.appendEvent("capture-buffer 峰值=\(await buffered.peakBufferedFrames) 丢弃=\(dropped)")
        }
        // 取消可能发生在「停止抓帧 / 排空缓冲」的 await 期间：`cancel()` 会递增
        // `sessionGeneration`，此处必须再确认一次。结果已作废时不能发预览，更不能
        // 调用 `onFinish`——它会把长图写进剪贴板（调用方在 OverlayController）。
        guard sessionGeneration == generation else { return }
        isFinishing = false
        // 收尾不受节流影响，导航和明细的坐标必须覆盖刚处理完的最后几帧。
        lastPreviewAt = .distantPast
        emitPreviewIfDue()

        let result = session.result()
        // 会话收尾摘要：排查时先看这一行，就知道那次会话拼了多少帧、有没有跟丢。
        let frameCount = session.acceptedFrameCount
        let observed = session.decisions.count
        let stalled = session.isStalled
        ScrollshotLogStore.shared.appendEvent(
            "session-finish 采纳=\(frameCount) 观察=\(observed) 输出高=\(result.image?.height ?? 0) 跟丢=\(stalled)"
        )
        // 会话产出的是**会话空间**的长图（横向时躺倒），归还原方向再交给界面。
        let image = result.image
            .flatMap { convertAxis($0) }
            .flatMap { Self.makeCGImage(from: $0) }
        onFinish?(Outcome(
            image: image,
            plan: result.plan,
            failure: captureFailure ?? result.failure.map(String.init(describing:)),
            capturedFrames: session.acceptedFrameCount,
            observedFrames: session.decisions.count,
            stalled: stalled
        ))
    }

    /// 取消：不产出结果。
    ///
    /// `isFinishing` 为 true 时也必须生效：用户点「完成」后排空缓冲、拼接与编码
    /// 需要时间，这期间进度浮层仍在、按钮仍可点。若这里因 `isRunning == false`
    /// 直接返回，收尾流程会照常调用 `onFinish`，把用户明确取消掉的长图写进剪贴板
    /// （写剪贴板的代码在 OverlayController，本类只能靠「不回调」来拦住它）。
    ///
    /// 递增 `sessionGeneration` 是让仍在进行的 `finish` 在任一 await 之后认出
    /// 结果已作废并直接返回。
    func cancel() {
        guard isRunning || isFinishing else { return }
        isRunning = false
        isFinishing = false
        sessionGeneration += 1
        captureTask?.cancel()
        captureTask = nil
        returnedWhileFinishing = nil
        if let buffered = capturer as? ScrollshotFrameCapturer {
            Task { _ = await buffered.stopAndDrain() }
        }
        ScrollshotLogStore.shared.appendEvent("session-cancel 用户取消")
        session = ScrollshotSession(options: options)
        lastSubmitted = nil
    }

    // MARK: - 抓帧

    private var scope: CaptureScope {
        // `region` 的 rect 是**逻辑点**，选区模型是像素。
        let logical = CGRect(
            x: CGFloat(selection.origin.x) / scaleFactor,
            y: CGFloat(selection.origin.y) / scaleFactor,
            width: CGFloat(selection.size.width) / scaleFactor,
            height: CGFloat(selection.size.height) / scaleFactor
        )
        return .region(displayID, rect: logical)
    }

    // MARK: - 轴向转换

    /// 屏幕空间 ↔ 会话空间的轴向转换。
    ///
    /// 转置是**自逆**的（转两次回到原图），所以入口与出口共用这一个方法：
    /// 横向模式下它把「宽图」变成「高图」交给会话，也把会话产出的「高图」
    /// 变回「宽图」交给界面；竖直模式下两者都是恒等。
    ///
    /// 返回可选：转置要分配一整块新缓冲，内存吃紧时可能失败。
    /// 失败必须走各自的错误路径，**不能退化成「不转置」**——那会让横向会话
    /// 把宽图当高图用，世界坐标与输出尺寸全错。
    private func convertAxis(_ image: ScrollshotImage) -> ScrollshotImage? {
        axis == .horizontal ? image.transposed() : image
    }

    private func captureInitialFrame() async {
        let generation = sessionGeneration
        let frame = try? await capturer.captureFrame(scope: scope)
        guard isRunning, sessionGeneration == generation, !Task.isCancelled else { return }
        guard let frame,
              let raw = ScrollshotImage(frame.image),
              let image = convertAxis(raw) else {
            isRunning = false
            if let buffered = capturer as? ScrollshotFrameCapturer { _ = await buffered.stopAndDrain() }
            onFinish?(Outcome(
                image: nil, plan: nil, failure: "首帧抓取失败",
                capturedFrames: 0, observedFrames: 0, stalled: false
            ))
            return
        }
        lastSubmitted = image
        lastSubmittedAt = .now
        // 帧录制改为**运行时开关**（`-recordFrames` / `-recordAllFrames`）：Release
        // 构建下也能留证据，而 Debug 构建里配准要 437ms/帧、根本不适合日常使用。
        ScrollshotFrameRecorder.begin()
        let firstDecision = session.submit(image)
        recordFrame(image, index: firstDecision.inputIndex, decision: firstDecision)
        onReady?()
        onProgress?(session.acceptedFrameCount, session.coveredWorldHeight)
        emitPreviewIfDue()
    }

    /// 单次采样。
    ///
    /// `internal` 而非 `private`：单飞闸门是这类「定时器 + async」结构最容易
    /// 破的一处不变式，测试需要能直接并发调用两次来验证它确实拦住了第二个。
    func tick() async {
        // 自动循环串行执行；诊断直接调用 tick 时仍须避免两个异步抓帧乱序提交。
        guard isRunning, !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        let generation = sessionGeneration
        let began = Date()

        guard session.acceptedFrameCount < Self.maxFrames,
              session.decisions.count < Self.maxObservedFrames else {
            // 「帧数到顶」不是跟丢：已经采够了，该收尾而不是重来。
            if !hasReportedFrameLimit {
                hasReportedFrameLimit = true
                onLimitReached?(.frameCount(session.acceptedFrameCount >= Self.maxFrames
                    ? Self.maxFrames : Self.maxObservedFrames))
            }
            await finish(waitForCaptureTask: false)
            return
        }
        let frame: CapturedFrame
        do {
            frame = try await capturer.captureFrame(scope: scope)
        } catch {
            guard isRunning, sessionGeneration == generation, !Task.isCancelled else { return }
            AnShotLog.capture.error("scrollshot frame failed: \(error.localizedDescription, privacy: .public)")
            if capturer is ScrollshotFrameCapturer {
                // 预取器失败后已经关闭，不能在零等待循环里不断读取同一个错误。
                captureFailure = error.localizedDescription
                ScrollshotLogStore.shared.appendEvent("capture-failed \(error.localizedDescription)")
                await finish(waitForCaptureTask: false)
            }
            return
        }
        if isFinishing, sessionGeneration == generation {
            returnedWhileFinishing = frame
            return
        }
        guard isRunning, sessionGeneration == generation, !Task.isCancelled else { return }
        processCapturedFrame(frame, began: began)
    }

    private func processCapturedFrame(_ frame: CapturedFrame, began: Date) {
        guard let raw = ScrollshotImage(frame.image), let image = convertAxis(raw) else { return }

        // 廉价变化检测：画面没变就整帧跳过，连配准都不跑。
        if let previous = lastSubmitted, !Self.isDifferent(previous, image) {
            nextCaptureInterval = max(frameInterval, 0.125)
            emitPreviewIfDue()
            return
        }
        lastSubmitted = image

        let alignmentBegan = Date()
        let decision = session.submit(image)
        let now = ContinuousClock.now
        let elapsed = lastSubmittedAt.duration(to: now)
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        lastSubmittedAt = now
        if decision.verdict == .unresolved {
            // 未对齐时尽快保留后续重叠，不再继续拉大与可信参考帧的间距。
            nextCaptureInterval = frameInterval
        } else if decision.deltaY != 0 {
            // 让相邻采样的预期位移保持在约 1/5 屏；慢滚回到 8 Hz，快滚最高 30 Hz。
            let target = elapsedSeconds * Double(image.height) / (5 * Double(abs(decision.deltaY)))
            nextCaptureInterval = max(frameInterval, min(max(frameInterval, 0.125), target))
        }
        AnShotLog.capture.notice("""
            scrollshot timing: frame=\(decision.inputIndex, privacy: .public) \
            prepare=\(Int(alignmentBegan.timeIntervalSince(began) * 1000), privacy: .public)ms \
            align=\(Int(Date().timeIntervalSince(alignmentBegan) * 1000), privacy: .public)ms \
            verdict=\(decision.verdict.rawValue, privacy: .public)
            """)
        recordFrame(image, index: decision.inputIndex, decision: decision)
        // 跟丢要当场告诉用户，并只报一次。
        if decision.stalled, !hasReportedStall {
            hasReportedStall = true
            onStall?()
        } else if hasReportedStall, !session.isStalled {
            hasReportedStall = false
            onRecovery?()
        }
        // 高度到顶单独判：帧被拒收但配准成功，所以它不会表现为 `stalled`。
        if session.coveredWorldHeight >= options.maxOutputHeight, !hasReportedHeightLimit {
            hasReportedHeightLimit = true
            onLimitReached?(.outputHeight(options.maxOutputHeight))
        }
        guard decision.isAccepted else { return }
        onProgress?(session.acceptedFrameCount, session.coveredWorldHeight)
        emitPreviewIfDue()
    }

    var retainedPixelBytesForDiagnostics: Int { session.retainedPixelBytes }

    /// 诊断：把本帧的结论写成一行，并在「可疑帧」时把画面也落盘。
    ///
    /// 可疑 = 没有被直接采纳，或者位移由 Vision 翻案。这些帧才是问题现场；
    /// 正常推进的帧只留一行日志，避免几十帧 PNG 编码拖慢采集。
    ///
    /// 未开启录制时**在构造诊断字符串之前就返回**：Release 构建下这条路径要
    /// 逐帧走，拼接字符串与写盘都不该出现在默认使用路径上。
    private func recordFrame(_ image: ScrollshotImage, index: Int, decision: ScrollshotSession.Decision) {
        // 翻转求解的帧也算可疑：它是「正向解不出来」时走的备用路径，
        // 需要能回看实际画面判断「到底救回了哪一帧、救得对不对」。
        let suspicious = !decision.isAccepted
            || decision.visionArbitrated
            || decision.matchSource == .flippedKernel

        // ── UI 日志：**无条件**写入 ──────────────────────────
        //
        // 与下面的帧录制分开：录制要写 PNG、开销大，所以有开关；
        // 而逐帧结论只是往内存环形缓冲里填空，代价可忽略，却是用户
        // 事后排查断层**唯一**的入口（他不可能为了这一刻事先开 -recordFrames）。
        // 所以不能把它放在 `ScrollshotFrameRecorder.isEnabled` 之后。
        ScrollshotLogStore.shared.appendFrame(
            index: index,
            decision: decision,
            coveredHeight: session.coveredWorldHeight,
            suspicious: suspicious
        )

        guard ScrollshotFrameRecorder.isEnabled else { return }
        // 拆成多个短表达式：拼成一个长串会让类型检查器超时。
        let confidence = String(format: "%.3f", decision.confidence)
        let sourceY = decision.sourceY.map(String.init) ?? "-"
        let coveredHeight = session.coveredWorldHeight
        let warnings = decision.warnings.joined(separator: " | ")
        let parts = [
            "verdict=\(decision.verdict)",
            "d=\(decision.deltaY)",
            "c=\(confidence)",
            "world=\(decision.worldOffset)",
            "sourceY=\(sourceY)",
            "rows=\(decision.acceptedRows)",
            "sticky=\(decision.stickyRows)",
            "coveredStart=\(session.coveredWorldStart)",
            "coveredEnd=\(session.coveredWorldEnd)",
            "coveredHeight=\(coveredHeight)",
            "vision=\(decision.visionArbitrated)",
            "src=\(decision.matchSource?.rawValue ?? "-")",
            "warnings=[\(warnings)]"
        ]
        let note = parts.joined(separator: " ")
        ScrollshotFrameRecorder.record(image, index: index, note: note, saveImage: suspicious)
    }

    /// 按节流频率生成一次预览：整幅导航缩略图 + 当前位置。
    private func emitPreviewIfDue() {
        guard onPreview != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPreviewAt) >= Self.previewInterval else { return }
        lastPreviewAt = now

        guard let preview = session.preview(
            fittingWidth: Self.navigatorWidth,
            fittingHeight: Self.navigatorHeight
        ), let cgImage = Self.makeCGImage(from: preview.image) else {
            onPreview?(nil)
            return
        }
        // ── 预览**不**做轴向转换（与导出、放大栏相反）───────────
        //
        // 导航区是一个竖长的容器（浮层里 84×244），它的「纵向」就是**世界轴**：
        // 定位框按 y 拖、按 worldStart/worldHeight 换算。
        //
        // 会话空间的图天然就是「沿纵向增长」的：
        // * 竖向会话：会话空间 == 屏幕空间，直接吻合；
        // * 横向会话：会话空间是屏幕转置后的样子（宽 = 屏幕高，高 = 世界长度），
        //   同样沿纵向增长。
        //
        // 所以这里**不能**调 `convertAxis`：一旦把横向长图转回「宽而晶」的显示
        // 方向，它会被 contain 成一条几像素高的线（5000×200 缩进 84×244 只剩
        // 3.4 点高），导航区等于作废；而定位框的「行」与缩略图的「y」也不再
        // 对应，拖动会错位。
        //
        // 代价是横向时缩略图内容侧躺。这是有意的取舍：导航区回答问题
        // 「整体到哪了、我在哪一段」，内容的可读性由右侧放大栏负责——
        // 而放大栏的切片是**转回正向**的（见 `detailImage`）。
        onPreview?(ScrollshotPreviewContent(
            navigatorImage: cgImage,
            navigatorPixelWidth: preview.image.width,
            navigatorPixelHeight: preview.image.height,
            worldWidth: preview.worldWidth,
            worldStart: preview.worldStart,
            worldHeight: preview.worldHeight,
            viewportWorldRows: preview.viewportWorldRows
        ))
    }

    /// 取长图中某段世界行的原图切片，供浮层的放大栏显示。
    ///
    /// 会话进行中由用户**拖动定位框**连续触发，所以这里只做一次 `slice` +
    /// 一次 `CGImage` 构造，不做任何缓存——切片本身就是最近邻采样，重复缓存的
    /// 收益抵不上它带来的失效判断复杂度。
    func detailImage(worldRows: Range<Int>, targetWidth: Int) -> CGImage? {
        // ── 横向时切片宽度取「视口高」而不是详情区宽 ──────────
        //
        // `slice` 的 `targetWidth` 是**会话空间**的宽：竖向时它就等于屏幕宽，
        // 传详情区宽即可；横向时会话空间的宽是**屏幕高**（两者在转置后互换），
        // 传详情区宽会把它横向拉伸/压缩一次，转置回来后就是纵向形变。
        //
        // 传视口高（像素）才能让切片保持等比：切片宽 = 屏幕高，转置后即
        // 「高 = 屏幕高、宽 = 世界列数」，正是横向长截图该有的比例。
        let sliceWidth = axis == .horizontal
            ? max(1, Int(selection.size.height))
            : targetWidth
        guard let slice = session.slice(worldRows: worldRows, targetWidth: sliceWidth) else {
            return nil
        }
        // 切片是会话空间，横向时转回正向再显示（与预览相反：内容要看得懂）。
        guard let oriented = convertAxis(slice) else { return nil }
        return Self.makeCGImage(from: oriented)
    }

    /// 廉价变化检测：抽样比较（不进入配准）。
    static func isDifferent(_ a: ScrollshotImage, _ b: ScrollshotImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return true }
        let stepY = max(1, a.height / 128)
        let stepX = max(1, a.width / 96)
        var sum = 0
        var count = 0
        var changed = 0
        a.withPixels { pa in
            b.withPixels { pb in
                var y = 0
                while y < a.height {
                    var x = 0
                    while x < a.width {
                        let index = (y * a.width + x) * 4
                        // 拆成独立语句：把三通道差写成一个多行 + 表达式时，
                        // 编译器在两层嵌套闭包里会推断超时（实测报
                        // "unable to type-check this expression in reasonable time"）。
                        let d0 = abs(Int(pa[index]) - Int(pb[index]))
                        let d1 = abs(Int(pa[index + 1]) - Int(pb[index + 1]))
                        let d2 = abs(Int(pa[index + 2]) - Int(pb[index + 2]))
                        sum += d0 + d1 + d2
                        if d0 + d1 + d2 > 45 { changed += 1 }
                        count += 1
                        x += stepX
                    }
                    y += stepY
                }
            }
        }
        guard count > 0 else { return false }
        // 稀疏文字不能被大片共同背景稀释；旧 24×24 网格会整帧漏掉真实滚动，
        // 等下一帧再提交时已经跨过重叠范围。保留绝对数量下限以过滤小光标闪烁。
        return Double(sum) / Double(count) / 3 > changeThreshold
            || changed >= max(8, count / 500)
    }

    private static func makeCGImage(from image: ScrollshotImage) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var buffer = image.data
        return buffer.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }
}
