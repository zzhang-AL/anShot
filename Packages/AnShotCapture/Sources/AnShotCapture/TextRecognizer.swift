//
//  TextRecognizer.swift
//  AnShotCapture
//
//  文字识别：把图像交给 Vision，返回**模型坐标系**的结果。
//
//  ── 为什么封装在 Capture 而不是 Core ───────────────────────
//
//  `AnShotCore` 是不依赖平台框架的模型与算法层；Vision 属于平台能力，
//  与截屏、录屏同层。结果的模型与坐标转换都在 Core（`OCRText.swift`），
//  这里只负责「调一次 Vision 并按契约转换」。
//
//  ── 语言不硬编码 ──────────────────────────────────────────
//
//  各 macOS 版本支持的语言集不同（本机运行时查到 33 种，含 `zh-Hans`/`zh-Hant`，
//  但那是**本机的请求配置结果**，不代表其它机器）。因此语言在运行时查询后过滤：
//  优先中文简繁与英文，取不到就退回系统给出的全集。
//

import AnShotCore
import CoreGraphics
import CoreML
import CoreText
import Foundation
import os
import Vision

/// 文字识别。
public enum TextRecognizer {

    /// 识别不可用的原因。
    public enum Failure: Error, LocalizedError {
        /// 请求执行失败。
        case requestFailed(String)
        /// 结果转换失败（图像尺寸非法等）。
        case invalidImage

        public var errorDescription: String? {
            switch self {
            case let .requestFailed(reason): return "文字识别失败：\(reason)"
            case .invalidImage: return "图像尺寸非法"
            }
        }
    }

    /// 本机识别能力（运行时查询）。
    public struct Availability: Sendable {
        /// 当前识别级别支持的语言标识。
        public let supportedLanguages: [String]
        /// 实际请求会使用的语言（按优先级从支持列表里挑出来的）。
        public let preferredLanguages: [String]

        /// 是否支持中文（简或繁）。
        public var supportsChinese: Bool {
            supportedLanguages.contains { $0.hasPrefix("zh") }
        }
    }

