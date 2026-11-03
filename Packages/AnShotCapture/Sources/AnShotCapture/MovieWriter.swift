//
//  MovieWriter.swift
//  AnShotCapture
//
//  把视频样本写入影片文件（MP4 / MOV）。模块内部类型。
//
//  ── 时间轴契约（本文件最容易出错的部分）────────────────────────
//
//  写入文件的呈现时间戳**不能**直接用样本的原始 PTS，必须做两件事：
//
//  1. **减去累计暂停时长**：暂停期间没有帧写入，若直接用原始 PTS，
//     暂停的几秒会变成文件里的一段空白。契约要求「暂停不计入时长」。
//
//  2. **保留静止时长**：画面静止时 `SCStream` 只投递 `idle` 状态帧，
//     我们丢弃它们，于是相邻两帧的 PTS 之间会出现大间隔——
//     但这段间隔**必须保留**，它代表真实经过的时间（播放器会保持显示最后一帧）。
//
//  两者的区别在于「暂停有显式边界，静止没有」，因此暂停时长由录制器显式告知，
//  绝不能靠「相邻帧间隔过大」来猜——那会把静止误判成暂停。
//
//  ── 退出时的时长**：录制在画面静止时结束，最后一帧的时间戳会远早于真实结束时刻。
//  若不处理，文件时长会短于实际录制时长。故收尾时用 `endSession(atSourceTime:)`
//  把时间轴显式延长到真实结束点。
//

import AnShotCore
import AVFoundation
import CoreMedia
import Foundation

private let writerLogger = AnShotLog.recording
final class MovieWriter: RecordingSampleSink {

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    /// 系统声音轨。未启用时为 nil——不建立空轨道，否则产出的文件会带一条无声轨。
    private let audioInput: AVAssetWriterInput?

    /// 麦克风轨。与系统声音**分轨存放**（DM-2 决策，见 model.md §4.3）：
    /// 两路来自不同时钟域，混音需要重采样与漂移补偿，属独立的后续工作；
    /// 分轨不损失任何音质，且播放器可分别静音。
    private let microphoneInput: AVAssetWriterInput?
    private let outputURL: URL
    private let pixelSize: CGSize

    /// 一帧的正常时长。暂停结算时必须保留这么长，见 `settlePauseIfNeeded`。
    private let frameStep: CMTime

    private var isStarted = false
    private var isFinished = false

    // MARK: 时间轴状态

    /// 第一帧的原始 PTS，作为文件时间轴的原点。
    private var originPTS: CMTime?

    /// 最近一个样本的原始 PTS，**视频与音频共享**。
    ///
    /// 可以共享的依据：SCStream 的视频与音频来自**同一时钟域**（plan.md §3.1/§6），
    /// 与 M2-4 的麦克风不同。暂停锚点需要的正是「暂停前最后一个样本」，
    /// 不必区分来自哪条轨。
    private var lastOriginalPTS: CMTime?

    /// 累计暂停时长。由 `notePauseResumed` 之后的第一个样本结算。
    private var accumulatedPause: CMTime = .zero

    /// 暂停锚点：进入暂停时最后一帧的 PTS。
    ///
    /// 非 nil 表示「正在等待恢复后的第一个样本来结算暂停时长」。
    private var pauseAnchorPTS: CMTime?

    /// 最近一次写入的输出时间戳。
    private var lastOutputPTS: CMTime = .zero

    private var writtenFrameCount = 0
    private var writtenAudioBufferCount = 0
    private var writtenMicrophoneBufferCount = 0

    /// 各音频轨上一块的**结束时刻**（文件时间轴）。用于检测并补齐空隙。
    private var lastSystemAudioEndTime: CMTime?
    private var lastMicrophoneEndTime: CMTime?
    private var filledSilenceBufferCount = 0

