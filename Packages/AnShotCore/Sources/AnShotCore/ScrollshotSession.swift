//
//  ScrollshotSession.swift
//  AnShotCore
//
//  长截图会话：**世界坐标追踪** + 逐帧采纳决策。会话期间唯一的状态持有者。
//
//  ── 两本账：观察基准 vs 采纳基准 ──────────────────────────
//
//  早期版本只记「上一帧被采纳的图」并拿它做配准基准。这在**用户往回滚**时会塌：
//
//  * 回滚帧被丢弃，基准却停在更靠下的位置，于是下一帧相对基准的位移是「净位移」，
//    中间隔了多少回滚全被算进去——位移越大，重叠越小，配准越不可靠；
//  * 大跨度回滚会直接冲出配准的搜索区间，内核只能报一个错的位移（实测把
//    回滚 150px 报成 +430px），编排层再据此把已采集的内容粘第二遍。
//
//  所以本文件把两件事分开：
//
//  | 基准 | 用途 | 更新时机 |
//  |---|---|---|
//  | `lastObserved` | 与最近可信帧**配准** | 配准可信且仍接得上已采内容时 |
//  | `acceptedFrames` | 参与**输出**的帧 | 只有带来新内容的帧 |
//
//  正常情况下按相邻帧累积位移，回滚自然表现为负位移；对齐失败时保留
//  最近可信帧及其坐标，等待用户回到有重叠的内容，不凭空续接未知位置。
//
//  ── 「上下滚动不反复采集」的准确含义 ──────────────────────
//
//  不可能在抓帧前就知道用户是否滚动、往哪滚——方向只能从画面推出来。
//  所以本文件保证的是**不把重复内容纳入输出**：
//
//  * 回滚帧（`deltaY < 0`）：判 `rewind`，不采纳、不增加已覆盖高度；
//  * 回滚后重新向下滚，但还没超出已覆盖区：判 `alreadyCovered`，同样不采纳。
//
//  两者都**不进入** `acceptedFrames`，因此不再参与最终拼接，也不占像素内存
//  （只有 `lastObserved` 这一份会被覆盖）。
//

import Foundation

/// 一帧被采纳进入输出时，连同它在世界坐标中的位置一起交给拼接。
public struct ScrollshotFrame: Sendable {
    /// 帧图像。
    public let image: ScrollshotImage
    /// 该帧**视口顶部**在世界坐标中的位置（像素）。首帧恒为 0。
    ///
    /// 与像素行的关系：帧内第 `y` 行对应世界的第 `worldOffset + y` 行。
    /// 负值表示用户在首帧之上还有内容（本次会话没采到），本身不影响拼接。
    public let worldOffset: Int
    /// 该帧相对上一**观察**帧的位移（有符号）；首帧为 0。
    ///
    /// 它只用于审计（`Plan`），拼接不再依赖它——坐标已经在 `worldOffset` 里。
    public let deltaY: Int
    /// 该帧的配准置信度 `0...1`；首帧为 1。
    public let confidence: Double

    public init(image: ScrollshotImage, worldOffset: Int, deltaY: Int = 0, confidence: Double = 1) {
        self.image = image
        self.worldOffset = worldOffset
        self.deltaY = deltaY
        self.confidence = confidence
    }

    /// 帧高（像素）。
    public var height: Int { image.height }
}

/// 会话预览：整幅长图的缩略图 + 当前屏幕视口在其中的位置。
public struct ScrollshotPreview: Sendable {
    /// **整幅**长图的缩略图（等比缩放进调用方给的框内）。
    public let image: ScrollshotImage
    /// 长图的源像素宽度。
    ///
    /// 界面要按它把「定位框该覆盖多少世界行」算出来（详情栏一屏能装多少行，
    /// 取决于长图有多宽），所以随缩略图一并给出，免得界面自己再反推。
    public let worldWidth: Int
    /// 缩略图纵向覆盖的世界行区间：`[worldStart, worldStart + worldHeight)`。
    ///
    /// 界面据此把「鼠标落在缩略图第几行」换算成世界行——**世界行是界面与
    /// 会话之间唯一的位置语言**，缩略图的像素高度会随窗口尺寸与像素上限变化，
    /// 不能让位置信息挂在它上面。
    public let worldStart: Int
    public let worldHeight: Int
    /// 当前屏幕视口在**世界坐标**里对应的行区间（已与已覆盖区域求交，非空）；
    /// 无法确定时为 nil。
    ///
    /// 界面据此标出「正在看的是哪一段」，并在自动跟随模式下把定位框放到这里。
    public let viewportWorldRows: Range<Int>?

    public init(
        image: ScrollshotImage,
        worldWidth: Int,
        worldStart: Int,
        worldHeight: Int,
        viewportWorldRows: Range<Int>?
    ) {
        self.image = image
        self.worldWidth = worldWidth
        self.worldStart = worldStart
        self.worldHeight = worldHeight
        self.viewportWorldRows = viewportWorldRows
    }
}

/// 长截图会话：逐帧提交，内部完成配准、世界坐标追踪与采纳决策。
///
/// 用法（顺序提交，不可乱序——位移是相对上一帧定义的）：
///
/// ```swift
/// var session = ScrollshotSession(options: .init())
/// for frame in captured { _ = session.submit(frame) }
/// let result = session.result()
/// ```
public struct ScrollshotSession {

    // MARK: - 结论

    /// 一帧的处置结论。
    ///
    /// 它是**产物的一部分**（见 `ScrollStitcher.Plan`）：用户看到的长图有瑕疵时，
    /// 需要能回答「是哪一帧、因为什么被丢」，否则只能重截。
    public enum Verdict: String, Sendable, Equatable, CaseIterable {
        /// 带来新内容，已进入输出。
        case accepted
        /// 画面没动（滚动到底／顶之后的空转）。
        case duplicate
        /// 置信度低，且距已采纳区仍未积累出足够的新内容：悬浮层动画、惯性回弹、
        /// 渲染到一半的页面。**画面在变，但没有可采纳的新行**，所以先攒着——
        /// 真正的慢速滚动会在两三帧后越过阈值，而「变了但没滚」永远不会。
        case transient
        /// 向上滚，但这一段已经贴过——用户在往回翻看已采到的部分。
        ///
        /// 它**不等于**「往上滚就该丢弃」：若往上滚到了尚未覆盖的区域，
        /// 那就是正常的`accepted`——长图是从首帧向**两端**生长的。
        case rewind
        /// 向下滚，但还没超出已覆盖区（回滚之后重新往前走的常态）。
        case alreadyCovered
        /// 配准置信度过低：**方向和位移都不可信**，无法判断该不该收录。
        ///
        /// 它和 `transient` 的区别是语义：`transient` 是「页面没滚，只有局部动画」
        ///（画面在变，但距已采纳区始终没有新内容），而这里是**连配准都没跑出结果**
        ///（尺寸异常、搜索区间为空）。这种帧必须留下告警，不能让用户以为长图是全的。
        case unresolved
        /// 与首帧尺寸不一致（理论上同一次会话不会发生，属防御性分支）。
        case sizeMismatch
        /// 已达到输出高度上限，后续帧一律不采纳。
        case outputLimit
    }

