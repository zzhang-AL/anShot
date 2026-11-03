//
//  VerticalOverlapTests.swift
//  AnShotCoreTests
//
//  竖直配准内核的测试。全部用**合成帧**：真值已知，才能区分
//  「配准算错了」与「测试期望写错了」。
//
//  ── 重点验证什么 ──────────────────────────────────────────
//
//  系统配准在真实网页上实测失手的三类场景（见
//  docs/m3-advanced/长截图算法与参数.md），本内核必须至少做到
//  **知道自己不确定**：
//
//  1. sticky 顶栏（固定不动的行）；
//  2. 周期内容（等距行高，多个候选分数打平）；
//  3. 大位移（重叠区变小、可依据的像素变少）。
//
//  其中「周期内容 + 大位移」对任何配准都是难题。这里**不要求位移一定正确**，
//  但要求 `confidence` 明显下降——置信度正是系统 API 缺失、而编排层必须依赖的信号。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotCore

/// 确定性伪随机（LCG），保证测试可复现。
private struct LCG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((state >> 33) % 1_000) / 1_000
    }
}

private enum FrameKind {
    /// 2D 随机纹理（照片、图标、多列排版的抽象）——配准最容易的一类。
    case textured
    /// 等距横线（整页文档、列表）——周期内容。
    case periodic(spacing: Int)
    /// 顶部若干行固定不动（sticky 顶栏），其余按视口滚动。
    case sticky(headerRows: Int)
}

/// 生成一帧：内容在「世界坐标」里固定，视口按 `viewOffset` 上移。
///
/// 因此 `viewOffset` 就是真值：内容上移了多少像素，配准应当报出同样的 `deltaY`。
private func makeFrame(
    width: Int = 320,
    height: Int = 480,
    viewOffset: Int,
    kind: FrameKind,
    seed: UInt64 = 7,
    noise: Int = 0
) -> ScrollshotImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // 底色
    context.setFillColor(CGColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let stickyRows = { if case let .sticky(rows) = kind { return rows } else { return 0 } }()

    // 内容在「世界坐标」里生成，范围必须**跟着视口走**：视口上移 viewOffset 后，
    // 当前需要的世界坐标区间是 [viewOffset − 40, viewOffset + height + 40]。
    // 若把范围写死成 [−150, height + 150)，大位移场景（例如 viewOffset = 274）
    // 的下半帧就没有内容，表现成「配准乱报 + 置信度极低」——
    // 那是测试帧坏了，不是内核坏了。
    func randomWorldY(_ generator: inout LCG) -> Int {
        Int(generator.next() * Double(height + 300)) - 150 + viewOffset
    }

    // 世界坐标 → 屏幕坐标：屏幕 y = 世界 y − viewOffset（内容上移 = 向下滚动）。
    // 注意 CGContext 的 y 轴向上，所以写进上下文时要再翻一次。
    func draw(worldY: Int, _ body: (CGFloat) -> Void) {
        let screenY = worldY - viewOffset
        guard screenY > -40, screenY < height + 40 else { return }
        body(CGFloat(height - screenY))
    }

    switch kind {
    case .textured, .sticky:
        // 内容必须**由世界坐标决定**，不能依赖随机数的调用顺序。
        //
        // 两帧的视口起点不同：按顺序取随机数时，next 的第一行消耗的随机数与 prev
        // 的第一行不同，于是「同一个世界坐标的行」在两帧里得到**不同内容**——
        // 那两帧就不是同一个页面的两个视口了，配准当然失败（症状是 delta 恒为 0）。
        // 正确做法：每行的内容由它自己的世界坐标派生随机数，与视口无关。
        // 行的位置钉在**固定的世界坐标网格**上（`k × spacing`），
        // 而不是从 `viewOffset` 起算。从视口起点起算会让两帧的行落在不同的网格
        // 相位上（0 帧是 −150、−139…，17 帧是 −133、−122…），于是「同一世界坐标的
        // 行」在两帧里根本不是同一组行——内容对不上，配准必然乱报。
        //
        // 这条与「内容由世界坐标决定」是一对：**位置与内容都必须只依赖世界坐标**。
        let spacing = 10
        let firstRow = Int(floor(Double(viewOffset - 150) / Double(spacing)))
        let lastRow = Int(ceil(Double(viewOffset + height + 150) / Double(spacing)))
        context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1))
        for row in firstRow...lastRow {
            let worldY = row * spacing
            let y = CGFloat(height - (worldY - viewOffset))
            guard y > -20, y < CGFloat(height) + 20 else { continue }
            var rowRandom = LCG(state: UInt64(bitPattern: Int64(worldY)) &* 2_654_435_761 &+ seed)
            var x = 12
            while x < width - 20 {
                // 覆盖率要接近真实文字页（约 85%）：稀疏内容会让 evidence 天生很低，
                // 于是「正常场景应当自信」这条测不出来。
                if rowRandom.next() < 0.9 {
                    context.fill(CGRect(x: CGFloat(x), y: y, width: 7, height: 8))
                }
                x += 8
            }
        }
        // 彩色块（图片、按钮）：位置与内容同样只由世界坐标决定。
        for index in 0..<30 {
            let blockWorldY = index * 41
            var blockRandom = LCG(state: UInt64(index) &* 6_364_136_223_846_793_005 &+ seed &+ 77)
            let x = Int(blockRandom.next() * Double(width - 60)) + 10
            let value = blockRandom.next()
            let blockWidth = 24 + CGFloat(blockRandom.next()) * 30
            draw(worldY: blockWorldY) { y in
                context.setFillColor(CGColor(red: value, green: 1 - value, blue: value * 0.7, alpha: 1))
                context.fill(CGRect(x: CGFloat(x), y: y, width: blockWidth, height: 18))
            }
        }

    case let .periodic(spacing):
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        for row in 0..<200 {
            let worldY = row * spacing
            draw(worldY: worldY) { y in
                context.fill(CGRect(x: 16, y: y, width: CGFloat(width - 32), height: 3))
                context.fill(CGRect(x: 20, y: y - 6, width: 40 + CGFloat(row % 5) * 18, height: 2))
            }
        }
    }

    // sticky 顶栏：**不随 viewOffset 移动**，直接画在屏幕顶部。
    if stickyRows > 0 {
        context.setFillColor(CGColor(red: 0.12, green: 0.16, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: CGFloat(height - stickyRows), width: CGFloat(width), height: CGFloat(stickyRows)))
    }

    let image = context.makeImage()!
    var result = ScrollshotImage(image)!
    if noise > 0 {
        var buffer = result.data
        var noiseRandom = LCG(state: seed &+ 991)
        for index in stride(from: 0, to: buffer.count, by: 1) where noiseRandom.next() < 0.02 {
            let delta = Int(noiseRandom.next() * Double(noise * 2)) - noise
            buffer[index] = UInt8(min(255, max(0, Int(buffer[index]) + delta)))
        }
        result = ScrollshotImage(width: result.width, height: result.height, data: buffer)!
    }
    return result
}

