//
//  CaptureDiagnostics+Recording.swift
//
//  CaptureDiagnostics 按主题拆分的一部分（同一类型的多文件 extension）。
//  纯机械拆分：函数体未改动。
//

#if DEBUG

import AnShotCapture
import AnShotCore
@preconcurrency import AVFoundation
import AppKit
import ImageIO
import Carbon.HIToolbox
@preconcurrency import ScreenCaptureKit
import Foundation

extension CaptureDiagnostics {

    /// `-diagnoseRecording [-sessions N] [-duration S] [-scopeRegion]`
    ///
    /// 验证 M2-1：连续起流并把结果写成可播放的 MP4。
    /// 每轮都重新打开产出文件读取时长与尺寸——**不采信写入过程中的自报值**，
    /// 否则「写入器说成功」与「文件真的可读」会被混为一谈。
    ///
    /// 轮间**不留延迟**：连续启动正是需要验证的场景。
    static func runRecordingDiagnostic() async {
        let args = CommandLine.arguments
        let sessions = parseIntArgument(args, "-sessions") ?? 3
        let duration = parseNamedDoubleArgument(args, "-duration") ?? 2.0
        // 重叠停止验证：验证重复 stop() 会等待同一次收尾完成。
        let doubleStop = args.contains("-doubleStop")
        // 范围框排除验证：录制期间显示范围框，检查它是否进入成片。
        let frameExclusion = args.contains("-frameExclusion")
        let displayID = DisplayGeometry.mainDisplay()

        // 范围解析。窗口/应用需要先查询可共享内容才能确定目标，
        // 且期望的输出尺寸必须在此刻一并算出——窗口会移动、缩放，
        // 事后再查一次得到的尺寸可能已经不同。
        let scope: CaptureScope
        let expectedPixelSize: CGSize
        if args.contains("-scopeRegion") {
            let rect = CGRect(x: 200, y: 150, width: 600, height: 400)
            let scale = DisplayGeometry.scaleFactor(for: displayID)
            scope = .region(displayID, rect: rect)
            expectedPixelSize = CGSize(width: 600 * scale, height: 400 * scale)
        } else if args.contains("-scopeWindow") {
            guard let picked = await pickLargestWindow() else {
                logger.error("[recording-diag] 找不到可用于验证的窗口（需存在一个可见的、非本进程的窗口）")
                exit(2)
            }
            scope = .window(picked.windowID)
            expectedPixelSize = picked.pixelSize
            logger.notice("""
                [recording-diag] 选中窗口 #\(picked.windowID, privacy: .public) \
                「\(picked.name, privacy: .public)」 frame=\(picked.frameDescription, privacy: .public) \
                expectedPixel=\(Int(picked.pixelSize.width), privacy: .public)x\(Int(picked.pixelSize.height), privacy: .public)
                """)
        } else if args.contains("-scopeApplication") {
            guard let picked = await pickApplicationWithLargestWindow() else {
                logger.error("[recording-diag] 找不到可用于验证的应用")
                exit(2)
            }
            scope = .application(picked.processID, on: displayID)
            expectedPixelSize = DisplayGeometry.pixelSize(for: displayID)
            logger.notice("""
                [recording-diag] 选中应用「\(picked.name, privacy: .public)」 pid=\(picked.processID, privacy: .public) \
                expectedPixel=\(Int(expectedPixelSize.width), privacy: .public)x\(Int(expectedPixelSize.height), privacy: .public)
                """)
        } else {
            scope = .display(displayID)
            expectedPixelSize = DisplayGeometry.pixelSize(for: displayID)
        }

        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            let padded = label.padding(toLength: 26, withPad: " ", startingAt: 0)
            logger.notice("""
                [recording-diag] \(padded, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        logger.notice("""
            [recording-diag] start scope=\(scope.displayName, privacy: .public) \
            sessions=\(sessions, privacy: .public) duration=\(duration, privacy: .public)s \
            expectedPixel=\(Int(expectedPixelSize.width), privacy: .public)x\(Int(expectedPixelSize.height), privacy: .public)
            """)

        let animator = CursorAnimator()
        animator.start(displayID: displayID)
        defer { animator.stop() }

        var succeeded = 0
        for index in 1...max(1, sessions) {
            let outputURL = URL(fileURLWithPath: NSTemporaryDirectory() + "anshot-recording-diag-\(index).mp4")
            let result = await runSession(
                scope: scope,
                recordSeconds: duration,
                pauseSeconds: nil,
                outputURL: outputURL,
                doubleStop: doubleStop,
                showRegionFrame: frameExclusion
            )
            switch result {
            case .failure(let error):
                report("session #\(index)", "\(error)", "文件可读", false)
            case .success(let outcome):
                if let frameRect = outcome.regionFrameRect {
                    let hasBorder = await decodedFrameHasRegionBorder(
                        movieURL: outcome.url,
                        appKitRect: frameRect,
                        displayID: displayID
                    )
                    // hasBorder == true 表示范围框**进入**了成片，属缺陷
                    report(
                        "范围框排除: 成片帧中不应出现录制边框",
                        hasBorder ? "检测到红色边框" : "未检测到",
                        "未检测到",
                        !hasBorder
                    )
                }
                let probed = await probeMovie(at: outcome.url)
                let pixelMatches = probed.map {
                    abs($0.pixelSize.width - expectedPixelSize.width) < 1
                        && abs($0.pixelSize.height - expectedPixelSize.height) < 1
                } ?? false
                let durationMatches = probed.map { $0.duration >= duration * 0.7 && $0.duration <= duration + 1.0 } ?? false
                let decoded = probed?.decodedFrame ?? false
                let ok = probed != nil && pixelMatches && durationMatches && decoded && outcome.frameCount > 0
                if ok { succeeded += 1 }
                if let preview = probed?.previewURL {
                    logger.notice("[recording-diag] session #\(index) preview: \(preview.path, privacy: .public)")
                }
                report(
                    "session #\(index)",
                    "files=\(probed != nil) duration=\(probed.map { String(format: "%.2f", $0.duration) } ?? "-")s "
                        + "pixel=\(probed.map { "\(Int($0.pixelSize.width))x\(Int($0.pixelSize.height))" } ?? "-") "
                        + "frames=\(outcome.frameCount) decoded=\(decoded) "
                        + "size=\(String(format: "%.1f", Double(outcome.fileSize) / 1_048_576))MB",
                    "duration≈\(String(format: "%.1f", duration))s pixel=\(Int(expectedPixelSize.width))x\(Int(expectedPixelSize.height)) decoded=true",
                    ok
                )
            }
        }
        report("consecutive sessions", "\(succeeded)/\(max(1, sessions))", "\(max(1, sessions))/\(max(1, sessions))", succeeded == max(1, sessions))

        // ── 暂停：文件时长应排除暂停段
        let pauseURL = URL(fileURLWithPath: NSTemporaryDirectory() + "anshot-recording-diag-pause.mp4")
        let paused = await runSession(
            scope: scope,
            recordSeconds: 1.5,
            pauseSeconds: 1.5,
            outputURL: pauseURL
        )
        switch paused {
        case .failure(let error):
            report("pause session", "\(error)", "文件可读", false)
        case .success(let outcome):
            let probed = await probeMovie(at: outcome.url)
            report(
                "pause: duration",
                "\(probed.map { String(format: "%.2f", $0.duration) } ?? "-")s",
                "≈3.0s（1.5 + 暂停1.5 + 1.5）",
                probed.map { $0.duration >= 2.2 && $0.duration <= 3.7 } ?? false
            )
            report(
                "pause: file readable",
                "\(probed != nil) decoded=\(probed?.decodedFrame ?? false) frames=\(outcome.frameCount)",
                "true true frames>0",
                probed != nil && (probed?.decodedFrame ?? false) && outcome.frameCount > 0
            )
            if let preview = probed?.previewURL {
                logger.notice("[recording-diag] pause preview: \(preview.path, privacy: .public)")
            }
        }

        // ── 系统声音：必须用**独立进程**发声，否则必然录到静音
        if args.contains("-audio") {
            let audioURL = URL(fileURLWithPath: NSTemporaryDirectory() + "anshot-recording-diag-audio.mp4")
            let audioSession = Task {
                await runSession(
                    scope: scope,
                    recordSeconds: 2.5,
                    pauseSeconds: nil,
                    outputURL: audioURL,
                    systemAudio: true
                )
            }
            // 稍等流稳定后再发声，避免声音落在首帧之前
            try? await Task.sleep(nanoseconds: 400_000_000)
            playExternalSound()
            try? await Task.sleep(nanoseconds: 400_000_000)
            playExternalSound()

            let audioResult = await audioSession.value
            switch audioResult {
            case .failure(let error):
                report("system audio", "\(error)", "文件含非静音音轨", false)
            case .success(let outcome):
                let peak = await audioPeakLevel(at: outcome.url)
                report(
                    "system audio: track",
                    "\(outcome.hasSystemAudio)",
                    "true",
                    outcome.hasSystemAudio
                )
                report(
                    "system audio: peak level",
                    peak.map { String(format: "%.4f", $0) } ?? "无音轨",
                    "> 0.01（非静音）",
                    (peak ?? 0) > 0.01
                )
                let audioDuration = await audioTrackDuration(at: outcome.url)
                let videoDuration = (await probeMovie(at: outcome.url))?.duration
                let drift = (audioDuration != nil && videoDuration != nil)
                    ? abs(audioDuration! - videoDuration!)
                    : nil
                report(
                    "system audio: track alignment",
                    "audio=\(audioDuration.map { String(format: "%.2f", $0) } ?? "-")s "
                        + "video=\(videoDuration.map { String(format: "%.2f", $0) } ?? "-")s "
                        + "drift=\(drift.map { String(format: "%.2f", $0) } ?? "-")s",
                    "差 < 0.30s",
                    (drift ?? .infinity) < 0.30
                )
            }
        }

        // ── 麦克风：需要真实声音输入
        if args.contains("-microphone") {
            let micURL = URL(fileURLWithPath: NSTemporaryDirectory() + "anshot-recording-diag-mic.mp4")
            logger.notice("""
                [recording-diag] 麦克风验证开始：**请对着麦克风说话 4 秒**（同时会播放一次系统提示音作为兜底声源）
                """)
            // 权限弹窗需要一个可呈现的前台应用。本 app 是 LSUIElement 菜单栏辅助程序，
            // 默认不活跃；不激活时系统会在约 10 秒后直接拒绝，且不产生 TCC 请求记录。
            NSApp.activate(ignoringOtherApps: true)
            logger.notice("[recording-diag] 已请求激活应用（前台=\(NSApp.isActive, privacy: .public)）")
            let micSession = Task {
                // 同时启用系统声音与麦克风：验证两路共存（契约要求最终混为一条轨）
                await runSession(
                    scope: scope,
                    recordSeconds: 4.0,
                    pauseSeconds: nil,
                    outputURL: micURL,
                    systemAudio: true,
                    microphone: true
                )
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            playExternalSound()

            let micResult = await micSession.value
            switch micResult {
            case .failure(let error):
                report("microphone session", "\(error)", "文件含麦克风轨", false)
            case .success(let outcome):
                report(
                    "microphone: track",
                    "\(outcome.hasMicrophone)",
                    "true",
                    outcome.hasMicrophone
                )
                let tracks = await audioTrackPeaks(at: outcome.url)
                let micPeak = tracks?.last
                report(
                    "microphone: peak level",
                    micPeak.map { String(format: "%.4f", $0.peak) } ?? "无音轨",
                    "> 0.01（非静音）",
                    (micPeak?.peak ?? 0) > 0.01
                )
                report(
                    "audio: track count",
                    "\(tracks?.count ?? 0)",
                    "2（系统声音 + 麦克风双轨，DM-2 决策）",
                    (tracks?.count ?? 0) == 2
                )
            }
        }

        // ── GIF：两段式（临时影片 → 逐帧转换）
        if args.contains("-gif") {
            let gifURL = URL(fileURLWithPath: NSTemporaryDirectory() + "anshot-recording-diag.gif")
            let settings = GIFSettings()
            logger.notice("""
                [recording-diag] GIF 验证：录制 3 秒，设置 帧率=\(settings.frameRate) \
                上限=\(settings.maximumDuration)s/\(settings.maximumPixelDimension)px
                """)
            let gifResult = await runSession(
                scope: scope,
                recordSeconds: 3.0,
                pauseSeconds: nil,
                outputURL: gifURL,
                gifSettings: settings
            )
            switch gifResult {
            case .failure(let error):
                report("gif export", "\(error)", "GIF 可读", false)
            case .success(let outcome):
                let probed = probeGIF(at: outcome.url)
                report(
                    "gif: decodable",
                    "\(probed != nil)",
                    "true",
                    probed != nil
                )
                report(
                    "gif: frame count",
                    "\(probed?.frameCount ?? 0)",
                    "≈\(Int(3.0 * Double(settings.frameRate)))（3s × \(settings.frameRate)fps）",
                    (probed?.frameCount ?? 0) >= Int(3.0 * Double(settings.frameRate)) / 2
                )
                let maxDimension = CGFloat(settings.maximumPixelDimension)
                report(
                    "gif: pixel size",
                    probed.map { "\(Int($0.pixelSize.width))x\(Int($0.pixelSize.height))" } ?? "-",
                    "任一边 ≤ \(settings.maximumPixelDimension)",
                    probed.map { max($0.pixelSize.width, $0.pixelSize.height) <= maxDimension + 1 } ?? false
                )
                report(
                    "gif: file size",
                    String(format: "%.1fMB", Double(outcome.fileSize) / 1_048_576),
                    "（记录项）",
                    true
                )
            }
        }

        logger.notice("[recording-diag] done")
        try? await Task.sleep(nanoseconds: 600_000_000)
        exit(0)
    }

    /// `-requestMicrophoneAccess`
    ///
    /// 纯粹的**人机交互**入口：发起麦克风权限请求并等待用户点击系统弹窗。
    ///
    /// 与 `-diagnoseRecording -microphone` 分开是必要的：权限请求可能等待数十秒，
    /// 而录制诊断有固定的会话时长。若把两者混在一起，用户还没点完弹窗，
    /// 诊断就已经结束并退出了，弹窗随之消失——永远无法完成授权。
    static func requestMicrophoneAccessDiagnostic() async {
        logger.notice("[mic-access] 当前状态：\(String(describing: MicrophonePermission.status), privacy: .public)")
        guard MicrophonePermission.status == .notDetermined else {
            logger.notice("[mic-access] 无需请求（已有结论），直接退出")
            exit(0)
        }

        NSApp.activate(ignoringOtherApps: true)
        logger.notice("[mic-access] 已发起请求，请在系统弹窗中点击「允许」；最多等待 120 秒")

        let start = Date()
        let granted = await MicrophonePermission.request()
        let elapsed = Date().timeIntervalSince(start)
        let finalStatus = MicrophonePermission.status

        logger.notice("""
            [mic-access] 请求结束：granted=\(granted, privacy: .public) \
            耗时=\(String(format: "%.1f", elapsed), privacy: .public)s \
            最终状态=\(String(describing: finalStatus), privacy: .public)
            """)
        try? await Task.sleep(nanoseconds: 600_000_000)
        exit(granted ? 0 : 1)
    }

    struct SessionOutcome {
        let url: URL
        let frameCount: Int
        let fileSize: Int64
        let hasSystemAudio: Bool
        let hasMicrophone: Bool
        /// 验证范围框排除时所用的矩形（AppKit 坐标）；未启用时为 nil。
        var regionFrameRect: CGRect?
    }

    /// 跑一轮录制会话：起流 → 录制（可选暂停）→ 停止 → 返回产出文件信息。
    private static func runSession(
        scope: CaptureScope,
        recordSeconds: TimeInterval,
        pauseSeconds: TimeInterval?,
        outputURL: URL,
        systemAudio: Bool = false,
        microphone: Bool = false,
        gifSettings: GIFSettings? = nil,
        doubleStop: Bool = false,
        showRegionFrame: Bool = false
    ) async -> Result<SessionOutcome, Error> {
        // 范围框排除验证：录制期间刻意显示范围框，用于检查它是否被过滤器排除。
        // 若未排除，成片里会看到自己的录制边框。
        var regionFrame: RecordingRegionFrame?
        var frameRect: CGRect?
        if showRegionFrame, let screen = NSScreen.main {
            let frame = RecordingRegionFrame()
            // 取屏幕中部一块，保证边框落在画面内部而不是贴边被裁掉
            let rect = CGRect(
                x: screen.frame.midX - 310,
                y: screen.frame.midY - 210,
                width: 620,
                height: 420
            )
            frame.show(rect: rect, appearance: .recording)
            regionFrame = frame
            frameRect = rect
        }
        defer { regionFrame?.hide() }

        let excluded = [regionFrame?.windowID].compactMap { $0 }
        let recorder = SCStreamRecorder()
        let configuration = RecordingConfiguration(
            scope: scope,
            video: VideoSettings(frameRate: 30, codec: .h264, showsCursor: true),
            audio: AudioSettings(systemAudio: systemAudio, microphone: microphone),
            output: gifSettings.map { RecordingOutput.gif(outputURL, settings: $0) }
                ?? .movie(outputURL, container: .mp4),
            excludedWindowIDs: excluded
        )

        let recordTask = Task { try await recorder.record(configuration: configuration) }
        _ = await waitForRecordingState(recorder, target: .recording, timeout: 6)

        do {
            try await Task.sleep(nanoseconds: UInt64(recordSeconds * 1_000_000_000))
            if let pauseSeconds {
                await recorder.pause()
                try await Task.sleep(nanoseconds: UInt64(pauseSeconds * 1_000_000_000))
                await recorder.resume()
                try await Task.sleep(nanoseconds: UInt64(recordSeconds * 1_000_000_000))
            }

            if doubleStop {
                // 重叠停止：第一次 stop 在后台取得收尾权，第二次必须**等到收尾完成**
                // 才返回。修复前第二次仅凭 claim 失败就立即 return，调用方据此
                // 关闭界面时文件其实还没写完；因此断言「第二次返回时文件已就绪」。
                let firstStop = Task { await recorder.stop() }
                try? await Task.sleep(nanoseconds: 30_000_000)
                await recorder.stop()
                let ready = FileManager.default.fileExists(atPath: outputURL.path)
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
                let ok = ready && size > 0
                logger.notice("""
                    [recording-diag] double stop: 第二次 stop 返回时文件已就绪 \
                    exists=\(ready, privacy: .public) size=\(size, privacy: .public)B \
                    \(ok ? "PASS" : "FAIL", privacy: .public)
                    """)
                _ = await firstStop.value
            } else {
                await recorder.stop()
            }
            let result = try await recordTask.value
            return .success(SessionOutcome(
                url: result.url,
                frameCount: recorder.statistics.videoFrameCount,
                fileSize: result.fileSize,
                hasSystemAudio: result.hasSystemAudio,
                hasMicrophone: result.hasMicrophone,
                regionFrameRect: frameRect
            ))
        } catch {
            await recorder.stop()
            return .failure(error)
        }
    }

    /// 产出的影片在磁盘上的实际属性（由 AVFoundation 重新读取，不信任写入时的自报数据）。
    struct ProbedMovie {
        let duration: TimeInterval
        let pixelSize: CGSize
        let videoTrackCount: Int
        /// 是否成功解码出一帧。能读出元数据**不等于**能解码，
        /// 只有真正解出画面才能证明文件可播放。
        let decodedFrame: Bool
        /// 解码帧的落盘位置，供人工目视确认画面内容。
        let previewURL: URL?
    }

    /// 用 AVFoundation 重新打开产出文件，读取真实时长与尺寸，并**实际解码一帧**。
    ///
    /// 不采信写入过程中的自报值，也不把「能读元数据」当作「可播放」：
    /// 只有解码成功才说明文件结构完整、编码数据可用。解码出的帧会落盘成 PNG，
    /// 供人工确认画面内容（例如不是全黑）。
    static func probeMovie(at url: URL) async -> ProbedMovie? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }
            let size = try await track.load(.naturalSize)

            var decoded: CGImage?
            var previewURL: URL?
            do {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let moment = CMTime(seconds: min(0.5, max(0, duration.seconds / 2)), preferredTimescale: 600)
                decoded = try await generator.image(at: moment).image
                if let decoded {
                    previewURL = savePreview(decoded, baseName: url.deletingPathExtension().lastPathComponent)
                }
            } catch {
                logger.error("产出文件解码失败：\(String(describing: error), privacy: .public)")
            }

            return ProbedMovie(
                duration: duration.seconds,
                pixelSize: size,
                videoTrackCount: tracks.count,
                decodedFrame: decoded != nil,
                previewURL: previewURL
            )
        } catch {
            logger.error("产出文件无法读取：\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 读取 GIF 的帧数与首帧尺寸。
    /// 用 ImageIO 重开 GIF，读出帧数、像素尺寸、**循环次数**，并采样一帧看画面是否非空白。
    ///
    /// 循环次数读的是文件属性而不是自报值：档位（如「循环 3 次」）是否真的写进了文件，
    /// 只有从产物里读回来才能证明。
    ///
    /// 「非空白」只断言**帧内存在像素差异**，不断言内容正确：
    /// 全黑或全白是转码路径出错时最典型的两种表现（帧没写进去、或者写进了空位图）。
    nonisolated static func probeGIF(at url: URL) -> ProbedGIF? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0, let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        // 循环次数在**文件级**属性里（`kCGImagePropertyGIFLoopCount`）
        let loopCount: Int?
        if let properties = CGImageSourceCopyProperties(source, nil) as? [String: Any],
           let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
            loopCount = gif[kCGImagePropertyGIFLoopCount as String] as? Int
        } else {
            loopCount = nil
        }

        // 采样中间帧：首帧可能是过渡帧，中间帧更能代表实际内容
        let sampleIndex = min(count - 1, count / 2)
        let sample = CGImageSourceCreateImageAtIndex(source, sampleIndex, nil) ?? first
        // 播放时长 = 各帧间隔之和。导出会合并相同的相邻帧（静止画面只写一帧并拉长间隔），
        // 所以「帧数 = 时长 × 帧率」不再成立；时长才是不随画面内容变化的判据。
        var playbackDuration: TimeInterval = 0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                  let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] else {
                continue
            }
            let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
                ?? (gif[kCGImagePropertyGIFDelayTime as String] as? Double)
                ?? 0
            playbackDuration += delay
        }

        return ProbedGIF(
            frameCount: count,
            playbackDuration: playbackDuration,
            pixelSize: CGSize(width: first.width, height: first.height),
            loopCount: loopCount,
            sampleHasVariation: hasPixelVariation(in: sample)
        )
    }

    /// GIF 产物探针结果。
    struct ProbedGIF {
        let frameCount: Int
        /// 各帧间隔之和（秒）。
        let playbackDuration: TimeInterval
        let pixelSize: CGSize
        /// 文件级循环次数。nil 表示文件里没写这一项。
        let loopCount: Int?
        /// 采样帧内是否存在像素差异（全黑 / 全白均为 false）。
        let sampleHasVariation: Bool
    }

    /// 把图缩到 32×32 后看是否存在像素差异。
    ///
    /// 缩小到 32×32 既足够代表「整帧是不是一片死色」（全黑、全白、单色块），
    /// 又不受单像素噪声干扰（缩放本身就是一次均值）。
    nonisolated private static func hasPixelVariation(in image: CGImage) -> Bool {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var minimum = UInt8.max
        var maximum = UInt8.min
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let luminance = pixels[index]
            minimum = min(minimum, luminance)
            maximum = max(maximum, luminance)
        }
        // 阈值 8：GIF 只有 256 色且经缩放，死色的抖动通常不会超过 ±2
        return Int(maximum) - Int(minimum) > 8
    }

    /// 逐条音频轨读取时长与峰值幅度。
    ///
    /// 按轨而非「第一条音频轨」读取：启用麦克风后文件里有两条音频轨，
    /// 只读第一条无法区分「系统声音正常」与「麦克风录到了声音」。
    private static func audioTrackPeaks(at url: URL) async -> [(duration: TimeInterval, peak: Float)]? {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
                return nil
            }
            var results: [(duration: TimeInterval, peak: Float)] = []
            for track in tracks {
                let duration = (try? await track.load(.timeRange).duration.seconds) ?? 0
                results.append((duration: duration, peak: peakLevel(of: asset, track: track)))
            }
            return results
        }.value
    }

    /// 读取单条音频轨的 PCM 峰值。
    ///
    /// 标记 `nonisolated`：它在 `Task.detached` 中被调用，而本类型整体是 `@MainActor`。
    /// 该函数只做纯计算，不触碰任何 actor 状态。
    nonisolated private static func peakLevel(of asset: AVAsset, track: AVAssetTrack) -> Float {
        guard let reader = try? AVAssetReader(asset: asset) else { return 0 }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        guard reader.startReading() else { return 0 }

        var peak: Float = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            ) == noErr, let pointer else { continue }
            let sampleCount = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { samples in
                for index in 0..<sampleCount {
                    peak = max(peak, abs(samples[index]))
                }
            }
        }
        return peak
    }

    /// 音频轨的时长。用于检查音视频两轨是否对齐（同步的必要条件）。
    private static func audioTrackDuration(at url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let range = try? await track.load(.timeRange) else {
            return nil
        }
        return range.duration.seconds
    }

    /// 读取音频轨的 PCM 数据并返回峰值幅度。
    ///
    /// 只检查「是否含音轨」不足以证明录到了声音——写入器完全可能写入一条静音轨。
    /// 因此必须解码到 PCM 后看幅度。返回 nil 表示无音频轨或读取失败。
    private static func audioPeakLevel(at url: URL) async -> Float? {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
                return nil
            }
            guard let reader = try? AVAssetReader(asset: asset) else { return nil }
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }

            var peak: Float = 0
            while let sampleBuffer = output.copyNextSampleBuffer() {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(
                    blockBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &pointer
                ) == noErr, let pointer else { continue }

                let sampleCount = length / MemoryLayout<Float>.size
                pointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { samples in
                    for index in 0..<sampleCount {
                        peak = max(peak, abs(samples[index]))
                    }
                }
            }
            return peak
        }.value
    }

    /// 用**独立进程**播放一个系统声音。
    ///
    /// 必须走外部进程：配置里的 `excludesCurrentProcessAudio` 会排除本进程产生的音频，
    /// 若用 `NSSound` 在本进程播放，录到的必然是静音——那会让「系统声音捕获」的验证
    /// 变成一个永远通过的假断言。
    private static func playExternalSound() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        task.arguments = ["/System/Library/Sounds/Ping.aiff"]
        do {
            try task.run()
        } catch {
            logger.error("[recording-diag] 播放声音失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 检查解码帧里是否出现了范围框的红色描边。
    ///
    /// 坐标换算：AppKit 屏幕坐标（左下原点）→ 图像像素坐标（左上原点），
    /// 翻转量取主屏高度，再乘缩放系数。采样四条边的中点各一小段：
    /// 只要出现「系统红」（R 高、G/B 低）就说明范围框**没有**被排除。
    ///
    /// - Returns: 找到红色返回 true。true 表示排除失败（缺陷），false 才是期望结果。
    private static func decodesRedBorder(
        image: CGImage,
        appKitRect rect: CGRect,
        displayID: CGDirectDisplayID
    ) -> Bool {
        let scale = DisplayGeometry.scaleFactor(for: displayID)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height

        // 四条边的中点（图像坐标，左上原点）
        let probes: [(CGFloat, CGFloat)] = [
            (rect.midX * scale, (primaryHeight - rect.maxY) * scale),  // 顶边
            (rect.midX * scale, (primaryHeight - rect.minY) * scale),  // 底边
            (rect.minX * scale, (primaryHeight - rect.midY) * scale),  // 左边
            (rect.maxX * scale, (primaryHeight - rect.midY) * scale)   // 右边
        ]

        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let found = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for probe in probes {
                let centerX = Int(probe.0)
                let centerY = Int(probe.1)
                // 边框粗 1.5pt，描边可能有几像素偏差，故在 ±4 像素内扫描
                for dx in -4...4 {
                    for dy in -4...4 {
                        let x = centerX + dx
                        let y = centerY + dy
                        guard x >= 0, y >= 0, x < width, y < height else { continue }
                        let offset = (y * width + x) * 4
                        let r = pixels[offset]
                        let g = pixels[offset + 1]
                        let b = pixels[offset + 2]
                        if r > 200 && g < 130 && b < 130 {
                            return true
                        }
                    }
                }
            }
            return false
        }
        return found
    }

    /// 解出成片中段的一帧，检查是否含范围框红色描边。
    private static func decodedFrameHasRegionBorder(
        movieURL: URL,
        appKitRect: CGRect,
        displayID: CGDirectDisplayID
    ) async -> Bool {
        let asset = AVURLAsset(url: movieURL)
        guard let duration = try? await asset.load(.duration),
              let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return false
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        _ = track

        let seconds = max(0.1, CMTimeGetSeconds(duration) / 2)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else {
            return false
        }
        return decodesRedBorder(image: image, appKitRect: appKitRect, displayID: displayID)
    }

    /// 诊断用的窗口候选。
    struct PickedWindow {
        let windowID: CGWindowID
        let name: String
        let pixelSize: CGSize
        let frameDescription: String
    }

    struct PickedApplication {
        let processID: pid_t
        let name: String
    }

    /// 选一个可见的、非本进程的窗口作为验证目标（取面积最大的那个）。
    private static func pickLargestWindow() async -> PickedWindow? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let candidates = content.windows.filter { window in
                guard let owner = window.owningApplication else { return false }
                // 排除本进程（菜单栏程序没有可录窗口）、过小的系统元素，
                // 以及非普通层窗口——桌面壁纸也满足「可见 + 尺寸够大」，
                // 不加 `windowLayer == 0` 时会被优先选中（实测首次即选中「Wallpaper」）。
                return owner.processID != ownPID
                    && window.isOnScreen
                    && window.windowLayer == 0
                    && window.frame.width >= 300
                    && window.frame.height >= 200
            }
            guard let window = candidates.max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }) else { return nil }

            // 输出尺寸 = 窗口逻辑尺寸 × 所在显示器缩放系数（与 CaptureSetup 的算法一致）
            let scale = DisplayGeometry.displayContaining(window.frame)
                .map { DisplayGeometry.scaleFactor(for: $0) } ?? 1.0
            return PickedWindow(
                windowID: window.windowID,
                name: window.title ?? window.owningApplication?.applicationName ?? "未命名",
                pixelSize: CGSize(
                    width: (window.frame.width * scale).rounded(),
                    height: (window.frame.height * scale).rounded()
                ),
                frameDescription: String(
                    format: "%.0fx%.0f@%.0f,%.0f",
                    window.frame.width, window.frame.height, window.frame.minX, window.frame.minY
                )
            )
        } catch {
            logger.error("[recording-diag] 枚举窗口失败：\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 选一个拥有最大可见窗口的应用作为验证目标。
    private static func pickApplicationWithLargestWindow() async -> PickedApplication? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let windows = content.windows.filter {
                $0.isOnScreen && $0.windowLayer == 0
                    && $0.frame.width >= 300 && $0.frame.height >= 200
            }
            let byArea = windows.max { lhs, rhs in
                lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
            guard let owner = byArea?.owningApplication, owner.processID != ownPID else { return nil }
            return PickedApplication(processID: owner.processID, name: owner.applicationName)
        } catch {
            logger.error("[recording-diag] 枚举应用失败：\(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

#endif
