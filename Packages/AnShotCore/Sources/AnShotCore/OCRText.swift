//
//  OCRText.swift
//  AnShotCore
//
//  OCR 结果模型与坐标转换。
//
//  ── 契约点名的最高易错点 ──────────────────────────────────
//
//  Vision 的 `boundingBox` 是**归一化坐标（0–1）、原点左下**；
//  本项目模型统一是**像素坐标、原点左上**。两者在**两个维度上都不同**：
//  既要乘尺寸，又要翻 y。只做其中一步，文字框就会整体上下错位。
//
//  转换**只在这里发生一次**：模块之外只见到像素坐标（契约 §4.2）。
//  识别侧的代码不允许自己算包围盒。
//

import CoreGraphics
import Foundation

/// 识别出的一行文字。
public struct OCRTextLine: Equatable, Sendable {

    /// 首选识别文本。
    public let text: String

    /// 备选识别结果（用于用户纠正）。
    public let candidates: [String]

    /// 置信度 `0...1`。
    public let confidence: Double

    /// 包围盒：**像素坐标、原点左上**（模型坐标系，非 Vision 坐标系）。
    public let boundingBox: PixelRect

    public init(text: String, candidates: [String], confidence: Double, boundingBox: PixelRect) {
        self.text = text
        self.candidates = candidates
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// OCR 语言识别偏好。
///
/// `.auto` 展开为固定优先级多语数组，并配合关闭 `automaticallyDetectsLanguage`
/// 避免 Vision 首次编译全部候选语言模型造成的超长冷启动。
public enum OCRLanguagePreference: String, CaseIterable, Codable, Sendable {
    case auto = "auto"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case enUS = "en-US"
    case jaJP = "ja-JP"
    case koKR = "ko-KR"

    public var displayName: String {
        switch self {
        case .auto: return "自动（中英日韩）"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁体中文"
        case .enUS: return "英文"
        case .jaJP: return "日文"
        case .koKR: return "韩文"
        }
    }

    /// 展开为 Vision `recognitionLanguages` 数组。
    public var recognitionLanguages: [String] {
        switch self {
        case .auto:
            return ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
        case .zhHans:
            return ["zh-Hans", "en-US"]
        case .zhHant:
            return ["zh-Hant", "en-US"]
        case .enUS:
            return ["en-US"]
        case .jaJP:
            return ["ja-JP", "en-US"]
        case .koKR:
            return ["ko-KR", "en-US"]
        }
    }
}

/// 识别出的二维码或条形码载荷。
public struct BarcodeItem: Codable, Equatable, Sendable {
    /// 解码出的文本载荷。
    public let payload: String
    /// 码制标识（如 `"QR"`、`"EAN13"`、`"Code128"`）。
    public let symbology: String
    /// 是否为可直接浏览器打开的 HTTP / HTTPS 链接。
    public let isWebURL: Bool

    public init(payload: String, symbology: String, isWebURL: Bool? = nil) {
        self.payload = payload
        self.symbology = symbology
        if let isWebURL {
            self.isWebURL = isWebURL
        } else {
            self.isWebURL = Self.parseWebURL(from: payload) != nil
        }
    }

    /// 若载荷为安全可打开的 HTTP / HTTPS 链接，返回解析后的 `URL`。
    public var webURL: URL? {
        Self.parseWebURL(from: payload)
    }

    public static func parseWebURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }
}

/// 一次 OCR 的结果。
public struct OCRResult: Equatable, Sendable {

    /// 按阅读顺序（上→下，左→右）排序的文本行。
    public let lines: [OCRTextLine]

    /// 识别时的图像像素尺寸——**包围盒的参照系**，必须随结果一同保存。
    public let imagePixelSize: PixelSize

