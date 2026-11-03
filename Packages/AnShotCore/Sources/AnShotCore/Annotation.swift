//
//  Annotation.swift
//  AnShotCore
//
//  五种标注的数据模型。
//
//  契约见 docs/m1-capture/model.md §4：
//  - JSON 为**扁平结构**，顶层含 id 与 type，其余字段依 type 而定；
//  - 不使用 Swift 自动合成的嵌套枚举编码（那样会产出 {"rectangle": {...}}，
//    与契约不符，且不利于跨语言与长期兼容）；
//  - 字体只存描述（family/size/weight/italic），绝不存字体对象；
//  - 所有几何数据均为底图像素坐标（原点左上，y 轴向下）。
//

import CoreGraphics
import Foundation

/// 描边样式，被多种标注复用（model.md §4.1）。
public struct StrokeStyle: Codable, Equatable, Sendable {
    /// 描边颜色。
    public var color: RGBAColor

    /// 描边宽度，像素单位，必须 > 0。
    public var width: Double

    /// 虚线段长序列，像素单位；`nil` 表示实线。
    public var dash: [Double]?

    /// 手绘风格（线框类标注的**样式开关**，不是一种新类型）。
    ///
    /// M3 新增：同一根线可以画得规整，也可以画得随手。M3-0 只落模型，
    /// 渲染扰动在 M3-4 实现——因此当前值不影响成图。
    public var isSketchy: Bool

    public init(color: RGBAColor, width: Double, dash: [Double]? = nil, isSketchy: Bool = false) {
        self.color = color
        self.width = width
        self.dash = dash
        self.isSketchy = isSketchy
    }

    /// 是否渲染为虚线。
    public var isDashed: Bool {
        guard let dash else {
            return false
        }
        return !dash.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case color
        case width
        case dash
        case isSketchy
    }

    /// 自定义解码：`isSketchy` 是 M3 新增字段，v1/v2 文件里没有它。
    ///
    /// 合成解码会因缺键整体失败，那样「旧文件仍可读」的契约就破了；
    /// 这里按 `false` 兜底，也让解码对字段是否存在不敏感。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decode(RGBAColor.self, forKey: .color)
        width = try container.decode(Double.self, forKey: .width)
        dash = try container.decodeIfPresent([Double].self, forKey: .dash)
        isSketchy = try container.decodeIfPresent(Bool.self, forKey: .isSketchy) ?? false
    }
}

/// 字体的可序列化描述（model.md §4.5）。
///
/// 只保存重建字体所需的信息，不保存字体对象，
/// 以保证工程文件跨机器、跨系统版本可重建。
public struct FontDescriptor: Codable, Equatable, Sendable {
    /// 字体族名，如 `".AppleSystemUIFont"`。
    public var family: String

    /// 字号，像素单位。
    public var size: Double

    /// 字重，对应 `NSFont.Weight` 的数值（`400` = regular）。
    public var weight: Int

    /// 是否斜体。
    public var italic: Bool

    public init(family: String, size: Double, weight: Int = 400, italic: Bool = false) {
        self.family = family
        self.size = size
        self.weight = weight
        self.italic = italic
    }

    /// 系统字体描述。
    public static func system(size: Double, weight: Int = 400, italic: Bool = false) -> FontDescriptor {
        FontDescriptor(family: ".AppleSystemUIFont", size: size, weight: weight, italic: italic)
    }
}

/// 马赛克的处理模式（model.md §4.6）。
///
/// M1 仅实现 `pixelate`；`blur` 与 `solid` 为契约预留，
/// 解码时保留原值以便未来实现，渲染时按「不支持的 mode」处理。
public enum MosaicMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// 像素化，`intensity` 为马赛克块边长（像素）。
    case pixelate

    /// 高斯模糊，`intensity` 为模糊半径（像素）。M1 未实现。
    case blur

    /// 纯色填充，`intensity` 被忽略，颜色取自 `stroke.color`。M1 未实现。
    case solid

    /// 当前版本是否具备渲染能力。
    public var isRenderable: Bool {
        self == .pixelate
    }
}

