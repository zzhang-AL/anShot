//
//  CaptureFrameStyle.swift
//  AnShotUI
//
//  截图选框与录制范围框共用的视觉样式：调色板、圆角几何、双层描边绘制。
//
//  ── 为什么需要共享 ────────────────────────────────────────────
//
//  两处边框此前各自硬编码颜色与线宽。它们出现在同一场会话里（准备面板弹起时
//  录制预览框与截图选框会同时/相继可见），分开维护迟早会出现「同一套 chrome
//  两种外观」——尤其录制预览与截图选框本就是同一个视觉语义（蓝＝待截/待录）。
//
//  ── 为什么是双层描边 ──────────────────────────────────────────
//
//  边框可能落在任何画面内容上，从纯黑终端到白色网页。单一描边只要与底色亮度
//  接近就直接消失，而用户无从判断「框还在不在」。故先铺一层略宽的半透明深色，
//  再把彩色线压在上面：浅底上深色层提供分离，深底上彩色线自身发亮。
//
//  ── 为什么圆角只是装饰 ────────────────────────────────────────
//
//  截图选区的裁剪几何是严格的矩形（`SelectionGeometry` 与导出路径都不看这里
//  的路径）。圆角只影响这一圈线的画法，半径上限 8pt 且不超过短边的四分之一，
//  就是为了把「看着是圆角、截出来是直角」的认知偏差压到看不出来。
//

import AnShotCapture
import AnShotCore
import AppKit

/// 覆盖层边框的共享视觉样式。
///
/// 刻意不做可配置主题：目前只有一套皮肤，多一层抽象只会增加阅读成本。
enum CaptureFrameStyle {

    // MARK: - 调色板

    /// 截图选框、录制预览（尚未开始录制）。
    ///
    /// 同一个蓝承担两种语义是有意的：对用户而言「蓝色框＝即将被截取/录制的
    /// 区域」，此时按下快门还是开始录制只是后续动作的差别。
    static let selection = RGBAColor(r: 0.302, g: 0.639, b: 1.000, a: 1.0)

    /// 录制中。
    static let recording = RGBAColor(r: 1.000, g: 0.380, b: 0.365, a: 1.0)

    /// 暂停。
    static let paused = RGBAColor(r: 0.969, g: 0.745, b: 0.310, a: 1.0)

    /// 未悬停的调整手柄。手柄保持白色：它是可拖控件而非状态指示，
    /// 涂上彩色会在选框上排出一圈彩色标记，压过边框本身。
    static let idleHandle = RGBAColor(r: 1.0, g: 1.0, b: 1.0, a: 1.0)

    /// 悬停 / 拖动中的手柄。
    ///
    /// 不能用边框那个蓝：手柄正压在蓝边框的圆角上，同色等于隐身，
    /// 用户看不出自己悬停到了控件上。这里改用同色系但明显更亮的一档，
    /// 靠**亮度差**而不是色相差做区分，因此不会给选框引入第二个色相；
    /// 且它在浅色底上比白色对比度更高（白底上白手柄几乎不可见），
    /// 浅底上反而比常态更清楚。
    static let highlightHandle = RGBAColor(r: 0.612, g: 0.796, b: 1.000, a: 1.0)

    // MARK: - 线宽（逻辑点）

    /// 截图选框线宽。
    ///
    /// 2.5pt 在 2x 屏上是 5 个设备像素。此前的 1 个设备像素 hairline 在
    /// 压暗的底图上几乎不可见——边框的职责是明确「截到这里」，可见性优先。
    static let selectionStrokeWidth: CGFloat = 2.5

    /// 录制范围框线宽。略粗于截图框：录制期间它常被用户用余光扫过，
    /// 而截图时视线本就盯着选框中心。
    static let recordingStrokeWidth: CGFloat = 3

    /// 手柄描边宽度（角括号）。
    static let handleStrokeWidth: CGFloat = 3

    /// 悬停 / 拖动中的手柄描边宽度。
    ///
    /// 比常态粗 1pt：颜色变化在浅色底上不够明显，加一层尺寸反馈。
    /// 只加 1pt 而非翻倍，避免手柄在指针下“跳”一下。
    static let handleHighlightStrokeWidth: CGFloat = 4

    /// 深色对比层比主描边**总**宽出的量（两侧各分一半，即每侧 0.75pt）。
    ///
    /// 0.75pt 在 2x 屏上是 1.5 像素，足以在浅底上与彩色线分离，
    /// 又不会在浅底上留下一圈明显的黑晕。
    static let contrastExtraWidth: CGFloat = 1.5

    /// 深色对比层不透明度。
    static let contrastAlpha: CGFloat = 0.45

    // MARK: - 圆角

    /// 圆角半径上限（逻辑点）。
    static let preferredCornerRadius: CGFloat = 8