    /// 这份包围盒有多可信。
    ///
    /// 默认 `.precise`，因此既有调用点（全部基于 Apple Vision）行为不变；
    /// 云端 provider 显式传 `.unavailable`，此时每行的 `boundingBox` 恒为零矩形。
    /// 消费方**必须**先看这个字段再决定能不能把坐标用于对齐
    /// （理由见 `OCRProvider.swift` 的文件头）。
    public let coordinateCapability: OCRCoordinateCapability

    /// 同步识别到的二维码与条形码列表（默认为空，不破坏既有构造调用）。
    public let barcodes: [BarcodeItem]

    public init(
        lines: [OCRTextLine],
        imagePixelSize: PixelSize,
        coordinateCapability: OCRCoordinateCapability = .precise,
        barcodes: [BarcodeItem] = []
    ) {
        self.lines = lines
        self.imagePixelSize = imagePixelSize
        self.coordinateCapability = coordinateCapability
        self.barcodes = barcodes
    }

    /// 纯文本（按行拼接），供复制/导出。
    public var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// 合并段落软换行后的文本（保留空行分段、列表项及英文连字符断词拼接）。
    public var paragraphText: String {
        OCRParagraphMerger.merge(lines: lines)
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// 是否包含任何可展示内容（文字或二维码/条码）。
    public var hasContent: Bool { !lines.isEmpty || !barcodes.isEmpty }

    /// 按阅读顺序排序：先上后下（`midY` 小的在前），同一行内先左后右。
    ///
    /// Vision 返回的顺序不保证是阅读顺序；不排的话复制出来的文字会是乱的。
    /// 同一行的判定用两阶段锚定行带聚类，避免两两比较器在多栏阶梯框上
    /// 违反严格弱序传递性造成随机错序。
    public static func readingOrder(_ lines: [OCRTextLine]) -> [OCRTextLine] {
        guard lines.count > 1 else { return lines }

        // 第一阶段：按文本框纵向中心升序排列，次关键字为水平起点，确保比较关系严格弱序。
        let sortedByVerticalCenter = lines.sorted { lhs, rhs in
            let lhsMidY = lhs.boundingBox.origin.y + lhs.boundingBox.size.height * 0.5
            let rhsMidY = rhs.boundingBox.origin.y + rhs.boundingBox.size.height * 0.5
            if lhsMidY != rhsMidY {
                return lhsMidY < rhsMidY
            }
            if lhs.boundingBox.origin.x != rhs.boundingBox.origin.x {
                return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
            }
            return lhs.boundingBox.origin.y < rhs.boundingBox.origin.y
        }

        // 第二阶段：线性扫描聚类为锚定行带，避免后续成员拉偏锚点产生传递漂移。
        struct RowBand {
            let anchor: PixelRect
            var items: [OCRTextLine]
        }

        var bands: [RowBand] = []
        bands.reserveCapacity(sortedByVerticalCenter.count)
        for line in sortedByVerticalCenter {
            if let lastIndex = bands.indices.last,
               overlapsVertically(bands[lastIndex].anchor, line.boundingBox) {
                bands[lastIndex].items.append(line)
            } else {
                bands.append(RowBand(anchor: line.boundingBox, items: [line]))
            }
        }

        // 行带间按顺序输出，行带内严格按水平起点升序排列。
        var ordered: [OCRTextLine] = []
        ordered.reserveCapacity(lines.count)
        for band in bands {
            if band.items.count == 1 {
                ordered.append(band.items[0])
            } else {
                ordered.append(contentsOf: band.items.sorted { lhs, rhs in
                    if lhs.boundingBox.origin.x != rhs.boundingBox.origin.x {
                        return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
                    }
                    return lhs.boundingBox.origin.y < rhs.boundingBox.origin.y
                })
            }
        }
        return ordered
    }

    /// 两个包围盒在纵向是否属于同一行。
    private static func overlapsVertically(_ a: PixelRect, _ b: PixelRect) -> Bool {
        let aTop = a.origin.y
        let aBottom = a.origin.y + a.size.height
        let bTop = b.origin.y
        let bBottom = b.origin.y + b.size.height
        let overlap = min(aBottom, bBottom) - max(aTop, bTop)
        return overlap > min(a.size.height, b.size.height) * 0.5
    }
}

/// Vision 坐标 → 模型坐标。
public enum OCRCoordinateConversion {