    /// 一帧的处置记录。
    public struct Decision: Sendable, Equatable {
        /// 在提交序列里的下标（从 0 开始，含首帧）。
        public let inputIndex: Int
        /// 相对上一**观察**帧的位移（有符号，负值为回滚）。
        public let deltaY: Int
        /// 该帧的配准置信度。
        public let confidence: Double
        /// 提交后本帧视口顶部在世界坐标中的位置。
        public let worldOffset: Int
        /// 处置结论。
        public let verdict: Verdict
        /// 与该帧有关的告警。
        public let warnings: [String]
        /// 该帧的位移是否由 **Vision 仲裁**得出（内核正向不干净时的翻案结果）。
        public let visionArbitrated: Bool
        /// 该帧位移的求解来源；未做配准（首帧、尺寸不符、直接跳过）时为 nil。
        ///
        /// 诊断用。`visionArbitrated` 只能回答「是不是 Vision 翻的案」，而回滚
        /// 现在有两条互不相同的求解路径（内核翻转 `flippedKernel`、互换两帧
        /// `reverseKernel`），两者都满足 `visionArbitrated == false`，只看那个
        /// 布尔值无法判断实际走了哪条。而「回滚到底有没有走上翻转」正是需要
        /// 长期观察的一件事，所以必须把来源本身记下来。
        public var matchSource: VerticalOverlap.Match.Source?
        /// 采纳时从帧内第几行开始取；未采纳为 nil。
        ///
        /// 诊断用：接缝错位类问题（「字被切一半」）要看的就是它。它与
        /// `worldOffset` 一起决定了这一帧贴的是画面的哪一段。
        public let sourceY: Int?
        /// 采纳的行数；未采纳为 0。
        public let acceptedRows: Int
        /// 当前是否因连续配准失败而暂停收录；回到有重叠的内容后恢复。
        public var stalled = false

        /// 采纳当帧生效的吸顶行数（明确指定或自动检测）。
        ///
        /// 这个值一旦偏大或偏小，每一帧都会在顶部多跳/少跳同样多行，
        /// 表现就是「内容重复」或「缺一截」。
        public let stickyRows: Int

        public var isAccepted: Bool { verdict == .accepted }
    }

    /// 一段已采纳的内容：从某帧的第 `sourceY` 行起取 `rows` 行，覆盖世界的
    /// `[worldStart, worldStart + rows)`。
    ///
    /// 存的是 **`worldStart`（世界坐标）而不是图内行号**：图内行号还要减去
    /// `coveredWorldStart`，而后者在会话进行中会变（用户往上滚）。先存世界坐标，
    /// 收尾时再统一重映射，就不会出现「边拼边改行号」那类错位。
    private struct Segment {
        let frame: ScrollshotFrame
        /// 产生它的帧在提交序列里的下标（首帧为 0）。
        let inputIndex: Int
        let sourceY: Int
        let rows: Int
        let worldStart: Int
        /// 存储图像首行在原始帧中的行号；精简存储后 sourceY 仍保留原帧语义。
        let imageRowOffset: Int
    }

    // MARK: - 状态

    private let options: ScrollStitcher.Options
    private var overlapOptions: VerticalOverlap.Options

    /// 首帧：尺寸校验的基准，也是输出的第一段。
    private var firstImage: ScrollshotImage?
    /// 连续未能接回已知内容的帧数；成功配准后清零。
    private var consecutiveUnresolved = 0

    /// 当前是否仍然跟丢；回到有重叠的内容后可恢复。
    public var isStalled: Bool { consecutiveUnresolved >= Self.unresolvedStallThreshold }

    /// 上一**观察**帧——配准基准。
    private var lastObserved: ScrollshotImage?
    /// 上一观察帧视口顶部在世界坐标中的位置。
    private var observedOffset = 0
    /// 已贴进输出的**世界坐标区间** `coveredWorldStart ..< coveredWorldEnd`。
    ///
    /// 长图不是「只向下生长」：首帧是原点，用户向下滚就抬高 `coveredWorldEnd`，
    /// **向上滚就压低 `coveredWorldStart`**。两个边界都是世界坐标，最终输出时
    /// 统一减去 `coveredWorldStart` 得到图内行号——「不管向上还是向下都能拼」
    /// 就落在这一对边界上。
    ///
    /// 对外暴露为只读：诊断要报告「这一帧把哪一段世界坐标接进了输出」，
    /// 接缝错位类问题（内容缺一截 / 错位）看的就是这两个边界。
    public private(set) var coveredWorldStart = 0
    public private(set) var coveredWorldEnd = 0
    /// 已提交的帧数（含首帧）。
    private var observationCount = 0

    /// 已采纳的原始帧；关闭 retainsSourceFrames 时为空，数量使用 acceptedFrameCount。
    public private(set) var acceptedFrames: [ScrollshotFrame] = []
    public private(set) var acceptedFrameCount = 0
    /// 保守统计持有的像素字节数（共享缓冲可能重复计入），用于验证采样不会累积整帧。
    public var retainedPixelBytes: Int {
        // 拆成局部变量再相加。
        //
        // 这一行在本地 Xcode 能过，但 CI 的 Swift 前端会在整条
        // `reduce + reduce + optional` 表达式上报
        // “unable to type-check this expression in reasonable time”。
        // 类型推断的成本不应成为构建是否通过的环境差异；把每一步
        // 的结果显式落到 Int 上，任何工具链都不必再猜。
        let segmentBytes = segments.reduce(0) { total, segment in
            total + segment.frame.image.data.count
        }
        let acceptedBytes = acceptedFrames.reduce(0) { total, frame in
            total + frame.image.data.count
        }
        let firstBytes = firstImage?.data.count ?? 0
        let lastBytes = lastObserved?.data.count ?? 0
        return segmentBytes + acceptedBytes + firstBytes + lastBytes
    }
    /// 全部处置记录（含被丢弃的帧）。
    public private(set) var decisions: [Decision] = []
    /// 整体告警。
    public private(set) var warnings: [String] = []

    /// 已覆盖的世界高度（像素）= `coveredWorldEnd - coveredWorldStart`。
    ///
    /// **进度与预览的唯一权威值**。它只随「带来新内容的帧」增长，
    /// 因此回滚期间（在已覆盖区内往返）不会跳动。
    public private(set) var coveredWorldHeight = 0

    /// **本次会话实际生效的输出行数上限**——所有行数限制的唯一来源。
    ///
    /// `options.maxOutputHeight` 只是行数上限；输出字节数是 `宽 × 高 × 4`，
    /// 同一行数在宽屏上占更多内存。所以再按像素预算压一道：
    ///
    ///     min(maxOutputHeight, maxOutputPixels / 宽)
    ///
    /// 首帧宽度是会话内唯一可信的宽度（尺寸不符的帧会被拒绝），因此以它为除数；
    /// 取 `max(1, …)` 保证宽到极端时上限也不会退化成 0 或负数。
    /// 首帧尚未到达时还无从计算，先返回 `maxOutputHeight`。
    public var outputHeightLimit: Int {
        guard let first = firstImage else { return options.maxOutputHeight }
        let pixelBound = max(1, options.maxOutputPixels / max(1, first.width))
        return min(options.maxOutputHeight, pixelBound)
    }

    /// 粘合片段：已经算好「从帧内第几行、取多少行、覆盖世界的哪一段」。
    ///
    /// 决策一旦做出就固定下来，收尾时只做坐标重映射与内存复制，不再重新推导——
    /// 避免「预览高度」与「最终图高度」因为两处计算而分叉。
    private var segments: [Segment] = []

    // MARK: - 吸顶行自动检测的状态