/// 一条标注。
///
/// 用「稳定的 `id` + 可穷尽匹配的 `kind`」表达，
/// 而不是为每种标注各写一个独立结构体：这样数组排序、z 序、
/// 与选中/删除等操作都不需要再套一层类型分支。
public struct Annotation: Equatable, Sendable, Identifiable {
    /// 会话内唯一标识。
    public let id: UUID

    /// 标注内容。
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// 标注内容。几何数据均为底图像素坐标。
    public enum Kind: Equatable, Sendable {
        /// 矩形。
        case rectangle(rect: PixelRect, stroke: StrokeStyle, fill: RGBAColor?, cornerRadius: Double)

        /// 直线。
        case line(start: PixelPoint, end: PixelPoint, stroke: StrokeStyle)

        /// 箭头，`start` 为尾、`end` 为头。
        case arrow(
            start: PixelPoint,
            end: PixelPoint,
            stroke: StrokeStyle,
            headLength: Double,
            headWidth: Double
        )

        /// 文字，`origin` 为**基线起点**（左下），非左上角。
        case text(
            origin: PixelPoint,
            text: String,
            font: FontDescriptor,
            color: RGBAColor,
            background: RGBAColor?,
            maxWidth: Double?
        )

        /// 马赛克（矩形框选）。渲染时依赖底图（或当前画布）像素。
        case mosaic(rect: PixelRect, mode: MosaicMode, intensity: Double)

        /// 涂抹马赛克：沿路径刷出的像素化区域。
        ///
        /// 存**矢量路径**而不是蒙版位图：路径占用可忽略，
        /// 位图蒙版会随笔画数线性增长，且无法参与「数组顺序即 z 序」的模型。
        case mosaicStroke(
            points: [PixelPoint],
            radius: Double,
            mode: MosaicMode,
            intensity: Double
        )

        /// 编号标记：中心点 + 半径 + 序号。
        ///
        /// 序号**存在模型里**。契约要求「自动递增由会话维护计数器，而非由模型推断」——
        /// 计数器在编辑器状态里，但值必须落到模型：删除中间一笔之后，
        /// 靠数组下标推断会得到与画面上不同的数字。
        case numbering(
            center: PixelPoint,
            radius: Double,
            index: Int,
            stroke: StrokeStyle,
            fill: RGBAColor?,
            textColor: RGBAColor
        )

        /// 高亮：半透明填充的矩形。
        case highlight(rect: PixelRect, color: RGBAColor)

        /// 测量：两点之间的直线 + 距离读数。
        ///
        /// 只存端点与样式，**不存距离文本**：距离是端点的派生值，
        /// 存下来就会产生「改了端点、文本没改」的不一致；单位换算属 UI 层。
        case measure(start: PixelPoint, end: PixelPoint, stroke: StrokeStyle)

        /// 放大镜：中心点 + 半径 + 倍率。
        ///
        /// 与 `mosaic` 同类：渲染时**读取底图**（此处是当前画布）并重采样。
        case magnifier(center: PixelPoint, radius: Double, zoom: Double, border: StrokeStyle)

        /// 自由绘制：**已简化**的点序列。
        ///
        /// 存简化后的点而不是原始采样点：一次拖动的原始点可达数千，
        /// 直接进 JSON 会让工程文件膨胀两个数量级（契约 §2.3 规定用
        /// Douglas–Peucker，容差为画笔宽度的固定比例）。
        case freehand(points: [PixelPoint], stroke: StrokeStyle)

        /// 弯曲箭头：起点 + 控制点 + 终点（二次贝塞尔），`end` 为箭头所指一端。
        case curvedArrow(
            start: PixelPoint,
            control: PixelPoint,
            end: PixelPoint,
            stroke: StrokeStyle,
            headLength: Double,
            headWidth: Double
        )

        /// 契约中的 `type` 字符串。
        public var typeName: String {
            switch self {
            case .rectangle: "rectangle"
            case .line: "line"
            case .arrow: "arrow"
            case .text: "text"
            case .mosaic: "mosaic"
            case .mosaicStroke: "mosaicStroke"
            case .numbering: "numbering"
            case .highlight: "highlight"
            case .measure: "measure"
            case .magnifier: "magnifier"
            case .freehand: "freehand"
            case .curvedArrow: "curvedArrow"
            }
        }
    }

