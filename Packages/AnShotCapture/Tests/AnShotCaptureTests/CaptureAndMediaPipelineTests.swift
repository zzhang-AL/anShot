//
//  CaptureAndMediaPipelineTests.swift
//  AnShotCaptureTests
//
//  MovieWriter 起始静音与暂停恢复、SCStreamRecorder 并发与取消恢复、
//  FirstFrameCollector 取消/超时区分、ScrollshotFrameCapturer 取消清理、
//  GIF 噪点合并与取消清理、TextRecognizer 缩进与分栏阅读序单测。
//

import AnShotCore
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnShotCapture

@Suite("MovieWriter 时间轴 · 起始静音与暂停恢复")
struct MovieWriterTimelineTests {

    private func makeVideoSample(pts: CMTime, width: Int = 320, height: Int = 240) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let pb = try #require(pixelBuffer)

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescriptionOut: &format
        )
        let desc = try #require(format)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        return try #require(sample)
    }

    private func makeAudioSample(
        pts: CMTime,
        frames: Int = 960,
        rate: Double = 48_000,
        channels: UInt32 = 1
    ) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        var format: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr)

        let length = frames * 4 * Int(channels)
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr)
        let dataBuffer = try #require(block)
        #expect(CMBlockBufferFillDataBytes(with: 0, blockBuffer: dataBuffer, offsetIntoDestination: 0, dataLength: length) == kCMBlockBufferNoErr)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        let audioFormat = try #require(format)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: dataBuffer,
            formatDescription: audioFormat,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr)
        return try #require(sample)
    }

    @Test("仅由首帧视频确立时间轴原点，极早期音频丢弃，首块音频补齐起始静音并安全跨越暂停恢复")
    func originSilencePaddingAndPauseResumeMonotonicity() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-writer-timeline-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try MovieWriter(
            url: url,
            container: .mp4,
            video: VideoSettings(frameRate: 30, codec: .h264),
            audio: AudioSettings(systemAudio: true, microphone: true, sampleRate: 48_000, channelCount: 2),
            pixelSize: CGSize(width: 321, height: 241) // 故意传奇数测试自动偶数对齐
        )

        // 分片写入保护必须设置，且奇数像素自动偶数对齐。
        let initialSnapshot = writer.timelineSnapshotForTesting
        #expect(CMTimeCompare(initialSnapshot.movieFragmentInterval, CMTime(seconds: 2, preferredTimescale: 600)) == 0)

        // 视频尚未到时到达的极早期音频必须被丢弃，不能初始化原点。
        let earlyMic = try makeAudioSample(pts: CMTime(seconds: 99.8, preferredTimescale: 48_000), channels: 1)
        #expect(!writer.consumeMicrophone(earlyMic))
        #expect(!writer.timelineSnapshotForTesting.isStarted)

        // 首帧视频在 100.000s 到达并确立时间轴原点。
        let video1 = try makeVideoSample(pts: CMTime(seconds: 100.0, preferredTimescale: 600))
        #expect(writer.consumeVideo(video1))
        #expect(writer.timelineSnapshotForTesting.originPTS == CMTime(seconds: 100.0, preferredTimescale: 600))

        // 原点前极早期音频（99.98s < 100.00s）也必须丢弃。
        let preOriginSys = try makeAudioSample(pts: CMTime(seconds: 99.98, preferredTimescale: 48_000), channels: 2)
        #expect(!writer.consumeSystemAudio(preOriginSys))

        // 麦克风首块晚于视频 200ms 到达：必须补齐 [0, 0.2s) 起始静音。
        let mic1 = try makeAudioSample(pts: CMTime(seconds: 100.2, preferredTimescale: 48_000), frames: 2400, channels: 1)
        #expect(writer.consumeMicrophone(mic1))
        let afterMic1 = writer.timelineSnapshotForTesting
        #expect(afterMic1.filledSilenceBufferCount > 0)
        let mic1End = try #require(afterMic1.lastMicrophoneEndTime)
        #expect(abs(mic1End.seconds - 0.25) < 0.01)

        // 系统音频首块在 100.3s 到达：同样补齐 [0, 0.3s) 起始静音。
        let sys1 = try makeAudioSample(pts: CMTime(seconds: 100.3, preferredTimescale: 48_000), frames: 2400, channels: 2)
        #expect(writer.consumeSystemAudio(sys1))
        let sys1End = try #require(writer.timelineSnapshotForTesting.lastSystemAudioEndTime)
        #expect(abs(sys1End.seconds - 0.35) < 0.01)

        // 模拟暂停 2 秒后恢复，且恢复首帧视频早于某路音轨的尾端，验证三轨单调无倒退。
        writer.notePauseStarted()
        let video2 = try makeVideoSample(pts: CMTime(seconds: 102.35, preferredTimescale: 600))
        #expect(writer.consumeVideo(video2))

        // 恢复后略微早到的音频（原始 pts 刚落在交界附近），不得导致 writer 报错。
        let mic2 = try makeAudioSample(pts: CMTime(seconds: 102.36, preferredTimescale: 48_000), frames: 2400, channels: 1)
        _ = writer.consumeMicrophone(mic2)
        let sys2 = try makeAudioSample(pts: CMTime(seconds: 102.37, preferredTimescale: 48_000), frames: 2400, channels: 2)
        _ = writer.consumeSystemAudio(sys2)

        #expect(writer.failureError == nil)

        let result = try await writer.finish(duration: 0.5)
        #expect(Int(result.pixelSize.width) == 320)
        #expect(Int(result.pixelSize.height) == 240)
        #expect(result.hasMicrophone)
        #expect(result.hasSystemAudio)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite("录制并发、超 4K 自动切 HEVC 与取消安全")