    /// 检测扫描的最大行数（帧高的 1/3 与 240 行取小）。
    ///
    /// 吸顶栏不会占据半屏；限定范围既控制成本，也避免把「下半屏恰好两帧相似」
    /// 误当成固定行。
    private static let stickyScanMaxRows = 240
    /// 判定「该行在两帧间没有变化」的平均通道差上限（每通道）。
    ///
    /// 订得比配准的 `matchPixelThreshold` 宽松一点：吸顶栏在滚动时会有阴影变化、
    /// 亚像素重绘，要求逐字节相同会永远检测不出。
    private static let stickyRowTolerance = 8.0

    /// 判定「不变的行」时，**滚动位置必须体现出的最小差异**。
    ///
    /// ── 缺了这条会怎样（实测）────────────────────────────
    /// 原判据是「同位置比滚动位置更像，且同位置足够像」。在**平坦区域**
    /// （空行、分隔线、背景）上，同位置和滚动位置**都接近 0**，谁大谁小
    /// 完全由压缩噪声决定，而 `0 <= tolerance 8` 又轻松成立——判据退化成
    /// 「比噪声大小」，一半概率判成「不变」，再经多数投票累积成固定行数。
    ///
    /// 真实终端顶部就是「一条边框 + 约 16px 空白」，于是自动检测稳定报出
    /// 4~11 行假吸顶（每帧还不同）。向上滚动时每帧都要跳过这些行，
    /// 13 帧累计少接约 90px ≈ 2.7 行文字，接缝正好落在文字中间，
    /// 表现就是用户报的「字只有一半」。
    ///
    /// 加上这条以后：平坦区域 two 值都小于门槛 → **不判定**（没有对比就没有依据）；
    /// 真有内容的吸顶栏 → 同位置≈0、滚动位置很大 → 正常判定。
    private static let stickyRowContrast = 20.0

    /// 位移被视为「有依据」所需的最低置信度。
    ///
    /// ── 为什么不能只用 `confidence > 0`（真实故障）──────────
    /// 配准在**完全失败**时并不会返回 0，而是返回一个**随机位移**：实测
    /// 「页面已到底、用户继续往下滚」的那一帧报出 `d=1270 / confidence=0.002`。
    /// `0.002 > 0` 成立，于是这个纯噪声位移被当成可靠滚动量采纳，世界坐标
    /// 前进 1270px，把首帧已经采过的画面又贴了一遍 —— 用户看到的就是
    /// 「下面出现重复内容」。
    ///
    /// 门槛取 0.01 而不是 `minConfidence 0.5`：真实内容（网页/终端）的置信度
    /// 普遍只有 0.05~0.15，用 0.5 会把正常帧全部拦掉。而「彻底没依据」的量级
    /// 是 0.00x，两者差一个数量级，0.01 正好落在空档里：
    /// 真·大跨度滚动（0.05~0.15）仍然走 FAIL-OPEN 保留，只有纯噪声被拦下。
    private static let minimumTrustedConfidence = 0.01

    /// 低置信度的静止帧仍须具备足够的像素对应，防止无关画面污染基准。
    private static let minimumStillMatchRatio = 0.9

    /// 判定「不变的行」时，**该行自身必须具备的最小行内对比度**。
    ///
    /// ── 缺了这条会怎样（实测）────────────────────────────
    /// 只有「同位置相同」是不够的：**空白行的同位置也相同**，但原因是它
    /// **没有内容**，而不是**内容固定**。空白与真吸顶栏在单帧对照里长得一样：
    /// 同位置都≈0，而 `y + shift` 落到下方文字上使「滚动位置差异大」也成立，
    /// 于是空白被当成固定栏。
    ///
    /// 后果不是「少采了一点空白」这么轻：被跳过的行会被代码当作**不占世界坐标**
    /// （吸顶栏只在输出顶端出现一次），于是该帧的滚动区起点整体上移、每帧上移量
    /// 还不一样（实测 4/9/10/11 行），相邻段的映射错开十几像素，接缝就切在
    /// 文字中间——用户看到的「字只有一半」。
    ///
    /// 行内对比度把两者分开：空白行的采样点几乎同值（对比度≈0），
    /// 真正有内容的导航栏/工具栏必然有明显起伏。
    private static let stickyRowContent = 20.0
    /// 每行的采样列数。检测本身不是精度活儿（只需要“变没变”），采稀一点即可。
    private static let stickySampleColumns = 24
    /// 至少观测多少次才开始采信检测结果。
    private static let stickyMinObservations = 3

    /// 每一行在历次「有滚动的帧对」中保持不变的票数。
    private var stickyVotes: [Int] = []
    /// 有效的检测次数（票数的分母）。
    private var stickyObservations = 0

    /// 自动检测出的吸顶行数。仅当调用方**未**指定 `stickyHeaderRows` 时有意义。
    public private(set) var detectedStickyRows = 0

    public init(options: ScrollStitcher.Options = ScrollStitcher.Options()) {
        self.options = options
        self.overlapOptions = options.overlap
        // 配准也要忽略顶部的固定元素：它们不随滚动移动，混进评分会把位移估计
        // 往「不动」的方向拉。这里取两者较大值——`stickyHeaderRows` 是页面顶栏，
        // `unusableTopRows` 是屏幕固定元素，对配准而言都属于「不该看的行」。
        self.overlapOptions.ignoreTopRows = max(0, options.stickyHeaderRows, options.unusableTopRows)
    }

    // MARK: - 提交