    /// 标注的几何包围盒（不含描边宽度向外扩张的部分）。
    ///
    /// 用于范围校验与命中测试；文字标注无法在不排版的前提下得知实际宽高，
    /// 因此只返回基线起点处的零尺寸矩形。
    public var boundingRect: PixelRect {
        switch kind {
        case let .rectangle(rect, _, _, _), let .mosaic(rect, _, _):
            return rect
        case let .line(start, end, _), let .arrow(start, end, _, _, _):
            return PixelRect(
                origin: PixelPoint(x: min(start.x, end.x), y: min(start.y, end.y)),
                size: PixelSize(width: abs(end.x - start.x), height: abs(end.y - start.y))
            )
        case let .mosaicStroke(points, radius, _, _):
            guard let first = points.first else {
                return PixelRect(origin: .zero, size: PixelSize(width: 0, height: 0))
            }
            var minX = first.x, maxX = first.x
            var minY = first.y, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
            // 笔刷有半径，包围盒必须外扩，否则边缘涂抹会被判为越界。
            return PixelRect(
                origin: PixelPoint(x: minX - radius, y: minY - radius),
                size: PixelSize(
                    width: (maxX - minX) + radius * 2,
                    height: (maxY - minY) + radius * 2
                )
            )
        case let .text(origin, _, _, _, _, _):
            return PixelRect(origin: origin, size: PixelSize(width: 0, height: 0))

        case let .numbering(center, radius, _, _, _, _),
             let .magnifier(center, radius, _, _):
            return PixelRect(
                origin: PixelPoint(x: center.x - radius, y: center.y - radius),
                size: PixelSize(width: radius * 2, height: radius * 2)
            )

        case let .highlight(rect, _):
            return rect

        case let .measure(start, end, _):
            return Self.boundingRect(of: [start, end], padding: 0)

        case let .freehand(points, stroke):
            // 笔迹有笔宽，包围盒必须外扩半个线宽，否则边缘笔迹会被判为越界。
            return Self.boundingRect(of: points, padding: stroke.width / 2)

        case let .curvedArrow(start, control, end, _, _, _):
            // 用三个控制点的包围盒，**不是**曲线的紧致包围盒：二次贝塞尔的极值
            // 可能落在控制点之外，这里取的是保守上界。用途是范围校验与命中，
            // 上界偏大只会让判界更宽松，不会漏掉内容。
            return Self.boundingRect(of: [start, control, end], padding: 0)
        }
    }
}

extension Annotation {
    /// 一组点的包围盒，可外扩。
    static func boundingRect(of points: [PixelPoint], padding: Double) -> PixelRect {
        guard let first = points.first else {
            return PixelRect(origin: .zero, size: PixelSize(width: 0, height: 0))
        }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return PixelRect(
            origin: PixelPoint(x: minX - padding, y: minY - padding),
            size: PixelSize(
                width: (maxX - minX) + padding * 2,
                height: (maxY - minY) + padding * 2
            )
        )
    }
}

// MARK: - 扁平 JSON 编解码

/// 标注解码错误。
public enum AnnotationDecodingError: Error, LocalizedError, Equatable {
    /// 遇到未知的 `type`。
    ///
    /// 这是**可跳过**的错误：读取新版本文件时，未知类型应被忽略而不是让整个文件加载失败
    /// （model.md §10 的兼容策略）。
    case unknownType(String)

    /// 缺少 `type` 字段。
    case missingType

    public var errorDescription: String? {
        switch self {
        case let .unknownType(type):
            return "未知的标注类型：\(type)"
        case .missingType:
            return "标注缺少 type 字段"
        }
    }
}

