import Foundation
import Testing

@testable import AnShotCore

@Suite("长截图恢复 · 内容连续性")
struct ScrollshotRecoveryTests {

    @Test("高频收录仅保留输出像素段，双向接缝和明细保持逐像素一致")
    func compactStoragePreservesPixels() throws {
        let page = makePage(width: 300, pageHeight: 5000)
        var session = ScrollshotSession(options: .init(joinsInsideOverlap: true, retainsSourceFrames: false))
        let offsets = Array(stride(from: 1000, through: 1800, by: 40))
            + Array(stride(from: 1760, through: 600, by: -40))
        for offset in offsets {
            session.submit(slice(page, offset: offset, height: 400))
            let bound = (session.coveredWorldHeight + 800) * 300 * 4
            #expect(session.retainedPixelBytes <= bound, "像素内存不能随观察帧数线性增长")
        }
        #expect(session.acceptedFrameCount > 20)
        #expect(session.acceptedFrames.isEmpty)
        let image = try #require(session.result().image)
        let expected = slice(page, offset: 600, height: 1600)
        let matches = image.data.elementsEqual(expected.data)
        #expect(matches)
        let detail = try #require(session.slice(worldRows: 0..<300, targetWidth: 300))
        let detailMatches = detail.data.elementsEqual(slice(page, offset: 1000, height: 300).data)
        #expect(detailMatches)
    }

    /// 与正文没有对应关系的画面，用于模拟遮挡或页面切换。
    private func noisePage(seed: UInt64, height: Int = 400) -> ScrollshotImage {
        var random = PageRandom(state: seed)
        var data = [UInt8](repeating: 255, count: 300 * height * 4)
        for index in stride(from: 0, to: data.count, by: 4) {
            data[index] = UInt8(random.next() * 255)
            data[index + 1] = UInt8(random.next() * 255)
            data[index + 2] = UInt8(random.next() * 255)
        }
        return ScrollshotImage(width: 300, height: height, data: data)!
    }

    @Test("遮挡消失后回到重叠内容：恢复原坐标，明细、预览和导出均无断层")
    func recoversWithoutInventingCoordinates() throws {
        let page = makePage(width: 300, pageHeight: 3000)
        var session = ScrollshotSession()
        for offset in [1000, 1100] {
            session.submit(slice(page, offset: offset, height: 400))
        }
        for seed: UInt64 in [4242, 2026, 9999] {
            session.submit(noisePage(seed: seed))
        }
        let resumed = session.submit(slice(page, offset: 1200, height: 400))
        session.submit(slice(page, offset: 1300, height: 400))

        #expect(resumed.worldOffset == 200)
        let result = session.result()
        let image = try #require(result.image)
        let expected = slice(page, offset: 1000, height: 700)
        #expect(compare(image, expected).differentPixels == 0)
        let detail = try #require(session.slice(worldRows: 350..<650, targetWidth: 300))
        #expect(compare(detail, slice(page, offset: 1350, height: 300)).differentPixels == 0)
        let preview = try #require(session.preview(fittingWidth: 300, fittingHeight: 1000))
        #expect(compare(preview.image, expected).differentPixels == 0)

        // 每个输出区间必须紧贴上一段；透明空洞不能靠查看缩略图碰运气发现。
        var covered = 0
        for frame in result.plan.frames.filter({ $0.rows > 0 }).sorted(by: {
            ($0.outputY ?? 0) < ($1.outputY ?? 0)
        }) {
            #expect(frame.outputY == covered)
            covered += frame.rows
        }
        #expect(covered == image.height)
    }

    @Test("新画面自身能滚动也不能硬接旧图，已采内容保持逐像素一致")
    func unrelatedSceneCannotExtendOutput() throws {
        let page = makePage(width: 300, pageHeight: 3000)
        var session = ScrollshotSession()
        for offset in [1000, 1100] {
            session.submit(slice(page, offset: offset, height: 400))
        }
        let unrelated = noisePage(seed: 9191, height: 1200)
        for offset in [0, 80, 160, 240, 320] {
            let decision = session.submit(slice(unrelated, offset: offset, height: 400))
            #expect(decision.acceptedRows == 0)
        }
        let result = session.result()
        let image = try #require(result.image)
        #expect(compare(image, slice(page, offset: 1000, height: 500)).differentPixels == 0)
        #expect(!result.plan.warnings.isEmpty, "收尾必须告知仍有未对齐的内容")
    }

    @Test("成功配准隔开的失败不算连续失败")
    func successfulMatchResetsFailureCount() {
        let page = makePage(width: 300, pageHeight: 3000)
        var session = ScrollshotSession()
        session.submit(slice(page, offset: 1000, height: 400))
        session.submit(noisePage(seed: 4242))
        session.submit(noisePage(seed: 2026))
        let recovered = session.submit(slice(page, offset: 1100, height: 400))
        #expect(recovered.isAccepted)
        let isolatedFailure = session.submit(noisePage(seed: 9999))
        #expect(!isolatedFailure.stalled)
    }

    @Test("近零位移候选缺少像素对应时不能冒充静止帧，也不能替换可信基准")
    func unrelatedZeroDeltaIsNotDuplicate() {
        let page = makePage(width: 300, pageHeight: 3000)
        let first = slice(page, offset: 1000, height: 400)
        var session = ScrollshotSession(options: .init(
            overlap: .init(minOverlapRatio: 0.9975, maxOverlapRatio: 1)
        ))
        session.submit(first)
        let unrelated = session.submit(noisePage(seed: 4242))
        #expect(unrelated.verdict == .unresolved)
        let returned = session.submit(first)
        #expect(returned.verdict == .duplicate)
    }

    @Test("延迟采纳积累到丢失覆盖区重叠时，不允许生成未填充的输出行")
    func rejectsUncoveredGap() {
        let page = makePage(width: 300, pageHeight: 3000)
        var session = ScrollshotSession(options: .init(
            minConfidence: 1.1, transientDeltaThreshold: 1000
        ))
        for offset in [1000, 1100, 1200, 1300, 1400, 1500, 1500] {
            session.submit(slice(page, offset: offset, height: 400))
        }
        #expect(session.coveredWorldHeight == 400)
        #expect(session.result().failure == .noAcceptedFrame)
    }
}