    /// 提交一帧，返回它的处置结论。
    ///
    /// 必须按采集顺序调用：位移是「相对上一帧」定义的，乱序提交会得到无意义的坐标。
    @discardableResult
    public mutating func submit(_ image: ScrollshotImage) -> Decision {
        let index = observationCount
        observationCount += 1

        guard let first = firstImage else {
            return acceptFirstFrame(image, index: index)
        }
        guard image.width == first.width, image.height == first.height else {
            // 尺寸不一致：不推进观察基准（这一帧不能作为下一次配准的依据）。
            return record(Decision(
                inputIndex: index, deltaY: 0, confidence: 0, worldOffset: observedOffset,
                verdict: .sizeMismatch,
                warnings: ["尺寸与首帧不一致（\(image.width)x\(image.height) vs \(first.width)x\(first.height)）"],
                visionArbitrated: false, sourceY: nil, acceptedRows: 0, stickyRows: 0
            ))
        }

        // 正常时逐帧配准；失败帧不能替换最后可信基准，恢复时仍与该基准对齐。
        var frameWarnings: [String] = []
        var delta = 0
        var confidence = 0.0
        var matchRatio = 0.0
        var matched = false
        var arbitratedByVision = false
        var matchSource: VerticalOverlap.Match.Source?
        var alignmentRows: Range<Int>?
        if let previous = lastObserved {
            do {
                let match = try VerticalOverlap.estimate(
                    previous: previous, next: image, options: overlapOptions
                )
                delta = match.deltaY
                confidence = match.confidence
                matchRatio = match.matchRatio
                arbitratedByVision = match.source == .visionArbitration
                matchSource = match.source
                alignmentRows = match.alignmentRows
                matched = true
                if match.confidence == 0, match.matchRatio < 0.8 {
                    frameWarnings.append("内容未通过像素对齐校验（匹配率 \(String(format: "%.2f", match.matchRatio))）")
                }
            } catch {
                frameWarnings.append("配准失败：\(error)")
            }
        }

        // 吸顶行检测：用「相邻两帧之间位置不变」这一特征猜出帧顶部的固定行数。
        // 必须在 `lastObserved` 被本帧覆盖**之前**做。
        if matched, !options.joinsInsideOverlap, let previous = lastObserved {
            detectStickyRows(previous: previous, next: image, delta: delta)
        }

        // 观察基准与观察偏移**始终成对推进**：它们描述的是同一个帧的位置。
        // 只有「这一帧能作为下一次配准的依据」时才推进——否则一个错的位移会把
        // 后续所有帧的世界坐标一起带偏。
        //
        // 带粘合信息的待采纳区间（也是「距已采纳区还有多远」的量）。
        let stickyRows = options.joinsInsideOverlap ? 0 : max(0, min(effectiveStickyRows, first.height - 1))

        // 置信度低于门槛（或配准直接失败）表示**没有任何依据**：此时配准给出的
        // 位移是纯噪声（实测 `d=1270 / c=0.002`、`d=-181 / c=0.000`），采信它
        // 会把世界坐标推到任意位置并重复粘贴已采内容。所以判 `unresolved`，
        // 且**不推进观察基准**（把这一帧当作没发生过）。
        //
        // 门槛的含义见 `minimumTrustedConfidence`：它只拦「彻底没依据」，
        // 不拦真实的大跨度滚动（那一档置信度 0.05~0.15，继续 FAIL-OPEN 保留）。
        //
        // **例外**：位移本身极小（≈没滚动）时，低置信度并不代表结论错。
        // 周期规律内容里「不动」和「动一点」的得分几乎一样，分离度天然趋零，
        // 所以「页面到底了、用户继续滚」这类帧的置信度必然很低，但「没滚动」
        // 正是正确答案。把它判成 `unresolved`（配准无依据）既误导用户，
        // 又会让观察基准冻住。判 `duplicate` 才是准确的，也会正常推进基准。
        // 位移接近零本身不能证明画面相同：无关画面也可能恰好得到零位移候选。
        let effectivelyStill = abs(delta) <= options.duplicateDeltaThreshold
            && matchRatio >= Self.minimumStillMatchRatio
        let trusted = matched
            && (confidence >= Self.minimumTrustedConfidence || effectivelyStill)
        let effectiveDelta = trusted ? delta : 0
        let candidateOffset = observedOffset + effectiveDelta

        // 本帧覆盖世界的 `[candidateOffset, candidateOffset + height)`；其中开头
        // `stickyRows` 行是固定顶栏（只在最终输出顶端出现一次，不重复计入），
        // 末尾 `bottomRows` 行是屏幕底部固定元素（同理，不参与内容）。
        //
        // **差集要在两端都算**：用户向上滚时新内容出现在上方、向下滚时出现在下方，
        // 这就是「不管向上还是向下都能拼」的全部含义。
        //
        // 判据用区间差集而不是位移符号：帧可能同时与两端都有交集（大幅回滚后
        // 重新走过），只看符号会漏掉真正该补的那一段。
        let frameTop = candidateOffset + stickyRows
        let bottomRows = options.joinsInsideOverlap ? 0 : usableFrameBottom
        let frameBottom = candidateOffset + image.height - bottomRows
        // 区间外的新帧不能扩张已覆盖边界：两段之间没有任何像素可供填充，
        // compose、预览和明细切片都会把这段空洞显示成黑色断层。
        let alignmentStart = candidateOffset + (alignmentRows?.lowerBound ?? 0)
        let alignmentEnd = candidateOffset + (alignmentRows?.upperBound ?? image.height)
        let connectsToCoverage = frameTop <= coveredWorldEnd && frameBottom >= coveredWorldStart
            && (!options.joinsInsideOverlap
                || max(coveredWorldStart, alignmentStart) < min(coveredWorldEnd, alignmentEnd))
        let rows: Int
        let sourceStart: Int
        if frameBottom > coveredWorldEnd {
            // 下方有新内容（向下滚动）。
            sourceStart = max(frameTop, coveredWorldEnd)
            rows = frameBottom - sourceStart
        } else if frameTop < coveredWorldStart {
            // 上方有新内容（向上滚动）。
            sourceStart = frameTop
            rows = coveredWorldStart - sourceStart
        } else {
            sourceStart = frameTop
            rows = 0
        }
        let lowConfidence = confidence < options.minConfidence
        var advancesObservation = true

        var verdict: Verdict
        /// 采纳时的粘合信息：帧内起点、行数、以及该段覆盖的**世界坐标起点**。
        var planning: (sourceY: Int, rows: Int, worldStart: Int)?

        var stalled = false
        if !trusted || (!connectsToCoverage && coveredWorldHeight < outputHeightLimit) {
            // 配准失败或完全没依据：既不知道位移也不知道方向。判 `unresolved` 而不是
            // 「没滚动」，后者会让一帧无法对齐的内容被静默当成空转丢掉。
            verdict = .unresolved
            advancesObservation = false
            consecutiveUnresolved += 1
            if consecutiveUnresolved >= Self.unresolvedStallThreshold {
                // 未知画面与旧图之间的位置无法推断，保留最后可信基准，
                // 等用户回到重叠内容后恢复，不能凭空把新段接到旧图末尾。
                stalled = true
                frameWarnings.append(
                    "连续 \(consecutiveUnresolved) 帧未能对齐，已暂停收录，请缓慢回滚到已采内容"
                )
            } else {
                frameWarnings.append(connectsToCoverage
                    ? "配准无依据，该帧未收录"
                    : "当前帧与已采内容之间存在空缺，该帧未收录")
            }
        } else if rows <= 0, abs(effectiveDelta) <= options.duplicateDeltaThreshold {
            // 规则一：画面没动，且没有待补的新行。
            //
            // 编排层**不依赖置信度**判断重复——两帧完全相同时，配准的权重指标
            // 天然接近下限，置信度不可信。
            verdict = .duplicate
        } else if rows <= 0, effectiveDelta < 0 {
            // 规则二：向上滚，但内容已经贴过——用户往回翻看已采到的部分。
            // 不重复粘贴。
            //
            // **不拿置信度卡这一支**：实测规律行距页面的正常滚动置信度只有
            // 0.07～0.40（周期内容让竞争假设的分离度天然偏低），用 `minConfidence`
            // 要求回滚会把它整段误判成「不可信」。而这里「没有新内容」是确定的，
            // 不确定的只是滚了多少——那只影响坐标精度，不影响「该不该收录」。
            verdict = .rewind
            if lowConfidence {
                frameWarnings.append("置信度低（\(String(format: "%.2f", confidence))），回滚量可能不准")
            }
        } else if rows <= 0 {
            // 规则三：向下滚，但还没超出已覆盖区——回滚之后重新往前走的常态。
            verdict = .alreadyCovered
        } else if abs(effectiveDelta) <= options.duplicateDeltaThreshold {
            // 规则四：画面没动，但**还有上一帧攒下的新行**。
            //
            // 典型路径：慢速滚动时上一帧因内容不够被 `transient` 拦下，
            // 用户随后停手、画面稳定——此时应当把落下的那几十像素补上，
            // 否则「滚完就停」的会话总会在末尾差一截。
            verdict = .accepted
        } else if lowConfidence, options.transientDeltaThreshold > 0,
                  rows <= options.transientDeltaThreshold {
            // 规则五：低置信度且**积累的新内容还不够多** = 瞬态噪声（悬浮层动画、
            // 惯性回弹、渲染到一半的页面）。
            //
            // 量的是 `rows`（距已覆盖区还有多少新行）而不是「相对上一帧的位移」：
            // 配准基准每帧都推进，慢速滚动时相邻位移永远只有几十像素，
            // 按相邻位移判瞬态会把慢滚的每一帧都丢掉（基准推进 → 位移永不累积）。
            // 按 `rows` 量：慢滚会在两三帧后自然越过阈值，而悬浮层动画
            //（画面在变但没滚动）的 `rows` 永远不增，会被一直拦住。
            verdict = .transient
        } else if coveredWorldHeight >= outputHeightLimit {
            // 高度上限：长截图的内存是 宽×高×4，必须有硬边界。
            // 报出**生效的**行数上限（可能已被像素预算压低）以及像素预算本身，
            // 否则宽屏下用户会看到「明明没到 32768 行就停了」而无法解释。
            warnings.append(
                "达到输出高度上限 \(outputHeightLimit)px（像素预算 \(options.maxOutputPixels)px），后续帧未采纳"
            )
            verdict = .outputLimit
            frameWarnings.append("超过高度上限")
        } else {
            // 采纳。低置信度的大位移帧走 FAIL-OPEN：更可能是一次真实的
            // **大跨度滚动**，配准只是没跟上。宁可留下可疑内容（用户能看见并重截），
            // 也不要静默丢帧。
            if lowConfidence {
                frameWarnings.append("置信度偏低（\(String(format: "%.2f", confidence))），内容可能有误")
            }
            verdict = .accepted
        }

        // ── 采纳的唯一执行点 ──
        // 所有判为 `accepted` 的路径（含「画面没动但有待补新行」）都必须汇到这里，
        // 否则会出现「结论是采纳、却什么都没贴」的不一致——实测就是这么漏掉
        // 用户停手时那最后几十像素的。
        if verdict == .accepted {
            let allowedRows = max(0, outputHeightLimit - coveredWorldHeight)
            let acceptedRows = min(rows, allowedRows)
            if acceptedRows < rows {
                frameWarnings.append("被高度上限截断，少接 \(rows - acceptedRows)px")
                warnings.append(
                    "达到输出高度上限 \(outputHeightLimit)px（像素预算 \(options.maxOutputPixels)px），最后一帧被截断"
                )
            }
            // 被截断时**保留紧邻已覆盖区的那一段**：向下扩展丢远端（更靠下的），
            // 向上扩展丢远端（更靠上的）。两端一致，用户看到的是「从当前进度往外接」
            // 的连续内容，而不是中间横插一段。
            if options.joinsInsideOverlap {
                let overlapStart = max(coveredWorldStart, candidateOffset + (alignmentRows?.lowerBound ?? 0))
                let overlapEnd = min(coveredWorldEnd, candidateOffset + (alignmentRows?.upperBound ?? image.height))
                let seam = overlapStart + max(0, overlapEnd - overlapStart) / 2
                if sourceStart >= coveredWorldStart {
                    let end = coveredWorldEnd + acceptedRows
                    retainSegments(in: coveredWorldStart..<seam)
                    planning = (seam - candidateOffset, end - seam, seam)
                    coveredWorldEnd = end
                } else {
                    let start = coveredWorldStart - acceptedRows
                    retainSegments(in: seam..<coveredWorldEnd)
                    planning = (start - candidateOffset, seam - start, start)
                    coveredWorldStart = start
                }
            } else if sourceStart >= coveredWorldStart {
                planning = (sourceStart - candidateOffset, acceptedRows, sourceStart)
                coveredWorldEnd = sourceStart + acceptedRows
            } else {
                let worldStart = coveredWorldStart - acceptedRows
                planning = (worldStart - candidateOffset, acceptedRows, worldStart)
                coveredWorldStart = worldStart
            }
            coveredWorldHeight = coveredWorldEnd - coveredWorldStart
        }

        // 观察基准与观察偏移**始终成对推进**：它们描述的是同一个帧的位置。
        // 只推进其中一个会让后续帧的坐标系统性错位——实测表现为「回滚之后
        // 输出高度莫名多出一截」（被误采纳），比位移本身不准更隐蔽。
        // 唯一例外是 `unresolved`：那一帧的位移是纯噪声，连位置都不可信，
        // 把它归入基准只会让后面每一帧一起漂。
        if advancesObservation {
            lastObserved = image
            observedOffset = candidateOffset
            consecutiveUnresolved = 0
        }

        if let plan = planning {
            let frame = ScrollshotFrame(
                image: image, worldOffset: candidateOffset, deltaY: delta, confidence: confidence
            )
            segments.append(makeSegment(
                frame: frame, inputIndex: index,
                sourceY: plan.sourceY, rows: plan.rows, worldStart: plan.worldStart
            ))
            acceptedFrameCount += 1
            if options.retainsSourceFrames { acceptedFrames.append(frame) }
        }

        return record(Decision(
            inputIndex: index, deltaY: delta, confidence: confidence,
            worldOffset: observedOffset, verdict: verdict, warnings: frameWarnings,
            visionArbitrated: arbitratedByVision, matchSource: matchSource,
            sourceY: planning?.sourceY, acceptedRows: planning?.rows ?? 0,
            stalled: stalled, stickyRows: stickyRows
        ))
    }

