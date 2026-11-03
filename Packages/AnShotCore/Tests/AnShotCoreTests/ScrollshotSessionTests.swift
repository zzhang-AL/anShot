//
//  ScrollshotSessionTests.swift
//  AnShotCoreTests
//
//  世界坐标追踪与采纳决策的测试。
//
//  ── 为什么必须用「整页 → 切帧」而不是造假位移 ──────────────
//
//  本层的全部难点都在「位移从哪来」：它由相邻帧配准得出，而不是调用方给的。
//  所以测试必须真的渲染一整页、按已知的视口偏移切帧——这样真值（视口偏移）
//  与实现（配准累积）互相独立，配准错了、坐标漂了、回滚判反了，都会在
//  结果图上暴露成重复或错位。
//
//  ── 本文件守住的核心不变量 ────────────────────────────────
//
//  1. **上下反复滚动不产生新内容**：回滚帧与「回到已覆盖区」的帧都不进输出，
//     帧数与输出高度都不增长；
//  2. **回滚后继续向下滚，已覆盖的内容不重复粘贴**；
//  3. **方向不可信时不许静默丢弃**，必须留下告警（FAIL-OPEN）。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotCore

@Suite("长截图会话 · 世界坐标与上下滚动")
struct ScrollshotSessionTests {

    /// 构造一帧：前 `headerRows` 行是**固定吸顶栏**（不随滚动变化）。
    ///
    /// 顶栏用**与正文明显不同**的纯色（模拟真实导航栏的色块/logo），而不是从页面
    /// 拷贝一段方块——`makePage` 是等距规律内容，拷贝出来的顶栏与正文过于相似，
    /// 会让「同位置 vs 滚动位置」的对照判据失效（实测只能检测出 8/40 行）。
    private func stickyFrame(
        _ page: ScrollshotImage,
        scrollOffset: Int,
        headerRows: Int,
        frameHeight: Int
    ) -> ScrollshotImage {
        let body = slice(page, offset: scrollOffset, height: frameHeight)
        var data = body.data
        let bytesPerRow = body.width * 4
        data.withUnsafeMutableBufferPointer { target in
            guard let dst = target.baseAddress else { return }
            for row in 0..<headerRows {
                for x in 0..<body.width {
                    let offset = row * bytesPerRow + x * 4
                    dst[offset] = 30
                    dst[offset + 1] = 60
                    dst[offset + 2] = 120
                    dst[offset + 3] = 255
                }
            }
        }
        return ScrollshotImage(width: body.width, height: frameHeight, data: data)!
    }

    /// 构造一帧：顶部 `blankRows` 行是**背景空白**（模拟终端/TUI 的顶边留白）。
    ///
    /// 这是「假吸顶」的现场：空白区里「同位置」和「滚动位置」的像素都接近背景，
    /// 判据若只看谁更相似，就等于在比噪声，会把空白逐行累加成固定行数。
    private func blankTopFrame(
        _ page: ScrollshotImage,
        scrollOffset: Int,
        blankRows: Int,
        frameHeight: Int
    ) -> ScrollshotImage {
        let body = slice(page, offset: scrollOffset, height: frameHeight)
        var data = body.data
        let bytesPerRow = body.width * 4
        // 取页面本身的背景色（左上角像素）来填充，避免凭空假定颜色。
        let bg = (r: data[0], g: data[1], b: data[2])
        data.withUnsafeMutableBufferPointer { target in
            guard let dst = target.baseAddress else { return }
            for row in 0..<blankRows {
                for x in 0..<body.width {
                    let offset = row * bytesPerRow + x * 4
                    dst[offset] = bg.r
                    dst[offset + 1] = bg.g
                    dst[offset + 2] = bg.b
                    dst[offset + 3] = 255
                }
            }
        }
        return ScrollshotImage(width: body.width, height: frameHeight, data: data)!
    }

    /// 构造一帧：顶部（或底部）`bandRows` 行是**屏幕固定元素**（纯色，不随滚动变化）。
    ///
    /// 与 `stickyFrame` 的区别：`stickyFrame` 模拟的是**页面自己的顶栏**（有内容，
    /// 属于滚动内容之外的一段固定内容）；这里模拟的是**屏幕固定元素**（窗口边框、
    /// 分隔带、常驻状态栏）——它是**纯色**，行内对比度为 0，与页面留白在单帧里
    /// 完全同形。这正是自动检测天然测不出来、必须靠 `unusableTopRows` /
    /// `unusableBottomRows` 兜底的那类。
    private func viewportBandFrame(
        _ page: ScrollshotImage,
        scrollOffset: Int,
        bandRows: Int,
        frameHeight: Int,
        atBottom: Bool = false
    ) -> ScrollshotImage {
        let body = slice(page, offset: scrollOffset, height: frameHeight)
        var data = body.data
        let bytesPerRow = body.width * 4
        data.withUnsafeMutableBufferPointer { target in
            guard let dst = target.baseAddress else { return }
            for step in 0..<bandRows {
                let row = atBottom ? frameHeight - 1 - step : step
                for x in 0..<body.width {
                    let offset = row * bytesPerRow + x * 4
                    // 品红：与 `makePage` 的灰底与深灰方块都不冲突，便于整行断言。
                    dst[offset] = 250
                    dst[offset + 1] = 20
                    dst[offset + 2] = 200
                    dst[offset + 3] = 255
                }
            }
        }
        return ScrollshotImage(width: body.width, height: frameHeight, data: data)!
    }