    /// 把 Vision 的归一化包围盒（**原点左下**）转成模型像素矩形（**原点左上**）。
    ///
    /// ```
    /// pixelX   = normX × imageWidth
    /// pixelW   = normW × imageWidth
    /// pixelH   = normH × imageHeight
    /// pixelTop = (1 − normY − normH) × imageHeight     ← 翻转在这一项里
    /// ```
    ///
    /// - Parameters:
    ///   - normalized: Vision 给出的归一化包围盒（原点左下）。
    ///   - imagePixelSize: 识别时的图像像素尺寸。
    public static func pixelRect(normalized: CGRect, imagePixelSize: PixelSize) -> PixelRect {
        let width = imagePixelSize.width
        let height = imagePixelSize.height
        // Vision 用 CGFloat，模型用 Double，这里显式转换一次。
        let x = Double(normalized.origin.x) * width
        // 归一化 y 是**底边**到图像底部的距离；左上原点下要算的是顶边的位置。
        let top = (1 - Double(normalized.origin.y) - Double(normalized.size.height)) * height
        return PixelRect(
            origin: PixelPoint(x: x, y: top),
            size: PixelSize(
                width: Double(normalized.size.width) * width,
                height: Double(normalized.size.height) * height
            )
        )
    }
}

// MARK: - 段落软换行合并

/// 无损段落软换行合并器。
///
/// 针对截图 OCR 常见的「一段话被硬拆成多行」痛点：
/// - 保留空行分段与明确列表项（`-` / `*` / `•` / `1.` / `(1)`）；
/// - 自动拼接英文行尾断词连字符（`implement-\nation` → `implementation`）；
/// - CJK 汉字/日文假名/韩文相邻拼接不插入多余空格，拉丁词与数字间补单个空格。
public enum OCRParagraphMerger {

    /// 从结构化 OCR 行合并段落（结合行间距判断是否应另起段落）。
    public static func merge(lines: [OCRTextLine]) -> String {
        guard !lines.isEmpty else { return "" }
        let validHeights = lines.map(\.boundingBox.size.height).filter { $0 > 1 }.sorted()
        let medianHeight = validHeights.isEmpty ? 0 : validHeights[validHeights.count / 2]

        var paragraphs: [String] = []
        var current = ""
        var previousLine: OCRTextLine?

        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = ""
                }
                previousLine = nil
                continue
            }

            if current.isEmpty {
                current = trimmed
                previousLine = line
                continue
            }

            let startsNewParagraph = shouldBreakBefore(
                currentText: current,
                nextText: trimmed,
                previousLine: previousLine,
                nextLine: line,
                medianHeight: medianHeight
            )
            if startsNewParagraph {
                paragraphs.append(current)
                current = trimmed
            } else {
                current = joinSoftWrapped(current, trimmed)
            }
            previousLine = line
        }

