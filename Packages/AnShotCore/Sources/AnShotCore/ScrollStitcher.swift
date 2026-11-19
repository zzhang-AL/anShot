//
//  ScrollStitcher.swift
//  AnShotCore
//
//  长截图拼接的**几何粘合**：把已采纳的帧按世界坐标贴成一张长图。
//
//  ── 它不做什么 ────────────────────────────────────────────
//
//  配准、世界坐标追踪、采纳决策都在 `ScrollshotSession` 里——那里才有
//  「上一帧是谁」「用户往哪个方向滚」「这段世界区间贴过没有」的上下文。
//  本文件只做两件事：按已经定好的行区间复制像素，以及把决策整理成
//  **可审计的计划**（`Plan`）。
//
//  这样拆开之后，换配准算法不动粘合，改粘合不动配准；
//  两层各自有测试，红了的时候能立刻分辨是谁错。
//
//  ── 内存边界 ─────────────────────────────────────────────
//
//  长截图的输出内存是 `宽 × 高 × 4` 字节，很容易到几百 MB。
//  `Options.maxOutputHeight` 是行数硬上限，`Options.maxOutputPixels` 是像素数
//  硬上限（宽屏下同一行数占更多内存），到达任一上限后 `ScrollshotSession`
//  停止采纳新帧，而不是让进程被 OOM 杀掉。
//
//  ── 决策记录是产物，不是调试信息 ──────────────────────────
//
//  用户看到的长图有瑕疵时，需要能回答「是哪一帧、因为什么被丢」，
//  否则只能重截。所以 `Plan` 逐帧保留 `deltaY` / `confidence` / `verdict` /
//  `outputY` / `rows` / `warnings`，以及接缝行号。
//

import CoreGraphics
import Foundation

/// 滚动截图的拼接编排。
public enum ScrollStitcher {

    // MARK: - 参数

    public struct Options: Sendable {
        /// 顶部固定不动的行数（sticky 顶栏）。
        ///
        /// 这些行在输出图里**只应出现一次**（最顶端），后续帧的该区域要跳过，
        /// 同时把它作为配准的忽略区传给 `VerticalOverlap`。
        public var stickyHeaderRows: Int
        /// 帧顶部**不可用**的行数：视口顶部的屏幕固定元素（窗口边框、分隔带、
        /// 纯色工具栏）所占的高度，单位与帧一致（物理像素）。
        ///
        /// ── 与 `stickyHeaderRows` 的区别 ──────────────────────
        /// * `stickyHeaderRows` 是**页面自己的**固定顶栏：它属于内容，应当在
        ///   输出里出现一次（长图顶端那条导航栏），所以只跳过后续帧的该区域；
        /// * `unusableTopRows` 是**屏幕的**固定元素：它不属于页面，出现在输出里
        ///   就是伪影；更糟的是它**遮住的那些真实内容会永久丢失** —— 每帧都丢
        ///   同样多行，接缝处就缺一截，落在文字行上就是「字只有一半」。
        ///
        /// ── 为什么必须由调用方给，而不是自动检测 ──────────────
        /// 这类元素往往是**纯色**，行内对比度为 0，与「页面留白」在单帧里完全
        /// 同形，任何只看单帧像素的判据都分不开（实测：13 组相邻帧投票只有
        /// 1~6 票，而判定需要过半）。所以用**保守下限**兜底。
        ///
        /// 取大不取小：跳过更多行**不会丢内容**（那几行会由后续帧在滚出固定带
        /// 区域后覆盖，只要最小滚动量大于它），而跳得不够就会丢。
        public var unusableTopRows: Int
        /// 帧底部**不可用**的行数（底部状态栏、常驻工具条同理）。
        public var unusableBottomRows: Int
        /// 位移 ≤ 此值视为「没滚动」（重复帧）。
        public var duplicateDeltaThreshold: Int
        /// 置信度低于此值的帧需要额外判断。
        public var minConfidence: Double
        /// 「小位移」的上界：低置信度帧的位移不超过它 → 按瞬态噪声丢弃；
        /// 超过它 → 保留并告警（FAIL-OPEN）。设为 0 可关闭该判定。
        public var transientDeltaThreshold: Int
        /// 输出高度上限（像素）。
        ///
        /// 长截图的内存是 `宽 × 高 × 4` 字节，很快就是几百 MB。
        /// 必须有硬上限，到达后停止接受新帧并告警，而不是让进程被 OOM 杀掉。
        public var maxOutputHeight: Int
        /// 输出**像素数**上限（宽 × 高），默认 4800 万（约 192MB RGBA8）。
        ///
        /// 输出字节数是 `宽 × 高 × 4`，所以**固定的行数上限对宽屏不够**：
        /// 同一行数在 2 倍宽度下占 2 倍内存（例如 4K 宽 3840px、
        /// `maxOutputHeight` 32768 行 = 约 503MB）。因此行数上限之外再加一道
        /// 像素预算硬上限：会话据此把有效行数上限压到
        /// `maxOutputPixels / 宽`，两者取小。
        ///
        /// 默认值 4800 万像素 ≈ 192MB，常见窗口宽度（≤ 1920px）下
        /// 折算行数 ≥ 25000，不会改变原有的行数上限语义。
        public var maxOutputPixels: Int
        /// 传给配准的参数（`ignoreTopRows` 会自动取 `stickyHeaderRows`）。
        public var overlap: VerticalOverlap.Options
        /// 在已对齐的重叠正文中接缝，并替换接缝外的旧帧区域。
        /// 保留整个选区及两端界面，避免将旧帧底部输入栏留在长图中段。
        public var joinsInsideOverlap: Bool
        /// 保留全部采纳原图供调用方审计；关闭时只存输出实际需要的像素段。
        public var retainsSourceFrames: Bool
        /// 未滚出第二段时是否静默兜底输出首帧（交互式长截图开启，纯拼接测试默认关闭以维持既有契约）。
        public var allowsSingleFrameFallback: Bool
        /// 探测到静态固定侧边栏时，是否对首帧之外的侧栏延伸区做洁净纯底色延展覆写以消除腰斩重复。
        public var cleanStaticSidebar: Bool
        /// 是否探测窗口底部左右圆角并自动归入底帽安全余量，消除接缝黑角。
        public var detectBottomWindowCorners: Bool