    // MARK: - 收尾

    /// 用当前已采纳的帧收尾：合成最终长图，并产出完整的决策计划。
    ///
    /// 只要还有一帧可用就产出结果；只有「确实没有东西可交付」才返回 `failure`。
    public func result() -> ScrollStitcher.Result {
        // 先把决策整理成计划帧：下面每个分支（包括失败分支）都要用它，
        // 否则失败时用户就看不到「哪一帧因为什么被丢」，只剩一句「失败」。
        let planFrames = makePlanFrames()

        guard let first = firstImage, first.width > 0, first.height > 0 else {
            return ScrollStitcher.Result(
                image: nil,
                plan: ScrollStitcher.Plan(
                    frames: planFrames, seamRows: [], outputWidth: 0, outputHeight: 0, warnings: []
                ),
                failure: .emptyFirstFrame
            )
        }
        guard observationCount >= 2 else {
            return ScrollStitcher.Result(
                image: nil,
                plan: ScrollStitcher.Plan(
                    frames: planFrames, seamRows: [], outputWidth: first.width,
                    outputHeight: first.height, warnings: ["输入只有 \(observationCount) 帧"]
                ),
                failure: .notEnoughFrames(observationCount)
            )
        }

        // 除首帧外至少要有一段，否则输出就等于首帧（向上或向下扩展都算，
        // 所以判据是**总高度**而不是「下界变大了」）。
        let beyondFirst = segments.filter { $0.inputIndex != 0 }
        let outputHeight = coveredWorldHeight
        guard !beyondFirst.isEmpty, outputHeight > first.height else {
            return ScrollStitcher.Result(
                image: nil,
                plan: ScrollStitcher.Plan(
                    frames: planFrames, seamRows: [], outputWidth: first.width,
                    outputHeight: first.height,
                    warnings: resultWarnings + ["除首帧外没有任何帧被接受"]
                ),
                failure: .noAcceptedFrame
            )
        }

        // 段按**世界坐标**排序 = 输出顺序。用户可能先往下拼、再往上扩展，
        // 采纳顺序与输出顺序因此不再一致，这里必须按坐标排。
        let ordered = segments.sorted { $0.worldStart < $1.worldStart }
        let seamRows = ordered
            .filter { $0.inputIndex != 0 }
            .map { $0.worldStart - coveredWorldStart }
        let image = ScrollStitcher.compose(
            segments: ordered.map {
                (source: $0.frame.image, sourceY: $0.sourceY - $0.imageRowOffset, rows: $0.rows,
                 outputY: $0.worldStart - coveredWorldStart)
            },
            width: first.width,
            height: outputHeight
        )
        // 尺寸不一致属逐帧告警，但它会让用户看到的长图缺一块，必须在整体告警里也有。
        var planWarnings = resultWarnings
        for decision in decisions where decision.verdict == .sizeMismatch {
            planWarnings.append("第 \(decision.inputIndex) 帧尺寸与首帧不一致，已跳过")
        }
        return ScrollStitcher.Result(
            image: image,
            plan: ScrollStitcher.Plan(
                frames: planFrames, seamRows: seamRows, outputWidth: first.width,
                outputHeight: outputHeight, warnings: planWarnings
            ),
            failure: nil
        )
    }