extension Annotation: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case rect
        case stroke
        case fill
        case cornerRadius
        case start
        case end
        case headLength
        case headWidth
        case origin
        case text
        case font
        case color
        case background
        case maxWidth
        case mode
        case intensity
        case points
        case radius
        case center
        case index
        case textColor
        case zoom
        case border
        case control
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)

        guard let type = try container.decodeIfPresent(String.self, forKey: .type) else {
            throw AnnotationDecodingError.missingType
        }

        switch type {
        case "rectangle":
            kind = try .rectangle(
                rect: container.decode(PixelRect.self, forKey: .rect),
                stroke: container.decode(StrokeStyle.self, forKey: .stroke),
                fill: container.decodeIfPresent(RGBAColor.self, forKey: .fill),
                cornerRadius: container.decode(Double.self, forKey: .cornerRadius)
            )
        case "line":
            kind = try .line(
                start: container.decode(PixelPoint.self, forKey: .start),
                end: container.decode(PixelPoint.self, forKey: .end),
                stroke: container.decode(StrokeStyle.self, forKey: .stroke)
            )
        case "arrow":
            kind = try .arrow(
                start: container.decode(PixelPoint.self, forKey: .start),
                end: container.decode(PixelPoint.self, forKey: .end),
                stroke: container.decode(StrokeStyle.self, forKey: .stroke),
                headLength: container.decode(Double.self, forKey: .headLength),
                headWidth: container.decode(Double.self, forKey: .headWidth)
            )
        case "text":
            kind = try .text(
                origin: container.decode(PixelPoint.self, forKey: .origin),
                text: container.decode(String.self, forKey: .text),
                font: container.decode(FontDescriptor.self, forKey: .font),
                color: container.decode(RGBAColor.self, forKey: .color),
                background: container.decodeIfPresent(RGBAColor.self, forKey: .background),
                maxWidth: container.decodeIfPresent(Double.self, forKey: .maxWidth)
            )
        case "mosaic":
            kind = try .mosaic(
                rect: container.decode(PixelRect.self, forKey: .rect),
                mode: container.decode(MosaicMode.self, forKey: .mode),
                intensity: container.decode(Double.self, forKey: .intensity)
            )
        case "mosaicStroke":
            kind = try .mosaicStroke(
                points: container.decode([PixelPoint].self, forKey: .points),
                radius: container.decode(Double.self, forKey: .radius),
                mode: container.decode(MosaicMode.self, forKey: .mode),
                intensity: container.decode(Double.self, forKey: .intensity)
            )
        case "numbering":
            kind = try .numbering(
                center: container.decode(PixelPoint.self, forKey: .center),
                radius: container.decode(Double.self, forKey: .radius),
                index: container.decode(Int.self, forKey: .index),
                stroke: container.decode(StrokeStyle.self, forKey: .stroke),
                fill: container.decodeIfPresent(RGBAColor.self, forKey: .fill),
                textColor: container.decode(RGBAColor.self, forKey: .textColor)
            )
        case "highlight":
            kind = try .highlight(
                rect: container.decode(PixelRect.self, forKey: .rect),
                color: container.decode(RGBAColor.self, forKey: .color)
            )
        case "measure":
            kind = try .measure(
                start: container.decode(PixelPoint.self, forKey: .start),
                end: container.decode(PixelPoint.self, forKey: .end),
                stroke: container.decode(StrokeStyle.self, forKey: .stroke)
            )
        case "magnifier":
            kind = try .magnifier(
                center: container.decode(PixelPoint.self, forKey: .center),
                radius: container.decode(Double.self, forKey: .radius),
                zoom: container.decode(Double.self, forKey: .zoom),
                border: container.decode(StrokeStyle.self, forKey: .border)
            )
        case "freehand":
            kind = try .freehand(
                points: container.decode([PixelPoint].self, forKey: .points),
                stroke: container.decode(StrokeStyle.self, forKey: .stroke)
            )
        case "curvedArrow":
            kind = try .curvedArrow(
                start: container.decode(PixelPoint.self, forKey: .start),
                control: container.decode(PixelPoint.self, forKey: .control),
                end: container.decode(PixelPoint.self, forKey: .end),
                stroke: container.decode(StrokeStyle.self, forKey: .stroke),
                headLength: container.decode(Double.self, forKey: .headLength),
                headWidth: container.decode(Double.self, forKey: .headWidth)
            )
        case let other:
            throw AnnotationDecodingError.unknownType(other)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind.typeName, forKey: .type)

        switch kind {
        case let .rectangle(rect, stroke, fill, cornerRadius):
            try container.encode(rect, forKey: .rect)
            try container.encode(stroke, forKey: .stroke)
            // 契约要求字段存在：不填充时写 null，而不是省略字段。
            try container.encode(fill, forKey: .fill)
            try container.encode(cornerRadius, forKey: .cornerRadius)

        case let .line(start, end, stroke):
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
            try container.encode(stroke, forKey: .stroke)

        case let .arrow(start, end, stroke, headLength, headWidth):
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
            try container.encode(stroke, forKey: .stroke)
            try container.encode(headLength, forKey: .headLength)
            try container.encode(headWidth, forKey: .headWidth)

        case let .text(origin, text, font, color, background, maxWidth):
            try container.encode(origin, forKey: .origin)
            try container.encode(text, forKey: .text)
            try container.encode(font, forKey: .font)
            try container.encode(color, forKey: .color)
            try container.encode(background, forKey: .background)
            try container.encode(maxWidth, forKey: .maxWidth)

        case let .mosaic(rect, mode, intensity):
            try container.encode(rect, forKey: .rect)
            try container.encode(mode, forKey: .mode)
            try container.encode(intensity, forKey: .intensity)

        case let .numbering(center, radius, index, stroke, fill, textColor):
            try container.encode(center, forKey: .center)
            try container.encode(radius, forKey: .radius)
            try container.encode(index, forKey: .index)
            try container.encode(stroke, forKey: .stroke)
            // 契约要求字段存在：不填充时写 null，而不是省略字段。
            try container.encode(fill, forKey: .fill)
            try container.encode(textColor, forKey: .textColor)

        case let .highlight(rect, color):
            try container.encode(rect, forKey: .rect)
            try container.encode(color, forKey: .color)

        case let .measure(start, end, stroke):
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
            try container.encode(stroke, forKey: .stroke)

        case let .magnifier(center, radius, zoom, border):
            try container.encode(center, forKey: .center)
            try container.encode(radius, forKey: .radius)
            try container.encode(zoom, forKey: .zoom)
            try container.encode(border, forKey: .border)

        case let .freehand(points, stroke):
            try container.encode(points, forKey: .points)
            try container.encode(stroke, forKey: .stroke)

        case let .curvedArrow(start, control, end, stroke, headLength, headWidth):
            try container.encode(start, forKey: .start)
            try container.encode(control, forKey: .control)
            try container.encode(end, forKey: .end)
            try container.encode(stroke, forKey: .stroke)
            try container.encode(headLength, forKey: .headLength)
            try container.encode(headWidth, forKey: .headWidth)

        case let .mosaicStroke(points, radius, mode, intensity):
            try container.encode(points, forKey: .points)
            try container.encode(radius, forKey: .radius)
            try container.encode(mode, forKey: .mode)
            try container.encode(intensity, forKey: .intensity)
        }
    }
}

