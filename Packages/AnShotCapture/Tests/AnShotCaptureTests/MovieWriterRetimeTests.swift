//
//  MovieWriterRetimeTests.swift
//  AnShotCaptureTests
//
//  重设时间戳时必须保留「每个采样的时长」：音频缓冲通常是一条计时项描述 N 个采样。
//

import CoreMedia
import Foundation
import Testing

@testable import AnShotCapture

@Suite("MovieWriter 时间戳平移")
struct MovieWriterRetimeTests {

    /// 造一块 `frames` 个采样的单声道 16-bit LPCM 缓冲，计时表只有一项（每采样 1/rate）。
    private func makeAudioBuffer(frames: Int, rate: Double, pts: CMTime) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr)

        let length = frames * 2
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        let dataBuffer = try #require(block)
        let formatDescription = try #require(format)
        var sampleSize = 2
        var buffer: CMSampleBuffer?
        #expect(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: dataBuffer,
            formatDescription: formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &buffer
        ) == noErr)
        return try #require(buffer)
    }

    @Test("平移后起点为新时间戳，总时长不变（不放大 N 倍）")
    func retimePreservesPerSampleDuration() throws {
        let original = try makeAudioBuffer(
            frames: 1024,
            rate: 48_000,
            pts: CMTime(value: 123_456, timescale: 48_000)
        )
        let target = CMTime(value: 4_800, timescale: 48_000)

        let retimed = try #require(MovieWriter.retimed(original, to: target))

        #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(retimed), target) == 0)
        #expect(CMSampleBufferGetNumSamples(retimed) == 1024)
        let expected = CMSampleBufferGetDuration(original)
        #expect(CMTimeCompare(CMSampleBufferGetDuration(retimed), expected) == 0)
        #expect(abs(CMSampleBufferGetDuration(retimed).seconds - 1024.0 / 48_000) < 1e-9)
    }
}
