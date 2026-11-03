//
//  VerticalOverlap.swift
//  AnShotCore
//
//  竖直平移配准：为滚动截图求出相邻两帧之间的位移与**置信度**。
//
//  ── 为什么不用系统配准（实测依据） ────────────────────────
//
//  `VNTranslationalImageRegistrationRequest` 在真实网页上实测（见
//  docs/m3-advanced/长截图算法与参数.md，诊断 `-diagnoseScrollshot`）：
//  sticky 顶栏场景 7 档只对 2 档，周期内容在大位移下 alias，
//  且它**不提供任何置信度**——每个失败都以「看起来正常的 transform」返回。
//
//  ── 三重加权 ──────────────────────────────────────────────
//
//  误差不是全图像素的平均差，而是加权后的平均差：
//
//  | 权重 | 计算 | 为什么 |
//  |---|---|---|
//  | 列权重 | 该列在两帧间的差异，归一化到 `[weightFloor, 1]` | 动得多的列才有信息量；纯色边栏/空白列降权 |
//  | 行运动 | 该屏幕行在两帧间是否变化 | **吸顶行与留白行降权**——这是 sticky 顶栏能被处理的原因 |
//  | 纹理 | 该像素的局部梯度（左邻 + 上邻） | 边缘/文字处权重高，纯色区降权。只用于第二遍 |
//
//  ── 置信度来自竞争假设 ────────────────────────────────────
//
//  周期内容（整页文档的行距、列表项行高）会让许多候选的分数**近似打平**，
//  而它们指向完全不同的位移。取距优胜者超过 `refinementRadius` 的最优候选作为
//  **rival**（±refinementRadius 内的只是同一波峰的细化邻居），
//  用两者的分离度算 confidence —— 这正是系统 API 缺失的那个信号。
//
//  ── 位移是有符号的（上下滚动都要能用） ────────────────────
//
//  `deltaY` 为正 = 内容上移（用户向下滚）；**为负 = 内容下移（用户向上回滚）**。
//  回滚不是异常输入，而是长截图的常规交互：用户会来回翻找想收录的段落。
//  内核本身只解非负位移（典型路径），回滚用**按需反向匹配**得到：
//  正向不够干净时把两帧互换再解一次，取负作为结果。
//  把负值直接并进搜索区间试过，会把正向判坏（详见 `estimate` 的注释）。
//

import Foundation

/// 竖直平移配准。
public enum VerticalOverlap {

    // MARK: - 参数

    /// 配准参数。
    public struct Options: Sendable {
        /// 允许的最小重叠比例。滚动量越大，剩下的重叠越少。
        public var minOverlapRatio: Double
        /// 允许的最大重叠比例。
        ///
        /// **默认 1.0 = 允许「完全没滚动」**：滚动到底之后的空转必须能被识别成
        /// delta 0。把它压低（例如 0.98）会让 `minDelta` 变成正数，正确候选直接被
        /// 排除在搜索范围外——症状是「明明没动，却报出一个很大的位移」。
        public var maxOverlapRatio: Double
        /// 忽略顶部若干行（**吸顶栏所在区域**）。
        public var ignoreTopRows: Int
        /// 忽略左侧列（例如固定侧栏）。
        public var ignoreLeftColumns: Int
        /// 忽略右侧列（**滚动条**通常在这里）。
        public var ignoreRightColumns: Int
        /// 采样列数。列越少越快，但对宽页面可能漏掉特征。
        public var sampleColumns: Int
        /// 第二遍使用的采样行数。
        public var sampleRows: Int

        public init(
            minOverlapRatio: Double = 0.10,
            maxOverlapRatio: Double = 1.0,
            ignoreTopRows: Int = 0,
            ignoreLeftColumns: Int = 0,
            ignoreRightColumns: Int = 0,
            sampleColumns: Int = 48,
            sampleRows: Int = 64
        ) {
            self.minOverlapRatio = minOverlapRatio
            self.maxOverlapRatio = maxOverlapRatio
            self.ignoreTopRows = ignoreTopRows
            self.ignoreLeftColumns = ignoreLeftColumns
            self.ignoreRightColumns = ignoreRightColumns
            self.sampleColumns = sampleColumns
            self.sampleRows = sampleRows
        }
    }

    /// 配准结果。
    public struct Match: Sendable {
        /// 内容**上移**的像素数：向下滚动为正，**向上回滚为负**。
        ///
        /// 与系统配准无关（它是自研实现），符号约定由本文件定义：
        /// `next` 的第 `y + deltaY` 行对应 `previous` 的第 `y` 行。
        public let deltaY: Int
        /// 与 `|deltaY|` 对应的重叠行数（与方向无关）。
        public let overlapRows: Int
        /// 置信度 `0...1`。
        public let confidence: Double
        /// 归一化误差，越小越好。
        public let score: Double
        /// 竞争假设（rival）的分数；没有 rival 时为 `nil`。
        public let secondBestScore: Double?
        /// 「这次匹配有多少依据」：权重占比 × 重叠比例。
        public let evidence: Double
        /// 对齐后**真的对上**的权重占比 `0...1`。
        ///
        /// 它是「这次匹配有多干净」的直接指标（而非统计量）：
        /// 干净的正向匹配接近 1，而发生回滚时正向假设下最多只能匹配到
        /// 另一段相似内容，这个值会明显偏低。`estimate` 靠它决定要不要再跑一次反向。
        public let matchRatio: Double
        /// 本结果是否来自**反向**匹配（把两帧互换后求解，再取负）。
        public let reversed: Bool
        /// 本结果的**来源**。
        ///
        /// 与 `confidence` 的关系：`confidence` 只说「该来源自己认为有多可信」。
        /// 三种来源的置信度**不是同一把尺子**（内核那条是
        /// `分离度 × 证据量 × 匹配率` 的连乘，仲裁那是人为标定的量级），
        /// 所以横向比较前必须先看来源。
        public let source: Source