    // MARK: - 预览

    /// 缩略图的总像素上限。
    ///
    /// 按调用方给的框等比缩，正常情况下远够不到这个数（导航栏只有几十点宽）。
    /// 留这条是**挡住巨框**：长图上限 32768 行，若有人按 1:1 索要整幅，
    /// 预览自己就成了几百 MB 的内存大头。超限时整体降比例（仍保持等比），
    /// 宁可细一点，也不让「看一眼」的功能把内存吃掉。
    private static let maxPreviewPixels = 2_000_000

    /// 连续三帧未能对齐时提示回滚；始终保留最后可信的坐标与参考帧。
    private static let unresolvedStallThreshold = 3

    /// 未恢复时，收尾也必须告知用户输出仅包含已对齐的连续内容。
    private var resultWarnings: [String] {
        guard consecutiveUnresolved > 0 else { return warnings }
        return warnings + ["仍有未对齐的画面，已保留已采集的连续内容；可回滚后继续采集"]
    }

    /// 生成**整幅长图**的缩略图，并附上「当前屏幕视口在其中的位置」。
    ///
    /// ── 为什么是「整幅 + contain」──────────────────────────
    ///
    /// 界面要回答两个问题：**长图现在长什么样**、**我正在看的是哪一段**。
    /// 只给末尾一段能答第一个答不了第二个；只给「按宽度铺满的末尾」更是把长图
    /// 切成了看不全的窗口。所以这里返回完整长图的等比缩略，让它**整个**装进
    /// 调用方给的框：`scale = min(框宽/图宽, 框高/图高)`。
    ///
    /// 代价是长图很长时缩略图会**窄成一条**。这是「整幅可见」的必然结果，不是
    /// 缺陷——本方法只负责回答「整体在哪、我在哪一段」，**细节由另一栏补**：
    /// 界面按世界行区间调 `slice(worldRows:targetWidth:)` 取原图切片，显示在放大栏。
    /// 两栏合起来才同时给出「看得全」与「看得清」，单靠其中任何一栏都做不到。
    ///
    /// 成本是 `thumbWidth × thumbHeight` 次最近邻采样。缩略图被框限死了上限，
    /// 这个量级与长图长度**无关**，可按节流频率反复调用。
    ///
    /// - Parameters:
    ///   - maxWidth: 缩略图框的像素宽度。
    ///   - maxHeight: 缩略图框的像素高度。
    /// - Returns: 还没首帧时为 nil。
    public func preview(fittingWidth maxWidth: Int, fittingHeight maxHeight: Int) -> ScrollshotPreview? {
        guard let first = firstImage,
              maxWidth > 0, maxHeight > 0,
              coveredWorldHeight > 0 else { return nil }

        let sourceWidth = first.width
        let sourceHeight = coveredWorldHeight

        // contain：取较小的比例；不放大（长图比框小就按原尺寸给，放大只是浪费内存）。
        let scaleByWidth = Double(maxWidth) / Double(sourceWidth)
        let scaleByHeight = Double(maxHeight) / Double(sourceHeight)
        var scale = min(1, min(scaleByWidth, scaleByHeight))

        // 像素上限兜底（见 `maxPreviewPixels`）。
        let pixelCount = Double(sourceWidth) * scale * Double(sourceHeight) * scale
        if pixelCount > Double(Self.maxPreviewPixels) {
            scale = (Double(Self.maxPreviewPixels) / (Double(sourceWidth) * Double(sourceHeight)))
                .squareRoot()
        }

        let thumbWidth = max(1, Int((Double(sourceWidth) * scale).rounded(.down)))
        let thumbHeight = max(1, Int((Double(sourceHeight) * scale).rounded(.down)))

        guard let image = render(
            worldRows: coveredWorldStart..<coveredWorldEnd,
            outputWidth: thumbWidth, outputHeight: thumbHeight
        ) else { return nil }
        return ScrollshotPreview(
            image: image,
            worldWidth: sourceWidth,
            worldStart: coveredWorldStart,
            worldHeight: coveredWorldHeight,
            viewportWorldRows: viewportWorldRows()
        )
    }

    /// 当前屏幕视口在**世界坐标**里对应的行区间。
    ///
    /// 当前视口覆盖世界 `[observedOffset, observedOffset + 帧高)`。
    ///
    /// ── 为什么返回世界坐标而不是缩略图坐标 ──────────────────
    ///
    /// 缩略图的高度会随框尺寸、像素上限与长图长度变化，位置信息挂在它上面就会在
    /// 每次预览更新时抖动；而界面手里那份「用户把定位框拖到哪了」要跨多次预览
    /// 持有。世界坐标是两者之间唯一不变的语言，换算留给界面（它本来就要算）。
    ///
    /// 与已覆盖区间求交后再返回：视口可能有一部分还没进长图（正在滚动的边界），
    /// 那部分没有像素可标，标了就是骗人。
    private func viewportWorldRows() -> Range<Int>? {
        guard let first = firstImage, coveredWorldHeight > 0 else { return nil }
        let top = max(observedOffset, coveredWorldStart)
        let bottom = min(observedOffset + first.height, coveredWorldEnd)
        guard top < bottom else { return nil }
        return top..<bottom
    }

    /// 取长图中指定**世界行区间**的像素切片，横向缩放到 `targetWidth`（等比，不放大）。
    ///
    /// ── 用途：放大栏 ──────────────────────────────────────
    ///
    /// `preview` 给的是「整幅可见」的导航缩略图，长图一长它就窄成一条、看不清内容。
    /// 界面把定位框停在某处时，用本方法取**那一处的原图切片**显示在放大栏，
    /// 于是「看得全」与「看得清」分给两栏各自成立。
    ///
    /// ── 为什么按世界行而不是图内行 ────────────────────────
    ///
    /// 会话进行中 `coveredWorldStart` 会因为用户**向上滚**而变小，图内行号随之整体
    /// 平移；界面持有的定位是跨多次预览的，只有世界坐标不会中途改变含义。
    ///
    /// - Parameters:
    ///   - worldRows: 期望的世界行区间（会与已覆盖区间求交）。
    ///   - targetWidth: 输出像素宽度上限；长图比它窄时按原宽输出（不放大）。
    /// - Returns: 区间落在已覆盖范围之外、或还没首帧时为 nil。
    public func slice(worldRows: Range<Int>, targetWidth: Int) -> ScrollshotImage? {
        guard let first = firstImage, targetWidth > 0, coveredWorldHeight > 0 else { return nil }

        let sourceWidth = first.width
        let start = max(worldRows.lowerBound, coveredWorldStart)
        let end = min(worldRows.upperBound, coveredWorldEnd)
        guard start < end else { return nil }
        let requestedRows = end - start

        let outputWidth = min(targetWidth, sourceWidth)
        let outputHeight = max(
            1,
            Int((Double(requestedRows) * Double(outputWidth) / Double(sourceWidth)).rounded(.down))
        )

        return render(worldRows: start..<end, outputWidth: outputWidth, outputHeight: outputHeight)
    }

