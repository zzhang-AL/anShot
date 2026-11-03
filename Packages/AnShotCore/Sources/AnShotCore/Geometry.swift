//
//  Geometry.swift
//  AnShotCore
//
//  底图像素坐标系的基础几何类型。
//
//  契约见 docs/m1-capture/model.md §1 与 §3：
//  模型内部的一切几何数据均使用「底图像素坐标」，不使用屏幕逻辑点。
//  逻辑点 → 像素的换算发生在模型边界处，由 AnShotUI 调用换算函数完成。
//

/// 底图像素坐标点。原点为底图左上角，y 轴向下。
public struct PixelPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    /// 原点（左上）。用于「画布原点即底图原点」的显示渲染场景。
    public static let zero = PixelPoint(x: 0, y: 0)

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 底图像素尺寸。宽高必须为正。
public struct PixelSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    /// 零尺寸。
    ///
    /// 专门给「没有位置信息」用：云端 OCR 不返回包围盒，
    /// 用零矩形而不是整图矩形——后者会被下游读成「这一行占了整张图」，
    /// 是误导（契约见 docs/model-providers/model.md §1.2）。
    public static let zero = PixelSize(width: 0, height: 0)

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// 底图像素矩形。
public struct PixelRect: Codable, Equatable, Sendable {
    public var origin: PixelPoint
    public var size: PixelSize

    /// 零矩形，含义见 `PixelSize.zero`。
    public static let zero = PixelRect(origin: .zero, size: .zero)

    public init(origin: PixelPoint, size: PixelSize) {
        self.origin = origin
        self.size = size
    }

    /// 是否具有正面积。
    public var isNonEmpty: Bool {
        size.width > 0 && size.height > 0
    }
}

/// sRGB 色彩，各分量取值 0.0...1.0，非预乘。
public struct RGBAColor: Codable, Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}