    /// 输出里「整行都是固定带色」的行号。
    ///
    /// 这就是缺陷的判据：固定带一旦被当成内容贴进长图，就会出现整行带色的行。
    private func fixedBandRows(_ image: ScrollshotImage) -> [Int] {
        var rows: [Int] = []
        image.withPixels { pixels in
            for y in 0..<image.height {
                let base = y * image.width * 4
                var isBand = true
                for x in 0..<image.width {
                    let index = base + x * 4
                    if pixels[index] != 250 || pixels[index + 1] != 20 || pixels[index + 2] != 200 {
                        isBand = false
                        break
                    }
                }
                if isBand { rows.append(y) }
            }
        }
        return rows
    }

    /// 缩略图第 `thumbY` 行是否与长图第 `fullY` 行逐像素一致（按宽度采样对齐）。
    ///
    /// 拆成「任意两行」的比对而不是只比首末行：缩略图是按比例重采样的，它的**末行**
    /// 对应的是长图末尾往上不到一个缩略图行距的位置，不是精确的最后一行——比对
    /// 「末行 vs 长图末行」只有在内容恰好周期性对齐时才碰巧成立。
    private func thumbRowMatches(
        _ thumb: ScrollshotImage,
        _ thumbY: Int,
        _ full: ScrollshotImage,
        _ fullY: Int
    ) -> Bool {
        var equal = true
        thumb.withPixels { t in
            full.withPixels { f in
                for thumbX in 0..<thumb.width {
                    let column = min(full.width - 1, thumbX * full.width / thumb.width)
                    let ti = (thumbY * thumb.width + thumbX) * 4
                    let fi = (fullY * full.width + column) * 4
                    if t[ti] != f[fi] || t[ti + 1] != f[fi + 1] || t[ti + 2] != f[fi + 2] {
                        equal = false
                        return
                    }
                }
            }
        }
        return equal
    }

    /// 吸顶栏内容在输出图里重复出现了几处。
    private func headerRepeats(_ image: ScrollshotImage, headerRows: Int) -> Int {
        let top = slice(image, offset: 0, height: headerRows)
        var repeats = 0
        var y = headerRows
        while y + headerRows <= image.height {
            let band = slice(image, offset: y, height: headerRows)
            if compare(top, band).differentPixels == 0 { repeats += 1 }
            y += 10
        }
        return repeats
    }

    /// 按视口偏移序列驱动一次会话，返回逐步结论。
    private func drive(
        _ page: ScrollshotImage,
        offsets: [Int],
        frameHeight: Int = 480,
        options: ScrollStitcher.Options = ScrollStitcher.Options()
    ) -> (session: ScrollshotSession, verdicts: [ScrollshotSession.Verdict]) {
        var session = ScrollshotSession(options: options)
        let verdicts = offsets.map { offset in
            session.submit(slice(page, offset: offset, height: frameHeight)).verdict
        }
        return (session, verdicts)
    }

    @Test("向下滚 → 回滚 → 再向下滚：回滚不增加输出，恢复后不重复粘贴")
    func rewindThenResume() throws {
        let page = makePage(pageHeight: 3000)
        let frameHeight = 480
        // 视口轨迹：0 → 200 → 400 →（回滚）200 → 400 → 600
        let offsets = [0, 200, 400, 200, 400, 600]
        let (session, verdicts) = drive(page, offsets: offsets, frameHeight: frameHeight)

        #expect(verdicts[0] == .accepted)
        #expect(verdicts[1] == .accepted)
        #expect(verdicts[2] == .accepted)
        // 回滚帧：内容已经贴过，不能再粘一遍。
        #expect(verdicts[3] == .rewind, "回滚帧的结论是 \(verdicts[3])")
        // 回到回滚前的位置：还没超出已覆盖区。
        #expect(verdicts[4] == .alreadyCovered, "返回原位的结论是 \(verdicts[4])")
        // 重新越过已覆盖区边界后才算新内容。
        #expect(verdicts[5] == .accepted, "重新前进的结论是 \(verdicts[5])")

        // 只有 4 帧进入输出：0 / 200 / 400 / 600，回滚与复位两帧都不算。
        #expect(session.acceptedFrames.count == 4, "采纳帧数 \(session.acceptedFrames.count)")

        let result = session.result()
        let image = try #require(result.image)
        #expect(result.failure == nil)
        // 输出高度 = 首帧 + 最大前进量，回滚不贡献任何行。
        #expect(image.height == frameHeight + 600, "输出高度 \(image.height)")

        // 逐像素比对：重复、错位、漏接任何一种都会在这里暴露。
        let expected = slice(page, offset: 0, height: frameHeight + 600)
        let diff = compare(image, expected)
        #expect(diff.differentPixels == 0, "不同像素 \(diff.differentPixels)，最大误差 \(diff.maxError)")
    }

