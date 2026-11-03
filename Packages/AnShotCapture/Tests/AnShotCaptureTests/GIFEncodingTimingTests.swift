import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import AnShotCapture

@Suite("GIF 文件播放时长")
struct GIFEncodingTimingTests {
    @Test("12fps 在实际 GIF 文件中保持总时长", arguments: [15.0, 30.0, 60.0, 1.2])
    func encodedDurationDoesNotDrift(duration: TimeInterval) throws {
        let count = max(1, Int(duration * 12))
        let decoded = try roundTrip(duration: duration, slots: Array(repeating: 1, count: count))
        #expect(abs(decoded - duration) <= 0.011)
    }

    @Test("合并重复帧和跳过失败格后，实际文件仍保留尾段时长")
    func coalescedFramesKeepDuration() throws {
        let duration = 15.04
        let totalSlots = Int(duration * 12)
        var timeline = GIFFrameTimeline<Int>(isSame: ==)
        var emittedSlots: [Int] = []
        for slot in 0..<totalSlots {
            if slot.isMultiple(of: 13) { continue }
            if let emitted = timeline.accept(slot / 4, at: slot) {
                emittedSlots.append(emitted.slots)
            }
        }
        if let emitted = timeline.finish(totalSlots: totalSlots) { emittedSlots.append(emitted.slots) }
        #expect(emittedSlots.reduce(0, +) == totalSlots)
        let decoded = try roundTrip(duration: duration, slots: emittedSlots)
        #expect(abs(decoded - duration) <= 0.011)
    }

    private func roundTrip(duration: TimeInterval, slots: [Int]) throws -> TimeInterval {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString,
                                                                      slots.count, nil))
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var timing = GIFFrameTiming(frameRate: 12, totalSlots: slots.reduce(0, +), duration: duration)
        for (index, count) in slots.enumerated() {
            context.setFillColor(gray: index.isMultiple(of: 2) ? 0 : 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            let image = try #require(context.makeImage())
            CGImageDestinationAddImage(destination, image, timing.properties(slots: count))
        }
        try #require(CGImageDestinationFinalize(destination))
        let source = try #require(CGImageSourceCreateWithData(data, nil))
        var playback: TimeInterval = 0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any])
            let gif = try #require(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
            playback += try #require((gif[kCGImagePropertyGIFUnclampedDelayTime as String]
                                      ?? gif[kCGImagePropertyGIFDelayTime as String]) as? Double)
        }
        return playback
    }
}
