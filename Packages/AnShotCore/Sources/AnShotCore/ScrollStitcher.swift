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
//  `Options.maxOutputHeight` 是硬上限，到达后 `ScrollshotSession` 停止采纳新帧，
//  而不是让进程被 OOM 杀掉。
//
//  ── 决策记录是产物，不是调试信息 ──────────────────────────
//
//  用户看到的长图有瑕疵时，需要能回答「是哪一帧、因为什么被丢」，
//  否则只能重截。所以 `Plan` 逐帧保留 `deltaY` / `confidence` / `verdict` /
//  `outputY` / `rows` / `warnings`，以及接缝行号。
//

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
        /// 传给配准的参数（`ignoreTopRows` 会自动取 `stickyHeaderRows`）。
        public var overlap: VerticalOverlap.Options
        /// 在已对齐的重叠正文中接缝，并替换接缝外的旧帧区域。
        /// 保留整个选区及两端界面，避免将旧帧底部输入栏留在长图中段。
        public var joinsInsideOverlap: Bool
        /// 保留全部采纳原图供调用方审计；关闭时只存输出实际需要的像素段。
        public var retainsSourceFrames: Bool

        public init(
            stickyHeaderRows: Int = 0,
            duplicateDeltaThreshold: Int = 2,
            minConfidence: Double = 0.5,
            transientDeltaThreshold: Int = 40,
            maxOutputHeight: Int = 32_768,
            overlap: VerticalOverlap.Options = VerticalOverlap.Options(),
            unusableTopRows: Int = 0,
            unusableBottomRows: Int = 0,
            joinsInsideOverlap: Bool = false,
            retainsSourceFrames: Bool = true
        ) {
            self.stickyHeaderRows = stickyHeaderRows
            self.duplicateDeltaThreshold = duplicateDeltaThreshold
            self.minConfidence = minConfidence
            self.transientDeltaThreshold = transientDeltaThreshold
            self.maxOutputHeight = maxOutputHeight
            self.overlap = overlap
            self.unusableTopRows = unusableTopRows
            self.unusableBottomRows = unusableBottomRows
            self.joinsInsideOverlap = joinsInsideOverlap
            self.retainsSourceFrames = retainsSourceFrames
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
        height: Int
    ) -> ScrollshotImage? {
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        return buffer.withUnsafeMutableBufferPointer { output -> ScrollshotImage? in
            guard let out = output.baseAddress else { return nil }
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
            return ScrollshotImage(width: width, height: height, data: Array(output))
        }
    }
}