        /// 本结果是否由 **Vision 仲裁**得出。
        ///
        /// 只在「正向匹配不干净（`matchRatio` 低于 `cleanMatchRatio`）且 Vision
        /// 给出了不同答案」时为 true。此时内核自己的结论本来就不可信，
        /// 所以由二维信号配准翻案。
        public let visionArbitrated: Bool

        /// 独立像素校验中获得运动纹理支持的行范围，坐标属于 next 帧。
        /// 接缝应落在这个范围内，避免在窗口标题或输入栏中切换帧。
        public var alignmentRows: Range<Int>? = nil

        /// 优胜者与竞争假设的相对分离度；没有 rival 时为 nil。
        public var separation: Double? {
            secondBestScore.map { ($0 - score) / max(score, 1e-4) }
        }

        /// 位移结果的来源。
        public enum Source: String, Sendable {
            /// 局部纹理块匹配与有符号位移投票。
            case localFeatureVotes
            /// 有纹理的多行签名投票，并通过移动内容的独立像素校验。
            case rowSignatureVotes
            /// 内核快路径：正向匹配干净，没有碰 Vision。
            case kernel
            /// 内核正向不干净，但 Vision 与内核给出**同一个**答案。
            case kernelAndVisionAgreement
            /// 内核正向不干净，Vision 给出不同答案，且该答案**通过了内核评分**。
            case visionArbitration
            /// 内核层面的反向匹配（两帧互换后求解再取负）。
            case reverseKernel
            /// 内核层面的**翻转**匹配（两帧各自上下翻转后求解再取负）。
            ///
            /// 与 `reverseKernel` 的区别是「先验是否还站得住」：互换两帧只是把
            /// `previous`/`next` 的角色对调，内核那套「同分取更小 delta」的先验
            /// 仍然是为内容上移调的；**翻转**则让内容下移在几何上真正变成内容
            /// 上移，先验才重新成立。实测差距是数量级的（见 `flipAdvantage`）。
            case flippedKernel
        }
    }

    /// 配准失败（尺寸不同等）。
    public enum Failure: Error, Equatable {
        /// 两帧尺寸不同（元组不自动 Equatable，所以拆成具名参数）。
        case shapeMismatch(
            previousWidth: Int, previousHeight: Int,
            nextWidth: Int, nextHeight: Int
        )
        /// 搜索区间内没有任何可用候选（画面太小、参数把区间压空等）。
        case noCandidate
    }

    // MARK: - 调参常量
    //
    // 这些是 anShot 的默认经验值（见 docs/m3-advanced/长截图算法与参数.md），
    // 每一条都在 VerticalOverlapTests 里用合成场景校准过判别力。

    /// 三通道差之和 ≤ 此值即视为该采样「匹配」。
    private static let matchPixelThreshold = 30
    /// 权重下限，避免某些区域权重为 0 后整体失去依据。
    private static let weightFloor = 0.05
    /// 三通道差达到此值即视为该行/该列「充分运动」。
    private static let motionScale = 48.0
    /// 局部梯度达到此值即视为该像素「充分有纹理」。
    private static let textureScale = 1530.0
    /// ±此值内的候选只是同一个波峰的细化邻居，不算竞争假设。
    private static let refinementRadius = 2
    /// 优胜者分数为 0 时的比较尺度，避免 0/0。
    private static let separationFloor = 1e-4
    /// 竞争者误差需高出此倍数才算「完全分离」。
    ///
    /// 定得太严会误伤正常场景：真实网页的行距是规律的（文字行等距），
    /// 相邻几行的内容相似，rival 的分数只比优胜者差两三成是常态。
    /// 这里按合成场景的实测分布取 0.25，同时用「周期内容置信度必须显著低于
    /// 非周期内容」的测试守住判别力不被削弱。
    private static let separationTarget = 0.25
    /// 证据量的满信任阈值。
    private static let evidenceTarget = 0.18
    /// 第一遍（粗筛）的采样行数：越小越快，越大越不容易漏掉真实位移。
    private static let pass1Rows = 14
    /// 进入第二遍（全分辨率 + 纹理）的候选个数。
    private static let pass2Candidates = 6
    /// 正向匹配的 `matchRatio` 达到此值即认为「够干净」，不再跑反向。
    ///
    /// 典型滚动路径（内容整体平移、重叠充分）对齐后几乎全部采样都匹配，
    /// 因此不会付双倍代价；只有正向本身就匹配不上时（回滚、周期 alias、
    /// 动态内容）才多跑一次。
    private static let cleanMatchRatio = 0.98
    /// 反向误差需低于正向的此倍数才采用反向结果。
    ///
    /// 取 0.85：「明显更好才翻符号」是这条的全部意义——两个方向都脏时
    /// （周期内容、界面动效）随便取反会凭空造出回滚。
    private static let reverseBetterRatio = 0.85
    /// 翻转匹配要**比正向干净多少**才被采用。
    ///
    /// 判据刻意只用 `matchRatio`：翻转结果同样是 `estimateDirected` 的产物，
    /// 与正向**同一把尺子**，可以直接比。`confidence` 不行——它在不同 `source`
    /// 之间不可比（见文件下方关于两把尺子的说明）。
    ///
    /// 0.01 取得很小，是因为这条分支只有在**正向已经不干净**（`matchRatio` <
    /// `cleanMatchRatio` = 0.98）时才会走到，而此时翻转本来就是更可能对的解释。
    /// 实测同一对真实帧：正向 `ratio` 0.776、翻转 0.793，翻转略高但位移完全
    /// 一致（-995 / -994）；真正的差别在置信度 0.018 对 0.900。
    private static let flipAdvantage = 0.01
    /// Vision 与内核结论相差不超过此值即视为「两个独立方法得出同一答案」。
    private static let visionAgreementTolerance = 2
    /// 两法一致时的置信度下限。
    ///
    /// 二维信号配准与加权逐点评分是两条独立路径，同时指向同一位移，
    /// 这本身就是强证据——比单独任一方法的置信度都更可信。
    private static let visionAgreementConfidence = 0.9
    /// Vision 单独翻案时的置信度。
    ///
    /// 不直接给高值：Vision 没有置信度可言，且实测在重叠很少（位移接近帧高）
    /// 时会报出完全错误的数值（900 行高的帧、真值 880 解成 −380）。
    /// 编排层据此仍会走「低置信度」那条谨慎路径。
    private static let visionDisagreementConfidence = 0.35
    /// Vision 的候选要被采用，其内核评分不得高于内核自身结论的此倍数。
    ///
    /// 取 1.0 表示「至少不能更差」。**只比较分数是不够的**（周期内容下两个
    /// 候选可能一样好），所以它是一道必要条件而不是充分条件；充分性由
    /// `noEvidenceMatchRatio` 与范围闸门共同保证。
    private static let visionAcceptRatio = 1.0
    /// Vision 仲裁结果的置信度上限。
    private static let visionArbitrationCap = 0.9
    /// 正向匹配率低于此值就认为**两帧没有对应关系**，不再做任何求解尝试。
    ///
    /// 与 `matchConfidence` 的起点一致（那里是 `(matchRatio − 0.35) / 0.5`）。
    /// 用途是拦住「画面在剧烈变化」的情形：那时内核的置信度是 0，而 Vision
    /// **依然会给出一个看起来很正常的 transform**（实测对随机噪声帧也会报位移），
    /// 不加这道闸就会把噪声当成有依据的位移写进世界坐标。
    private static let noEvidenceMatchRatio = 0.35

