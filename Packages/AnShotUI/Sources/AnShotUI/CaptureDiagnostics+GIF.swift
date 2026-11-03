//
//  CaptureDiagnostics+GIF.swift
//
//  CaptureDiagnostics 按主题拆分的一部分（同一类型的多文件 extension）。
//
//  `-diagnoseGIF`：GIF 录制链路的端到端证据。
//
//  ── 为什么它需要独立入口 ────────────────────────────────────
//
//  `-diagnoseRecording -gif` 只做四件事（可解码 / 帧数≈一半 / 尺寸上限 /
//  文件大小仅记录），用的还是写死的默认档位。以下三条是本次新增的行为，
//  而**新增代码没有证据就是零证据**：
//
//  * 档位真的生效（含循环次数从产物里读回来，而不是自报）
//  * 到达时长上限**自动停止**（M2 挂着未验证项：超时自动停止未做专项测试）
//  * 转码失败时留下什么（M2 之前是「结果被丢弃 + 临时文件泄漏」）
//
//  另加两条不变量：产物路径不得覆盖已存在文件、导出内存峰值可回归。
//
//  判据刻意**严格**（帧数 ±2、边长精确到缩放值）：时长与帧率都是我们自己设的输入，
//  帧数就是个确定的数，「丢一半也算过」的判据几乎没有证据价值。
//  旧的宽松判据在 `-diagnoseRecording` 里原地不动——改它会让历史 MATCH 与当前判据
//  不可比（证据纪律要求结论可追溯）。
//

#if DEBUG

import AnShotCapture
import AnShotCore
@preconcurrency import AVFoundation
import AppKit
import Foundation
import ImageIO

extension CaptureDiagnostics {