    /// 麦克风的原始时间戳是否已验证与视频同处一个时钟域。
    ///
    /// **实测结论（2026-09-12）**：两路同处 host clock。
    /// 首个麦克风样本 `rawPTS=378379.418` 与当时的视频时间轴位置 `378379.409`
    /// 仅差 **9 毫秒**——这是样本到达的时间差，不是时钟偏移。
    ///
    /// 因此 `plan.md` §6 所担心的「不同时钟域」在本路径上**并不存在**，
    /// 麦克风与系统声音、视频共用同一换算即可（`adjustedTime(for:)`）。
    ///
    /// ⚠️ 曾实现过「首个麦克风样本锚定到当前视频时间轴位置」的相对对齐，那是**错误的**：
    /// 它依赖样本到达顺序，并且会把 9ms 当作永久偏移、
    /// 还会抹掉静止画面期间的真实时间。已移除。
    private var hasLoggedMicrophoneClock = false

    // MARK: - 构造

    init(
        url: URL,
        container: MovieContainer,
        video: VideoSettings,
        audio: AudioSettings,
        pixelSize: CGSize
    ) throws {
        // AVAssetWriter 不会覆盖已存在的文件，必须先删除
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw RecordingError.writerFailed("无法覆盖已存在的文件：\(error.localizedDescription)")
            }
        }

        let fileType: AVFileType = container == .mp4 ? .mp4 : .mov
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw RecordingError.writerFailed("无法创建写入器：\(error.localizedDescription)")
        }

        outputURL = url
        self.pixelSize = pixelSize
        frameStep = CMTime(value: 1, timescale: CMTimeScale(max(1, video.frameRate)))

        let compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: video.frameRate
        ].merging(
            video.averageBitRate.map { [AVVideoAverageBitRateKey: $0] } ?? [:]
        ) { _, new in new }

        var outputSettings: [String: Any] = [
            AVVideoCodecKey: video.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(pixelSize.width.rounded()),
            AVVideoHeightKey: Int(pixelSize.height.rounded()),
            AVVideoCompressionPropertiesKey: compression
        ]
        outputSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        // 实时源：不设此标志会让写入器按「离线转码」策略缓冲，导致帧延迟落盘
        videoInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw RecordingError.writerFailed("写入器不接受视频轨道")
        }
        writer.add(videoInput)

        // 系统声音轨。采样率与声道数沿用配置，避免额外的重采样环节。
        if audio.systemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: audio.channelCount,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecordingError.writerFailed("写入器不接受音频轨道")
            }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        // 麦克风轨
        if audio.microphone {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecordingError.writerFailed("写入器不接受麦克风轨道")
            }
            writer.add(input)
            microphoneInput = input
        } else {
            microphoneInput = nil
        }
    }

    // MARK: - 暂停边界

    /// 告知写入器「暂停开始」。
    func notePauseStarted() {
        pauseAnchorPTS = lastOriginalPTS
    }

    /// 暂停时长在恢复后的第一个样本到达时结算（此时才能算出真实间隔）。
    private func settlePauseIfNeeded(currentPTS: CMTime) {
        guard let anchor = pauseAnchorPTS else { return }
        pauseAnchorPTS = nil

        // 从间隔中**保留一帧**：恢复后的第一帧与暂停前最后一帧之间，本来就应当相隔一帧。
        // 若把整个间隔都扣掉，这两帧会得到相同、或因 CMTime 精度而略微倒退的时间戳，
        // 而 AVAssetWriter 要求时间戳严格递增——实测后果是 finishWriting 直接失败
        // （错误为「The operation could not be completed」，已写入的部分文件保留在磁盘上）。
        let gap = CMTimeSubtract(currentPTS, anchor)
        let pauseLength = CMTimeSubtract(gap, frameStep)
        guard pauseLength.isValid, pauseLength.seconds > 0 else { return }

        accumulatedPause = CMTimeAdd(accumulatedPause, pauseLength)
        writerLogger.notice("""
            暂停结算：本段 \(String(format: "%.2f", pauseLength.seconds), privacy: .public)s，\
            累计 \(String(format: "%.2f", self.accumulatedPause.seconds), privacy: .public)s
            """)
    }

    // MARK: - RecordingSampleSink

    func consumeVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard !isFinished else { return false }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return false }

        if !isStarted {
            guard startIfNeeded(originPTS: pts) else { return false }
        }

        settlePauseIfNeeded(currentPTS: pts)

        guard videoInput.isReadyForMoreMediaData else {
            // 写入器跟不上（磁盘或编码器瓶颈）：如实报告未消费，由录制器计入丢弃
            return false
        }

        let outputPTS = adjustedTime(for: pts)
        guard let adjusted = Self.retimed(sampleBuffer, to: outputPTS) else {
            return false
        }
        guard videoInput.append(adjusted) else {
            writerLogger.error("视频帧写入失败：\(String(describing: self.writer.error), privacy: .public)")
            return false
        }

        lastOriginalPTS = pts
        lastOutputPTS = outputPTS
        writtenFrameCount += 1
        return true
    }

    func consumeSystemAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard !isFinished, let audioInput else { return false }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return false }

        if !isStarted {
            guard startIfNeeded(originPTS: pts) else { return false }
        }

        settlePauseIfNeeded(currentPTS: pts)

        guard audioInput.isReadyForMoreMediaData else {
            // 写入器跟不上：如实报告未消费，由录制器计入丢弃
            return false
        }

        let outputPTS = adjustedTime(for: pts)
        // 补齐上一块与本块之间的空隙，否则该轨时长会短于视频
        if let lastEnd = lastSystemAudioEndTime, CMTimeCompare(lastEnd, outputPTS) < 0 {
            guard fillSilence(into: audioInput, like: sampleBuffer, from: lastEnd, to: outputPTS) else {
                return false
            }
        }

        guard let adjusted = Self.retimed(sampleBuffer, to: outputPTS) else {
            return false
        }
        guard audioInput.append(adjusted) else {
            writerLogger.error("音频样本写入失败：\(String(describing: self.writer.error), privacy: .public)")
            return false
        }

        lastOriginalPTS = pts
        lastSystemAudioEndTime = Self.sampleEndTime(of: sampleBuffer, startingAt: outputPTS)
        writtenAudioBufferCount += 1
        logFormatsIfNeeded(systemBuffer: sampleBuffer)
        return true
    }

    func consumeMicrophone(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard !isFinished, let microphoneInput else { return false }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard rawPTS.isValid else { return false }

        if !isStarted {
            guard startIfNeeded(originPTS: rawPTS) else { return false }
        }

        // 诊断记录（仅一次）：确认两路确实同处一个时钟域
        if !hasLoggedMicrophoneClock, let origin = originPTS {
            hasLoggedMicrophoneClock = true
            writerLogger.notice("""
                麦克风时钟校验：rawPTS=\(String(format: "%.3f", rawPTS.seconds), privacy: .public) \
                时间轴原点=\(String(format: "%.3f", origin.seconds), privacy: .public) \
                差=\(String(format: "%.3f", CMTimeSubtract(rawPTS, origin).seconds), privacy: .public)s
                """)
        }

        settlePauseIfNeeded(currentPTS: rawPTS)

        guard microphoneInput.isReadyForMoreMediaData else { return false }
        // 与视频、系统音频使用**同一个**换算：三者同处一个时钟域，各用一套偏移
        // 会让轨间同步随时间漂移。
        let outputPTS = adjustedTime(for: rawPTS)
        // 麦克风启动晚于视频（实测差 108ms），首块之前必然有一段空隙；
        // 运行中也可能因写入器未就绪而丢帧。不补齐会让该轨比视频短。
        if let lastEnd = lastMicrophoneEndTime, CMTimeCompare(lastEnd, outputPTS) < 0 {
            guard fillSilence(into: microphoneInput, like: sampleBuffer, from: lastEnd, to: outputPTS) else {
                return false
            }
        }
        guard let adjusted = Self.retimed(sampleBuffer, to: outputPTS) else {
            return false
        }
        guard microphoneInput.append(adjusted) else {
            writerLogger.error("麦克风样本写入失败：\(String(describing: self.writer.error), privacy: .public)")
            return false
        }

        lastOriginalPTS = rawPTS
        lastMicrophoneEndTime = Self.sampleEndTime(of: sampleBuffer, startingAt: outputPTS)
        writtenMicrophoneBufferCount += 1
        logFormatsIfNeeded(microphoneBuffer: sampleBuffer)
        return true
    }

    // MARK: - 收尾

    /// 收尾并返回结果。
    ///
    /// - Parameter duration: 会话的真实时长（不含暂停）。用于把时间轴延长到真实结束点，
    ///   否则在画面静止时结束的录制会得到一个明显偏短的文件。
    func finish(duration: TimeInterval) async throws -> RecordingResult {
        guard !isFinished else {
            throw RecordingError.writerFailed("写入器已收尾")
        }
        isFinished = true

        // 从未收到任何帧：没有任何可写内容，删除空文件并如实报错
        guard isStarted else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordingError.writerFailed("未收到任何视频帧")
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        microphoneInput?.markAsFinished()

        // 把时间轴延长到真实结束点：静止结束时最后一帧的时间戳会早于结束时刻。
        //
        // ⚠️ 必须取**所有轨**的最大结束时间，而不只是视频最后一帧：
        // 音频轨（尤其经静音填充后）可能延伸到视频末帧之后，
        // 若 endSession 的终点早于某轨的末尾，该轨会被截断并使收尾失败
        // （实测表现为 finishWriting 报「The operation could not be completed」）。
        let requestedEnd = CMTime(seconds: max(duration, 0), preferredTimescale: 600)
        var endTime = CMTimeMaximum(requestedEnd, lastOutputPTS)
        if let audioEnd = lastSystemAudioEndTime {
            endTime = CMTimeMaximum(endTime, audioEnd)
        }
        if let microphoneEnd = lastMicrophoneEndTime {
            endTime = CMTimeMaximum(endTime, microphoneEnd)
        }
        writerLogger.notice("""
            时间轴终点：requested=\(String(format: "%.3f", requestedEnd.seconds), privacy: .public) \
            video=\(String(format: "%.3f", self.lastOutputPTS.seconds), privacy: .public) \
            sysAudio=\(self.lastSystemAudioEndTime.map { String(format: "%.3f", $0.seconds) } ?? "-", privacy: .public) \
            mic=\(self.lastMicrophoneEndTime.map { String(format: "%.3f", $0.seconds) } ?? "-", privacy: .public) \
            → 采用=\(String(format: "%.3f", endTime.seconds), privacy: .public)
            """)
        writer.endSession(atSourceTime: endTime)

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }

        guard writer.status == .completed else {
            // 带上 underlying error：仅凭 localizedDescription（常为
            // 「The operation could not be completed」）无法判断真因。
            let detail: String
            if let error = writer.error as NSError? {
                let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
                detail = "status=\(writer.status.rawValue) \(error.domain)#\(error.code) "
                    + "\(error.localizedDescription)"
                    + (underlying.map { " ← \($0.domain)#\($0.code) \($0.localizedDescription)" } ?? "")
            } else {
                detail = "status=\(writer.status.rawValue) 未知原因"
            }
            // 保留已写入的部分文件，由上层决定是否留存（契约 model.md §5）
            throw RecordingError.writerFailed(detail)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let duration = endTime.seconds
        let frameRate = duration > 0.01 ? Double(writtenFrameCount) / duration : 0

        writerLogger.notice("""
            影片收尾：frames=\(self.writtenFrameCount, privacy: .public) \
            audioBuffers=\(self.writtenAudioBufferCount, privacy: .public) \
            micBuffers=\(self.writtenMicrophoneBufferCount, privacy: .public) \
            silenceFills=\(self.filledSilenceBufferCount, privacy: .public) \
            duration=\(String(format: "%.2f", duration), privacy: .public)s \
            size=\(fileSize, privacy: .public)B
            """)

        return RecordingResult(
            url: outputURL,
            duration: duration,
            pixelSize: pixelSize,
            frameRate: frameRate,
            hasSystemAudio: audioInput != nil && writtenAudioBufferCount > 0,
            hasMicrophone: microphoneInput != nil && writtenMicrophoneBufferCount > 0,
            fileSize: fileSize
        )
    }

    // MARK: - 静音填充

    /// 样本在文件时间轴上的结束时刻。
    private static func sampleEndTime(of sampleBuffer: CMSampleBuffer, startingAt pts: CMTime) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.seconds > 0 {
            return CMTimeAdd(pts, duration)
        }
        // 回退：按帧数与采样率推算
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0 else {
            return pts
        }
        return CMTimeAdd(
            pts,
            CMTime(
                value: CMTimeValue(CMSampleBufferGetNumSamples(sampleBuffer)),
                timescale: CMTimeScale(asbd.mSampleRate)
            )
        )
    }

    /// 向指定轨写入 `[start, end)` 区间的零值 PCM，补齐空隙。
    ///
    /// **为何必须做**：某轨在没有样本的时间段内不会自行延长，其时长会短于视频，
    /// 播放时表现为音画错位或末尾缺失。麦克风启动晚于视频时（实测差 108ms）
    /// 首块之前必然存在这样的空隙。
    ///
    /// - Returns: 是否完整填充（写入器未就绪时返回 false，由调用方计入丢弃）。
    private func fillSilence(
        into input: AVAssetWriterInput,
        like reference: CMSampleBuffer,
        from start: CMTime,
        to end: CMTime
    ) -> Bool {
        guard start.isValid, end.isValid, CMTimeCompare(start, end) < 0,
              let format = CMSampleBufferGetFormatDescription(reference),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0 else {
            return true
        }

        // 按参考样本的块大小切块：一次性构造整个空隙会产生一个超大 buffer，
        // 既占内存也让写入器难以按实时节奏消化。
        let chunkFrames = max(1, CMSampleBufferGetNumSamples(reference))
        let sampleRate = CMTimeScale(asbd.mSampleRate)
        var cursor = start

        while CMTimeCompare(cursor, end) < 0 {
            let remaining = CMTimeSubtract(end, cursor)
            let remainingFrames = Int((remaining.seconds * Double(sampleRate)).rounded(.up))
            guard remainingFrames > 0 else { break }
            // 最后一块精确到剩余帧数，避免越过 end 与真实样本重叠
            let frames = min(chunkFrames, remainingFrames)

            guard input.isReadyForMoreMediaData else { return false }
            guard let silent = Self.makeSilence(
                formatDescription: format,
                asbd: asbd,
                at: cursor,
                frameCount: frames
            ), input.append(silent) else {
                return false
            }

            filledSilenceBufferCount += 1
            cursor = CMTimeAdd(cursor, CMTime(value: CMTimeValue(frames), timescale: sampleRate))
        }
        return true
    }

    /// 构造一段零值 PCM 样本。
    private static func makeSilence(
        formatDescription: CMAudioFormatDescription,
        asbd: AudioStreamBasicDescription,
        at pts: CMTime,
        frameCount: Int
    ) -> CMSampleBuffer? {
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let length = bytesPerFrame * frameCount
        guard bytesPerFrame > 0, length > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        guard CMBlockBufferFillDataBytes(
            with: 0,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: length
        ) == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - 内部

    /// 诊断：记录两路音频的实际格式。
    ///
    /// 混音必须在**相同的采样率、位深、声道布局**下做样本级求和，
    /// 因此实现前必须先确认两路的真实格式，而不是假设它们一致。
    private var loggedSystemFormat = false
    private var loggedMicrophoneFormat = false

    private func logFormatsIfNeeded(systemBuffer: CMSampleBuffer? = nil, microphoneBuffer: CMSampleBuffer? = nil) {
        if let systemBuffer, !loggedSystemFormat {
            loggedSystemFormat = true
            writerLogger.notice("系统声音格式：\(Self.formatDescription(of: systemBuffer), privacy: .public)")
        }
        if let microphoneBuffer, !loggedMicrophoneFormat {
            loggedMicrophoneFormat = true
            writerLogger.notice("麦克风格式：\(Self.formatDescription(of: microphoneBuffer), privacy: .public)")
        }
    }

    private static func formatDescription(of sampleBuffer: CMSampleBuffer) -> String {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            return "未知"
        }
        let pointer = UnsafeRawPointer(asbd).assumingMemoryBound(to: AudioStreamBasicDescription.self)
        let description = pointer.pointee
        let isFloat = (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (description.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        return """
            rate=\(description.mSampleRate) ch=\(description.mChannelsPerFrame) \
            bits=\(description.mBitsPerChannel) float=\(isFloat) \
            nonInterleaved=\(isNonInterleaved) bytesPerFrame=\(description.mBytesPerFrame) \
            每缓冲帧数=\(CMSampleBufferGetNumSamples(sampleBuffer))
            """
    }

    /// 把原始 PTS 换算为文件时间轴上的位置。
    ///
    /// 视频与音频走同一换算：两者的时间基准相同（同一时钟域），
    /// 若各用一套偏移，轨间同步会随时间漂移。
    private func adjustedTime(for pts: CMTime) -> CMTime {
        CMTimeSubtract(CMTimeSubtract(pts, originPTS ?? pts), accumulatedPause)
    }

    private func startIfNeeded(originPTS: CMTime) -> Bool {
        guard writer.startWriting() else {
            writerLogger.error("startWriting 失败：\(String(describing: self.writer.error), privacy: .public)")
            return false
        }
        writer.startSession(atSourceTime: .zero)
        self.originPTS = originPTS
        self.lastOriginalPTS = originPTS
        isStarted = true
        return true
    }

    /// 用新的呈现时间戳复制一份样本缓冲。
    ///
    /// 不能直接改原样本的时间戳：`CMSampleBuffer` 是不可变的，
    /// 且原始缓冲可能仍被上游持有。
    ///
    /// **逐条平移原有的计时表**，而不是新造一条：音频缓冲通常是「一条计时项描述
    /// N 个采样」，那一项里的 duration 是**单个采样**的时长。若拿整块缓冲的总时长
    /// （`CMSampleBufferGetDuration`）去填这唯一一项，每个采样都会被声明成整块那么长，
    /// 缓冲的总时长随之放大 N 倍。平移原表则保留了原本的时长语义，只改起点。
    static func retimed(_ sampleBuffer: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        var entryCount: CMItemCount = 0
        let countStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &entryCount
        )

        var timings: [CMSampleTimingInfo]
        if countStatus == noErr, entryCount > 0 {
            timings = Array(repeating: CMSampleTimingInfo(), count: entryCount)
            guard CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: entryCount,
                arrayToFill: &timings,
                entriesNeededOut: &entryCount
            ) == noErr else { return nil }

            let offset = CMTimeSubtract(pts, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            for index in timings.indices {
                let original = timings[index].presentationTimeStamp
                timings[index].presentationTimeStamp = original.isValid
                    ? CMTimeAdd(original, offset)
                    : pts
                timings[index].decodeTimeStamp = .invalid
            }
        } else {
            // 没有计时表（例如不带时间信息的缓冲）：退回单项，只给起点。
            timings = [CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: pts,
                decodeTimeStamp: .invalid
            )]
        }

        var newBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timings.count,
            sampleTimingArray: &timings,
            sampleBufferOut: &newBuffer
        )
        guard status == noErr else { return nil }
        return newBuffer
    }
}