    // MARK: - 入口

    /// 估计 `previous` → `next` 的竖直位移（有符号，负值为回滚）。
    ///
    /// ── 为什么可能跑两次 ──────────────────────────────────
    ///
    /// 内核本身只解**非负**位移（内容上移 = 用户向下滚），这就是典型路径。
    /// 回滚用「把两帧互换再估一次」得到：互换后回滚变成正向，把反向结果取负即可。
    /// 反向只在正向**不够干净**时才跑，所以典型滚动不付双倍代价。
    ///
    /// ── 为什么不把负值直接并进搜索区间 ────────────────────
    ///
    /// 试过，且**实测把正向判坏了**：区间含负值后，周期内容会让 ±行距整数倍的
    /// 候选同场竞争，正向的正确答案被负向 alias 挤掉。诊断里的连续滚动拼接
    /// 从「4 帧位移 300,300,300,300、输出 1440×2160」退化成
    /// 「300,-713,300,300、输出 1440×1260」——整整少拼一帧。
    /// 正向路径必须保持原样。
    ///
    /// - Returns: 尺寸不一致时抛 `shapeMismatch`；搜索区间内没有任何候选时抛 `noCandidate`。
    public static func estimate(
        previous: ScrollshotImage,
        next: ScrollshotImage,
        options: Options = Options()
    ) throws -> Match {
        if let translation = ScrollshotRowTranslation.estimate(previous: previous, next: next, options: options),
           let quality = evaluateCandidate(previous: previous, next: next, delta: translation.delta, options: options) {
            let candidate = Match(
                deltaY: translation.delta, overlapRows: previous.height - abs(translation.delta),
                confidence: 0.95 * Double(translation.votes - translation.rivalVotes) / Double(translation.votes),
                score: quality.score, secondBestScore: nil, evidence: quality.evidence,
                matchRatio: quality.matchRatio, reversed: translation.delta < 0,
                source: .rowSignatureVotes, visionArbitrated: false
            )
            let validated = validateMovingContent(candidate, previous: previous, next: next, options: options)
            if validated.confidence > 0 { return validated }
        }
        if let translation = ScrollshotFeatureTranslation.estimate(previous: previous, next: next, options: options),
           let quality = evaluateCandidate(previous: previous, next: next, delta: translation.delta, options: options) {
            let candidate = Match(
                deltaY: translation.delta, overlapRows: previous.height - abs(translation.delta),
                confidence: 0.95 * Double(translation.votes - translation.rivalVotes) / Double(translation.votes),
                score: quality.score, secondBestScore: nil, evidence: quality.evidence,
                matchRatio: quality.matchRatio, reversed: translation.delta < 0,
                source: .localFeatureVotes, visionArbitrated: false
            )
            let validated = validateMovingContent(candidate, previous: previous, next: next, options: options)
            if validated.confidence > 0 { return validated }
        }
        let candidate = try estimate(previous: previous, next: next, options: options, allowFlip: true)
        let validated = validateMovingContent(candidate, previous: previous, next: next, options: options)
        if validated.confidence > 0 { return validated }
        // 字体的相位变化会使两个方向的原始逐点评分不同。正向候选未通过
        // 独立校验时，反向求解后仍在原图坐标内验证，不能只比较旧评分便放弃。
        if let reverse = try? estimate(previous: next, next: previous, options: options, allowFlip: true) {
            let alternate = Match(
                deltaY: -reverse.deltaY, overlapRows: reverse.overlapRows,
                confidence: reverse.confidence, score: reverse.score,
                secondBestScore: reverse.secondBestScore, evidence: reverse.evidence,
                matchRatio: reverse.matchRatio, reversed: true,
                source: .reverseKernel, visionArbitrated: reverse.visionArbitrated
            )
            let checked = validateMovingContent(alternate, previous: previous, next: next, options: options)
            // 竞争方向须提供明确证据，不能用周期内容的低置信度别名替换原先验。
            if checked.confidence >= 0.5 { return checked }
        }
        return validated
    }