        public init(
            stickyHeaderRows: Int = 0,
            duplicateDeltaThreshold: Int = 2,
            minConfidence: Double = 0.5,
            transientDeltaThreshold: Int = 40,
            maxOutputHeight: Int = 32_768,
            maxOutputPixels: Int = 48_000_000,
            overlap: VerticalOverlap.Options = VerticalOverlap.Options(),
            unusableTopRows: Int = 0,
            unusableBottomRows: Int = 0,
            joinsInsideOverlap: Bool = false,
            retainsSourceFrames: Bool = false,
            allowsSingleFrameFallback: Bool = false,
            cleanStaticSidebar: Bool = false,
            detectBottomWindowCorners: Bool = false
        ) {
            self.stickyHeaderRows = stickyHeaderRows
            self.duplicateDeltaThreshold = duplicateDeltaThreshold
            self.minConfidence = minConfidence
            self.transientDeltaThreshold = transientDeltaThreshold
            self.maxOutputHeight = maxOutputHeight
            self.maxOutputPixels = maxOutputPixels
            self.overlap = overlap
            self.unusableTopRows = unusableTopRows
            self.unusableBottomRows = unusableBottomRows
            self.joinsInsideOverlap = joinsInsideOverlap
            self.retainsSourceFrames = retainsSourceFrames
            self.allowsSingleFrameFallback = allowsSingleFrameFallback
            self.cleanStaticSidebar = cleanStaticSidebar
            self.detectBottomWindowCorners = detectBottomWindowCorners
        }
    }

    /// 一帧的处置结果。
    public struct FrameDecision: Equatable, Sendable {
        /// 在输入数组里的下标（含被丢弃的帧，因此可能不连续）。
        public let inputIndex: Int
        /// 相对上一**观察**帧的位移（像素，有符号：向下滚为正，回滚为负）；
        /// 被丢弃时仍是配准给出的值——审计需要知道「它当时被认为动了多少」。
        public let deltaY: Int
        /// 该帧的配准置信度。
        public let confidence: Double
        /// 该帧视口顶部在世界坐标中的位置。
        public let worldOffset: Int
        /// 处置结论（决定这一帧为什么被采纳或被丢）。
        public let verdict: ScrollshotSession.Verdict
        /// 该帧在输出图里的起始行；被丢弃时为 nil。
        public let outputY: Int?
        /// 该帧贡献的行数；被丢弃时为 0。
        public let rows: Int
        /// 与该帧有关的告警。
        public let warnings: [String]

        /// 是否按「重复帧」（没滚动）丢弃。
        public var discardedAsDuplicate: Bool { verdict == .duplicate }
        /// 是否按「瞬态噪声」（小位移 + 低置信度）丢弃。
        public var discardedAsTransient: Bool { verdict == .transient }