    /// 导航预览与明细共用逐行取段，接缝取整也不会留下透明行或取到相邻段的固定栏。
    private func render(worldRows: Range<Int>, outputWidth: Int, outputHeight: Int) -> ScrollshotImage? {
        guard let first = firstImage else { return nil }
        let sourceWidth = first.width
        let start = worldRows.lowerBound
        let requestedRows = worldRows.count
        let sourceBytesPerRow = sourceWidth * 4
        let outputBytesPerRow = outputWidth * 4
        var buffer = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)

        // 列映射预计算：用户在拖动定位框时本方法会被连续调用（每帧一次），
        // 把每次采样都要做的整数除法提到循环外是实打实的提速。
        var columnMap = [Int](repeating: 0, count: outputWidth)
        for outX in 0..<outputWidth {
            columnMap[outX] = min(sourceWidth - 1, outX * sourceWidth / outputWidth)
        }

        // 段按世界坐标排序后**逐输出行**推进：一个输出行只由一个段提供，而段与段
        // 之间可能不满一个输出行。逐行推进能保证每个输出行都落到真正覆盖它的那段上，
        // 不会像「按段分块」那样在边界留下没填的透明行。
        let ordered = segments.sorted { $0.worldStart < $1.worldStart }
        var segmentIndex = 0

        buffer.withUnsafeMutableBufferPointer { out in
            guard let outBase = out.baseAddress else { return }
            for outY in 0..<outputHeight {
                // 输出行 → 世界行（`outY` 单调递增，所以世界行也单调，指针只需前进）。
                let worldRow = start + outY * requestedRows / outputHeight
                while segmentIndex < ordered.count,
                      ordered[segmentIndex].worldStart + ordered[segmentIndex].rows <= worldRow {
                    segmentIndex += 1
                }
                guard segmentIndex < ordered.count else { break }
                let segment = ordered[segmentIndex]
                guard worldRow >= segment.worldStart,
                      worldRow < segment.worldStart + segment.rows else { continue }

                // 世界行 → 帧内行。
                let frameRow = segment.sourceY - segment.imageRowOffset + (worldRow - segment.worldStart)
                guard frameRow >= 0, frameRow < segment.frame.image.height else { continue }

                let sourceOffset = frameRow * sourceBytesPerRow
                let targetOffset = outY * outputBytesPerRow
                segment.frame.image.withPixels { source in
                    guard let src = source.baseAddress else { return }
                    for outX in 0..<outputWidth {
                        let s = sourceOffset + columnMap[outX] * 4
                        guard s + 3 < source.count else { continue }
                        let d = targetOffset + outX * 4
                        outBase[d] = src[s]
                        outBase[d + 1] = src[s + 1]
                        outBase[d + 2] = src[s + 2]
                        // 与最终导出使用同一像素，保留窗口圆角等位置的透明度。
                        outBase[d + 3] = src[s + 3]
                    }
                }
            }
        }