    /// 独立检查真正移动的纹理，不让共同背景或固定栏为错误位移背书。
    /// 内核和 Vision 同意一个答案仍须过这一关，不能直接提升到固定置信度。
    private static func validateMovingContent(
        _ candidate: Match, previous: ScrollshotImage, next: ScrollshotImage, options: Options
    ) -> Match {
        let top = max(1, options.ignoreTopRows)
        let start = top + max(0, candidate.deltaY)
        let end = min(previous.height, next.height + candidate.deltaY)
        let left = max(1, options.ignoreLeftColumns)
        let right = previous.width - max(0, options.ignoreRightColumns)
        var features = 0
        var aligned = 0
        var supportedRows = 0
        var firstAlignedRow = next.height
        var lastAlignedRow = -1
        var motionFeatures: [(y: Int, x: Int)] = []
        if start < end, left < right {
            previous.withPixels { p in
                next.withPixels { n in
                    for y in stride(from: start, to: end, by: max(1, (end - start) / 160)) {
                        let targetY = y - candidate.deltaY
                        var targetRowMotion = 0
                        for x in stride(from: left, to: right, by: max(1, (right - left) / 160)) {
                            let index = (targetY * next.width + x) * 4
                            let change = abs(Int(p[index]) - Int(n[index]))
                                + abs(Int(p[index + 1]) - Int(n[index + 1]))
                                + abs(Int(p[index + 2]) - Int(n[index + 2]))
                            if change > 30 { targetRowMotion += 1 }
                            if targetRowMotion >= 2 { break }
                        }
                        // 位移对应的目标行也须有运动；正文映到固定标题/输入栏的部分不属重叠。
                        guard targetRowMotion >= 2 else { continue }
                        var rowMatches = 0
                        for x in stride(from: left, to: right, by: max(1, (right - left) / 160)) {
                            let source = (y * previous.width + x) * 4
                            let target = (targetY * next.width + x) * 4
                            let same = (y * next.width + x) * 4
                            func difference(_ a: Int, _ b: Int, _ sameImage: Bool = false) -> Int {
                                let q = sameImage ? p : n
                                return abs(Int(p[a]) - Int(q[b]))
                                    + abs(Int(p[a + 1]) - Int(q[b + 1]))
                                    + abs(Int(p[a + 2]) - Int(q[b + 2]))
                            }
                            // 固定栏、大片背景和空行没有运动纹理，不能算作对齐证据。
                            guard difference(source, same) > 30,
                                  max(difference(source, source - 4, true),
                                      difference(source, source - previous.width * 4, true)) > 30 else {
                                continue
                            }
                            features += 1
                            motionFeatures.append((y, x))
                            if difference(source, target) <= 45 {
                                aligned += 1
                                rowMatches += 1
                            }
                        }
                        if rowMatches > 0 {
                            supportedRows += 1
                            firstAlignedRow = min(firstAlignedRow, targetY)
                            lastAlignedRow = max(lastAlignedRow, targetY)
                        }
                    }
                }
            }
        }
        // 完全静止的帧没有运动特征；重复帧仍交给原有像素匹配率判断。
        if candidate.deltaY == 0, features < 12 { return candidate }
        var ratio = features > 0 ? Double(aligned) / Double(features) : 0
        if features >= 12, ratio < 0.8 {
            // 合成器滚动时会改变文字的像素相位。用相同的低通和一个全局相位
            // 校验两帧，而不是逐点放宽阈值或让每个像素随意寻找邻居。
            let resampled = validateResampledContent(
                previous: previous, next: next, delta: candidate.deltaY, features: motionFeatures
            )
            if resampled.ratio > ratio {
                ratio = resampled.ratio
                supportedRows = resampled.rows
                firstAlignedRow = resampled.firstRow
                lastAlignedRow = resampled.lastRow
            }
        }
        let valid = features >= 12 && supportedRows >= 3 && ratio >= 0.8
        return Match(
            deltaY: candidate.deltaY, overlapRows: candidate.overlapRows,
            confidence: valid ? candidate.confidence : 0,
            score: candidate.score, secondBestScore: candidate.secondBestScore,
            evidence: candidate.evidence, matchRatio: min(candidate.matchRatio, ratio),
            reversed: candidate.reversed, source: candidate.source,
            visionArbitrated: candidate.visionArbitrated,
            alignmentRows: valid ? firstAlignedRow..<(lastAlignedRow + 1) : nil
        )
    }

    /// 对所有运动纹理使用同一个亚像素相位；仍要求至少 80% 的独立特征对应。
    private static func validateResampledContent(
        previous: ScrollshotImage, next: ScrollshotImage, delta: Int,
        features: [(y: Int, x: Int)]
    ) -> (ratio: Double, rows: Int, firstRow: Int, lastRow: Int) {
        var counts = [Int](repeating: 0, count: 7)
        var rowCounts = counts
        var firstRows = [Int](repeating: next.height, count: 7)
        var lastRows = [Int](repeating: -1, count: 7)
        previous.withPixels { p in
            next.withPixels { n in
                func smoothed(_ pixels: UnsafeBufferPointer<UInt8>, x: Int, y: Int, channel: Int) -> Int {
                    var sum = 0
                    for dy in -1...1 {
                        let row = max(0, min(previous.height - 1, y + dy))
                        for dx in -1...1 {
                            let column = max(0, min(previous.width - 1, x + dx))
                            sum += Int(pixels[(row * previous.width + column) * 4 + channel])
                        }
                    }
                    return sum / 9
                }
                for feature in features {
                    let targetY = feature.y - delta
                    var errors = SIMD8<Int32>(repeating: 0)
                    for channel in 0..<3 {
                        let source = smoothed(p, x: feature.x, y: feature.y, channel: channel)
                        let center = smoothed(n, x: feature.x, y: targetY, channel: channel)
                        let before = smoothed(n, x: feature.x, y: targetY - 1, channel: channel)
                        let after = smoothed(n, x: feature.x, y: targetY + 1, channel: channel)
                        for phase in -3...3 {
                            let adjacent = phase < 0 ? before : after
                            let target = (center * (4 - abs(phase)) + adjacent * abs(phase)) / 4
                            errors[phase + 3] += Int32(abs(source - target))
                        }
                    }
                    for index in 0..<7 where errors[index] <= 45 {
                        counts[index] += 1
                        if lastRows[index] != targetY { rowCounts[index] += 1 }
                        firstRows[index] = min(firstRows[index], targetY)
                        lastRows[index] = targetY
                    }
                }
            }
        }
        let winner = (0..<7).max { counts[$0] < counts[$1] } ?? 3
        return (Double(counts[winner]) / Double(features.count), rowCounts[winner],
                firstRows[winner], lastRows[winner])
    }