    /// 我们希望优先使用的固定多语列表（显式关闭 `automaticallyDetectsLanguage` 以避免首次编译耗时暴涨）。
    private static let preferredLanguageIdentifiers = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]

    /// 缓存的识别能力查询结果。
    ///
    /// `supportedRecognitionLanguages` 首次要 6.7ms、之后 0.1ms，单看并不慢；
    /// 但它**每次 `recognize` 都会被问一遍**，而调用方在 MainActor 上——
    /// 也就是说这几毫秒以及任何版本相关的抖动，都是结结实实卡在主线程上的。
    /// 语言集在运行期不会变，所以缓存的代价是零。
    /// （`static let` 自带一次性、线程安全的懒惰初始化。）
    private static let cachedAvailability: Availability = {
        // 用实例方法而不是已弃用的类方法。
        //
        // `VNRecognizeTextRequest.supportedRecognitionLanguages(for:revision:)`
        // 自 macOS 12 起被弃用；SDK 头文件中的 `API_DEPRECATED_WITH_REPLACEMENT`
        // 指向 `-supportedRecognitionLanguagesAndReturnError:`（Swift 侧即实例方法
        // `supportedRecognitionLanguages()`，**同步 throws**，非 async）。
        //
        // 与旧调用的等价条件：新 API 读的是 **request 自身的配置**
        //（“based on its current state of configuration”），
        // 所以必须先把 recognitionLevel 与 revision 设成与旧调用相同的值。
        // 实测等价：本机两者均返回 33 项，顺序与内容完全一致，均含 zh。
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = VNRecognizeTextRequestRevision3
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let preferred = preferredLanguageIdentifiers.filter { supported.contains($0) }
        return Availability(
            supportedLanguages: supported,
            preferredLanguages: preferred.isEmpty ? supported : preferred
        )
    }()

    /// 查询本机识别能力。UI 用它决定是否显示中文相关提示、以及语言数量。
    public static func availability() -> Availability {
        cachedAvailability
    }

    private struct PrewarmState {
        var inFlightTask: Task<Void, Never>?
        var completed = false
    }

    private static let prewarmLock = OSAllocatedUnfairLock<PrewarmState>(initialState: PrewarmState())

    /// 预热：把 Vision 的一次性加载成本从「用户第一次点识别」挪到后台（单飞去重）。
    ///
    /// 并发或重复调用时复用同一个预热任务，避免重复启动十余秒的模型加载。
    public static func prewarm() async {
        enum Action {
            case alreadyDone
            case join(Task<Void, Never>)
        }

        let action = prewarmLock.withLock { state -> Action in
            if state.completed {
                return .alreadyDone
            }
            if let existing = state.inFlightTask {
                return .join(existing)
            }
            let task = Task(priority: .utility) {
                if let image = sampleImage() {
                    _ = try? await recognize(in: image)
                }
                prewarmLock.withLock { current in
                    current.completed = true
                    current.inFlightTask = nil
                }
            }
            state.inFlightTask = task
            return .join(task)
        }

        switch action {
        case .alreadyDone:
            return
        case .join(let task):
            await task.value
        }
    }

    /// 一张带中英混合文字的小图（白底 + `"预热 Prewarm"`）。
    ///
    /// 两个用途，共同点是「需要一张确定的、确实有中英文文字的图」：
    /// - `prewarm()` 同时预热中英文识别模型管线；
    /// - 设置界面的「测试连接」按钮拿它做一次真实识别。
    public static func sampleImage() -> CGImage? {
        let width = 280
        let height = 60
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("PingFang SC" as CFString, 24, nil)
        let attributed = NSAttributedString(
            string: "预热 Prewarm",
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
        )
        context.textPosition = CGPoint(x: 12, y: 18)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        return context.makeImage()
    }

    /// 识别图中的文字。
    ///
    /// - Parameters:
    ///   - image: 待识别的图像（像素尺寸即结果包围盒的参照系）。
    ///   - languages: 指定语言；nil 表示用 `availability()` 挑出的偏好集。
    /// - Returns: 按分栏阅读序与代码块缩进整理后的结果，包围盒为**模型坐标系（像素、原点左上）**。
    public static func recognize(
        in image: CGImage,
        languages: [String]? = nil
    ) async throws -> OCRResult {
        let pixelSize = PixelSize(width: Double(image.width), height: Double(image.height))
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            throw Failure.invalidImage
        }
        let chosen = languages ?? availability().preferredLanguages

        // Vision 的请求执行是同步阻塞的，放到后台执行，避免卡住主线程
        //（整屏识别是几百毫秒量级）。
        return try await Task.detached(priority: .userInitiated) {
            let observations = try Self.performWithComputeFallback(on: image, languages: chosen)
            let rawLines: [OCRTextLine] = observations.compactMap { observation in
                let candidates = observation.topCandidates(3)
                guard let best = candidates.first else { return nil }
                return OCRTextLine(
                    text: best.string,
                    candidates: candidates.map(\.string),
                    confidence: Double(best.confidence),
                    // 坐标转换只在模型边界做一次（契约 §4.2）。
                    boundingBox: OCRCoordinateConversion.pixelRect(
                        normalized: observation.boundingBox,
                        imagePixelSize: pixelSize
                    )
                )
            }
            return OCRResult(
                lines: layoutLines(rawLines, imagePixelSize: pixelSize),
                imagePixelSize: pixelSize
            )
        }.value
    }

    /// 构造标准化的 Vision 文字识别请求（供真实识别与预热共用同一份配置）。
    static func makeRequest(
        languages: [String],
        level: VNRequestTextRecognitionLevel = .accurate,
        forceCPU: Bool = false
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.revision = VNRecognizeTextRequestRevision3
        request.usesLanguageCorrection = (level == .accurate)
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }
        // 显式关闭自动语言检测：避免新版本首次运行时为所有候选语言编译模型导致 ~52s 冷启动。
        request.automaticallyDetectsLanguage = false

        if forceCPU {
            if #available(macOS 14.0, *) {
                if let cpuDevice = MLComputeDevice.allComputeDevices.first(where: {
                    if case .cpu = $0 { return true }
                    return false
                }) {
                    request.setComputeDevice(cpuDevice, for: .main)
                } else {
                    request.usesCPUOnly = true
                }
            } else {
                request.usesCPUOnly = true
            }
        }
        return request
    }

    /// 三级计算设备兜底执行管线：默认硬件加速(.accurate) → CPU(.accurate) → CPU(.fast)。
    ///
    /// 兼容无 ANE、独立 AMD 显卡驱动异常及 Rosetta 2 缺少高精度 Espresso 切片的环境。
    private static func performWithComputeFallback(
        on image: CGImage,
        languages: [String]
    ) throws -> [VNRecognizedTextObservation] {
        let tiers: [(level: VNRequestTextRecognitionLevel, forceCPU: Bool)] = [
            (.accurate, false),
            (.accurate, true),
            (.fast, true),
        ]
        var lastError: Error?
        for tier in tiers {
            let request = makeRequest(
                languages: languages,
                level: tier.level,
                forceCPU: tier.forceCPU
            )
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                return request.results ?? []
            } catch {
                lastError = error
            }
        }
        throw Failure.requestFailed(String(describing: lastError ?? Failure.invalidImage))
    }

    // MARK: - 版面与缩进还原

    /// 基于几何包围盒还原多栏阅读序与代码块左缩进。
    public static func layoutLines(
        _ lines: [OCRTextLine],
        imagePixelSize: PixelSize
    ) -> [OCRTextLine] {
        guard lines.count > 1 else { return lines }

        // 先检测是否存在显著垂直分栏缝隙，将页面切分为左右独立栏再分别按序整理。
        if let splitX = detectColumnSplitX(in: lines, imageWidth: imagePixelSize.width) {
            let left = lines.filter { $0.boundingBox.origin.x + $0.boundingBox.size.width * 0.5 < splitX }
            let right = lines.filter { $0.boundingBox.origin.x + $0.boundingBox.size.width * 0.5 >= splitX }
            if left.count >= 2 && right.count >= 2 {
                return layoutSingleColumn(left) + layoutSingleColumn(right)
            }
        }
        return layoutSingleColumn(lines)
    }

    /// 探测显著的双栏垂直分界线：要求左右两栏各自有多行且纵向跨度交错，中间存在空白隔离带。
    private static func detectColumnSplitX(
        in lines: [OCRTextLine],
        imageWidth: Double
    ) -> Double? {
        guard lines.count >= 4, imageWidth > 0 else { return nil }
        let averageHeight = lines.map(\.boundingBox.size.height).reduce(0, +) / Double(lines.count)
        let minGap = max(averageHeight * 1.8, imageWidth * 0.05)

        let narrowLines = lines.filter { $0.boundingBox.size.width < imageWidth * 0.65 }
        guard narrowLines.count >= 4 else { return nil }

        let sortedByX = narrowLines.sorted { $0.boundingBox.origin.x < $1.boundingBox.origin.x }
        var runningMaxX = sortedByX[0].boundingBox.origin.x + sortedByX[0].boundingBox.size.width
        var bestSplit: (x: Double, gap: Double)?

        for line in sortedByX.dropFirst() {
            let minX = line.boundingBox.origin.x
            let gap = minX - runningMaxX
            if gap >= minGap {
                let candidateX = runningMaxX + gap * 0.5
                if bestSplit == nil || gap > bestSplit!.gap {
                    bestSplit = (candidateX, gap)
                }
            }
            runningMaxX = max(runningMaxX, minX + line.boundingBox.size.width)
        }

        guard let split = bestSplit else { return nil }
        let left = lines.filter { $0.boundingBox.origin.x + $0.boundingBox.size.width * 0.5 < split.x }
        let right = lines.filter { $0.boundingBox.origin.x + $0.boundingBox.size.width * 0.5 >= split.x }
        guard left.count >= 2, right.count >= 2 else { return nil }

        // 校验左右两栏在垂直 Y 方向确实交错重叠（否则只是上下两段不同偏移）。
        let leftMinY = left.map(\.boundingBox.origin.y).min() ?? 0
        let leftMaxY = left.map { $0.boundingBox.origin.y + $0.boundingBox.size.height }.max() ?? 0
        let rightMinY = right.map(\.boundingBox.origin.y).min() ?? 0
        let rightMaxY = right.map { $0.boundingBox.origin.y + $0.boundingBox.size.height }.max() ?? 0
        let verticalOverlap = min(leftMaxY, rightMaxY) - max(leftMinY, rightMinY)
        guard verticalOverlap > averageHeight else { return nil }

        return split.x
    }

    /// 单栏内按行带聚类排序，并基于左基准线还原代码块前导缩进空格。
    private static func layoutSingleColumn(_ lines: [OCRTextLine]) -> [OCRTextLine] {
        let ordered = deterministicReadingOrder(lines)
        return restoringIndentation(in: ordered)
    }

    /// 确定性两阶段行带聚类排序（严格弱序安全，避免循环比较）。
    private static func deterministicReadingOrder(_ lines: [OCRTextLine]) -> [OCRTextLine] {
        guard lines.count > 1 else { return lines }
        let sortedByMidY = lines.sorted { lhs, rhs in
            let lMid = lhs.boundingBox.origin.y + lhs.boundingBox.size.height * 0.5
            let rMid = rhs.boundingBox.origin.y + rhs.boundingBox.size.height * 0.5
            if lMid != rMid { return lMid < rMid }
            return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
        }

        var bands: [[OCRTextLine]] = []
        var bandTops: [Double] = []
        var bandBottoms: [Double] = []

        for line in sortedByMidY {
            let top = line.boundingBox.origin.y
            let bottom = top + line.boundingBox.size.height
            if let lastIndex = bands.indices.last {
                let overlap = min(bandBottoms[lastIndex], bottom) - max(bandTops[lastIndex], top)
                let minHeight = min(bandBottoms[lastIndex] - bandTops[lastIndex], line.boundingBox.size.height)
                if overlap > minHeight * 0.5 {
                    bands[lastIndex].append(line)
                    bandTops[lastIndex] = min(bandTops[lastIndex], top)
                    bandBottoms[lastIndex] = max(bandBottoms[lastIndex], bottom)
                    continue
                }
            }
            bands.append([line])
            bandTops.append(top)
            bandBottoms.append(bottom)
        }

        return bands.flatMap { band in
            band.sorted { $0.boundingBox.origin.x < $1.boundingBox.origin.x }
        }
    }

    /// 当存在明确左对齐基线与多级缩进时，基于 `boundingBox.origin.x` 还原行首缩进空格。
    private static func restoringIndentation(in lines: [OCRTextLine]) -> [OCRTextLine] {
        guard lines.count >= 2 else { return lines }

        let charWidths: [Double] = lines.compactMap { line in
            let count = line.text.count
            guard count >= 3, line.boundingBox.size.width > 0 else { return nil }
            return line.boundingBox.size.width / Double(count)
        }.sorted()

        guard !charWidths.isEmpty else { return lines }
        let medianCharWidth = charWidths[charWidths.count / 2]
        guard medianCharWidth > 1 else { return lines }

        let baseX = lines.map(\.boundingBox.origin.x).min() ?? 0
        let baselineCount = lines.filter {
            ($0.boundingBox.origin.x - baseX) <= medianCharWidth * 0.8
        }.count
        let indentedCount = lines.filter {
            ($0.boundingBox.origin.x - baseX) >= medianCharWidth * 1.5
        }.count

        // 仅当存在明确左基线（>=2 行贴左边界）且有显著缩进行时才还原，避免误改居中标题。
        guard baselineCount >= 2, indentedCount >= 1 else {
            return lines
        }

        // 同行多框时只对每条物理行最左侧首个片段补齐缩进。
        var result: [OCRTextLine] = []
        var previousRow: OCRTextLine?
        for line in lines {
            let isSameRowAsPrevious: Bool
            if let prev = previousRow {
                let overlap = min(
                    prev.boundingBox.origin.y + prev.boundingBox.size.height,
                    line.boundingBox.origin.y + line.boundingBox.size.height
                ) - max(prev.boundingBox.origin.y, line.boundingBox.origin.y)
                let minH = min(prev.boundingBox.size.height, line.boundingBox.size.height)
                isSameRowAsPrevious = overlap > minH * 0.5
            } else {
                isSameRowAsPrevious = false
            }

            if !isSameRowAsPrevious {
                let deltaX = line.boundingBox.origin.x - baseX
                let leadingSpaces = deltaX >= medianCharWidth * 1.5
                    ? min(24, max(1, Int((deltaX / medianCharWidth).rounded())))
                    : 0
                if leadingSpaces > 0, !line.text.hasPrefix(" ") {
                    let prefix = String(repeating: " ", count: leadingSpaces)
                    let adjusted = OCRTextLine(
                        text: prefix + line.text,
                        candidates: line.candidates.map { prefix + $0 },
                        confidence: line.confidence,
                        boundingBox: line.boundingBox
                    )
                    result.append(adjusted)
                    previousRow = line
                    continue
                }
            }
            result.append(line)
            previousRow = line
        }
        return result
    }
}