// MARK: - 数组的容错解码

/// 标注数组的包装类型，用于**跳过未知类型**而不是让整个文件加载失败。
///
/// model.md §10：新版应用写出的文件含旧版不认识的标注类型时，
/// 旧版应跳过该条并继续加载其余内容。
public struct AnnotationList: Equatable, Sendable {
    /// 成功解码的标注。
    public var annotations: [Annotation]

    /// 因未知类型或字段缺失而被跳过的条目数。
    public var skippedCount: Int

    public init(annotations: [Annotation] = [], skippedCount: Int = 0) {
        self.annotations = annotations
        self.skippedCount = skippedCount
    }
}

extension AnnotationList: Codable {
    public init(from decoder: Decoder) throws {
        // 第一步：解成一个「必定成功」的类型，让容器游标必定前进。
        //
        // 不能直接 `try container.decode(Annotation.self)`：解码失败时
        // JSONDecoder 不会推进游标，下面的「失败就跳过」循环会永远停在同一条上。
        var container = try decoder.unkeyedContainer()
        var rawItems: [JSONValue] = []
        while !container.isAtEnd {
            rawItems.append(try container.decode(JSONValue.self))
        }

        // 第二步：在普通数组上做容错转换，此处不可能死循环。
        var decoded: [Annotation] = []
        var skipped = 0
        for raw in rawItems {
            if let annotation = try? raw.decode(as: Annotation.self) {
                decoded.append(annotation)
            } else {
                skipped += 1
            }
        }

        annotations = decoded
        skippedCount = skipped
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for annotation in annotations {
            try container.encode(annotation)
        }
    }
}