    /// `estimate` 的实现体。
    ///
    /// `allowFlip` 存在只是为了**防递归**：翻转分支会把翻转后的两帧再交给本函数
    /// 走完整流程（内核正向 → Vision 仲裁 → 反向内核），若翻转世界里的正向也不
    /// 干净，它会想再翻一次——翻回去正好是最初的两帧，就成了无限递归。
    ///
    /// 翻转世界是**一次性**的变换（翻两次回到原点），所以只需一层。
    private static func estimate(
        previous: ScrollshotImage,
        next: ScrollshotImage,
        options: Options,
        allowFlip: Bool
    ) throws -> Match {
        // 正向**连候选都找不到**时不能直接向外抛：向上回滚在正向假设（内容上移）
        // 下本就无解，而回滚正是本函数的正常输入之一（见上文「为什么可能跑两次」）。
        // 直接抛的后果不是「少接一帧」——编排层把它记成 `unresolved`，连续三帧
        // 就判定跟丢、换基准，用户看到「内容跳变」。所以这里换反向重试。
        //
        // 反向也失败才把**正向的错误**抛出去：正向是主路径，它的失败原因更具代表性。
        let forward: Match
        do {
            forward = try estimateDirected(previous: previous, next: next, options: options)
        } catch {
            let reverse = try estimateDirected(previous: next, next: previous, options: options)
            return Match(
                deltaY: -reverse.deltaY,
                overlapRows: reverse.overlapRows,
                confidence: reverse.confidence,
                score: reverse.score,
                secondBestScore: reverse.secondBestScore,
                evidence: reverse.evidence,
                matchRatio: reverse.matchRatio,
                reversed: true,
                source: .reverseKernel,
                visionArbitrated: false
            )
        }

        // 快路径：正向匹配干净就直接返回，不付任何额外代价（来源即 `.kernel`）。
        //
        // **为什么不把「分离度低（疑似周期别名）」也算进触发条件**：试过，且实测
        // 把严格周期内容判坏了。等距横线（内容完全重复）下，内核的先验偏置
        // 「同分取更小的 delta」恰好给出正确答案（实测位移 5px、周期 28px 时给出 5），
        // 而 Vision 给出 285 = 5 + 10×28 —— 纯别名。**严格周期内容单帧本就无解**，
        // 此时内核「偏好重叠更多」的先验比二维配准的任意答案更安全。
        // 真实内容（终端、代码、列表）都是「行距固定但每行不同」，属于另一种情形，
        // 那时正向匹配本就不干净，会被下面的分支接住。
        guard forward.matchRatio < cleanMatchRatio else { return forward }

        // ── 回滚优先走「翻转」，这一步比问 Vision 便宜得多 ──────────
        //
        // 正向不干净时最可能的解释是用户在往上回滚（见下）。而回滚在内核眼里
        // 是「内容下移」，恰好与内核假设相反，所以过去只能请 Vision 兜底。
        //
        // 把两帧**各自上下翻转**（行序反转）后，内容下移在几何上就变成了内容
        // 上移——不只是换了个说法，而是内核那套先验（同分取更小 delta）重新
        // 成立。实测同一对真实帧（上滚 995px，视口 1406px）：
        //
        //   正向         d=-995  c=0.018  ratio=0.776  Vision 仲裁
        //   翻转后       d=-994  c=0.900  ratio=0.793  内核与 Vision 一致
        //
        // 50 倍置信度差。这个差别不是锦上添花：编排层用 confidence 对 0.01 的
        // 下限判「这一帧可不可信」，0.018 擦着线，稍有风吹草动就掉到 0.00x，
        // 连判三帧就换基准、用户看到「内容跳变」。0.900 不擦线。
        //
        // 判据只用 `matchRatio`（同一把尺子），且要求**超过**正向一点点：
        // 两个方向都脏时（周期内容、界面动效）不能随便取反，那会凭空造出回滚。
        if allowFlip,
           let flipped = flippedEstimate(previous: previous, next: next, options: options),
           flipped.matchRatio > forward.matchRatio + flipAdvantage {
            return Match(
                deltaY: -flipped.deltaY,
                overlapRows: flipped.overlapRows,
                confidence: flipped.confidence,
                score: flipped.score,
                secondBestScore: flipped.secondBestScore,
                evidence: flipped.evidence,
                matchRatio: flipped.matchRatio,
                reversed: true,
                source: .flippedKernel,
                visionArbitrated: false
            )
        }

        // 正向不干净——要么是真的难配（动态内容、周期别名），要么是**用户在往上
        // 回滚**：负位移在正向假设下只能匹配到另一段相似内容（实测回滚 150px
        // 被报成 +430px），编排层据此会把已采集的内容再粘一遍。
        //
        // 这时请 Vision 做二维信号级求解。它不逐行独立打分，因此不会 snap 到
        // 「局部合理、整体错误」的候选——终端、代码、聊天记录这类相邻行相似的
        // 内容正是内核的弱项。
        if let arbitrated = arbitrateWithVision(
            previous: previous, next: next, forward: forward, options: options
        ) {
            return arbitrated
        }

        // Vision 不可用或没有结果：退回内核层面的反向匹配。
        guard let reverse = try? estimateDirected(previous: next, next: previous, options: options) else {
            return forward
        }
        guard reverse.score < forward.score * reverseBetterRatio else { return forward }
        return Match(
            deltaY: -reverse.deltaY,
            overlapRows: reverse.overlapRows,
            confidence: reverse.confidence,
            score: reverse.score,
            secondBestScore: reverse.secondBestScore,
            evidence: reverse.evidence,
            matchRatio: reverse.matchRatio,
            reversed: true,
            source: .reverseKernel,
            visionArbitrated: false
        )
    }