    @Test("反复上下滚动：帧数与输出高度都不增长（不反复采集）")
    func repeatedScrollingDoesNotAccumulate() throws {
        let page = makePage(pageHeight: 3000)
        let frameHeight = 480

        var session = ScrollshotSession()
        // 先一路向下滚到 600。
        for offset in [0, 200, 400, 600] {
            session.submit(slice(page, offset: offset, height: frameHeight))
        }
        let framesAfterForward = session.acceptedFrames.count
        let heightAfterForward = session.coveredWorldHeight
        #expect(framesAfterForward == 4)

        // 来回滚 10 轮：400 ↔ 600 之间反复横跳。
        var acceptedDuringScrolling = 0
        for round in 0..<10 {
            let offset = round.isMultiple(of: 2) ? 400 : 600
            let decision = session.submit(slice(page, offset: offset, height: frameHeight))
            if decision.isAccepted { acceptedDuringScrolling += 1 }
        }

        #expect(acceptedDuringScrolling == 0, "回滚期间仍然采纳了 \(acceptedDuringScrolling) 帧")
        #expect(
            session.acceptedFrames.count == framesAfterForward,
            "回滚期间帧数从 \(framesAfterForward) 涨到 \(session.acceptedFrames.count)"
        )
        #expect(
            session.coveredWorldHeight == heightAfterForward,
            "回滚期间输出高度从 \(heightAfterForward) 涨到 \(session.coveredWorldHeight)"
        )
    }

    @Test("首帧之上还有内容：向上滚同样能拼（长图两端都在生长）")
    func extendsUpwardFromFirstFrame() throws {
        let page = makePage(pageHeight: 3000)
        let frameHeight = 480
        // 首帧落在页面 offset 600（= 世界 0），之后一路**向上**滚到页面顶部。
        // 首帧上方还有 600px 内容——它们必须能被采到，这正是「向上也能长截图」
        // 与「回滚只是不重复采集」的分界。
        let offsets = stride(from: 600, through: 0, by: -40).map { $0 }
        // 下面还要再提交一帧「停手帧」，所以 session 需要可变。
        var (session, verdicts) = drive(page, offsets: offsets, frameHeight: frameHeight)

        // 向上滚的每一步都指向未覆盖区：要么直接采纳，要么因新内容不足阈值先攒着
        // （`transient`，下一步会连同它一起越过阈值）。**不该**出现 rewind /
        // alreadyCovered / duplicate —— 那意味着把"还没采过的上方内容"误判成已采过。
        let misjudged = verdicts.dropFirst().filter {
            $0 == .rewind || $0 == .alreadyCovered || $0 == .duplicate
        }
        #expect(misjudged.isEmpty, "向上滚时被误判为「已覆盖」：\(misjudged)")

        // 停手时允许补齐待采内容，也允许此前已准确收录完毕；最终像素必须完整。
        let settled = session.submit(slice(page, offset: 0, height: frameHeight))
        #expect(settled.verdict == .accepted || settled.verdict == .duplicate)

        // 世界区间从 −600 延伸到 480 → 总高 1080。
        #expect(session.coveredWorldHeight == 1080, "总高 \(session.coveredWorldHeight)")

        let image = try #require(session.result().image)
        #expect(image.height == 1080, "输出高度 \(image.height)")
        let expected = slice(page, offset: 0, height: 1080)
        #expect(compare(image, expected).differentPixels == 0, "向上拼接的内容出现重复或错位")
    }

    @Test("先向下再向上：两端都能扩展，内容等于整段世界区间")
    func extendsBothDirections() throws {
        let page = makePage(pageHeight: 3000)
        let frameHeight = 480
        // 首帧在页面 offset 600：先向下滚到 1200（世界 +600），
        // 再一路向上滚到页面顶部（世界 −600）。
        let offsets = [600, 800, 1000, 1200, 1000, 800, 600, 400, 200, 0]
        let (session, _) = drive(page, offsets: offsets, frameHeight: frameHeight)

        // 世界区间 [−600, 1080) → 总高 1680，恰好是页面 [0, 1680)。
        #expect(session.coveredWorldHeight == 1680, "总高 \(session.coveredWorldHeight)")
        let image = try #require(session.result().image)
        #expect(image.height == 1680, "输出高度 \(image.height)")
        let expected = slice(page, offset: 0, height: 1680)
        #expect(compare(image, expected).differentPixels == 0, "双向拼接的内容出现重复或错位")
    }

    @Test("小幅连续回滚逐格退回：每一步都判为回滚，不累积漂移")
    func gradualRewindKeepsOffsetTrue() throws {
        let page = makePage(pageHeight: 3000)
        let frameHeight = 480

        var session = ScrollshotSession()
        // 先向下滚 400。
        for offset in [0, 200, 400] {
            session.submit(slice(page, offset: offset, height: frameHeight))
        }
        // 再逐格退回 0，然后又逐格回到 400。
        for offset in stride(from: 360, through: 0, by: -40) {
            let decision = session.submit(slice(page, offset: offset, height: frameHeight))
            #expect(decision.verdict == .rewind, "回退到 \(offset) 的结论是 \(decision.verdict)")
        }
        // 退回过程中「预先存在的首帧区域」也算回滚（世界坐标比首帧更靠上）。
        #expect(session.coveredWorldHeight == frameHeight + 400)

        // 再往下滚：必须**继续从 400 之后**接，而不是重复已经采过的区间。
        for offset in stride(from: 40, through: 600, by: 40) {
            session.submit(slice(page, offset: offset, height: frameHeight))
        }
        // 用户停手：画面不再变化，此时攒下但尚未满阈值的那几十像素应当补上——
        // 否则「滚完就停」的会话总会在末尾差一截。
        let settled = session.submit(slice(page, offset: 600, height: frameHeight))
        #expect(settled.verdict == .accepted || settled.verdict == .duplicate)

        let image = try #require(session.result().image)
        #expect(image.height == frameHeight + 600, "输出高度 \(image.height)")
        let expected = slice(page, offset: 0, height: frameHeight + 600)
        #expect(compare(image, expected).differentPixels == 0, "回滚往返后内容出现重复或错位")
    }

    @Test("预览：整幅长图等比 contain 进导航栏 + 当前位置标记")
    func previewShowsWholeImage() throws {
        let page = makePage(width: 600, pageHeight: 8000)
        let frameHeight = 480
        var session = ScrollshotSession()
        // 一路向下滚 10 次，再多提交一帧「停手帧」把末尾补齐。
        for index in 0..<10 {
            session.submit(slice(page, offset: index * 400, height: frameHeight))
        }
        session.submit(slice(page, offset: 9 * 400, height: frameHeight))

        let full = try #require(session.result().image)
        let boxWidth = 168
        let boxHeight = 488
        let preview = try #require(
            session.preview(fittingWidth: boxWidth, fittingHeight: boxHeight)
        )
        let thumb = preview.image

        // ① **整幅 contain**：宽高都不超过框，且至少一边贴边——按宽度铺满的实现
        //    在这里会因高度溢出而失败。
        #expect(thumb.width <= boxWidth, "缩略图宽度 \(thumb.width) 超过框")
        #expect(thumb.height <= boxHeight, "缩略图高度 \(thumb.height) 超过框")
        #expect(
            abs(thumb.width - boxWidth) <= 1 || abs(thumb.height - boxHeight) <= 1,
            "缩略图 \(thumb.width)x\(thumb.height) 没有贴住框的任意一边"
        )
        // 等比：用交叉相乘比比例，而不是拿取整后的宽度反推高度——缩略图宽高都是
        // 向下取整的，反推会把两次取整的误差叠加成一个看起来很大的差值。
        let thumbAspect = Double(thumb.height) / Double(thumb.width)
        let sourceAspect = Double(full.height) / Double(full.width)
        #expect(
            abs(thumbAspect - sourceAspect) / sourceAspect < 0.02,
            "缩略图 \(thumb.width)x\(thumb.height) 与长图 \(full.width)x\(full.height) 不同比"
        )

        // ② 首行与末行都缩进去了——「看得到整个长截图」的直接证据。
        //    末行对应长图末尾往上不到一个缩略图行距的位置，不是精确的最后一行。
        let lastThumbRow = thumb.height - 1
        let lastFullRow = lastThumbRow * full.height / thumb.height
        #expect(thumbRowMatches(thumb, 0, full, 0), "缩略图首行与长图首行不一致")
        #expect(
            thumbRowMatches(thumb, lastThumbRow, full, lastFullRow),
            "缩略图末行与长图第 \(lastFullRow) 行不一致"
        )
        let rowPitch = full.height / thumb.height
        #expect(
            full.height - lastFullRow <= rowPitch + 1,
            "长图末尾还有 \(full.height - lastFullRow) 行没进缩略图（超过一个行距 \(rowPitch)）"
        )

        // ③ 世界坐标基准：缩略图覆盖的就是已拼的整段世界区间；界面靠它做换算。
        #expect(preview.worldStart == session.coveredWorldStart)
        #expect(preview.worldHeight == full.height, "缩略图覆盖 \(preview.worldHeight) 行，长图 \(full.height) 行")
        #expect(preview.worldWidth == full.width)

        // ④ 位置标记：当前视口在世界坐标里占的行数应等于帧高一档，
        //    且底端对齐已覆盖末尾（用户刚滚到过的地方）。
        let rows = try #require(preview.viewportWorldRows)
        #expect(abs(rows.count - frameHeight) <= 2, "位置标记 \(rows.count) 行，应为帧高 \(frameHeight)")
        #expect(
            rows.upperBound >= preview.worldStart + preview.worldHeight - 2,
            "位置标记未对齐到长图末尾"
        )
    }

    @Test("切片：按世界行区间取到的像素与长图对应的那一段一致")
    func sliceMatchesLongImageRows() throws {
        let page = makePage(width: 600, pageHeight: 8000)
        let frameHeight = 480
        var session = ScrollshotSession()
        for index in 0..<10 {
            session.submit(slice(page, offset: index * 400, height: frameHeight))
        }
        session.submit(slice(page, offset: 9 * 400, height: frameHeight))

        let full = try #require(session.result().image)
        // 世界行 → 图内行要减掉 coveredWorldStart（本用例只向下滚，它是 0，
        // 但不能把这一点写进断言——向上滚的场景由下一条用例覆盖）。
        let worldRows = 900..<1140
        let cut = try #require(session.slice(worldRows: worldRows, targetWidth: full.width))

        #expect(cut.width == full.width, "宽度 \(cut.width) 与长图 \(full.width) 不一致")
        #expect(cut.height == worldRows.count, "高度 \(cut.height) 与请求行数 \(worldRows.count) 不一致")

        let offset = worldRows.lowerBound - session.coveredWorldStart
        let expected = slice(full, offset: offset, height: worldRows.count)
        #expect(compare(cut, expected).differentPixels == 0, "切片内容与长图对应的那一段不一致")

        // 横向缩到一半：高度同比例跟着减半（等比，不是各缩各的）。
        let half = try #require(session.slice(worldRows: 400..<1200, targetWidth: full.width / 2))
        #expect(half.width == full.width / 2)
        #expect(half.height == 400, "高度 \(half.height)，等比应为 400")

        // 越界区间裁剪到已覆盖范围，而不是失败——定位框贴到边界时就是这种请求。
        let clipped = try #require(
            session.slice(worldRows: (full.height - 120)..<(full.height + 500), targetWidth: full.width)
        )
        #expect(clipped.height == 120, "越界区间应裁到已覆盖末尾，实得 \(clipped.height) 行")

        // 完全落在已覆盖范围之外：没有像素可给，如实返回 nil。
        let beyond = (full.height + 10_000)..<(full.height + 12_000)
        #expect(session.slice(worldRows: beyond, targetWidth: full.width) == nil)
    }

    @Test("切片：向上滚动画内起点平移后，同一世界区间仍指向同一段内容")
    func sliceKeepsMeaningWhenWorldStartShifts() throws {
        let page = makePage(width: 600, pageHeight: 8000)
        let frameHeight = 480
        var session = ScrollshotSession()
        // 首帧落在页面 2000 处：它上方的 2000 行是**尚未覆盖**的内容，
        // 之后向上滚会压低 coveredWorldStart，整张图的图内起点随之平移。
        session.submit(slice(page, offset: 2000, height: frameHeight))
        session.submit(slice(page, offset: 2400, height: frameHeight))
        let beforeStart = session.coveredWorldStart

        // 界面（浮层定位框）手里的位置是世界行，跨多次预览持有。
        //
        // 注意世界原点在**首帧顶部**，不是页面顶部：首帧落在页面 2000 处，所以
        // 页面 2000 对应世界 0。下面这段世界区间就是首帧那一段。
        let markerWorldRows = 0..<frameHeight
        let before = try #require(session.slice(worldRows: markerWorldRows, targetWidth: 600))

        // 向上滚的步长必须**小于帧高**：一步跨过整帧时两帧毫无重叠，配准只能失败，
        // 会话随即判定跟丢（那是正确行为，测不到「向上扩展」这件事）。
        // 起点接在上一帧 2400 之后 200 行处，逐格回退到越过首帧位置（2000）以下。
        for offset in stride(from: 2200, through: 1200, by: -200) {
            session.submit(slice(page, offset: offset, height: frameHeight))
        }
        #expect(session.coveredWorldStart < beforeStart, "向上滚动应压低世界起点")

        let after = try #require(session.slice(worldRows: markerWorldRows, targetWidth: 600))
        #expect(
            compare(before, after).differentPixels == 0,
            "世界起点平移后，同一世界行区间取到了别的像素"
        )
    }

    @Test("方向不可信的帧：判 unresolved 并告警，而不是静默丢弃")
    func unreliableReverseIsReported() throws {
        let page = makePage(pageHeight: 3000)
        let frameHeight = 480
        var session = ScrollshotSession()
        session.submit(slice(page, offset: 0, height: frameHeight))
        session.submit(slice(page, offset: 200, height: frameHeight))

        // 一帧与页面毫无关系的噪声：模拟内容整体变化（切换页面、视频、弹窗遮挡）。
        var random = PageRandom(state: 4242)
        var noise = [UInt8](repeating: 0, count: 300 * frameHeight * 4)
        for index in stride(from: 0, to: noise.count, by: 4) {
            noise[index] = UInt8(random.next() * 255)
            noise[index + 1] = UInt8(random.next() * 255)
            noise[index + 2] = UInt8(random.next() * 255)
            noise[index + 3] = 255
        }
        let chaotic = try #require(ScrollshotImage(width: 300, height: frameHeight, data: noise))

        let decision = session.submit(chaotic)
        #expect(decision.verdict != .duplicate, "配准不可信的帧被当成「没滚动」静默丢掉了")
        #expect(decision.verdict != .accepted, "配准不可信的帧不应凭猜测贴进长图")
        #expect(!decision.warnings.isEmpty, "不可信的帧被丢弃却没有留下任何说明")
        // 不可信帧不得污染世界坐标：后续帧仍应接着上一次可信位置推进。
        let before = session.coveredWorldHeight

        let resumed = session.submit(slice(page, offset: 400, height: frameHeight))
        #expect(resumed.verdict == .accepted, "恢复后的结论是 \(resumed.verdict)")
        let image = try #require(session.result().image)
        #expect(image.height == frameHeight + 400, "输出高度 \(image.height)")
        #expect(before == frameHeight + 200)
        let expected = slice(page, offset: 0, height: frameHeight + 400)
        #expect(compare(image, expected).differentPixels == 0, "不可信帧污染了世界坐标")
    }

    @Test("计划与采纳帧一一对应：每个 accepted 都有输出区间")
    func planMatchesAcceptedFrames() throws {
        // 走一条混合轨迹（前进 / 回滚 / 回位 / 重复），把 `result()` 里
        // 「决策序列」与「粘合片段」的对应关系压到极限：
        // 两侧顺序一旦错位，就会出现「判为采纳却没有输出位置」或反之。
        let page = makePage(pageHeight: 3000)
        let frameHeight = 480
        let offsets = [0, 200, 400, 200, 400, 600, 600, 100, 600, 800]
        let (session, _) = drive(page, offsets: offsets, frameHeight: frameHeight)
        let plan = session.result().plan

        let accepted = plan.frames.filter { $0.verdict == .accepted }
        #expect(
            accepted.count == session.acceptedFrames.count,
            "计划里的采纳帧数 \(accepted.count) 与 session 的 \(session.acceptedFrames.count) 不一致"
        )
        for decision in accepted {
            #expect(decision.outputY != nil, "第 \(decision.inputIndex) 帧判为采纳却没有输出位置")
            #expect(decision.rows > 0, "第 \(decision.inputIndex) 帧被采纳了 0 行")
        }
        for decision in plan.frames where decision.verdict != .accepted {
            #expect(
                decision.outputY == nil && decision.rows == 0,
                "第 \(decision.inputIndex) 帧未采纳却占了输出区间"
            )
        }

        // 末段末端必须等于计划高度；接缝数比采纳帧数少一。
        let last = try #require(accepted.last)
        let lastY = try #require(last.outputY)
        #expect(
            lastY + last.rows == plan.outputHeight,
            "计划高度 \(plan.outputHeight) 与末段末端 \(lastY + last.rows) 不一致"
        )
        #expect(plan.seamRows.count == accepted.count - 1)
    }

    @Test("sticky 顶栏：回滚往返后顶栏仍只出现一次")
    func stickyHeaderSurvivesRewind() throws {
        let page = makePage(pageHeight: 2000)
        let headerRows = 40
        let frameHeight = 400
        let options = ScrollStitcher.Options(stickyHeaderRows: headerRows)
        var session = ScrollshotSession(options: options)
        // 0 → 100 → 200 →（回滚）100 → 200 → 300
        for offset in [0, 100, 200, 100, 200, 300] {
            session.submit(stickyFrame(page, scrollOffset: offset, headerRows: headerRows, frameHeight: frameHeight))
        }

        let image = try #require(session.result().image)
        // 允许几像素偏差：相邻行相似时配准可能取到 ±1px 的邻居，多次拼接会累积。
        let expectedHeight = frameHeight + 300
        #expect(
            abs(image.height - expectedHeight) <= 4,
            "输出高度 \(image.height)，期望约 \(expectedHeight)"
        )
        // 顶栏只应出现在最顶端一次。
        #expect(headerRepeats(image, headerRows: headerRows) == 0, "顶栏内容在输出里重复出现了")
    }

    @Test("达到高度上限不是跟丢：位置一直可信，只该报上限")
    func heightLimitIsNotStall() throws {
        // 这两件事从产物上就不同：
        //   * 上限——已采到的部分是一张**可用**的长图，用户该收尾；
        //   * 跟丢——位置不可信，拼下去只会错位，用户该重来。
        // 界面上一旦把上限说成「位置丢失」，用户就会丢掉一张其实能用的图。
        // 而两者在界面层长得像：帧到顶后都不再增长、都不再采纳新帧。
        let page = makePage(pageHeight: 3000)
        let frameHeight = 480
        // 上限设得比页面小得多，滚几帧就到顶。
        let options = ScrollStitcher.Options(maxOutputHeight: 1000)
        var session = ScrollshotSession(options: options)

        var decisions: [ScrollshotSession.Decision] = []
        for offset in stride(from: 0, through: 2000, by: 200) {
            decisions.append(session.submit(slice(page, offset: offset, height: frameHeight)))
        }

        // 确实顶到了上限（否则这个测试什么也没测）。
        #expect(session.coveredWorldHeight == 1000, "覆盖高度 \(session.coveredWorldHeight)")
        // 上限走的是 warnings，**不是** stalled：配准始终成功，位置始终可信。
        #expect(
            decisions.contains { $0.warnings.contains { $0.contains("高度上限") } },
            "没有任何一帧报出高度上限"
        )
        #expect(
            decisions.allSatisfy { !$0.stalled },
            "把高度上限误报成了跟丢——界面会因此让用户白丢一张能用的长图"
        )
        // 到顶之后的帧确实不再被采纳（长图不会无限长）。
        #expect(decisions.last?.isAccepted == false, "到顶后的帧仍在被采纳")
        // 产物本身仍然可用。
        #expect(session.result().image?.height == 1000, "产物高度不对")
    }

    @Test("连续配准失败：保留可信基准，坐标和已采内容均不改变")
    func consecutiveFailuresReportStall() throws {
        let page = makePage(width: 400, pageHeight: 3000)
        var random = PageRandom(state: 4242)
        func noise() -> ScrollshotImage {
            var data = [UInt8](repeating: 255, count: 400 * 400 * 4)
            for index in stride(from: 0, to: data.count, by: 4) {
                data[index] = UInt8(random.next() * 255)
                data[index + 1] = UInt8(random.next() * 255)
                data[index + 2] = UInt8(random.next() * 255)
            }
            return ScrollshotImage(width: 400, height: 400, data: data)!
        }

        var session = ScrollshotSession()
        let first = session.submit(slice(page, offset: 0, height: 400))
        #expect(!first.stalled)
        let decisions = (0..<4).map { _ in session.submit(noise()) }
        #expect(decisions.allSatisfy { $0.verdict == .unresolved })
        #expect(!decisions[0].stalled)
        #expect(decisions[2].stalled)
        #expect(decisions[3].stalled)
        #expect(session.isStalled)
        #expect(session.coveredWorldHeight == 400)
        for decision in decisions {
            #expect(decision.worldOffset == first.worldOffset)
            #expect(decision.acceptedRows == 0)
            #expect(decision.sourceY == nil)
        }
    }

    @Test("顶部留白不得被误判为吸顶栏（真实终端顶边的形态）")
    func blankTopIsNotSticky() throws {
        // 真实故障现场：终端/TUI 顶部有一条边框 + 约 16px 空白，下面才是滚动内容。
        // 原判据在这里退化成「比噪声大小」，把空白逐行累加成假吸顶（实测 4~11 行、
        // 每帧还不同），向上滚动时每帧都跳过这些像素，累计约 90px ≈ 2.7 行文字，
        // 接缝落在文字中间 —— 就是用户看到的「字只有一半」。
        let page = makePage(width: 400, pageHeight: 6000)
        var session = ScrollshotSession()
        var offset = 0
        // 步长刻意变化：固定步长会让周期性内容在投票里被误判（见 sticky 检测说明）。
        for index in 0..<6 {
            let frame = blankTopFrame(
                page, scrollOffset: offset, blankRows: 20, frameHeight: 400
            )
            session.submit(frame)
            offset += 37 + (index * 13) % 29
        }

        #expect(
            session.detectedStickyRows == 0,
            "顶部空白被误判成吸顶栏（检测出 \(session.detectedStickyRows) 行）"
        )
    }

    @Test("视口顶部的固定带（纯色）不得被当作内容贴进长图 —— 「字只有一半」的根因")
    func viewportFixedBandIsNotPasted() throws {
        // 真实故障现场（14 帧全帧会话离线复算）：视口顶部有约 10 行（@2x）固定在
        // 屏幕上的元素。它不随内容滚动，却是纯色 —— 自动检测要求的「同位置相同、
        // 滚动位置明显不同」在它上面两项都趋零（实测 13 组相邻帧只有 1~6 票，
        // 过半需 ≥7），**检测天然测不出来**。
        //
        // 测不出来的后果不是「少跳几行空白」：向上扩展取的是帧顶部的新行，固定带
        // 正好在那里，于是每帧把固定带当作内容贴进世界坐标，**同时把它遮住的真实
        // 内容永久丢弃** —— 每处接缝丢同样多行，接缝落在文字行上就是「字只有一半」。
        let page = makePage(width: 300, pageHeight: 4000)
        let band = 12
        let frameHeight = 400
        let offsets = [2000, 1900, 1800, 1700, 1600]

        func run(unusableTopRows: Int) throws -> ScrollshotImage {
            var session = ScrollshotSession(
                options: ScrollStitcher.Options(unusableTopRows: unusableTopRows)
            )
            for offset in offsets {
                session.submit(viewportBandFrame(
                    page, scrollOffset: offset, bandRows: band, frameHeight: frameHeight
                ))
            }
            return try #require(session.result().image)
        }

        // 不给下限：固定带被逐帧贴进长图，每个采纳帧留下一段整行带色。
        let broken = try run(unusableTopRows: 0)
        let brokenRows = fixedBandRows(broken)
        #expect(
            brokenRows.count >= band * 4,
            "未设下限时应复现缺陷（固定带被贴进输出），实际整行带色 \(brokenRows.count) 行"
        )

        // 给出下限：固定带只应出现在首帧段顶端那一次（那是用户选区里真实看到的
        // 顶边，保留它是忠实的），**不应再出现在长图的任何其它位置**。
        let fixed = try run(unusableTopRows: band)
        let fixedRows = fixedBandRows(fixed)
        #expect(
            fixedRows.count == band,
            "固定带被贴进长图：整行带色 \(fixedRows.count) 行（期望只剩首帧顶端 \(band) 行），位置 \(fixedRows.prefix(40))"
        )

        // 最强的断言：接缝区间与整页**逐像素一致**。
        // 中间各段都由后续帧在滚出固定带之后补上了，所以既没有缺行（缺失会让比对
        // 整体错位）也没有把固定带贴进去（那会多出成片带色）。这一段跨越 3 处接缝。
        let coveredStart = -(4 * 100) + band
        let truthOffset = 2000 + coveredStart
        let seamSpan = frameHeight - band
        let probe = slice(fixed, offset: 0, height: seamSpan)
        let truth = slice(page, offset: truthOffset, height: seamSpan)
        #expect(
            compare(probe, truth).differentPixels == 0,
            "接缝区间与整页不一致：不同像素 \(compare(probe, truth).differentPixels)"
        )

        // 代价只有一处、且是物理上不可见的：会话**最后**一帧的视口顶部仍被固定带
        // 遮住（那一刻用户也看不到那几行），所以末尾少接 `band` 行；中间各段不再
        // 缺失 —— 它们由后续帧在滚出固定带区域后补上。
        let expectedHeight = frameHeight + 4 * 100
        #expect(
            abs(fixed.height - (expectedHeight - band)) <= 4,
            "输出高度 \(fixed.height)，期望约 \(expectedHeight - band)（末尾少接 \(band) 行）"
        )
    }

    @Test("向上大步滚动也必须能配上——正向无候选时不能直接判「配不上」")
    func largeUpwardScrollIsNotUnresolved() throws {
        // 既有测试只覆盖**每帧 40px** 的小步上滚（`extendsUpwardFromFirstFrame`），
        // 而真实用户上滚常常一次几十到几百像素。
        //
        // 这条测试针对一个确凿的调度缺陷：`VerticalOverlap.estimate` 的第一行是
        // `let forward = try estimateDirected(...)` —— 正向**抛错**时直接向外抛，
        // 反向**从未被尝试**。而上滚在正向假设（内容上移）下本就无解，
        // 于是向上滚动会被判成 unresolved，连续三帧就误报暂停收录。
        let page = makePage(pageHeight: 3000)
        let frameHeight = 480
        var session = ScrollshotSession()
        session.submit(slice(page, offset: 1000, height: frameHeight))
        // 逐步加大向上步长，直到接近「一帧滚掉大半屏」——那是真实用户
        // 用触控板快速上翻时常见的幅度，也是正向搜索区间最先撑不住的区间。
        for step in [120, 240, 360, 420] {
            var s2 = ScrollshotSession()
            s2.submit(slice(page, offset: 1000, height: frameHeight))
            let d = s2.submit(slice(page, offset: 1000 - step, height: frameHeight))
            #expect(
                d.verdict == .accepted,
                "向上滚 \(step)px 时结果是 \(d.verdict)（告警：\(d.warnings)）"
            )
        }
    }

    @Test("多轮跟丢均保留原基准，回到原页面后可继续")
    func lostSessionRecoversAtKnownContent() throws {
        let page = makePage(width: 300, pageHeight: 4000)
        var session = ScrollshotSession()
        session.submit(slice(page, offset: 1000, height: 400))
        session.submit(slice(page, offset: 1100, height: 400))
        let heightBefore = session.coveredWorldHeight
        var random = PageRandom(state: 2026)
        for _ in 0..<6 {
            var data = [UInt8](repeating: 255, count: 300 * 400 * 4)
            for index in stride(from: 0, to: data.count, by: 4) {
                data[index] = UInt8(random.next() * 255)
                data[index + 1] = UInt8(random.next() * 255)
                data[index + 2] = UInt8(random.next() * 255)
            }
            session.submit(ScrollshotImage(width: 300, height: 400, data: data)!)
        }
        #expect(session.isStalled)
        #expect(session.coveredWorldHeight == heightBefore)
        let recovered = session.submit(slice(page, offset: 1200, height: 400))
        #expect(recovered.isAccepted)
        #expect(!session.isStalled)
        let image = try #require(session.result().image)
        #expect(compare(image, slice(page, offset: 1000, height: 600)).differentPixels == 0)
    }

    @Test("底部固定带仅保留首帧一次")
    func viewportBottomFixedBandIsNotPasted() throws {
        // 与向上扩展对称：**向下扩展取的是帧底部的「新行」**，那里同样可能有
        // 不随内容滚动的屏幕固定元素（窗口底边装饰、CLI/编辑器常驻状态栏）。
        // 实测某次真实会话的帧底部 19~24 行满足「相邻帧同位置完全相同、
        // 滚动位置不匹配」（行内纯色、std=0），确认不参与滚动。
        //
        // 不跳过它的后果与顶部同源：每处接缝都重复粘贴这段固定内容，
        // 并把它覆盖掉的那几行真实内容永久丢弃 —— 向下长截图因此出现
        // 「同样的东西反复出现 + 文字被切断」。
        let page = makePage(width: 300, pageHeight: 4000)
        let band = 12
        let frameHeight = 400
        let offsets = [1000, 1100, 1200, 1300, 1400]

        func run(unusableBottomRows: Int) throws -> ScrollshotImage {
            var session = ScrollshotSession(
                options: ScrollStitcher.Options(unusableBottomRows: unusableBottomRows)
            )
            for offset in offsets {
                session.submit(viewportBandFrame(
                    page, scrollOffset: offset, bandRows: band,
                    frameHeight: frameHeight, atBottom: true
                ))
            }
            return try #require(session.result().image)
        }

        // 不给下限：每段尾部都把固定带贴进来。
        let broken = try run(unusableBottomRows: 0)
        let brokenRows = fixedBandRows(broken)
        #expect(
            brokenRows.count >= band * 4,
            "未设下限时应复现缺陷，实际整行带色 \(brokenRows.count) 行"
        )

        // 给出下限：固定带只应出现在**首帧段底部**那一次（用户选区里真实看到的底边）。
        let fixed = try run(unusableBottomRows: band)
        let fixedRows = fixedBandRows(fixed)
        #expect(
            fixedRows.count == band,
            "底部固定带被贴进长图：整行带色 \(fixedRows.count) 行（期望只剩首帧底部 \(band) 行），位置 \(fixedRows.prefix(40))"
        )
        // 代价只有「末帧底部被固定带遮住的那几行」（用户当时也看不到）。
        let expectedHeight = frameHeight + 4 * 100
        #expect(
            abs(fixed.height - (expectedHeight - band)) <= 4,
            "输出高度 \(fixed.height)，期望约 \(expectedHeight - band)"
        )
    }

}