    /// `-diagnoseGIF [-default|-custom|-autoStop|-pauseLimit|-fallback|-noOverwrite|-memory]`
    ///
    /// 不给子命令时**按顺序全跑**。任一 MISMATCH → 非零退出码（脚本可判读）。
    ///
    /// 用法：
    ///     open -n anShot.app --args -diagnoseGIF
    ///     open -n anShot.app --args -diagnoseGIF -autoStop
    static func runGIFDiagnostic() async {
        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            let padded = label.padding(toLength: 30, withPad: " ", startingAt: 0)
            logger.notice("""
                [gif-diag] \(padded, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        let args = CommandLine.arguments
        let selected = ["-default", "-custom", "-autoStop", "-pauseLimit", "-fallback", "-noOverwrite", "-memory"]
            .filter { args.contains($0) }
        let runAll = selected.isEmpty
        func wanted(_ flag: String) -> Bool { runAll || selected.contains(flag) }

        logger.notice("[gif-diag] 开始，子项=\(runAll ? "全部" : selected.joined(separator: ","), privacy: .public)")

        if wanted("-default") { await checkDefault(report: report) }
        if wanted("-custom") { await checkCustomTiers(report: report) }
        if wanted("-autoStop") { await checkAutoStop(report: report) }
        if wanted("-pauseLimit") { await checkPausedDurationLimit(report: report) }
        if wanted("-fallback") { await checkFallback(report: report) }
        if wanted("-noOverwrite") { await checkNoOverwrite(report: report) }
        if wanted("-memory") { await checkMemory(report: report) }

        logger.notice("[gif-diag] done，失败项=\(failed, privacy: .public)")
        try? await Task.sleep(nanoseconds: 600_000_000)
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: - 子项 1：默认档位（3 秒 / 12fps / 800px / 循环 0）

    /// 默认档位下的基本契约：可解码、帧数、尺寸、**循环 0**、画面非空白。
    private static func checkDefault(
        report: (_ label: String, _ measured: String, _ expected: String, _ ok: Bool) -> Void
    ) async {
        let settings = GIFSettings()
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "anshot-gif-diag-default.gif")
        try? FileManager.default.removeItem(at: url)

        let outcome = await runGIFSession(
            output: .gif(url, settings: settings),
            scope: .display(DisplayGeometry.mainDisplay()),
            recordSeconds: 3.0
        )

        guard case .success(let result) = outcome else {
            report("default: session", "\(outcome)", "成功产出 GIF", false)
            return
        }
        guard let probed = probeGIF(at: result.url) else {
            report("default: decodable", "nil", "可解码", false)
            return
        }

        let expectedFrames = Int(3.0 * Double(settings.frameRate))
        let expectedPlayback = min(result.duration, settings.maximumDuration)
        report("default: decodable", "true", "true", true)
        // 判时长而不是帧数：相同的相邻帧会被合并，帧数随画面是否在动而变。
        report(
            "default: playback duration",
            String(format: "%.2fs（%d 帧）", probed.playbackDuration, probed.frameCount),
            "实际录制时长 \(expectedPlayback)s±0.02s，帧数 ≤ \(expectedFrames + 2)",
            abs(probed.playbackDuration - expectedPlayback) <= 0.02
                && probed.frameCount <= expectedFrames + 2
        )
        let longest = max(probed.pixelSize.width, probed.pixelSize.height)
        report(
            "default: pixel size",
            "\(Int(probed.pixelSize.width))x\(Int(probed.pixelSize.height))",
            "任一边 ≤ \(settings.maximumPixelDimension)",
            longest <= CGFloat(settings.maximumPixelDimension) + 1
        )
        report(
            "default: loop count",
            probed.loopCount.map(String.init) ?? "无此项",
            "0（无限循环）",
            probed.loopCount == 0
        )
        report(
            "default: frame not blank",
            "\(probed.sampleHasVariation)",
            "true（全黑/全白均为 false）",
            probed.sampleHasVariation
        )
        report(
            "default: file size",
            String(format: "%.1fMB", Double(result.fileSize) / 1_048_576),
            "（记录项，不设阈值）",
            true
        )
        try? FileManager.default.removeItem(at: result.url)
    }

    // MARK: - 子项 2：非默认档位 + 区域范围

    /// 档位真的生效：6fps / 上限 2s / 320px / 循环 3，且用**区域范围**录制
    /// （顺带覆盖「缩放与范围正交」这一交互）。
    private static func checkCustomTiers(
        report: (_ label: String, _ measured: String, _ expected: String, _ ok: Bool) -> Void
    ) async {
        await checkDefault(report: report)

        let displayID = DisplayGeometry.mainDisplay()
        let rect = CGRect(x: 200, y: 150, width: 600, height: 400)
        let scale = DisplayGeometry.scaleFactor(for: displayID)
        let capturedPixel = CGSize(width: 600 * scale, height: 400 * scale)

        let settings = GIFSettings(maximumDuration: 2, maximumPixelDimension: 320, loopCount: 3)
        // 帧率不下沉到界面，但这里要验「非默认帧率也确实生效」，故直接构造。
        var custom = settings
        custom.frameRate = 6

        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "anshot-gif-diag-custom.gif")
        try? FileManager.default.removeItem(at: url)

        let outcome = await runGIFSession(
            output: .gif(url, settings: custom),
            scope: .region(displayID, rect: rect),
            recordSeconds: 3.0
        )

        guard case .success(let result) = outcome else {
            report("custom: session", "\(outcome)", "成功产出 GIF", false)
            return
        }
        guard let probed = probeGIF(at: result.url) else {
            report("custom: decodable", "nil", "可解码", false)
            return
        }

        // 上限 2s、帧率 6 → 2 秒 / 至多 12 帧。判据 ±1 帧：这是两个我们完全控制的输入相乘。
        report(
            "custom: playback duration",
            String(format: "%.2fs（%d 帧）", probed.playbackDuration, probed.frameCount),
            "2s±1 帧（6fps），帧数 ≤ 13",
            abs(probed.playbackDuration - 2.0) <= 1.0 / 6.0 && probed.frameCount <= 13
        )

        // 1200×800 → 等比缩到长边 320 → 320×213
        let expectedLongest: CGFloat = 320
        let ratio = min(capturedPixel.width, capturedPixel.height) / max(capturedPixel.width, capturedPixel.height)
        let expectedShortest = (expectedLongest * ratio).rounded()
        let longest = max(probed.pixelSize.width, probed.pixelSize.height)
        let shortest = min(probed.pixelSize.width, probed.pixelSize.height)
        report(
            "custom: scaled pixel size",
            "\(Int(probed.pixelSize.width))x\(Int(probed.pixelSize.height))",
            "\(Int(expectedLongest))x\(Int(expectedShortest))±1（源 \(Int(capturedPixel.width))x\(Int(capturedPixel.height))）",
            abs(longest - expectedLongest) <= 1 && abs(shortest - expectedShortest) <= 1
        )
        report(
            "custom: loop count",
            probed.loopCount.map(String.init) ?? "无此项",
            "3",
            probed.loopCount == 3
        )
        try? FileManager.default.removeItem(at: result.url)
    }

    // MARK: - 子项 3：到达时长上限自动停止

    /// 上限 2s，录 5 秒**且不调用 `stop()`**：会话应当自己结束。
    ///
    /// 判据用 `statistics.duration`（收尾时定格的权威值）而不是墙钟：
    /// 墙钟包含了停流与转码的时间，量到的不是「什么时候停的」。
    private static func checkAutoStop(
        report: (_ label: String, _ measured: String, _ expected: String, _ ok: Bool) -> Void
    ) async {
        let settings = GIFSettings(maximumDuration: 2)
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "anshot-gif-diag-autostop.gif")
        try? FileManager.default.removeItem(at: url)

        let outcome = await runGIFSession(
            output: .gif(url, settings: settings),
            scope: .display(DisplayGeometry.mainDisplay()),
            recordSeconds: 5.0,
            stopExplicitly: false
        )

        guard case .success(let result) = outcome else {
            report("autoStop: session", "\(outcome)", "自行结束并产出 GIF", false)
            return
        }

        report(
            "autoStop: ended without stop()",
            "\(result.terminatedWithoutStop)",
            "true",
            result.terminatedWithoutStop
        )
        report(
            "autoStop: recorder flag",
            "\(result.didReachDurationLimit)",
            "true",
            result.didReachDurationLimit
        )
        report(
            "autoStop: recorded duration",
            String(format: "%.2fs", result.duration),
            "2.0–2.6s",
            result.duration >= 2.0 && result.duration <= 2.6
        )
        if let probed = probeGIF(at: result.url) {
            // 播放时长应为 2s：偏长说明没停住；帧数至多 24（静止画面会合并成更少的帧）。
            report(
                "autoStop: playback duration",
                String(format: "%.2fs（%d 帧）", probed.playbackDuration, probed.frameCount),
                "2s±0.011s，帧数 ≤ 26",
                abs(probed.playbackDuration - 2.0) <= 0.011 && probed.frameCount <= 26
            )
        } else {
            report("autoStop: decodable", "nil", "可解码", false)
        }
        try? FileManager.default.removeItem(at: result.url)
    }

    /// 暂停时间不得计入 GIF 的有效录制时长上限。
    private static func checkPausedDurationLimit(
        report: (_ label: String, _ measured: String, _ expected: String, _ ok: Bool) -> Void
    ) async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anshot-gif-pause-limit-\(UUID()).gif")
        let recorder = SCStreamRecorder()
        let configuration = RecordingConfiguration(
            scope: .region(DisplayGeometry.mainDisplay(), rect: CGRect(x: 80, y: 80, width: 400, height: 280)),
            audio: AudioSettings(systemAudio: false, microphone: false),
            output: .gif(url, settings: GIFSettings(maximumDuration: 1.2))
        )
        let task = Task { try await recorder.record(configuration: configuration) }
        let started = await waitForRecordingState(recorder, target: .recording, timeout: 8)
        report("pauseLimit: started", "\(started)", "true", started)
        if started {
            try? await Task.sleep(for: .milliseconds(250))
            await recorder.pause()
            let pausedDuration = recorder.statistics.duration
            try? await Task.sleep(for: .milliseconds(1500))
            report("pauseLimit: stays paused", recorder.state.rawValue, "paused", recorder.state == .paused)
            let durationDelta = abs(recorder.statistics.duration - pausedDuration)
            report("pauseLimit: duration frozen", "\(durationDelta)", "<0.03s", durationDelta < 0.03)
            await recorder.resume()
        }
        let ended = await waitForCondition(timeout: 5) { recorder.state.isTerminal }
        report("pauseLimit: automatic end", "\(ended)", "true", ended)
        if !ended { await recorder.stop() }
        do {
            let result = try await task.value
            report("pauseLimit: duration flag", "\(recorder.didReachDurationLimit)", "true", recorder.didReachDurationLimit)
            report("pauseLimit: active duration", "\(result.duration)", "1.2–1.6s", result.duration >= 1.2 && result.duration <= 1.6)
            let playback = probeGIF(at: result.url)?.playbackDuration ?? 0
            report("pauseLimit: playback", "\(playback)", "1.2s±0.011s", abs(playback - 1.2) <= 0.011)
        } catch {
            report("pauseLimit: result", error.localizedDescription, "可解码 GIF", false)
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 子项 4：转码失败时留下什么

    /// 目标目录不可写 → GIF 转不出来，但**用户录到的东西不能因此消失**。
    ///
    /// 本场景刻意让目录整体不可写，因此**回退影片的移动也会失败**——
    /// 这正好覆盖「保留也失败」这条分支：此时必须如实给出临时路径，
    /// 而不是写一句「影片已保留」却给不出可用的文件。
    ///
    /// - Note: 「转码失败但回退影片移动**成功**」这条分支**未被自动化覆盖**：
    ///   它要求同一目录对 `.gif` 不可写而对 `.mp4` 可写，无法确定性地构造。
    ///   该限制已记录在 `docs/m2-recording/task.md` 的未验证项里。
    private static func checkFallback(
        report: (_ label: String, _ measured: String, _ expected: String, _ ok: Bool) -> Void
    ) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-gif-diag-readonly", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // r-x：可读可进入、不可写 → 既写不出 GIF，也移不进回退影片
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let target = directory.appendingPathComponent("anshot-gif-diag.gif")
        let outcome = await runGIFSession(
            output: .gif(target, settings: GIFSettings()),
            scope: .display(DisplayGeometry.mainDisplay()),
            recordSeconds: 2.0
        )

        guard case .failure(let failure_) = outcome else {
            report("fallback: session", "成功", "应当失败（目标不可写）", false)
            return
        }

        let reason = failure_.reason as? RecordingError
        let isGIFFailure: Bool
        if case .gifExportFailed = reason {
            isGIFFailure = true
        } else {
            isGIFFailure = false
        }
        report(
            "fallback: error is gifExportFailed",
            "\(String(describing: reason))",
            "gifExportFailed（不复用 writerFailed 的措辞）",
            isGIFFailure
        )

        guard let kept = failure_.keptOutput else {
            report("fallback: kept output", "nil", "临时影片仍在", false)
            return
        }
        report(
            "fallback: moved to target dir",
            "\(kept.isAtRequestedLocation)",
            "false（目标目录不可写，如实回报）",
            !kept.isAtRequestedLocation
        )
        let stillThere = FileManager.default.fileExists(atPath: kept.url.path)
        report("fallback: file exists", "\(stillThere)", "true", stillThere)
        let probed = await probeMovie(at: kept.url)
        report(
            "fallback: movie decodable",
            "\(probed != nil)",
            "true（录到的东西仍然可用）",
            probed != nil
        )
        // 清理：临时影片是真实产物，诊断结束后不留垃圾
        try? FileManager.default.removeItem(at: kept.url)
    }

    // MARK: - 子项 5：产物路径不得覆盖已存在文件

    /// 同秒连录两次会撞名，而两个写入器遇到同名文件都**先删再写**。
    ///
    /// 断言分两段：界面算出的路径必须绕开已占用的名字（`-2`），
    /// 且被绕开的那个文件**内容逐字节未变**——这才是「不覆盖」的真正含义。
    private static func checkNoOverwrite(
        report: (_ label: String, _ measured: String, _ expected: String, _ ok: Bool) -> Void
    ) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-gif-diag-nooverwrite", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 用独立的 UserDefaults suite：诊断不得污染真实保存设置
        let suiteName = "com.anshot.diagnostics.gifdir"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let settings = AppSettings(store: defaults)
        settings.setSaveFolder(directory)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 抢占「此刻」前后的三个时间戳文件名：defaultOutputURL 内部按当前秒生成名字，
        // 覆盖 ±1 秒就不会因为跨越秒边界而偶发不撞名。
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date()
        var sentinels: [URL] = []
        var sentinelBytes: [Data] = []
        for offset in -1...1 {
            let stamp = formatter.string(from: now.addingTimeInterval(TimeInterval(offset)))
            let url = directory.appendingPathComponent("anShot-录制-\(stamp).gif")
            let payload = Data("sentinel-\(offset)".utf8)
            try? payload.write(to: url)
            sentinels.append(url)
            sentinelBytes.append(payload)
        }

        let product = RecordingController.defaultOutputURL(for: settings, output: .gif(GIFSettings()))
        report(
            "noOverwrite: path avoids taken name",
            product.lastPathComponent,
            "…-2.gif（三个候选已被占用）",
            product.lastPathComponent.hasSuffix("-2.gif")
        )

        let outcome = await runGIFSession(
            output: .gif(product, settings: GIFSettings(maximumDuration: 15)),
            scope: .display(DisplayGeometry.mainDisplay()),
            recordSeconds: 1.5
        )
        report(
            "noOverwrite: product written",
            "\(outcome.isSuccess)",
            "true",
            outcome.isSuccess
        )

        var intact = true
        for (index, url) in sentinels.enumerated() {
            let current = (try? Data(contentsOf: url)) ?? Data()
            if current != sentinelBytes[index] { intact = false }
        }
        report(
            "noOverwrite: sentinels untouched",
            "\(intact)",
            "true（三个哨兵文件逐字节未变）",
            intact
        )
        try? FileManager.default.removeItem(at: product)
    }

    // MARK: - 子项 6：导出内存峰值

    /// 上限 15s 的长会话，按 0.5s 采样 `phys_footprint` 并记录**最大值**。
    ///
    /// **只记录、不设阈值**：先有数，再谈阈值。而且这个读数本身偏高
    /// （见 `footprintMB` 的注释：本进程读到 120.9MB 而外部 `footprint -p` 只有 32MB），
    /// 它的价值在于「这次比上次高了多少」这条趋势，而不是绝对值。
    private static func checkMemory(
        report: (_ label: String, _ measured: String, _ expected: String, _ ok: Bool) -> Void
    ) async {
        let settings = GIFSettings(maximumDuration: 15)
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "anshot-gif-diag-memory.gif")
        try? FileManager.default.removeItem(at: url)

        let peakBox = PeakBox()
        let sampler = Task {
            while !Task.isCancelled {
                peakBox.record(footprintMB())
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        let outcome = await runGIFSession(
            output: .gif(url, settings: settings),
            scope: .display(DisplayGeometry.mainDisplay()),
            recordSeconds: 15.0
        )
        sampler.cancel()

        guard case .success(let result) = outcome, let probed = probeGIF(at: result.url) else {
            report("memory: session", "\(outcome)", "成功产出 GIF", false)
            return
        }
        report(
            "memory: peak footprint",
            String(format: "%.1fMB", peakBox.peak),
            "（仅记录；绝对值须以外部 `footprint -p` 为准）",
            peakBox.peak > 0
        )
        report(
            "memory: 15s playback",
            String(format: "%.2fs（%d 帧）", probed.playbackDuration, probed.frameCount),
            "15s±2 帧（12fps），帧数 ≤ 182",
            abs(probed.playbackDuration - 15.0) <= 2.0 / 12.0 && probed.frameCount <= 182
        )
        report(
            "memory: file size",
            String(format: "%.1fMB", Double(result.fileSize) / 1_048_576),
            "（记录项）",
            true
        )
        try? FileManager.default.removeItem(at: result.url)
    }

    // MARK: - 会话夹具

    /// 一轮 GIF 会话的产出摘要。
    private struct GIFSessionSummary {
        let url: URL
        let duration: TimeInterval
        let fileSize: Int64
        /// 会话是否在**我们没有调用 `stop()`** 的情况下自行结束。
        let terminatedWithoutStop: Bool
        /// 录制器是否报告「到达时长上限」。
        let didReachDurationLimit: Bool
    }

    /// 一轮 GIF 会话的失败摘要。
    private struct GIFSessionFailure {
        let reason: Error
        let keptOutput: KeptRecording?
    }

    private enum GIFSessionOutcome {
        case success(GIFSessionSummary)
        case failure(GIFSessionFailure)

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    /// 跑一轮录制会话（直接驱动录制器，不经界面）。
    ///
    /// - Parameters:
    ///   - output: 输出目标。
    ///   - scope: 录制范围。
    ///   - recordSeconds: 起流成功后等待多久。
    ///   - stopExplicitly: 是否调用 `stop()`。传 false 用于验证「上限自动停止」；
    ///     此时等待会话自行终结，并设 15 秒兜底（否则诊断会挂在一条活着的流上）。
    private static func runGIFSession(
        output: RecordingOutput,
        scope: CaptureScope,
        recordSeconds: TimeInterval,
        stopExplicitly: Bool = true
    ) async -> GIFSessionOutcome {
        let recorder = SCStreamRecorder()
        let configuration = RecordingConfiguration(
            scope: scope,
            video: VideoSettings(frameRate: 30, codec: .h264, showsCursor: true),
            // 刻意**打开两路音频**：GIF 无音轨，归一化必须在这里生效
            // （否则会白申请一次麦克风权限、白跑一路系统声音捕获）。
            audio: AudioSettings(systemAudio: true, microphone: true),
            output: output
        )

        logger.notice("""
            [gif-diag] 起流：output=\(output.isGIF ? "gif" : "movie", privacy: .public) \
            录 \(recordSeconds, privacy: .public)s stopExplicitly=\(stopExplicitly, privacy: .public)
            """)

        let task = Task { try await recorder.record(configuration: configuration) }
        _ = await waitForRecordingState(recorder, target: .recording, timeout: 8)
        try? await Task.sleep(nanoseconds: UInt64(max(0, recordSeconds) * 1_000_000_000))

        var terminatedWithoutStop = false
        if stopExplicitly {
            await recorder.stop()
        } else {
            terminatedWithoutStop = await waitForCondition(timeout: 15) { recorder.state.isTerminal }
            if !terminatedWithoutStop { await recorder.stop() }
        }

        do {
            let result = try await task.value
            return .success(GIFSessionSummary(
                url: result.url,
                duration: result.duration,
                fileSize: result.fileSize,
                terminatedWithoutStop: terminatedWithoutStop,
                didReachDurationLimit: recorder.didReachDurationLimit
            ))
        } catch {
            return .failure(GIFSessionFailure(reason: error, keptOutput: recorder.keptOutput))
        }
    }

    /// 内存采样的可变盒子。
    ///
    /// 采样任务与主流程并发，因此需要一层串行化。用锁而不是 actor：
    /// 采样点是同步函数（`task_info`），而 actor 的存取需要 await，
    /// 会把采样循环变成「等待—采样—等待」的形态，采样间隔不再可信。
    private final class PeakBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0

        func record(_ sample: Double) {
            lock.withLock { value = max(value, sample) }
        }

        var peak: Double {
            lock.withLock { value }
        }
    }
}

#endif