        if !current.isEmpty {
            paragraphs.append(current)
        }
        return paragraphs.joined(separator: "\n")
    }

    /// 从纯文本字符串合并段落软换行（用于编辑框内随时无损切换）。
    public static func merge(plainText: String) -> String {
        let rawLines = plainText.components(separatedBy: .newlines)
        var paragraphs: [String] = []
        var current = ""

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = ""
                }
                if paragraphs.last != "" {
                    paragraphs.append("")
                }
                continue
            }
            if current.isEmpty {
                current = trimmed
            } else if isListItemPrefix(trimmed) || isHardParagraphEnding(current) {
                paragraphs.append(current)
                current = trimmed
            } else {
                current = joinSoftWrapped(current, trimmed)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }
        while paragraphs.last == "" {
            paragraphs.removeLast()
        }
        return paragraphs.joined(separator: "\n")
    }

    private static func shouldBreakBefore(
        currentText: String,
        nextText: String,
        previousLine: OCRTextLine?,
        nextLine: OCRTextLine,
        medianHeight: Double
    ) -> Bool {
        if isListItemPrefix(nextText) {
            return true
        }
        if let prev = previousLine, medianHeight > 1 {
            let prevBottom = prev.boundingBox.origin.y + prev.boundingBox.size.height
            let verticalGap = nextLine.boundingBox.origin.y - prevBottom
            // 明显大于正常行距的空隙视作新段落。
            if verticalGap > medianHeight * 0.95 {
                return true
            }
        }
        return isHardParagraphEnding(currentText) && nextText.first?.isUppercase == true && !isCJK(nextText.first)
    }

    /// 识别常见无序/有序列表项与任务项前缀。
    static func isListItemPrefix(_ line: String) -> Bool {
        let bulletPrefixes = ["- ", "* ", "• ", "· ", "– ", "— ", "[ ] ", "[x] ", "[X] "]
        if bulletPrefixes.contains(where: { line.hasPrefix($0) }) {
            return true
        }
        // 有序列表：`1. `、`12) `、`1、`、`（1）`
        var index = line.startIndex
        var digitCount = 0
        while index < line.endIndex, line[index].isASCII, line[index].isNumber {
            digitCount += 1
            index = line.index(after: index)
        }
        if digitCount > 0, index < line.endIndex {
            let marker = line[index]
            if marker == "." || marker == ")" || marker == "、" {
                let afterMarker = line.index(after: index)
                if afterMarker == line.endIndex || line[afterMarker] == " " || marker == "、" {
                    return true
                }
            }
        }
        return false
    }

    private static func isHardParagraphEnding(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last == "。" || last == "！" || last == "？" || last == ":" || last == "："
    }

    /// 将两行软换行文本按语种习惯自然拼接。
    static func joinSoftWrapped(_ lhs: String, _ rhs: String) -> String {
        guard let last = lhs.last, let first = rhs.first else {
            return lhs + rhs
        }
        // 英文断词连字符：`develop-` + `ment` → `development`（排除 `foo -` 带空格的破折号）
        if last == "-",
           lhs.count >= 2,
           let beforeHyphen = lhs.dropLast().last,
           beforeHyphen.isASCII && beforeHyphen.isLetter,
           first.isASCII && first.isLetter && first.isLowercase {
            return String(lhs.dropLast()) + rhs
        }
        // 两侧任一侧为 CJK 字符（汉字/假名/韩文/全角标点）时直接拼接不加多余空格。
        if isCJK(last) || isCJK(first) {
            return lhs + rhs
        }
        return "\(lhs) \(rhs)"
    }

    private static func isCJK(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first?.value else { return false }
        return (0x4E00 ... 0x9FFF).contains(scalar)
            || (0x3400 ... 0x4DBF).contains(scalar)
            || (0x3000 ... 0x30FF).contains(scalar)
            || (0xAC00 ... 0xD7AF).contains(scalar)
            || (0xFF00 ... 0xFFEF).contains(scalar)
    }
}

// MARK: - 超长图分块 OCR 规划与空间去重

/// 超长图分块识别瓦片规划器与重叠区去重器。
public enum OCRTilePlanner {
    public struct TileRect: Equatable, Sendable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// 默认瓦片边长与重叠像素宽度（契约 `model.md` §3.2）。
    public static let defaultTileSize = 2048
    public static let defaultOverlap = 256

    /// 判断图像是否应启用分块 OCR（边长 > 4096px 或长宽比 > 4:1）。
    public static func shouldTile(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let longSide = max(width, height)
        let shortSide = max(1, min(width, height))
        return longSide > 4096 || (Double(longSide) / Double(shortSide) > 4.0 && longSide > defaultTileSize)
    }