        return ScrollshotImage(width: outputWidth, height: outputHeight, data: buffer)
    }

    // MARK: - 吸顶行检测

    /// 拼接时要跳过的**不可用**行数：显式指定优先，否则用自动检测的结果，
    /// 但**任何情况下都不低于 `unusableTopRows`**（屏幕固定元素的保守下限）。
    ///
    /// ── 为什么要和下限取 max（「字只有一半」的真实成因）────────
    ///
    /// 视口顶部常有一条固定在屏幕上的元素（窗口边框、分隔带、纯色工具栏）。
    /// 它不随内容滚动，却是**纯色**：行内对比度为 0，与「页面留白」在单帧里
    /// 完全同形。`detectStickyRows` 的判据要求「同位置相同、且滚动位置明显不同」，
    /// 而这类元素对应的内容区在某些位置也是背景，两项都趋零 —— 实测 13 组
    /// 相邻帧投票只有 1~6 票（过半需 ≥7），**检测天然测不出来**。
    ///
    /// 测不出来的后果不是「少跳几行空白」，而是**每帧把固定带当作内容贴进世界
    /// 坐标，并把该位置的真实内容永久丢弃**：向上扩展时取的是帧顶部的新行，
    /// 固定带正好在那里，于是每处接缝丢同样多行，接缝落在文字行上就是
    /// 「字只有一半」。
    ///
    /// 所以下限必须由调用方给（`unusableTopRows`）：它是结构性的，不依赖像素。
    /// 而自动检测仍然留着——它能识别**有内容的**固定顶栏（那是它擅长的事），
    /// 两者取 max 互不干扰：检测不到时下限兜底，检测误报时下限也把抖动吸收掉。
    private var effectiveStickyRows: Int {
        let declared = options.stickyHeaderRows > 0 ? options.stickyHeaderRows : detectedStickyRows
        return max(declared, options.unusableTopRows)
    }

    /// 向下扩展时可用的最后一行在帧内的位置（帧底部固定元素之下不可用）。
    private var usableFrameBottom: Int {
        let bottom = max(0, options.unusableBottomRows)
        guard let first = firstImage else { return bottom }
        return min(bottom, max(0, first.height - 1))
    }

    /// 用「相邻两帧之间位置不变」这一特征，自动猜出帧顶部的固定行数（吸顶栏/工具栏）。
    ///
    /// ── 为什么需要它 ──────────────────────────────────────
    ///
    /// 拼接时要跳过每帧开头的固定行，否则**向上扩展**会把导航栏逐段粘一遍——
    /// 实测输出里顶栏重复 4 次。向下扩展没有这个问题（那时取的是帧**底部**的新行，
    /// 吸顶栏天然只出现一次），所以这个缺陷只在支持上行滚动之后才出现。
    ///
    /// ── 判据：同位置 vs 滚动位置 ──────────────────────────
    ///
    /// 只看「两帧同位置是否相同」会被骗：位移恰为行距整数倍时，**周期内容**
    /// 会成片地看起来没变。所以这里做的是对照比较：
    ///
    /// ```
    /// 把内容更靠下的那帧记为 base，它在 moved 里应出现在 y + |delta|
    /// 固定行： base[y] ≈ moved[y]     且  base[y] ≠ moved[y + |delta|]
    /// 滚动内容：base[y] ≈ moved[y+|delta|]     （不满足上面）
    /// 周期内容：base[y] ≈ moved[y] ≈ moved[y+|delta|]（也不满足）
    /// ```
    ///
    /// 即「**同位置比滚动位置更相似**」。它不需要绝对阈值，也能自动排除周期性
    /// 带来的伪相似。再叠一层投票（不同帧的位移不同，只有真固定的行能持续过半）。
    private mutating func detectStickyRows(
        previous: ScrollshotImage,
        next: ScrollshotImage,
        delta: Int
    ) {
        // 调用方已显式指定行数，不必猜。
        guard options.stickyHeaderRows == 0 else { return }
        // 没有滚动时无法判断「什么是不动的」。
        guard abs(delta) > options.duplicateDeltaThreshold else { return }
        guard next.width == previous.width, next.height == previous.height else { return }

        let scanRows = min(next.height / 3, Self.stickyScanMaxRows)
        let shift = abs(delta)
        let height = next.height
        guard scanRows > 0, shift < height else { return }

        // `base` 是内容更靠下的那帧：`base[y]` 在 `moved` 里会出现在 `y + shift`。
        let base = delta >= 0 ? previous : next
        let moved = delta >= 0 ? next : previous

        if stickyVotes.count < scanRows {
            stickyVotes.append(contentsOf: [Int](repeating: 0, count: scanRows - stickyVotes.count))
        }
        stickyObservations += 1

        let width = next.width
        let columns = Self.stickySampleColumns
        var unchanged = [Bool](repeating: false, count: scanRows)
        base.withPixels { b in
            moved.withPixels { m in
                for y in 0..<scanRows {
                    // 需要 `y + shift` 有效才能做对照。
                    guard y + shift < height else { continue }
                    var sameSum = 0
                    var shiftedSum = 0
                    // 行内亮度极值：用来判断这一行**有没有内容**（空白行的采样点几乎同值）。
                    var rowMin = 255
                    var rowMax = 0
                    for index in 0..<columns {
                        let x = min(width - 1, index * width / columns)
                        let baseOffset = (y * width + x) * 4
                        let sameOffset = (y * width + x) * 4
                        let shiftedOffset = ((y + shift) * width + x) * 4
                        let luminance = Int(b[baseOffset])
                        rowMin = min(rowMin, luminance)
                        rowMax = max(rowMax, luminance)
                        sameSum += abs(Int(b[baseOffset]) - Int(m[sameOffset]))
                            + abs(Int(b[baseOffset + 1]) - Int(m[sameOffset + 1]))
                            + abs(Int(b[baseOffset + 2]) - Int(m[sameOffset + 2]))
                        shiftedSum += abs(Int(b[baseOffset]) - Int(m[shiftedOffset]))
                            + abs(Int(b[baseOffset + 1]) - Int(m[shiftedOffset + 1]))
                            + abs(Int(b[baseOffset + 2]) - Int(m[shiftedOffset + 2]))
                    }
                    let sameAverage = Double(sameSum) / Double(columns) / 3
                    let shiftedAverage = Double(shiftedSum) / Double(columns) / 3
                    // 四个条件缺一不可：
                    //  1) 这一行**自己有内容**（空白行的「相同」不是「固定」，是「没东西」）；
                    //  2) 同位置足够像；
                    //  3) 滚动位置确实不一样（没有对比就没有判断依据）；
                    //  4) 同位置确实比滚动位置更像。
                    // 详见 stickyRowContent / stickyRowContrast 的说明。
                    unchanged[y] = Double(rowMax - rowMin) >= Self.stickyRowContent
                        && sameAverage <= Self.stickyRowTolerance
                        && shiftedAverage >= Self.stickyRowContrast
                        && sameAverage < shiftedAverage
                }
            }
        }
        for y in 0..<scanRows where unchanged[y] {
            stickyVotes[y] += 1
        }

        // 只采信「从头连续、且过半检测都判为不变」的行数。
        // 观测不足时保持 0——宁可头几帧多粘一遍顶栏，也不要凭一两帧就跳行。
        guard stickyObservations >= Self.stickyMinObservations else {
            detectedStickyRows = 0
            return
        }
        var count = 0
        while count < scanRows, stickyVotes[count] * 2 > stickyObservations {
            count += 1
        }
        detectedStickyRows = count
    }

    // MARK: - 内部

    /// 仅替换接缝外的像素段；已确定的世界坐标保持不变，预览和导出共用同一组段。
    private mutating func retainSegments(in range: Range<Int>) {
        segments = segments.compactMap { segment in
            let start = max(segment.worldStart, range.lowerBound)
            let end = min(segment.worldStart + segment.rows, range.upperBound)
            guard start < end else { return nil }
            if start == segment.worldStart, end == segment.worldStart + segment.rows { return segment }
            return makeSegment(
                frame: segment.frame, inputIndex: segment.inputIndex,
                sourceY: segment.sourceY + start - segment.worldStart,
                rows: end - start, worldStart: start, imageRowOffset: segment.imageRowOffset
            )
        }
    }

    private func makeSegment(
        frame: ScrollshotFrame, inputIndex: Int, sourceY: Int, rows: Int,
        worldStart: Int, imageRowOffset: Int = 0
    ) -> Segment {
        if !options.retainsSourceFrames, (rows != frame.image.height || sourceY != imageRowOffset),
           let cropped = ScrollshotViewport(
               x: 0, y: sourceY - imageRowOffset, width: frame.image.width, height: rows
           ).crop(frame.image) {
            return Segment(
                frame: ScrollshotFrame(image: cropped, worldOffset: frame.worldOffset,
                                      deltaY: frame.deltaY, confidence: frame.confidence),
                inputIndex: inputIndex, sourceY: sourceY, rows: rows,
                worldStart: worldStart, imageRowOffset: sourceY
            )
        }
        return Segment(frame: frame, inputIndex: inputIndex, sourceY: sourceY, rows: rows,
                       worldStart: worldStart, imageRowOffset: imageRowOffset)
    }

    private mutating func acceptFirstFrame(_ image: ScrollshotImage, index: Int) -> Decision {
        firstImage = image
        lastObserved = image
        observedOffset = 0

        // 首帧**整帧**采纳，包括底部固定带（`unusableBottomRows`）。
        //
        // 这里的取舍是**有意的**，不是遗漏：
        // * 首帧就是用户在选区里真实看到的那一屏，所见即所得——把窗口底边
        //   也贴进去，长图顶端与实际屏幕一致；
        // * 后续帧才跳底部固定带（它们的作用是「新增内容」，不是复现屏幕）。
        //
        // `viewportBottomFixedBandIsNotPasted` 把这个契约钉住了：固定带
        // 应当恰好出现一次（首帧段末尾）。改这里会让那条测试变红，也会使
        // 首帧底部出现一块**空缺像素**（固定带被跳过、但后面没有帧能补）。
        coveredWorldEnd = image.height
        coveredWorldHeight = image.height

        let frame = ScrollshotFrame(image: image, worldOffset: 0, deltaY: 0, confidence: 1)
        acceptedFrameCount = 1
        acceptedFrames = options.retainsSourceFrames ? [frame] : []
        segments = [makeSegment(
            frame: frame, inputIndex: index, sourceY: 0, rows: image.height, worldStart: 0
        )]

        return record(Decision(
            inputIndex: index, deltaY: 0, confidence: 1, worldOffset: 0,
            verdict: .accepted, warnings: [], visionArbitrated: false,
            sourceY: 0, acceptedRows: image.height, stickyRows: 0
        ))
    }

    private mutating func record(_ decision: Decision) -> Decision {
        decisions.append(decision)
        return decision
    }

    /// 决策 → 计划帧（回填 `outputY` / `rows`）。
    ///
    /// 用 `inputIndex` 关联 segment，而不是靠「第几个 accepted」：
    /// 用户可能先往下拼、再往上扩展，采纳顺序与**输出顺序**不再一致，
    /// 靠序号会在向上扩展时把行号安到错的段上。
    private func makePlanFrames() -> [ScrollStitcher.FrameDecision] {
        let byIndex = Dictionary(
            segments.map { ($0.inputIndex, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return decisions.map { decision -> ScrollStitcher.FrameDecision in
            guard let segment = byIndex[decision.inputIndex] else {
                return ScrollStitcher.FrameDecision(
                    inputIndex: decision.inputIndex, deltaY: decision.deltaY,
                    confidence: decision.confidence, worldOffset: decision.worldOffset,
                    verdict: decision.verdict, outputY: nil, rows: 0,
                    warnings: decision.warnings
                )
            }
            return ScrollStitcher.FrameDecision(
                inputIndex: decision.inputIndex, deltaY: decision.deltaY,
                confidence: decision.confidence, worldOffset: decision.worldOffset,
                verdict: decision.verdict,
                outputY: segment.worldStart - coveredWorldStart,
                rows: segment.rows,
                warnings: decision.warnings
            )
        }
    }
}
