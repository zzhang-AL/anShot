import Foundation
import ImageIO
import Testing

@testable import AnShotCore

@Suite("长截图 · 真实网页采集帧回归")
struct ScrollshotCapturedFrameTests {
    private func frame(_ name: String) throws -> ScrollshotImage {
        let directory = try #require(Bundle.module.url(forResource: "Scrollshot", withExtension: nil))
        let source = try #require(CGImageSourceCreateWithURL(
            directory.appendingPathComponent(name + ".png") as CFURL, nil
        ))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(ScrollshotImage(image))
    }

    @Test("真实中文网页下滚和上滚均解出已知的 400px")
    func realTextScrollMatchesKnownMovement() throws {
        let previous = try frame("previous")
        let next = try frame("next")
        for reverse in [false, true] {
            let from = reverse ? next : previous
            let to = reverse ? previous : next
            let match = try VerticalOverlap.estimate(previous: from, next: to)
            #expect(match.deltaY == (reverse ? -400 : 400))
            #expect(match.confidence >= 0.5)
            var session = ScrollshotSession()
            session.submit(from)
            let decision = session.submit(to)
            #expect(decision.verdict == .accepted)
            #expect(session.coveredWorldHeight == previous.height + 400)
            let output = try #require(session.result().image)
            #expect(output.height == previous.height + 400)
        }
    }

    @Test("连续滚动中的亚像素文字重采样不应使有重叠的帧跟丢")
    func fractionalTextRasterization() throws {
        let previous = try frame("previous")
        let next = try frame("next")
        for inverted in [false, true] {
            for fraction in [64, 128, 192] {
                let from = resampled(previous, fraction: 0, inverted: inverted)
                let to = resampled(next, fraction: fraction, inverted: inverted)
                for reverse in [false, true] {
                    let started = Date()
                    let match = try VerticalOverlap.estimate(
                        previous: reverse ? to : from, next: reverse ? from : to
                    )
                    let expected = reverse ? -400 : 400
                    print("fraction=\(fraction) inverted=\(inverted) reverse=\(reverse) delta=\(match.deltaY) confidence=\(match.confidence) ratio=\(match.matchRatio) source=\(match.source) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
                    #expect(abs(match.deltaY - expected) <= 1)
                    #expect(match.confidence >= 0.5)
                }
            }
        }
    }

    @Test("相位交替的连续滚动不能累积整行位置误差")
    func fractionalScrollDoesNotAccumulateDrift() throws {
        let previous = try frame("previous")
        let next = try frame("next")
        let tail = next.data[(next.height - 400) * next.bytesPerRow..<next.data.count]
        let page = try #require(ScrollshotImage(
            width: previous.width, height: previous.height + 400,
            data: previous.data + tail
        ))
        var session = ScrollshotSession(options: .init(joinsInsideOverlap: true))
        for index in 0..<8 {
            let image = try #require(ScrollshotViewport(
                x: 0, y: index * 110, width: page.width, height: 400
            ).crop(page))
            let decision = session.submit(resampled(image, fraction: index.isMultiple(of: 2) ? 0 : 128, inverted: true))
            print("phase sequence frame=\(index) delta=\(decision.deltaY) world=\(decision.worldOffset) verdict=\(decision.verdict)")
            #expect(decision.isAccepted)
            #expect(abs(decision.worldOffset - index * 110) <= 1)
        }
        #expect(abs(session.coveredWorldHeight - 1170) <= 1)
    }

    @Test("文字消失后的共同背景不能在平滑校验中变成对齐证据")
    func missingTextCannotPassSmoothedValidation() throws {
        let image = try frame("previous")
        for inverted in [false, true] {
            let from = resampled(image, fraction: 128, inverted: inverted)
            var bytes = [UInt8](repeating: inverted ? 231 : 24, count: image.data.count)
            for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
            let blank = try #require(ScrollshotImage(width: image.width, height: image.height, data: bytes))
            var session = ScrollshotSession(options: .init(joinsInsideOverlap: true))
            session.submit(from)
            let decision = session.submit(blank)
            #expect(decision.verdict == .unresolved)
            #expect(session.coveredWorldHeight == image.height)
        }
    }

    /// 仅在测试中模拟滚动合成器的相邻像素混合；反色同时覆盖白底正文。
    private func resampled(_ image: ScrollshotImage, fraction: Int, inverted: Bool) -> ScrollshotImage {
        var pixels = image.data
        for y in 0..<image.height {
            for x in 0..<image.width {
                let first = (y * image.width + x) * 4
                let second = (min(image.height - 1, y + 1) * image.width + x) * 4
                for channel in 0..<3 {
                    let value = (Int(image.data[first + channel]) * (256 - fraction)
                        + Int(image.data[second + channel]) * fraction) / 256
                    pixels[first + channel] = UInt8(inverted ? 255 - value : value)
                }
            }
        }
        return ScrollshotImage(width: image.width, height: image.height, data: pixels)!
    }
}