    /// 圆角半径上限＝短边的八分之一。
    ///
    /// **这是视觉取值，不是几何必然**：小选区上的圆角必须按比例收窄，
    /// 否则 58×42pt 的框上 8pt 圆角已接近短边的五分之一，看起来「过圆」，
    /// 矩形被读成了胶囊。
    ///
    /// 顺带的好处：该上限不超过角括号臂长上限（短边 1/4）的一半，
    /// 因此括号的圆弧总是完整落在臂的范围内，不需要再夹取半径。
    private static let cornerRadiusShortSideRatio: CGFloat = 0.125

    /// 角括号的臂长上限＝短边的四分之一。
    ///
    /// 同样是为了解决一个**看出来的**问题（不是推导出来的）：
    /// 臂长取固定 16pt 时，在 58×42pt 的选区上四角括号会占满整圈，
    /// 蓝色边框只剩几段碎片——括号压过了边框。
    /// 收到短边的四分之一后，一条边上两段臂之间总留得下明显的边框线。
    static let bracketArmShortSideRatio: CGFloat = 0.25

    /// **基准**圆角半径：只按尺寸收窄，不看你是否贴屏幕边缘。
    static func cornerRadius(for size: CGSize) -> CGFloat {
        let shortSide = min(size.width, size.height)
        guard shortSide > 0 else { return 0 }
        return min(preferredCornerRadius, shortSide * cornerRadiusShortSideRatio)
    }

    /// 矩形四边到**所在屏幕边缘**的距离：已删除。
    ///
    /// 曾经的实现按「离屏幕边越近半径越小、贴边即直角」收窄。这条策略是**错的**：
    /// Mac 的屏幕本身不是直角，把它收成直角反而更不贴合。正确的做法是
    /// 在选框的角与屏幕角对齐时，采用**该屏幕角的实际圆角半径**
    /// （见 `DisplayCornerGeometry`）。

    /// 四个角各自的圆角半径。
    struct CornerRadii: Equatable {
        var minXMinY: CGFloat
        var maxXMinY: CGFloat
        var minXMaxY: CGFloat
        var maxXMaxY: CGFloat

        /// 四角同值。
        static func uniform(_ radius: CGFloat) -> CornerRadii {
            CornerRadii(
                minXMinY: radius,
                maxXMinY: radius,
                minXMaxY: radius,
                maxXMaxY: radius
            )
        }
    }

    /// 基准圆角（四角同值）：只按尺寸收窄，不涉及屏幕。
    static func cornerRadii(for size: CGSize) -> CornerRadii {
        .uniform(cornerRadius(for: size))
    }

    /// 与屏幕圆角**共圆心**所需的路径半径。
    ///
    /// 描边画在内缩了半个最外层线宽的矩形上（内缩量 `strokeInset`）。若直接拿屏幕
    /// 半径 R 去画，圆弧圆心会落在屏幕角内侧 R + strokeInset 处，与屏幕圆角的
    /// 圆心（角内侧 R 处）差一个 strokeInset。
    ///
    /// 取 `R - strokeInset` 后：圆心回到角内侧 R 处（与屏幕圆弧共圆心），
    /// 而描边外缘向外扩 strokeInset，正好等于 R——**外缘与屏幕圆弧重合**。
    ///
    /// 也就是说，贴合的是描边的外缘；描边本体整个落在屏幕圆弧内侧，不会被裁掉。
    /// （小半径时夹到 0，退化为直线角，这是屏幕圆角本身就很小的情形。）
    static func concentricRadius(screenRadius: CGFloat, strokeInset: CGFloat) -> CGFloat {
        max(0, screenRadius - strokeInset)
    }

    /// 一个角在绘图坐标系里的位置。
    ///
    /// **只用绘图坐标系**，不带「上下左右」语义：两个调用方的 y 方向相反
    /// （截图覆盖层左上原点、录制范围框 AppKit 默认左下原点），
    /// 一旦让类型同时表达两套语义，就必然出现「按屏幕语义算、按绘图语义画」
    /// 这类上下颠倒——本功能的第一次实现正是栽在这里。
    /// 「屏幕的这个角对应绘图的哪个角」由各调用方在映射处写清楚。
    enum Corner: CaseIterable {
        case minXMinY
        case maxXMinY
        case minXMaxY
        case maxXMaxY
    }