        public init(
            inputIndex: Int,
            deltaY: Int,
            confidence: Double,
            worldOffset: Int,
            verdict: ScrollshotSession.Verdict,
            outputY: Int?,
            rows: Int,
            warnings: [String]
        ) {
            self.inputIndex = inputIndex
            self.deltaY = deltaY
            self.confidence = confidence
            self.worldOffset = worldOffset
            self.verdict = verdict
            self.outputY = outputY
            self.rows = rows
            self.warnings = warnings
        }
    }

    /// 拼接计划：**逐帧的决策记录**。
    public struct Plan: Sendable {
        public let frames: [FrameDecision]
        /// 接缝在输出图里的行号。
        public let seamRows: [Int]
        public let outputWidth: Int
        public let outputHeight: Int
        /// 整体告警（配准失败、达到高度上限等）。
        public let warnings: [String]

        public init(
            frames: [FrameDecision],
            seamRows: [Int],
            outputWidth: Int,
            outputHeight: Int,
            warnings: [String]
        ) {
            self.frames = frames
            self.seamRows = seamRows
            self.outputWidth = outputWidth
            self.outputHeight = outputHeight
            self.warnings = warnings
        }
    }

    /// 没有东西可交付时的原因。
    public enum Failure: Error, Equatable {
        /// 输入不足 2 帧：拼出来的只会等于第一帧。
        case notEnoughFrames(Int)
        /// 除首帧外没有任何帧被接受，输出只会等于第一帧。
        case noAcceptedFrame
        /// 首帧为空（宽或高为 0）。
        case emptyFirstFrame
    }

    public struct Result: Sendable {
        /// 拼好的长图；失败时为 nil。
        public let image: ScrollshotImage?
        public let plan: Plan
        public let failure: Failure?

        public init(image: ScrollshotImage?, plan: Plan, failure: Failure?) {
            self.image = image
            self.plan = plan
            self.failure = failure
        }
    }

    // MARK: - 入口

    /// 一次性拼接：帧序列 → 世界坐标追踪 → 粘合。
    ///
    /// 会话（`ScrollshotController`）为了实时门控与预览会自己驱动
    /// `ScrollshotSession`；这个入口服务于「手上已经有一串帧」的调用方与测试。
    ///
    /// 只要还有一帧可用就产出结果；只有「确实没有东西可交付」才返回 `failure`。
    public static func stitch(frames: [ScrollshotImage], options: Options = Options()) -> Result {
        var session = ScrollshotSession(options: options)
        for frame in frames {
            session.submit(frame)
        }
        return session.result()
    }

    // MARK: - 合成

    /// 把各段的指定行贴到输出缓冲上。
    ///
    /// 只做整数下标的内存复制；区间合法性已在决策阶段保证，这里仍做防御性裁剪
    /// （越界的 `memcpy` 会直接崩进程，而不是产出一张错图）。
    static func compose(
        segments: [(source: ScrollshotImage, sourceY: Int, rows: Int, outputY: Int)],
        width: Int,
        height: Int,
        colorSpace: CGColorSpace? = nil
    ) -> ScrollshotImage? {
        guard width > 0, height > 0 else { return nil }
        var buffer = Data(count: width * height * 4)
        // 直接在预分配缓冲上写完，再把这块内存**移交**给结果。
        //
        // 早期版本在闭包里把指针缓冲再复制成数组后返回：那会额外复制一整张
        // 宽×高×4 的输出图（长图常达数百 MB），峰值内存瞬间翻倍——正是本模块
        // 要防的 OOM。闭包只负责填像素，结果在闭包外用同一块 `buffer` 构造。
        let filled = buffer.withUnsafeMutableBytes { rawOutput -> Bool in
            guard let out = rawOutput.bindMemory(to: UInt8.self).baseAddress else { return false }
            let bytesPerRow = width * 4
            let totalBytes = width * height * 4
            for segment in segments {
                let rows = min(segment.rows, height - segment.outputY)
                guard rows > 0 else { continue }
                segment.source.withPixels { source in
                    guard let src = source.baseAddress else { return }
                    for row in 0..<rows {
                        let sourceOffset = (segment.sourceY + row) * bytesPerRow
                        let outputOffset = (segment.outputY + row) * bytesPerRow
                        guard sourceOffset >= 0, sourceOffset + bytesPerRow <= source.count,
                              outputOffset >= 0, outputOffset + bytesPerRow <= totalBytes else { continue }
                        memcpy(out + outputOffset, src + sourceOffset, bytesPerRow)
                    }
                }
            }
            return true
        }
        guard filled else { return nil }
        return ScrollshotImage(
            width: width,
            height: height,
            data: buffer,
            colorSpace: colorSpace ?? segments.first?.source.colorSpace
        )
    }