@Suite("竖直配准内核")
struct VerticalOverlapTests {

    @Test("非周期纹理：各档位移都精确")
    func exactOnTexturedContent() throws {
        for offset in [2, 17, 34, 88, 137] {
            let previous = makeFrame(viewOffset: 0, kind: .textured)
            let next = makeFrame(viewOffset: offset, kind: .textured)
            let match = try VerticalOverlap.estimate(previous: previous, next: next)
            #expect(match.deltaY == offset, "位移 \(offset) 实测 \(match.deltaY)")
        }
    }

    @Test("非周期纹理：置信度高")
    func confidentOnTexturedContent() throws {
        let previous = makeFrame(viewOffset: 0, kind: .textured)
        let next = makeFrame(viewOffset: 88, kind: .textured)
        let match = try VerticalOverlap.estimate(previous: previous, next: next)
        #expect(match.confidence > 0.5, "置信度 \(match.confidence)")
    }

    @Test("未滚动：位移为 0")
    func stableWhenNotScrolled() throws {
        let previous = makeFrame(viewOffset: 200, kind: .textured)
        let next = makeFrame(viewOffset: 200, kind: .textured)
        let match = try VerticalOverlap.estimate(previous: previous, next: next)
        // 这里**不要求**高置信度：列权重与行运动衡量的都是「同位置是否变化」，
        // 两帧完全相同时该值天然接近下限。重复帧（滚动到底后的空转）由编排层用
        // 「位移 ≤ 阈值」判定，不依赖置信度。
        #expect(match.deltaY == 0, "实测 \(match.deltaY)")
    }

    @Test("帧间噪声：位移仍然正确")
    func robustToNoise() throws {
        let previous = makeFrame(viewOffset: 0, kind: .textured)
        let next = makeFrame(viewOffset: 63, kind: .textured, noise: 12)
        let match = try VerticalOverlap.estimate(previous: previous, next: next)
        #expect(match.deltaY == 63, "实测 \(match.deltaY)")
    }

