//
//  SelectionGeometry.swift
//  AnShotCore
//
//  选区几何与坐标换算。
//
//  docs/m1-capture/model.md §1 规定：换算函数是**唯一的跨边界通道**，
//  定义于 AnShotCore，由 AnShotUI 调用。本文件即该通道。
//
//  ── 符号约定（关键）────────────────────────────────────────
//
//  视图坐标（显示器逻辑点）与模型坐标（底图像素）**同为左上原点、y 轴向下**，
//  因此换算只是等比缩放，**不含任何轴向翻转**。
//
//  这是 P3 把 OverlayView 设为 isFlipped 的目的：让这套换算是纯缩放，
//  而不是「缩放 + 上下翻转」——后者正是坐标类缺陷的高发形态。
//

import CoreGraphics

// MARK: - 坐标换算

public enum CoordinateConversion {

    /// 显示器逻辑点矩形 → 底图像素矩形。
    ///
    /// - Parameters:
    ///   - rect: 显示器逻辑点坐标（左上原点）。
    ///   - scaleFactor: 底图像素 ÷ 逻辑点，必须为正。
    public static func pixelRect(fromLogical rect: CGRect, scaleFactor: CGFloat) -> PixelRect {
        PixelRect(
            origin: PixelPoint(
                x: Double(rect.minX * scaleFactor),
                y: Double(rect.minY * scaleFactor)
            ),
            size: PixelSize(
                width: Double(rect.width * scaleFactor),
                height: Double(rect.height * scaleFactor)
            )
        )
    }

    /// 底图像素矩形 → 显示器逻辑点矩形。
    public static func logicalRect(fromPixel rect: PixelRect, scaleFactor: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x / Double(scaleFactor),
            y: rect.origin.y / Double(scaleFactor),
            width: rect.size.width / Double(scaleFactor),
            height: rect.size.height / Double(scaleFactor)
        )
    }
}

// MARK: - 调整手柄

/// 选区的 8 个调整手柄。
///
/// 用枚举而非「4 角 + 4 边」两组常量，是为了让命中测试、缩放与绘制
/// 共用同一份定义，避免三者对「有哪几个手柄」产生分歧。
public enum SelectionHandle: String, CaseIterable, Codable, Sendable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    /// 手柄中心在选区内的归一化位置（各分量取值 0...1）。
    public var unitPoint: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .top: return CGPoint(x: 0.5, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .right: return CGPoint(x: 1, y: 0.5)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .left: return CGPoint(x: 0, y: 0.5)
        }
    }

    /// 该手柄是否推动选区的左边界。
    public var movesLeftEdge: Bool {
        self == .topLeft || self == .left || self == .bottomLeft
    }

    /// 该手柄是否推动选区的右边界。
    public var movesRightEdge: Bool {
        self == .topRight || self == .right || self == .bottomRight
    }

    /// 该手柄是否推动选区的上边界。
    public var movesTopEdge: Bool {
        self == .topLeft || self == .top || self == .topRight
    }

    /// 该手柄是否推动选区的下边界。
    public var movesBottomEdge: Bool {
        self == .bottomLeft || self == .bottom || self == .bottomRight
    }
}

// MARK: - 选区几何

public enum SelectionGeometry {

    /// 用两个对角点构造规范化矩形。
    ///
    /// 支持任意拖拽方向：从右下往左上拖与从左上往右下拖得到同一结果。
    public static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    /// 拖动某个手柄后的新矩形。
    ///
    /// **不允许越过对边**：边界被钳制为至少相隔 `minimumSize`。
    /// 若允许翻转，用户拖过头时选区会瞬间跳到另一侧，属于难以预期的手感。
    public static func resizedRect(
        _ rect: CGRect,
        handle: SelectionHandle,
        to point: CGPoint,
        minimumSize: CGFloat
    ) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        if handle.movesLeftEdge {
            minX = min(point.x, maxX - minimumSize)
        }
        if handle.movesRightEdge {
            maxX = max(point.x, minX + minimumSize)
        }
        if handle.movesTopEdge {
            minY = min(point.y, maxY - minimumSize)
        }
        if handle.movesBottomEdge {
            maxY = max(point.y, minY + minimumSize)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 手柄中心点。
    public static func center(of handle: SelectionHandle, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + rect.width * handle.unitPoint.x,
            y: rect.minY + rect.height * handle.unitPoint.y
        )
    }

    /// 命中测试：返回位于 `point` 附近的手柄，没有则返回 nil。
    ///
    /// 用「与手柄中心的曼哈顿距离」而非严格包含：手柄绘制尺寸较小，
    /// 但在高分屏上仍难以精确点中，容差放大于绘制尺寸能明显改善手感。
    public static func handle(
        at point: CGPoint,
        in rect: CGRect,
        tolerance: CGFloat
    ) -> SelectionHandle? {
        for handle in SelectionHandle.allCases {
            let center = center(of: handle, in: rect)
            if abs(point.x - center.x) <= tolerance && abs(point.y - center.y) <= tolerance {
                return handle
            }
        }
        return nil
    }

    /// 把点钳制在给定矩形内。
    public static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    /// 把矩形钳制在给定边界内，并在尺寸不足时返回 nil。
    ///
    /// 用于「拖动选区内部移动」：移动中选区尺寸不变，但需要被限制在屏幕内。
    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var origin = rect.origin
        origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - rect.width))
        origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - rect.height))
        return CGRect(origin: origin, size: rect.size)
    }
}
