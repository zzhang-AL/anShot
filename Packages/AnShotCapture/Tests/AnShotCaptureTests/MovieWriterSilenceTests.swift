//
//  MovieWriterSilenceTests.swift
//  AnShotCaptureTests
//
//  静音填充缓冲必须满足 CoreMedia 对**非交错音频**的声明约定：
//  数据按声道平面存放，且不得提供 per-sample 尺寸（样本在缓冲内不连续）。
//  违反时 AVAssetWriter 的 append 会以 OSStatus -12704
//  （kCMBlockBufferBadLengthParameterErr）失败，并让整条录制报废。
//

import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import AnShotCapture

@Suite("MovieWriter 静音填充")
struct MovieWriterSilenceTests {

    private func makeNonInterleavedFormat(
        rate: Double,
        channels: UInt32
    ) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1
            ? kAudioChannelLayoutTag_Mono
            : kAudioChannelLayoutTag_Stereo

        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        #expect(status == noErr)
        return try #require(format)
    }

    /// 逐块追加 1.5 秒静音后收尾；返回数据长度供断言。
    private func assertSilenceIsWritable(
        format: CMAudioFormatDescription,
        rate: Double,
        channels: Int,
        framesPerBuffer: Int
    ) async throws -> Int {
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
        let first = try #require(MovieWriter.makeSilence(
            formatDescription: format,
            asbd: asbd,
            at: .zero,
            frameCount: framesPerBuffer
        ))
        #expect(CMSampleBufferGetNumSamples(first) == framesPerBuffer)

        let block = try #require(CMSampleBufferGetDataBuffer(first))
        let dataLength = CMBlockBufferGetDataLength(block)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-silence-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000
        ])
        input.expectsMediaDataInRealTime = true
        #expect(writer.canAdd(input))
        writer.add(input)

        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let bufferCount = Int(rate * 1.5) / framesPerBuffer
        for index in 0..<bufferCount {
            let buffer = try #require(MovieWriter.makeSilence(
                formatDescription: format,
                asbd: asbd,
                at: CMTime(value: CMTimeValue(index * framesPerBuffer), timescale: CMTimeScale(rate)),
                frameCount: framesPerBuffer
            ))
            guard input.append(buffer) else {
                Issue.record("append #\(index) failed: \(String(describing: writer.error))")
                break
            }
        }
        input.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        #expect(writer.status == .completed)
        return dataLength
    }

    @Test("非交错立体声静音缓冲按双声道字节数构造，并可由写入器收尾")
    func nonInterleavedStereoIsWritable() async throws {
        let format = try makeNonInterleavedFormat(rate: 48_000, channels: 2)
        let dataLength = try await assertSilenceIsWritable(
            format: format,
            rate: 48_000,
            channels: 2,
            framesPerBuffer: 960
        )
        #expect(dataLength == 960 * 4 * 2)
    }

    @Test("非交错单声道（麦克风）静音缓冲可写入")
    func nonInterleavedMonoIsWritable() async throws {
        let format = try makeNonInterleavedFormat(rate: 96_000, channels: 1)
        let dataLength = try await assertSilenceIsWritable(
            format: format,
            rate: 96_000,
            channels: 1,
            framesPerBuffer: 512
        )
        #expect(dataLength == 512 * 4)
    }
}