    /// 两帧各自上下翻转后走**完整**流程（内核正向 → Vision 仲裁 → 反向内核）。
    ///
    /// ── 为什么不只跑内核正向 ──────────────────────────────
    ///
    /// 试过，实测差两个数量级：同一对真实帧只跑内核正向得 c=0.006，走完整流程得
    /// c=0.900。原因是 0.900 来自「内核与 Vision 得出同一答案」这条路径——它是
    /// 两个独立方法互相印证才有的高置信度，跳过 Vision 就永远拿不到。**翻转解决
    /// 的是方向问题，不是「Vision 不再需要」**。
    ///
    /// 返回的是**翻转坐标系**里的结果：那里的「内容上移」等于原坐标系的
    /// 「内容下移」即向上回滚，所以调用方要取负（见 `estimate`）。
    private static func flippedEstimate(
        previous: ScrollshotImage,
        next: ScrollshotImage,
        options: Options
    ) -> Match? {
        guard let flippedPrevious = flippedVertically(previous),
              let flippedNext = flippedVertically(next)
        else {
            return nil
        }
        return try? estimate(
            previous: flippedPrevious, next: flippedNext, options: options, allowFlip: false
        )
    }

    /// 垂直翻转：行序反转（第 0 行与最后一行互换）。
    ///
    /// 不用 `CGContext` 重绘，也不碰 `CGImage`：内核只认 `data` 这一份 RGBA8
    /// 缓冲，逐行搬运就够，且不引入任何平台依赖。翻转是**上下对称**的，所以
    /// 通道顺序、行填充都不受影响——这正是它比交换两帧更可靠的原因。
    private static func flippedVertically(_ image: ScrollshotImage) -> ScrollshotImage? {
        let bytesPerRow = image.bytesPerRow
        var flipped = [UInt8](repeating: 0, count: image.data.count)
        for row in 0..<image.height {
            let source = (image.height - 1 - row) * bytesPerRow
            let destination = row * bytesPerRow
            flipped.replaceSubrange(
                destination..<(destination + bytesPerRow),
                with: image.data[source..<(source + bytesPerRow)]
            )
        }
        return ScrollshotImage(width: image.width, height: image.height, data: flipped)
    }

    /// 用 Vision 的二维信号配准，对**已经判定为不干净**的正向结果做仲裁。
    ///
    /// 关键分工：**Vision 只出候选，优劣由内核的评分函数判**。Vision 没有置信度，
    /// 且实测在重叠很少时会给出完全错误的值（900 行高的帧、真值 880 解成 −380），
    /// 所以「它给了一个答案」本身不能成为采用它的理由。
    ///
    /// - Returns: 采用 Vision 的答案（或两法一致值得提置信度）时返回新结果；
    ///   Vision 不可用、没有结果、候选被内核评分否决、或超出可解范围时返回 nil，
    ///   交给反向匹配。
    private static func arbitrateWithVision(
        previous: ScrollshotImage,
        next: ScrollshotImage,
        forward: Match,
        options: Options
    ) -> Match? {
        // ⓪ 两帧没有对应关系（画面剧烈变化）：任何位移都是在猜。
        //    Vision 对纯随机噪声帧同样会报出一个「看起来很正常」的 transform。
        guard forward.matchRatio >= noEvidenceMatchRatio else { return nil }

        let searchable = previous.height - max(0, options.ignoreTopRows)

        // ① 范围闸门：Vision 的答案必须落在「两帧重叠充分」的可解区间内。
        let maxDelta = min(
            searchable - 2,
            Int((Double(searchable) * (1 - options.minOverlapRatio)).rounded())
        )
        guard let vision = VisionRegistrar.estimate(
            previous: previous,
            next: next,
            topCrop: max(0, options.ignoreTopRows)
        ), abs(vision.deltaY) <= maxDelta else { return nil }

        // ② 两法一致：两条独立路径给出同一答案，这本身就是强证据。
        if abs(vision.deltaY - forward.deltaY) <= visionAgreementTolerance {
            return Match(
                deltaY: forward.deltaY,
                overlapRows: forward.overlapRows,
                confidence: max(forward.confidence, visionAgreementConfidence),
                score: forward.score,
                secondBestScore: forward.secondBestScore,
                evidence: forward.evidence,
                matchRatio: forward.matchRatio,
                reversed: forward.reversed,
                source: .kernelAndVisionAgreement,
                visionArbitrated: false
            )
        }

        // ③ 不一致：**用内核的评分函数评估 Vision 的候选**，只有它不更差才翻案。
        //    置信度沿用内核在**该位移**上量出的匹配率与证据量，而不是凭空给一个数。
        //
        //    「Vision 给了个不同的答案」本身不是证据：候选必须通过内核评分。
        guard let candidate = evaluateCandidate(
            previous: previous, next: next, delta: vision.deltaY, options: options
        ), candidate.score <= forward.score * visionAcceptRatio else { return nil }

        let matchConfidence = clamp01((candidate.matchRatio - 0.35) / 0.5)
        let evidenceConfidence = clamp01(candidate.evidence / evidenceTarget)
        return Match(
            deltaY: vision.deltaY,
            overlapRows: max(0, searchable - abs(vision.deltaY)),
            confidence: min(visionArbitrationCap, matchConfidence * evidenceConfidence),
            score: candidate.score,
            secondBestScore: forward.secondBestScore,
            evidence: candidate.evidence,
            matchRatio: candidate.matchRatio,
            reversed: vision.deltaY < 0,
            source: .visionArbitration,
            visionArbitrated: true
        )
    }

    /// 在**指定位移**上跑一次内核评分（全分辨率 + 纹理）。
    ///
    /// 用途是评判外部（Vision）给的候选。内核只解非负位移，所以负候选等价于
    /// 「把两帧互换后求正位移」——列权重与行运动必须按交换后的顺序**重算**，
    /// 否则两侧权重语义不同，分数不可比。
    private static func evaluateCandidate(
        previous: ScrollshotImage,
        next: ScrollshotImage,
        delta: Int,
        options: Options
    ) -> (score: Double, matchRatio: Double, evidence: Double)? {
        let (from, to) = delta >= 0 ? (previous, next) : (next, previous)
        let magnitude = abs(delta)
        let searchable = from.height - max(0, options.ignoreTopRows)
        guard searchable >= 8, magnitude < searchable else { return nil }
        let columns = sampleColumns(in: from.width, options: options)
        guard !columns.isEmpty else { return nil }
        let columnWeights = computeColumnWeights(
            previous: from, next: to, columns: columns, options: options
        )
        let rowMotion = computeRowMotion(
            previous: from, next: to, columns: columns, options: options
        )
        let rows = sampledRows(count: options.sampleRows, overlapRows: searchable - magnitude)
        guard let result = score(
            previous: from, next: to, delta: magnitude, columns: columns,
            columnWeights: columnWeights, rowMotion: rowMotion, rows: rows,
            useTexture: true, options: options
        ) else { return nil }
        return (result.score, result.matchRatio, result.evidence)
    }