struct RecorderConcurrencyAndLifecycleTests {

    @Test("录屏像素偶数对齐与超 4096px 时 H.264 自动切换 HEVC")
    func evenAlignmentAndOver4KCodecSwitch() {
        let aligned = CaptureSetup.alignedEvenPixelSize(CGSize(width: 1921, height: 1081))
        #expect(aligned == CGSize(width: 1920, height: 1080))
        #expect(CaptureSetup.alignedEvenPixelSize(CGSize(width: 1, height: 1)) == CGSize(width: 2, height: 2))

        let hdSettings = VideoSettings(frameRate: 30, codec: .h264)
        #expect(SCStreamRecorder.resolvedVideoSettings(hdSettings, pixelSize: CGSize(width: 1920, height: 1080)).codec == .h264)
        #expect(SCStreamRecorder.resolvedVideoSettings(hdSettings, pixelSize: CGSize(width: 5120, height: 2880)).codec == .hevc)
    }

    @Test("onExportProgress 并发读写安全且外部取消 record() 不悬挂")
    func exportProgressThreadSafetyAndCancellation() async {
        let recorder = SCStreamRecorder()
        await withTaskGroup(of: Void.self) { group in
            for idx in 0..<20 {
                group.addTask {
                    recorder.onExportProgress = { value in _ = value + Double(idx) }
                    _ = recorder.onExportProgress
                    _ = recorder.keptOutput
                    _ = recorder.didReachDurationLimit
                }
            }
        }
        #expect(!recorder.didReachDurationLimit)
        #expect(recorder.keptOutput == nil)

        // 在进入前或执行中途取消父 Task 均能安全返回 cancelled。
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-cancel-run-\(UUID().uuidString).mp4")
        let task = Task {
            let config = RecordingConfiguration(
                scope: .display(DisplayGeometry.mainDisplay()),
                audio: AudioSettings(systemAudio: false, microphone: false),
                output: .movie(url, container: .mp4)
            )
            return try await recorder.record(configuration: config)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("预期录制任务被取消后应抛错")
        } catch {
            // 权限受限环境下可能先抛 permissionDenied，否则为 cancelled，均不得永久挂起。
            #expect(error is RecordingError)
        }
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("捕获超时、取消区分与长截图清理")
struct CaptureCancellationAndTimeoutTests {

    @Test("FirstFrameCollector 严格区分外部 Task 取消与超时")
    func collectorDistinguishesCancellationFromTimeout() async throws {
        let collector = FirstFrameCollector()
        let task = Task {
            try await collector.waitForFirstFrame(timeout: 5.0)
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("预期抛出 CancellationError")
        } catch is CancellationError {
            // 预期结果：绝不能误报 CaptureError.timedOut。
        } catch {
            Issue.record("预期为 CancellationError，实际为 \(error)")
        }
    }

    @Test("CaptureSetup.withTimeout 超时抛 CaptureError.timedOut")
    func asyncTimeoutThrowsTimedOut() async {
        do {
            _ = try await CaptureSetup.withTimeout(0.05) {
                try await Task.sleep(for: .seconds(2))
                return 1
            }
            Issue.record("预期触发超时")
        } catch CaptureError.timedOut {
            // 预期结果。
        } catch {
            Issue.record("预期 CaptureError.timedOut，实际为 \(error)")
        }
    }

    @Test("ScrollshotFrameCapturer 等待期间取消任务立即抛出 CancellationError 且不泄漏 Continuation")
    func scrollshotFrameCapturerCancelsCleanly() async throws {
        let source = HangingCapturer()
        let capturer = ScrollshotFrameCapturer(capturer: source, interval: .milliseconds(10), capacity: 4)
        let task = Task {
            try await capturer.captureFrame(scope: .display(1))
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("预期取消抛出 CancellationError")
        } catch is CancellationError {
            // 预期结果。
        } catch {
            Issue.record("预期 CancellationError，实际为 \(error)")
        }
        _ = await capturer.stopAndDrain()
    }
}

private struct HangingCapturer: ScreenCapturing {
    func captureFrame(scope: CaptureScope) async throws -> CapturedFrame {
        try await Task.sleep(for: .seconds(10))
        throw CancellationError()
    }
}

@Suite("GIF 降噪合并与本地 OCR 排版还原")
struct GIFNoiseAndTextLayoutTests {

    private func makeSolidImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        for offset in stride(from: 0, to: data.count, by: 4) {
            data[offset] = r
            data[offset + 1] = g
            data[offset + 2] = b
            data[offset + 3] = 255
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: srgb,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    @Test("GIFSourceFrame 容忍 H.264 ±2 灰阶底噪，显著色变不误合并")
    func gifSourceFrameNoiseTolerance() {
        let base = GIFSourceFrame(makeSolidImage(width: 64, height: 64, r: 100, g: 120, b: 140))
        let minorNoise = GIFSourceFrame(makeSolidImage(width: 64, height: 64, r: 102, g: 119, b: 141))
        let distinct = GIFSourceFrame(makeSolidImage(width: 64, height: 64, r: 115, g: 120, b: 140))

        #expect(base.hasSamePixels(as: minorNoise))
        #expect(!base.hasSamePixels(as: distinct))
    }

    @Test("TextRecognizer 还原代码块左缩进与双栏阅读序，且不误伤普通行")
    func textRecognizerLayoutAndSampleImage() {
        let image = TextRecognizer.sampleImage()
        #expect(image != nil)

        // 1. 代码块左缩进还原。
        let codeLines = [
            OCRTextLine(text: "func hello() {", candidates: [], confidence: 1, boundingBox: PixelRect(origin: PixelPoint(x: 20, y: 10), size: PixelSize(width: 140, height: 20))),
            OCRTextLine(text: "print(1)", candidates: [], confidence: 1, boundingBox: PixelRect(origin: PixelPoint(x: 60, y: 40), size: PixelSize(width: 80, height: 20))),
            OCRTextLine(text: "}", candidates: [], confidence: 1, boundingBox: PixelRect(origin: PixelPoint(x: 20, y: 70), size: PixelSize(width: 14, height: 20)))
        ]
        let laidOutCode = TextRecognizer.layoutLines(codeLines, imagePixelSize: PixelSize(width: 400, height: 120))
        #expect(laidOutCode[0].text == "func hello() {")
        #expect(laidOutCode[1].text.hasPrefix("    ") || laidOutCode[1].text.hasPrefix("   "))
        #expect(laidOutCode[1].text.hasSuffix("print(1)"))
        #expect(laidOutCode[2].text == "}")

        // 2. 双栏阅读序（左栏上→下，再右栏上→下）。
        let twoColumns = [
            OCRTextLine(text: "Right-1", candidates: [], confidence: 1, boundingBox: PixelRect(origin: PixelPoint(x: 320, y: 10), size: PixelSize(width: 100, height: 20))),
            OCRTextLine(text: "Left-1", candidates: [], confidence: 1, boundingBox: PixelRect(origin: PixelPoint(x: 20, y: 12), size: PixelSize(width: 100, height: 20))),
            OCRTextLine(text: "Right-2", candidates: [], confidence: 1, boundingBox: PixelRect(origin: PixelPoint(x: 320, y: 50), size: PixelSize(width: 100, height: 20))),
            OCRTextLine(text: "Left-2", candidates: [], confidence: 1, boundingBox: PixelRect(origin: PixelPoint(x: 20, y: 52), size: PixelSize(width: 100, height: 20)))
        ]
        let laidOutCols = TextRecognizer.layoutLines(twoColumns, imagePixelSize: PixelSize(width: 500, height: 120))
        #expect(laidOutCols.map(\.text) == ["Left-1", "Left-2", "Right-1", "Right-2"])

        // 3. 普通左对齐两行不误加空格。
        let normal = [
            OCRTextLine(text: "你好，世界", candidates: [], confidence: 1, boundingBox: PixelRect(origin: PixelPoint(x: 40, y: 20), size: PixelSize(width: 200, height: 40))),
            OCRTextLine(text: "今天天气很好", candidates: [], confidence: 1, boundingBox: PixelRect(origin: PixelPoint(x: 42, y: 80), size: PixelSize(width: 240, height: 40)))
        ]
        let laidOutNormal = TextRecognizer.layoutLines(normal, imagePixelSize: PixelSize(width: 400, height: 160))
        #expect(laidOutNormal.map(\.text) == ["你好，世界", "今天天气很好"])
    }

    @Test("MouseClickMonitor 生命周期过滤与高亮叠加不改变零点击帧")
    func mouseClickMonitorAndOverlay() throws {
        let monitor = MouseClickMonitor(highlightDuration: 0.4)
        monitor.record(RecordedMouseClick(globalPoint: CGPoint(x: 150, y: 120), uptime: 10.0, buttonNumber: 0))
        monitor.record(RecordedMouseClick(globalPoint: CGPoint(x: 180, y: 140), uptime: 10.2, buttonNumber: 1))

        let activeAt10_3 = monitor.activeHighlights(at: 10.3)
        #expect(activeAt10_3.count == 2)
        #expect(abs(activeAt10_3[0].progress - 0.75) < 1e-6)

        // 超过 0.4s 的点击被清理，全部过期后列表为空。
        #expect(monitor.activeHighlights(at: 11.0).isEmpty)

        // 验证叠加：先构造 32BGRA sampleBuffer。
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess)
        let pb = try #require(pixelBuffer)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMVideoFormatDescriptionGetDimensions(try #require(format))
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescription: try #require(format),
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        let baseSample = try #require(sample)

        // 空波纹零拷贝原样返回。
        let passthrough = MouseClickHighlightRenderer.overlayHighlights([], onto: baseSample, captureOrigin: .zero, scaleFactor: 1)
        #expect(passthrough === baseSample)

        // 有波纹时渲染新缓冲。
        let overlayed = MouseClickHighlightRenderer.overlayHighlights(
            activeAt10_3,
            onto: baseSample,
            captureOrigin: CGPoint(x: 100, y: 100),
            scaleFactor: 1.0
        )
        #expect(overlayed !== baseSample)

        // 枚举音频输入设备（即使测试环境无麦也不得崩溃）。
        _ = MicrophoneCapturer.availableInputDevices()
    }

    @Test("ImageEncoding 对 PNG/JPEG 2x Retina 编码写入 144 DPI，且 Vision 关闭自动语言检测")
    func imageEncodingRetinaDPIAndVisionConfig() throws {
        let context = try #require(CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(context.makeImage())

        for format in [ImageFormat.png, .jpeg(quality: 0.9)] {
            let encoded = try ImageEncoding.data(from: image, format: format, backingScale: 2.0)
            let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let dpiW = try #require(props[kCGImagePropertyDPIWidth] as? Double)
            let dpiH = try #require(props[kCGImagePropertyDPIHeight] as? Double)
            #expect(abs(dpiW - 144.0) < 1.0)
            #expect(abs(dpiH - 144.0) < 1.0)
        }

        let request = TextRecognizer.makeRequest(languages: TextRecognizer.availability().preferredLanguages)
        #expect(request.automaticallyDetectsLanguage == false, "必须关闭自动语言检测，规避新二进制首次 ~52s 模型编译")
        #expect(request.recognitionLanguages.contains("zh-Hans"))
        #expect(request.recognitionLanguages.contains("en-US"))
    }
}