    @Test("sticky 顶栏：指定 ignoreTopRows 后位移正确（系统配准在此失败）")
    func handlesStickyHeader() throws {
        for offset in [17, 44, 137] {
            let previous = makeFrame(viewOffset: 0, kind: .sticky(headerRows: 56))
            let next = makeFrame(viewOffset: offset, kind: .sticky(headerRows: 56))
            let options = VerticalOverlap.Options(ignoreTopRows: 56)
            let match = try VerticalOverlap.estimate(previous: previous, next: next, options: options)
            // 允许 1px：相邻行相似时几个候选分数完全相同，稳定排序取更小的 delta。
            // 长截图靠重叠拼接，1px 与真实重叠量相比可忽略。
            #expect(abs(match.deltaY - offset) <= 1, "位移 \(offset) 实测 \(match.deltaY)")
        }
    }

    @Test("sticky 顶栏：不指定 ignoreTopRows 时行运动权重也能救回来")
    func stickyHeaderViaRowMotion() throws {
        // 这条是「行运动权重」存在的意义：即使调用方没告诉内核顶栏有多高，
        // 固定不动的行也会被自动降权。
        let previous = makeFrame(viewOffset: 0, kind: .sticky(headerRows: 56))
        let next = makeFrame(viewOffset: 137, kind: .sticky(headerRows: 56))
        let match = try VerticalOverlap.estimate(previous: previous, next: next)
        #expect(match.deltaY == 137, "实测 \(match.deltaY)")
    }

    @Test("滚动条：忽略右侧列后位移正确")
    func ignoresScrollbar() throws {
        var previous = makeFrame(viewOffset: 0, kind: .textured)
        var next = makeFrame(viewOffset: 44, kind: .textured)
        // 在最右侧 12 列贴上「滚动条」：两帧位置不同，会误导配准。
        previous = paintScrollbar(in: previous, offset: 0)
        next = paintScrollbar(in: next, offset: 180)
        let options = VerticalOverlap.Options(ignoreRightColumns: 16)
        let match = try VerticalOverlap.estimate(previous: previous, next: next, options: options)
        #expect(match.deltaY == 44, "实测 \(match.deltaY)")
    }