    /// 把某个角设为「贴屏幕角」时的路径半径（含同心换算）。
    ///
    /// - Parameters:
    ///   - corner: 绘图坐标系下的角。
    ///   - screenRadius: 该角对应的**屏幕**半径。
    ///   - strokeInset: 描边的内缩量（见 `concentricRadius`）。
    static func alignedRadius(
        for corner: Corner,
        in radii: CornerRadii,
        screenRadius: CGFloat,
        strokeInset: CGFloat
    ) -> CornerRadii {
        let value = concentricRadius(screenRadius: screenRadius, strokeInset: strokeInset)
        var result = radii
        switch corner {
        case .minXMinY: result.minXMinY = value
        case .maxXMinY: result.maxXMinY = value
        case .minXMaxY: result.minXMaxY = value
        case .maxXMaxY: result.maxXMaxY = value
        }
        return result
    }

    /// 夹取到半边长以内：屏幕圆角可能大于很小的框，半径过大会让路径自交。
    static func clamped(_ radii: CornerRadii, to size: CGSize) -> CornerRadii {
        let limit = min(size.width, size.height) / 2
        return CornerRadii(
            minXMinY: min(radii.minXMinY, limit),
            maxXMinY: min(radii.maxXMinY, limit),
            minXMaxY: min(radii.minXMaxY, limit),
            maxXMaxY: min(radii.maxXMaxY, limit)
        )
    }

    /// 某个角所在两条边是否都贴到屏幕（决定是否采用该屏幕角）。
    ///
    /// 只贴一条边不算：屏幕在那里是**直线**，用屏幕圆角反而会把框的角
    /// 提前弯向屏幕内部。
    static func isCornerAligned(
        _ corner: Corner,
        minXGap: CGFloat,
        maxXGap: CGFloat,
        minYGap: CGFloat,
        maxYGap: CGFloat,
        tolerance: CGFloat = 1
    ) -> Bool {
        let atMinX = minXGap <= tolerance
        let atMaxX = maxXGap <= tolerance
        let atMinY = minYGap <= tolerance
        let atMaxY = maxYGap <= tolerance
        switch corner {
        case .minXMinY: return atMinX && atMinY
        case .maxXMinY: return atMaxX && atMinY
        case .minXMaxY: return atMinX && atMaxY
        case .maxXMaxY: return atMaxX && atMaxY
        }
    }

    // MARK: - 路径与几何