    /// 对静态固定侧边栏在首帧高度之外的延伸区做洁净底色延展，避免左侧栏导航菜单在长图中段被腰斩或反复克隆。
    ///
    /// - Parameters:
    ///   - image: 已合成的整幅长图。
    ///   - firstFrameHeight: 首帧底端在输出图中的行号（首帧内侧栏完整保留）。
    ///   - leftWidth: 左侧固定侧边栏宽度（像素），`< 24` 视为无左侧栏。
    ///   - rightWidth: 右侧固定侧边栏宽度（像素），`< 24` 视为无右侧栏。
    ///   - bottomFooterRows: 输出底部的全宽固定底栏行数（像素），延展涂刷严格避开该区域以免破坏页脚/输入栏。
    /// - Returns: 处理后的长图（无需处理时原样返回，零拷贝）。
    public static func extendSidebarBackground(
        in image: ScrollshotImage,
        firstFrameHeight: Int,
        leftWidth: Int,
        rightWidth: Int = 0,
        bottomFooterRows: Int = 0
    ) -> ScrollshotImage {
        let width = image.width
        let height = image.height
        let footer = max(0, min(bottomFooterRows, height))
        let fillStartY = max(0, min(height, firstFrameHeight - footer))
        let fillEndY = max(fillStartY, height - footer)
        guard fillEndY > fillStartY, fillStartY >= 16 else { return image }

        let effectiveLeft = (leftWidth >= 24 && leftWidth <= width / 2) ? leftWidth : 0
        let effectiveRight = (rightWidth >= 24 && rightWidth <= width / 2 && effectiveLeft + rightWidth < width - 32) ? rightWidth : 0
        guard effectiveLeft > 0 || effectiveRight > 0 else { return image }

        var data = image.data
        let bytesPerRow = width * 4

        /// 采样侧栏底端内缩几行的中位 RGB 作为洁净底色，避开最边缘 1px 描边、文字像素及底部固定栏。
        func sampleCleanBackground(xStart: Int, xEnd: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let safeStart = max(0, xStart + 4)
            let safeEnd = min(width, xEnd - 4)
            guard safeStart < safeEnd else { return (255, 255, 255, 255) }
            let rowStart = max(0, fillStartY - 20)
            let rowEnd = max(rowStart + 1, fillStartY - 4)
            var rs: [UInt8] = []
            var gs: [UInt8] = []
            var bs: [UInt8] = []
            let stepX = max(1, (safeEnd - safeStart) / 16)
            image.withPixels { pixels in
                for y in stride(from: rowStart, to: rowEnd, by: 2) {
                    for x in stride(from: safeStart, to: safeEnd, by: stepX) {
                        let i = y * bytesPerRow + x * 4
                        rs.append(pixels[i])
                        gs.append(pixels[i + 1])
                        bs.append(pixels[i + 2])
                    }
                }
            }
            guard !rs.isEmpty else { return (255, 255, 255, 255) }
            rs.sort()
            gs.sort()
            bs.sort()
            let mid = rs.count / 2
            return (rs[mid], gs[mid], bs[mid], 255)
        }

        let leftColor = effectiveLeft > 0 ? sampleCleanBackground(xStart: 0, xEnd: effectiveLeft) : nil
        let rightColor = effectiveRight > 0 ? sampleCleanBackground(xStart: width - effectiveRight, xEnd: width) : nil

        data.withUnsafeMutableBytes { rawOut in
            guard let out = rawOut.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in fillStartY..<fillEndY {
                let rowOffset = y * bytesPerRow
                if let c = leftColor {
                    // 保留最右 1px 分隔线不覆写，使侧栏边界在整幅长图中连续笔直。
                    let fillEnd = max(0, effectiveLeft - 1)
                    for x in 0..<fillEnd {
                        let i = rowOffset + x * 4
                        out[i] = c.0
                        out[i + 1] = c.1
                        out[i + 2] = c.2
                        out[i + 3] = c.3
                    }
                }
                if let c = rightColor {
                    let fillStart = min(width, width - effectiveRight + 1)
                    for x in fillStart..<width {
                        let i = rowOffset + x * 4
                        out[i] = c.0
                        out[i + 1] = c.1
                        out[i + 2] = c.2
                        out[i + 3] = c.3
                    }
                }
            }
        }
        return ScrollshotImage(width: width, height: height, data: data, colorSpace: image.colorSpace) ?? image
    }
}
