import Foundation
import ImageIO
import Testing

@testable import AnShotCore

/// 用户参考图仅从本地环境读取，不将对话内容纳入测试资源。
@Suite("长截图 · 本地参考图重放")
struct ScrollshotReferenceReplayTests {
    @Test("真实正文与固定整窗混合时，双向位移均须精确",
          .enabled(if: ProcessInfo.processInfo.environment["ANSHOT_REFERENCE_IMAGE"] != nil))
    func localReferenceWithFixedChrome() throws {
        let reference = try load("ANSHOT_REFERENCE_IMAGE")
        let chrome = try load("ANSHOT_CHROME_IMAGE")
        let body = ScrollshotViewport(x: 448, y: 74, width: 2456, height: reference.height - 374)
        let page = try #require(body.crop(reference))
        let lastStart = page.height - 2536
        for start in [0, lastStart / 2, lastStart] {
            try replay(page: page, chrome: chrome, start: start)
        }
    }

    private func replay(page: ScrollshotImage, chrome: ScrollshotImage, start: Int) throws {
        let viewport = ScrollshotViewport(x: 448, y: 74, width: page.width, height: 1420)
        let offsets = [0, 36, 252, 648, 1116, 1080, 864, 504, 144, 0]
        let frames = offsets.map { offset -> ScrollshotImage in
            var pixels = chrome.data
            for row in 0..<viewport.height {
                let from = (start + offset + row) * page.bytesPerRow
                let to = ((viewport.y + row) * chrome.width + viewport.x) * 4
                pixels.replaceSubrange(to..<(to + page.bytesPerRow),
                                       with: page.data[from..<(from + page.bytesPerRow)])
            }
            return ScrollshotImage(width: chrome.width, height: chrome.height, data: pixels)!
        }
        for index in 1..<frames.count {
            let match = try VerticalOverlap.estimate(previous: frames[index - 1], next: frames[index])
            let expected = offsets[index] - offsets[index - 1]
            print("reference start=\(start) frame=\(index) expected=\(expected) delta=\(match.deltaY) confidence=\(match.confidence) source=\(match.source)")
            #expect(match.deltaY == expected,
                    "帧 \(index)：预期 \(expected)，实际 \(match.deltaY) 来源 \(match.source) 置信度 \(match.confidence)")
            #expect(match.confidence >= 0.5)
        }
        var session = ScrollshotSession(options: .init(joinsInsideOverlap: true))
        for frame in frames { session.submit(frame) }
        let result = session.result()
        let output = try #require(result.image)
        #expect(output.width == chrome.width)
        #expect(output.height == chrome.height + offsets.max()!)
        let actualBody = try #require(ScrollshotViewport(
            x: viewport.x, y: viewport.y, width: page.width, height: viewport.height + offsets.max()!
        ).crop(output))
        let expectedBody = try #require(ScrollshotViewport(
            x: 0, y: start, width: page.width, height: actualBody.height
        ).crop(page))
        let bodyMatches = actualBody.data.elementsEqual(expectedBody.data)
        #expect(bodyMatches, "真实终端正文必须逐像素连续，侧栏保留在原选区内")
        let detail = try #require(session.slice(worldRows: 600..<1000, targetWidth: chrome.width))
        let expectedDetail = try #require(ScrollshotViewport(x: 0, y: 600, width: output.width, height: 400).crop(output))
        let detailMatches = detail.data.elementsEqual(expectedDetail.data)
        #expect(detailMatches)
        let preview = try #require(session.preview(fittingWidth: 317, fittingHeight: 631))
        var previewMatches = true
        for y in 0..<preview.image.height {
            for x in 0..<preview.image.width {
                let sourceY = y * output.height / preview.image.height
                let sourceX = x * output.width / preview.image.width
                let from = (sourceY * output.width + sourceX) * 4
                let to = (y * preview.image.width + x) * 4
                for channel in 0..<4 where output.data[from + channel] != preview.image.data[to + channel] {
                    previewMatches = false
                }
            }
        }
        #expect(previewMatches, "缩略图的每行必须来自对应输出行，不能在接缝处取错帧")
        var covered = 0
        for segment in result.plan.frames.filter({ $0.rows > 0 }).sorted(by: { $0.outputY! < $1.outputY! }) {
            #expect(segment.outputY == covered)
            covered += segment.rows
        }
        #expect(covered == output.height)
        if let path = ProcessInfo.processInfo.environment["ANSHOT_TEST_ARTIFACT_DIR"], let cgImage = output.makeCGImage() {
            let destination = try #require(CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path).appendingPathComponent("reference-replay-\(start).png") as CFURL,
                "public.png" as CFString, 1, nil
            ))
            CGImageDestinationAddImage(destination, cgImage, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
    }

    private func load(_ key: String) throws -> ScrollshotImage {
        let path = try #require(ProcessInfo.processInfo.environment[key])
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(ScrollshotImage(image))
    }
}