    @Test("周期内容 + 大位移：位移可能不可靠，但置信度必须显著下降")
    func periodicContentLowersConfidence() throws {
        // 周期内容会让多个候选分数打平（行距的整数倍）。此处**不要求**位移正确
        // ——那对任何配准都困难——但要求内核**知道自己不确定**。
        let previous = makeFrame(viewOffset: 0, kind: .periodic(spacing: 28))
        let next = makeFrame(viewOffset: 196, kind: .periodic(spacing: 28))
        let match = try VerticalOverlap.estimate(previous: previous, next: next)

        let textured = try VerticalOverlap.estimate(
            previous: makeFrame(viewOffset: 0, kind: .textured),
            next: makeFrame(viewOffset: 196, kind: .textured)
        )
        #expect(
            match.confidence < textured.confidence,
            "周期内容置信度 \(match.confidence) 应低于非周期 \(textured.confidence)"
        )
        // 196 = 7 × 28，正好落在 alias 上：这里允许位移错，但置信度必须低到
        // 能让编排层把它当作「可疑帧」处理。
        if match.deltaY != 196 {
            #expect(match.confidence < 0.6, "位移错时报出了过高的置信度 \(match.confidence)")
        }
    }

    @Test("周期内容：小位移仍能对齐")
    func periodicContentSmallShift() throws {
        let previous = makeFrame(viewOffset: 0, kind: .periodic(spacing: 28))
        let next = makeFrame(viewOffset: 5, kind: .periodic(spacing: 28))
        let match = try VerticalOverlap.estimate(previous: previous, next: next)
        #expect(match.deltaY == 5, "实测 \(match.deltaY)，置信度 \(match.confidence)，匹配率 \(match.matchRatio)")
    }

    @Test("反向滚动（回滚）：位移为负且精确")
    func exactOnRewind() throws {
        // 视口从 300 退回 300 − k：真实位移是 **负的**。
        // 这条是「上下滚动」场景的地基：负位移若不可表达，回滚帧只能在正向假设下
        // 匹配到另一段相似内容（实测曾把回滚 150px 报成 +430px），
        // 编排层据此把同一段内容再粘一遍。
        for rewind in [2, 17, 34, 88, 137] {
            let previous = makeFrame(viewOffset: 300, kind: .textured)
            let next = makeFrame(viewOffset: 300 - rewind, kind: .textured)
            let match = try VerticalOverlap.estimate(previous: previous, next: next)
            #expect(match.deltaY == -rewind, "回滚 \(rewind) 实测 \(match.deltaY)")
        }
    }

    @Test("回滚再前进：位移的符号随方向翻转")
    func signFollowsDirection() throws {
        let base = makeFrame(viewOffset: 300, kind: .textured)
        let back = makeFrame(viewOffset: 240, kind: .textured)
        let again = makeFrame(viewOffset: 380, kind: .textured)

        #expect(try VerticalOverlap.estimate(previous: base, next: back).deltaY == -60)
        #expect(try VerticalOverlap.estimate(previous: back, next: again).deltaY == 140)
        // 回滚后回到原点的两帧应当报 0，而不是“另一个方向的一大段位移”。
        #expect(try VerticalOverlap.estimate(previous: again, next: base).deltaY == -80)
    }

    @Test("尺寸不一致：抛出 shapeMismatch")
    func rejectsShapeMismatch() {
        let previous = makeFrame(width: 320, height: 480, viewOffset: 0, kind: .textured)
        let next = makeFrame(width: 300, height: 480, viewOffset: 0, kind: .textured)
        #expect(throws: VerticalOverlap.Failure.self) {
            _ = try VerticalOverlap.estimate(previous: previous, next: next)
        }
    }

    @Test("性能：整屏尺寸单次配准明显快于系统实现")
    func performance() throws {
        // 1440×960 是 720×480 逻辑点在 2x 屏上的实际抓帧尺寸。
        let previous = makeFrame(width: 1440, height: 960, viewOffset: 0, kind: .textured)
        let next = makeFrame(width: 1440, height: 960, viewOffset: 274, kind: .textured)
        let start = Date()
        let match = try VerticalOverlap.estimate(previous: previous, next: next)
        let elapsed = Date().timeIntervalSince(start) * 1000
        #expect(match.deltaY == 274, "实测 \(match.deltaY)")
        // 注意：`swift test` 默认是 Debug（-Onone）构建，同样的代码比 Release
        // 慢一个数量级；系统配准的 17–40ms 是 Release 下测的，不能直接对比。
        // 真实耗时用 `-diagnoseScrollshot` 在 Release 里测。这里只挡住
        // 「实现退化成平方级」这一类问题。
        #expect(elapsed < 2000, "耗时 \(elapsed)ms（Debug 构建；Release 实测见诊断）")
    }

    @Test("回滚：由翻转内核直接解出，而不是被正向的同向候选带偏")
    func rollbackIsSolvedByFlippedKernel() throws {
        // 回滚时正向假设必然不干净（负位移在「内容上移」假设下只能匹配到另一段
        // 相似内容），所以正向结果不可用——这条测试保护的就是「别采信正向的
        // 同向候选」，而不是「必须走哪条路径」。
        //
        // 这条断言原先写的是 `match.visionArbitrated`，即**必须由 Vision 仲裁**。
        // 加入翻转分支后它不再成立，而且新结果更强：内核把两帧上下翻转后，
        // 回滚在几何上变成正向，实测 `matchRatio` 达到 1.0（靠 Vision 仲裁时
        // 只有 0.78 左右）。所以这里改为断言**答案有依据**——位移正确且
        // 匹配比足够高——不再绑定实现路径。
        //
        // 位移上限取帧高的一半左右：再大就只剩很少重叠，任何配准器（含 Vision）
        // 都会失真——仲裁里那道「位移必须在可解范围内」的闸门正是为此存在。
        for shift in [20, 60, 120, 180, 240] {
            let previous = makeFrame(viewOffset: 700, kind: .textured)
            let next = makeFrame(viewOffset: 700 - shift, kind: .textured)
            let match = try VerticalOverlap.estimate(previous: previous, next: next)
            #expect(
                match.deltaY == -shift,
                "回滚 \(shift) 被解成 \(match.deltaY)"
            )
            #expect(
                match.matchRatio > 0.95,
                "回滚 \(shift) 的 matchRatio 只有 \(match.matchRatio)，答案缺乏依据"
            )
        }
}

/// 在图像右侧画一条「滚动条」（竖直亮条）。
private func paintScrollbar(in image: ScrollshotImage, offset: Int) -> ScrollshotImage {
    var buffer = image.data
    let width = image.width
    let barWidth = 12
    for y in 0..<image.height {
        let barTop = offset
        let barBottom = offset + 120
        let inside = y >= barTop && y < barBottom
        for x in (width - barWidth)..<width {
            let index = (y * width + x) * 4
            let value: UInt8 = inside ? 90 : 235
            buffer[index] = value
            buffer[index + 1] = value
            buffer[index + 2] = value
        }
    }
    return ScrollshotImage(width: width, height: image.height, data: buffer)!
}
    }