    /// 将整图按固定瓦片尺寸与重叠区切分为覆盖全图的瓦片网格。
    public static func planTiles(
        width: Int,
        height: Int,
        tileSize: Int = defaultTileSize,
        overlap: Int = defaultOverlap
    ) -> [TileRect] {
        guard width > 0, height > 0, tileSize > 0 else { return [] }
        let safeOverlap = max(0, min(overlap, tileSize / 2))
        let step = max(1, tileSize - safeOverlap)

        func axisRanges(total: Int) -> [(start: Int, length: Int)] {
            if total <= tileSize {
                return [(0, total)]
            }
            var ranges: [(Int, Int)] = []
            var start = 0
            while start < total {
                let end = min(total, start + tileSize)
                let adjustedStart = (end == total && end - start < tileSize) ? max(0, total - tileSize) : start
                let entry = (adjustedStart, end - adjustedStart)
                if ranges.last?.0 != entry.0 || ranges.last?.1 != entry.1 {
                    ranges.append(entry)
                }
                if end >= total { break }
                start += step
            }
            return ranges
        }

        let xs = axisRanges(total: width)
        let ys = axisRanges(total: height)
        var tiles: [TileRect] = []
        tiles.reserveCapacity(xs.count * ys.count)
        for yRange in ys {
            for xRange in xs {
                tiles.append(TileRect(x: xRange.start, y: yRange.start, width: xRange.length, height: yRange.length))
            }
        }
        return tiles
    }

    /// 对来自多个重叠瓦片的全局坐标文本行执行空间去重。
    ///
    /// 当两行包围盒满足高 IoU（≥ 0.45）或纵向中心相近且水平强重叠且文本等价/包含时，
    /// 保留置信度更高或信息更完整的一条，消除接缝处重复文字。
    public static func deduplicateTiledLines(_ lines: [OCRTextLine]) -> [OCRTextLine] {
        guard lines.count > 1 else { return lines }
        var kept: [OCRTextLine] = []
        kept.reserveCapacity(lines.count)

        for candidate in lines {
            if let existingIndex = kept.firstIndex(where: { isSpatialDuplicate($0, candidate) }) {
                if isBetterCandidate(candidate, than: kept[existingIndex]) {
                    kept[existingIndex] = candidate
                }
            } else {
                kept.append(candidate)
            }
        }
        return kept
    }

    private static func isSpatialDuplicate(_ a: OCRTextLine, _ b: OCRTextLine) -> Bool {
        let ra = a.boundingBox
        let rb = b.boundingBox
        let interLeft = max(ra.origin.x, rb.origin.x)
        let interTop = max(ra.origin.y, rb.origin.y)
        let interRight = min(ra.origin.x + ra.size.width, rb.origin.x + rb.size.width)
        let interBottom = min(ra.origin.y + ra.size.height, rb.origin.y + rb.size.height)
        let interW = max(0, interRight - interLeft)
        let interH = max(0, interBottom - interTop)
        let interArea = interW * interH
        guard interArea > 0 else { return false }

        let areaA = max(1e-6, ra.size.width * ra.size.height)
        let areaB = max(1e-6, rb.size.width * rb.size.height)
        let iou = interArea / max(1e-6, areaA + areaB - interArea)
        if iou >= 0.45 {
            return true
        }

        let minH = max(1, min(ra.size.height, rb.size.height))
        let midYA = ra.origin.y + ra.size.height * 0.5
        let midYB = rb.origin.y + rb.size.height * 0.5
        guard abs(midYA - midYB) <= minH * 0.55 else { return false }

        let minW = max(1, min(ra.size.width, rb.size.width))
        guard interW / minW >= 0.55 else { return false }

        let normA = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normB = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normA == normB || normA.contains(normB) || normB.contains(normA) {
            return true
        }
        return false
    }

    private static func isBetterCandidate(_ candidate: OCRTextLine, than existing: OCRTextLine) -> Bool {
        let candLen = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        let existLen = existing.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        if candLen != existLen {
            return candLen > existLen
        }
        return candidate.confidence > existing.confidence
    }
}