    /// 单方向求解：只考虑**非负**位移。正向与反向都走这里。
    private static func estimateDirected(
        previous: ScrollshotImage,
        next: ScrollshotImage,
        options: Options = Options()
    ) throws -> Match {
        guard previous.width == next.width, previous.height == next.height else {
            throw Failure.shapeMismatch(
                previousWidth: previous.width, previousHeight: previous.height,
                nextWidth: next.width, nextHeight: next.height
            )
        }
        let searchable = previous.height - max(0, options.ignoreTopRows)
        guard searchable >= 8 else { throw Failure.noCandidate }

        // 位移的可行区间由重叠比例约束得出：overlap = searchable − delta。
        let minDelta = max(0, Int((Double(searchable) * (1 - options.maxOverlapRatio)).rounded()))
        let maxDelta = min(
            searchable - 2,
            Int((Double(searchable) * (1 - options.minOverlapRatio)).rounded())
        )
        guard maxDelta > minDelta else { throw Failure.noCandidate }

        let columns = sampleColumns(in: previous.width, options: options)
        guard !columns.isEmpty else { throw Failure.noCandidate }

        let columnWeights = computeColumnWeights(
            previous: previous, next: next, columns: columns, options: options
        )
        let rowMotion = computeRowMotion(
            previous: previous, next: next, columns: columns, options: options
        )

        // ── 第一遍：1 像素步进穷举，廉价采样、不算纹理 ──
        //
        // 为什么必须穷举而不是粗网格：周期内容（行距、行高）会让真实位移附近
        // 出现一串分数接近的峰，粗网格会直接跨过真正的峰。
        var candidates: [(delta: Int, score: Double, evidence: Double, matchRatio: Double)] = []
        var weightsByDelta: [Int: Double] = [:]

        for delta in minDelta...maxDelta {
            let rows = sampledRows(count: pass1Rows, overlapRows: searchable - delta)
            guard let result = score(
                previous: previous, next: next, delta: delta, columns: columns,
                columnWeights: columnWeights, rowMotion: rowMotion, rows: rows,
                useTexture: false, options: options
            ) else { continue }
            candidates.append((delta, result.score, result.evidence, result.matchRatio))
            weightsByDelta[delta] = result.weightSum
        }
        guard !candidates.isEmpty else { throw Failure.noCandidate }

        // 分数相同时取更小的 delta（重叠更多）——这是先验偏置，不改变正确时的结果。
        candidates.sort { $0.score == $1.score ? $0.delta < $1.delta : $0.score < $1.score }
        let shortlist = Array(candidates.prefix(pass2Candidates))

        // ── 第二遍：短名单用全分辨率 + 纹理复算 ──
        var rescored: [(delta: Int, score: Double, evidence: Double, matchRatio: Double)] = []
        for candidate in shortlist {
            let rows = sampledRows(count: options.sampleRows, overlapRows: searchable - candidate.delta)
            guard let result = score(
                previous: previous, next: next, delta: candidate.delta, columns: columns,
                columnWeights: columnWeights, rowMotion: rowMotion, rows: rows,
                useTexture: true, options: options
            ) else { continue }
            rescored.append((candidate.delta, result.score, result.evidence, result.matchRatio))
        }
        let finalists = rescored.isEmpty ? shortlist : rescored
        guard let winner = finalists.min(by: { $0.score < $1.score }) else {
            throw Failure.noCandidate
        }

        // ── 竞争假设与置信度 ──
        let rival = finalists
            .filter { abs($0.delta - winner.delta) > refinementRadius }
            .min(by: { $0.score < $1.score })

        let separation = rival.map {
            ($0.score - winner.score) / max(winner.score, separationFloor)
        }
        let separationConfidence = clamp01((separation ?? separationTarget) / separationTarget)
        let evidenceConfidence = clamp01(winner.evidence / evidenceTarget)
        // 对齐后仍然「很多采样不匹配」说明内容在两帧之间真的变了（动态内容、
        // 渲染到一半），此时即使峰很尖也不该给高置信度。
        let matchConfidence = clamp01((winner.matchRatio - 0.35) / 0.5)

        return Match(
            deltaY: winner.delta,
            overlapRows: searchable - winner.delta,
            confidence: separationConfidence * evidenceConfidence * matchConfidence,
            score: winner.score,
            secondBestScore: rival?.score,
            evidence: winner.evidence,
            matchRatio: winner.matchRatio,
            reversed: false,
            source: .kernel,
            visionArbitrated: false
        )
    }

    // MARK: - 采样

    /// 等距采样列，避开左右忽略区。
    private static func sampleColumns(in width: Int, options: Options) -> [Int] {
        let left = max(0, options.ignoreLeftColumns)
        let right = max(0, options.ignoreRightColumns)
        let usable = width - left - right
        let count = max(1, min(options.sampleColumns, usable))
        guard usable > 0 else { return [] }
        if count == 1 {
            return [left + usable / 2]
        }
        return (0..<count).map { left + Int(round(Double($0) * Double(usable - 1) / Double(count - 1))) }
    }

    /// 在 `overlapRows` 内等距采样行号（含 0 与最后一行附近）。
    private static func sampledRows(count: Int, overlapRows: Int) -> [Int] {
        guard overlapRows > 0 else { return [] }
        let n = max(1, min(count, overlapRows))
        if n == 1 {
            return [overlapRows / 2]
        }
        return (0..<n).map { min(overlapRows - 1, Int(round(Double($0) * Double(overlapRows - 1) / Double(n - 1)))) }
    }