    /// 圆角矩形路径，**允许四角半径各不相同**。
    ///
    /// 不用 `CGPath(roundedRect:cornerWidth:cornerHeight:)`：它只支持四角同半径，
    /// 而「与屏幕四角贴合」必然产生不同半径的角（屏幕本身就可能顶底不同）。
    static func roundedPath(in rect: CGRect, radii: CornerRadii) -> CGPath {
        let path = CGMutablePath()
        // 顺时针一圈，起笔在上边（左上角弧之后的位置）。
        path.move(to: CGPoint(x: rect.minX + radii.minXMinY, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radii.maxXMinY, y: rect.minY))
        addCorner(
            path,
            corner: CGPoint(x: rect.maxX, y: rect.minY),
            next: CGPoint(x: rect.maxX, y: rect.minY + radii.maxXMinY),
            radius: radii.maxXMinY
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radii.maxXMaxY))
        addCorner(
            path,
            corner: CGPoint(x: rect.maxX, y: rect.maxY),
            next: CGPoint(x: rect.maxX - radii.maxXMaxY, y: rect.maxY),
            radius: radii.maxXMaxY
        )
        path.addLine(to: CGPoint(x: rect.minX + radii.minXMaxY, y: rect.maxY))
        addCorner(
            path,
            corner: CGPoint(x: rect.minX, y: rect.maxY),
            next: CGPoint(x: rect.minX, y: rect.maxY - radii.minXMaxY),
            radius: radii.minXMaxY
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radii.minXMinY))
        addCorner(
            path,
            corner: CGPoint(x: rect.minX, y: rect.minY),
            next: CGPoint(x: rect.minX + radii.minXMinY, y: rect.minY),
            radius: radii.minXMinY
        )
        path.closeSubpath()
        return path
    }

    /// 在当前点与给定角之间接一个圆角；半径为 0 时退化为直角。
    ///
    /// - Parameters:
    ///   - corner: 角的顶点。
    ///   - next: 相邻边方向上的参考点（只用来定方向）。
    ///   - radius: 该角的半径。
    private static func addCorner(
        _ path: CGMutablePath,
        corner: CGPoint,
        next: CGPoint,
        radius: CGFloat
    ) {
        guard radius > 0 else {
            // 半径 0 就是直角。不用 `addArc(radius: 0)`——退化弧的行为没有文档保证。
            path.addLine(to: corner)
            return
        }
        // 用「切线→切线」接法而不是算角度：两个调用方的 y 方向相反，
        // 角度正负会随之反转，而该接法只依赖三个点的位置。
        path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
    }

    /// 让一条描边**完全落在** `rect` 内所需的内缩量。
    ///
    /// 描边以路径为中心向两侧各扩半个线宽，因此外缘落在 rect 边缘要求
    /// 路径内缩半个线宽。录制范围框必须走这一步：窗口边缘是硬裁剪，
    /// 超出部分不是被压暗而是直接不存在，画面上会表现为边框缺一段。
    static func strokeInset(lineWidth: CGFloat) -> CGFloat {
        lineWidth / 2
    }

    // MARK: - 绘制

    /// 虚线图案（实线段长度、空段长度）。
    ///
    /// 只有「候选」态用它：候选与已选定共用同一个蓝，若画法也完全相同，
    /// 用户无法分辨「这个框已经定了」还是「还跟着鼠标跑」。
    /// 虚线是这类「尚未落定」状态最通用的画法。
    static let candidateDashPattern: [CGFloat] = [10, 6]

    /// 描一条路径：先深色对比层，再彩色层。
    ///
    /// - Parameters:
    ///   - path: 待描路径。
    ///   - color: 主描边颜色。
    ///   - lineWidth: 主描边宽度；对比层自动取其加 `contrastExtraWidth`。
    ///   - lineCap: 端点样式，默认 `butt`（直角收口与原线宽一致）。
    ///   - lineJoin: 转折样式，默认圆角——尖角在多层描边下会向外刺出。
    ///   - dash: 虚线图案；`nil` 为实线。
    static func strokePath(
        _ path: CGPath,
        color: RGBAColor,
        lineWidth: CGFloat,
        lineCap: CGLineCap = .butt,
        lineJoin: CGLineJoin = .round,
        dash: [CGFloat]? = nil,
        in context: CGContext
    ) {
        context.saveGState()
        context.setLineCap(lineCap)
        context.setLineJoin(lineJoin)
        // 两层必须共用同一套虚线相位：相偏会让深色层从彩色层的空段里露出来，
        // 虚线看起来变成「彩色与黑色相间」。
        if let dash {
            context.setLineDash(phase: 0, lengths: dash)
        }

        context.setStrokeColor(NSColor.black.withAlphaComponent(contrastAlpha).cgColor)
        context.setLineWidth(lineWidth + contrastExtraWidth)
        context.addPath(path)
        context.strokePath()

        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.addPath(path)
        context.strokePath()

        context.restoreGState()
    }

    /// 填充一个实心形状，并在其外缘补一圈深色对比层。
    ///
    /// 对比层用「描边同一路径」实现：描边向形状外扩自身线宽的一半，
    /// 因此线宽取 `contrastExtraWidth` 即得每侧 0.75pt——与 `strokePath`
    /// 的对比层等宽（那里是主线宽加上同一个常量）。
    static func fillPathWithContrast(
        _ path: CGPath,
        color: RGBAColor,
        in context: CGContext
    ) {
        context.saveGState()
        context.setLineJoin(.round)

        context.setStrokeColor(NSColor.black.withAlphaComponent(contrastAlpha).cgColor)
        context.setLineWidth(contrastExtraWidth)
        context.addPath(path)
        context.strokePath()

        context.setFillColor(color.cgColor)
        context.addPath(path)
        context.fillPath()

        context.restoreGState()
    }

    /// 绘制一圈圆角边框（截图选框 / 录制范围框的主绘制入口）。
    ///
    /// - Parameters:
    ///   - rect: 边框所在矩形。调用方负责决定是否内缩：
    ///     截图选框以选区边界为线中心（边框即边界），
    ///     录制范围框按 `strokeInset(lineWidth:)` 内缩（窗口会裁掉越界部分）。
    ///   - color: 边框颜色。
    ///   - lineWidth: 边框线宽。
    ///   - radii: 四角半径，取 `cornerRadii(for:gaps:)` 的结果。
    ///   - dash: 虚线图案；`nil` 为实线。
    static func drawBorder(
        in rect: CGRect,
        color: RGBAColor,
        lineWidth: CGFloat,
        radii: CornerRadii,
        dash: [CGFloat]? = nil,
        in context: CGContext
    ) {
        strokePath(
            roundedPath(in: rect, radii: radii),
            color: color,
            lineWidth: lineWidth,
            dash: dash,
            in: context
        )
    }
}

// MARK: - 颜色桥接

extension RGBAColor {

    /// sRGB 的 AppKit 颜色。
    ///
    /// 显式声明 sRGB 而非走 `NSColor(red:green:blue:alpha:)`（设备 RGB）：
    /// 后者在广色域显示器上会被当作显示器的原生空间解释，同一个 0.3 在
    /// P3 与 sRGB 屏上看起来是两个颜色。取色器与工具栏也是同一约定。
    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(r),
            green: CGFloat(g),
            blue: CGFloat(b),
            alpha: CGFloat(a)
        )
    }

    /// 供 `CGContext` 直接使用的颜色。
    var cgColor: CGColor {
        nsColor.cgColor
    }
}