    // MARK: - 权重

    /// 列权重：该列在两帧之间变化越大，越有信息量。
    private static func computeColumnWeights(
        previous: ScrollshotImage,
        next: ScrollshotImage,
        columns: [Int],
        options: Options
    ) -> [Double] {
        let rows = sampledRows(count: min(96, options.sampleRows), overlapRows: max(1, previous.height - options.ignoreTopRows))
        let base = max(0, options.ignoreTopRows)
        guard !rows.isEmpty else { return columns.map { _ in weightFloor } }
        let width = previous.width
        let height = previous.height
        return previous.withPixels { p in
            next.withPixels { n in
                columns.map { x in
                    var accumulated = 0
                    for s in rows {
                        let y = base + s
                        guard y < height else { continue }
                        let a = (y * width + x) * 4
                        accumulated += abs(Int(p[a]) - Int(n[a]))
                            + abs(Int(p[a + 1]) - Int(n[a + 1]))
                            + abs(Int(p[a + 2]) - Int(n[a + 2]))
                    }
                    let average = Double(accumulated) / Double(rows.count)
                    return weightFloor + (1 - weightFloor) * clamp01(average / motionScale)
                }
            }
        }
    }

    /// 行运动：某个屏幕行在两帧之间是否变化。
    ///
    /// 与 `delta` 无关，因此整幅只需算一次。**吸顶行与留白行在这里被降权**，
    /// 这是 sticky 顶栏不会污染位移估计的原因。
    private static func computeRowMotion(
        previous: ScrollshotImage,
        next: ScrollshotImage,
        columns: [Int],
        options: Options
    ) -> [Double] {
        var motion = [Double](repeating: weightFloor, count: previous.height)
        guard !columns.isEmpty else { return motion }
        let base = max(0, options.ignoreTopRows)
        let width = previous.width
        return previous.withPixels { p in
            next.withPixels { n in
                for y in base..<previous.height {
                    var accumulated = 0
                    for x in columns {
                        let a = (y * width + x) * 4
                        accumulated += abs(Int(p[a]) - Int(n[a]))
                            + abs(Int(p[a + 1]) - Int(n[a + 1]))
                            + abs(Int(p[a + 2]) - Int(n[a + 2]))
                    }
                    let average = Double(accumulated) / Double(columns.count)
                    motion[y] = weightFloor + (1 - weightFloor) * clamp01(average / motionScale)
                }
                return motion
            }
        }
    }

    // MARK: - 打分

    private struct ScoreResult {
        let score: Double
        let weightSum: Double
        let matchRatio: Double
        let evidence: Double
    }

    /// 对某个候选位移打分。
    ///
    /// - Parameter useTexture: 是否叠加纹理权重。第一遍不算（省时间），第二遍算
    ///   （用纹理把「有内容的边缘」与「纯色区」区分开）。
    private static func score(
        previous: ScrollshotImage,
        next: ScrollshotImage,
        delta: Int,
        columns: [Int],
        columnWeights: [Double],
        rowMotion: [Double],
        rows: [Int],
        useTexture: Bool,
        options: Options
    ) -> ScoreResult? {
        let base = max(0, options.ignoreTopRows)
        guard !rows.isEmpty else { return nil }

        // 重叠区在两帧里的起点：位移为正时 `previous` 要往下取，`next` 从顶部开始。
        //
        // 两个 `max` 是防御性的（当前内核只传非负 `delta`）。曾有一版把负位移并进
        // 搜索区间，而下标写成 `previousY = base + delta + s`，`delta < 0` 时掉到 0
        // 以下被 `guard` 跳过——负位移只有一部分采样参与打分，权重和与正位移不同，
        // 两者的 `score` 根本不是同一把尺子。症状是真实网页向下滚 400px 被**稳定地**
        // 报成 −400，连续十几帧全判回滚，长图拼不出任何东西。
        let previousStart = base + max(0, delta)
        let nextStart = base + max(0, -delta)

        var weightedError = 0.0
        var weightSum = 0.0
        var matchedWeight = 0.0
        let width = previous.width
        let height = previous.height

        previous.withPixels { p in
            next.withPixels { n in
                for s in rows {
                    let previousY = previousStart + s
                    let nextY = nextStart + s
                    guard previousY < height, nextY < height else { continue }
                    let motion = rowMotion[nextY]

                    for (index, x) in columns.enumerated() {
                        let a = (previousY * width + x) * 4
                        let b = (nextY * width + x) * 4
                        let diff = abs(Int(p[a]) - Int(n[b]))
                            + abs(Int(p[a + 1]) - Int(n[b + 1]))
                            + abs(Int(p[a + 2]) - Int(n[b + 2]))
                        var weight = columnWeights[index] * motion

                        if useTexture {
                            // 局部梯度：与左邻、上邻的差。只在有边缘的地方给高权重。
                            let sum = Int(p[a]) + Int(p[a + 1]) + Int(p[a + 2])
                            var gradient = 0
                            if x > 0 {
                                gradient += abs(sum - (Int(p[a - 4]) + Int(p[a - 3]) + Int(p[a - 2])))
                            }
                            if previousY > 0 {
                                let c = a - width * 4
                                gradient += abs(sum - (Int(p[c]) + Int(p[c + 1]) + Int(p[c + 2])))
                            }
                            weight *= weightFloor + (1 - weightFloor) * clamp01(Double(gradient) / textureScale)
                        }

                        weightSum += weight
                        weightedError += weight * Double(diff)
                        if diff <= matchPixelThreshold {
                            matchedWeight += weight
                        }
                    }
                }
            }
        }

        guard weightSum > 0 else { return nil }
        let sampleCount = Double(rows.count * columns.count)
        let searchableBase = max(1, previous.height - base)
        let overlapRows = searchableBase - delta
        return ScoreResult(
            score: weightedError / (weightSum * 3 * 255),
            weightSum: weightSum,
            matchRatio: matchedWeight / weightSum,
            evidence: (weightSum / sampleCount) * (Double(overlapRows) / Double(searchableBase))
        )
    }

    @inline(__always)
    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
