//
//  SelectionDecoration.swift
//  AnShotUI
//
//  选区装饰的**几何与度量**：角括号 / 中点抓手的尺寸、手柄布局与命中判定。
//
//  抽出来的理由：这些是纯几何（输入选中矩形与半径，输出布局），
//  原先嵌在 `OverlayView` 里与鼠标事件、绘制、标注编辑混在一个 2000+ 行的类中，
//  既难核对「绘制与命中是不是同一份布局」，也无法单独验证。
//
//  一条硬约束：**绘制、命中、光标必须共用同一份布局**。
//  历史上它们曾各算一遍，于是出现「画在这里、要往那边点」与
//  「看不见却点得到」两类缺陷。现在布局只有 `SelectionHandleLayout.items(...)`
//  一个来源，调用方不得自己再算一遍。
//

import AnShotCore
import AnShotCapture
import CoreGraphics

/// 选区装饰的尺寸与阈值（逻辑点）。
///
/// 全是外观取值，不是推导出来的：每一条都对应一次目视修正，
/// 注释里记的是**当时看到的症状**，改数值前先读一遍。
struct SelectionDecoration {

    static let standard = SelectionDecoration()

    /// 角括号的臂长。
    ///
    /// 16pt 是与 3pt 描边相称的结果：臂长不足线宽四倍的括号会缩成
    /// 看不出朝向的短茬，而它是「这个角可以拖」的唯一可见提示。
    /// 小选区按短边收窄（见 `armLength(for:cornerRadius:)`）。
    let cornerArmLength: CGFloat = 16

    /// 中点抓手沿边界方向的长度。12×4 的胶囊：明显宽于边框（2.5pt）才读得出
    /// 「这条边可以拖」，又远小于角括号以免抢走主次。
    let midpointGripLength: CGFloat = 12

    /// 中点抓手垂直于边界方向的厚度。
    let midpointGripThickness: CGFloat = 4

    /// 拖动中的中点抓手放大倍数。
    ///
    /// 悬停已有变色提示，拖动中再加一层尺寸变化：此时指针压在手柄上，
    /// 颜色被遮挡的部分更多，只靠颜色反馈不足。
    let midpointGripActiveScale: CGFloat = 1.25

    /// 角手柄的不可见命中半径。
    ///
    /// 必须覆盖整条**可见**的括号：可见范围沿边界到角点约 17.5pt
    /// （臂长 16 + 端点圆帽），取 20pt 保证「看得见的都点得到」。
    let cornerHitRadius: CGFloat = 20

    /// 中点手柄的不可见命中半径。
    let midpointHitRadius: CGFloat = 12

    /// 选区短边小于此值时只保留四角手柄：8 个控件在几十点见方的选区里
    /// 会互相叠压，既看不清也点不准。
    let compactHandleThreshold: CGFloat = 44

    /// 尺寸提示的高度。
    let labelHeight: CGFloat = 25

    /// 尺寸提示的圆角半径。
    let labelCornerRadius: CGFloat = 7

    /// 小于此尺寸的拖拽视为误触，不成立选区。
    let minimumSelectionSize: CGFloat = 8

    /// 角括号臂长：默认值按选区尺寸收窄，但**不小于该角的圆角半径**。
    ///
    /// 上限的理由：不限制时小选区上四角括号会占满整圈，蓝色边框只剩几段碎片
    /// （实测 58×42pt 的选区上 16pt 臂长就是这个下场）。
    /// 下限的理由：贴屏幕角时圆角可达 20pt+，若臂长仍只有 16pt，
    /// 括号的圆弧会被截小——边框沿屏幕圆弧走、白色括号却停在另一条弧上。
    func armLength(for size: CGSize, cornerRadius: CGFloat) -> CGFloat {
        let shortSide = min(size.width, size.height)
        guard shortSide > 0 else { return 0 }
        let capped = min(cornerArmLength, shortSide * CaptureFrameStyle.bracketArmShortSideRatio)
        return max(capped, cornerRadius)
    }

    /// 该尺寸的选区是否使用紧凑模式（只留四角手柄）。
    func usesCompactHandles(for size: CGSize) -> Bool {
        min(size.width, size.height) < compactHandleThreshold
    }
}

/// 手柄布局与命中判定。
///
/// 无状态：绘制、命中、光标都从这里取同一份结果。
enum SelectionHandleLayout {

    /// 一个可交互手柄的布局结果。
    struct Item: Equatable {
        let handle: SelectionHandle
        /// 绘制与命中共同使用的中心。
        let center: CGPoint
        /// 不可见命中半径。
        let hitRadius: CGFloat
    }

    /// 装饰矩形：选区向内缩半个最外层描边。
    ///
    /// 内缩的依据：路径是**描边**的，它的外边缘会向外扩半个线宽，
    /// 不内缩的话边框最外侧会压在选区之外——选区几何本身（裁剪、导出）保持严格矩形。
    static func decoratedRect(for selection: CGRect) -> CGRect {
        let outermost = CaptureFrameStyle.selectionStrokeWidth + CaptureFrameStyle.contrastExtraWidth
        return selection.insetBy(dx: CaptureFrameStyle.strokeInset(lineWidth: outermost),
                                 dy: CaptureFrameStyle.strokeInset(lineWidth: outermost))
    }

    /// 遮罩挖空选区的路径。
    ///
    /// 抽成函数而不是在 `drawMask` 里就地拼路径：绘制与断言必须读**同一份**
    /// 几何。否则「挖空是圆角」这件事只能靠肉眼看图，而它恰恰是
    /// 「边框圆角、挖空直角」这类不一致的藏身之处。
    static func maskPath(
        for selection: CGRect,
        viewBounds: CGRect,
        displayID: CGDirectDisplayID
    ) -> CGPath {
        CaptureFrameStyle.roundedPath(
            in: selection,
            radii: maskRadii(for: selection, viewBounds: viewBounds, displayID: displayID)
        )
    }

    /// 遮罩挖空选区时所用的四角圆角。
    ///
    /// 与 `cornerRadii` 是**同一份几何的两种表达**，只差一个 `strokeInset`：
    ///
    /// - 边框路径画在**内缩了 `strokeInset`** 的矩形上，它的**描边外缘**
    ///   才是选区边界；
    /// - 而遮罩挖掉的正是选区边界。
    ///
    /// 两者用同一套 radii 就会差一个 `strokeInset` 的圆弧：四个角各露出一块
    /// 没被压暗的小月牙，看起来就是「边框明明是圆的，外面却还有一个直角」。
    ///
    /// 为什么是**统一**加 `strokeInset`（而不是只给贴屏幕角的那些加）：
    /// 基准半径与屏幕半径都定义在内缩矩形这一层，外缘半径一律等于它们
    /// 加 `strokeInset`；而 `concentricRadius` 正是取 `screenRadius - strokeInset`，
    /// 所以加上之后贴屏角的那几角恰好回到屏幕半径，圆心不变、外缘与之重合。
    static func maskRadii(
        for selection: CGRect,
        viewBounds: CGRect,
        displayID: CGDirectDisplayID
    ) -> CaptureFrameStyle.CornerRadii {
        let radii = cornerRadii(for: selection, viewBounds: viewBounds, displayID: displayID)
        // 内缩量：内缩矩形的边在选区边的**内侧**，所以是「内缩矩形 − 选区」。
        // 写成反过来会得到负值，从而把圆角改小——那时遮罩会在圆角处反向地
        // 多压暗一小条，与边框仍然不贴合，只是月牙换了个方向。
        let inset = decoratedRect(for: selection).minX - selection.minX
        return CaptureFrameStyle.CornerRadii(
            minXMinY: radii.minXMinY + inset,
            maxXMinY: radii.maxXMinY + inset,
            minXMaxY: radii.minXMaxY + inset,
            maxXMaxY: radii.maxXMaxY + inset
        )
    }

    /// 选区四角的圆角半径。
    ///
    /// 默认是基准半径；**当选框的某个角与本屏的物理屏角对齐时**，改用该屏幕角的
    /// 实际圆角半径——屏幕的四角是圆的，用固定半径会在屏幕圆弧与框的圆弧之间
    /// 露出一块月牙形错位（用户反馈的「上方圆角没贴合」就是这个）。
    ///
    /// 只有「两条边都贴」才采用屏幕轮廓：只贴上边中段时屏幕在那里是**直线**，
    /// 用屏幕半径反而会把框的角提前弯向屏幕内部。不贴边时完全不碰屏幕值。
    ///
    /// 屏幕半径取不到（符号不可用、返回值不可信）时保持基准半径——
    /// **不把「读不到」当成「直角」**。
    ///
    /// - Parameters:
    ///   - viewBounds: 本视图（= 本屏）的边界，用于判断某条边是否贴屏幕边。
    ///   - displayID: 本视图所在显示器，决定读谁的物理圆角。
    static func cornerRadii(
        for selection: CGRect,
        viewBounds: CGRect,
        displayID: CGDirectDisplayID
    ) -> CaptureFrameStyle.CornerRadii {
        let rect = decoratedRect(for: selection)
        var radii = CaptureFrameStyle.cornerRadii(for: rect.size)
        guard let screen = DisplayCornerGeometry.radii(for: displayID) else {
            return CaptureFrameStyle.clamped(radii, to: rect.size)
        }

        // **覆盖层视图是左上原点**：绘图坐标系的 minY 侧就是屏幕上方、maxY 侧是屏幕下方，
        // 因此 `.minXMinY ↔ 屏幕左上角`、`.minXMaxY ↔ 屏幕左下角`（其余同理）。
        // 「屏幕角 → 绘图角」的映射只在这一处，写错就会把上下贴合搞反。
        let strokeInset = selection.minX - rect.minX
        let minXGap = selection.minX - viewBounds.minX
        let maxXGap = viewBounds.maxX - selection.maxX
        let minYGap = selection.minY - viewBounds.minY      // 上边
        let maxYGap = viewBounds.maxY - selection.maxY      // 下边

        func apply(
            _ corner: CaptureFrameStyle.Corner,
            _ screenRadius: CGFloat,
            minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat
        ) -> CaptureFrameStyle.CornerRadii {
            guard CaptureFrameStyle.isCornerAligned(
                corner,
                minXGap: minX, maxXGap: maxX, minYGap: minY, maxYGap: maxY
            ) else { return radii }
            return CaptureFrameStyle.alignedRadius(
                for: corner, in: radii, screenRadius: screenRadius, strokeInset: strokeInset
            )
        }

        radii = apply(.minXMinY, screen.topLeft, minX: minXGap, maxX: maxXGap, minY: minYGap, maxY: maxYGap)
        radii = apply(.maxXMinY, screen.topRight, minX: minXGap, maxX: maxXGap, minY: minYGap, maxY: maxYGap)
        radii = apply(.minXMaxY, screen.bottomLeft, minX: minXGap, maxX: maxXGap, minY: minYGap, maxY: maxYGap)
        radii = apply(.maxXMaxY, screen.bottomRight, minX: minXGap, maxX: maxXGap, minY: minYGap, maxY: maxYGap)
        return CaptureFrameStyle.clamped(radii, to: rect.size)
    }

    /// 从选区一次算出布局：装饰矩形、四角圆角、手柄。
    ///
    /// 绘制、命中测试、光标都走这里，保证三者看到同一份几何
    /// （分开算就是「画在这里、要往那边点」那类缺陷的来源）。
    static func items(
        for selection: CGRect,
        viewBounds: CGRect,
        displayID: CGDirectDisplayID,
        decoration: SelectionDecoration = .standard,
        activeHandle: SelectionHandle? = nil
    ) -> [Item] {
        items(
            decoratedRect: decoratedRect(for: selection),
            radii: cornerRadii(for: selection, viewBounds: viewBounds, displayID: displayID),
            decoration: decoration,
            activeHandle: activeHandle
        )
    }

    /// 当前应显示且可交互的手柄。
    ///
    /// 几何取自 `decoratedRect`（与边框同一矩形），而不是选区本身：
    /// 手柄中心必须落在它实际压着的那条边框线上，否则会重现
    /// 「手柄看着在框上、命中却在框外」的旧缺陷。
    ///
    /// - Parameters:
    ///   - decoratedRect: 选区向内缩半个最外层描边之后的矩形。
    ///   - radii: 四角圆角（贴屏幕角时各角可能不同）。
    ///   - activeHandle: 正在拖动的手柄；紧凑模式必须保留它，
    ///     否则把选区缩到阈值以下时手柄会从指针下方消失、拖动立刻中断。
    static func items(
        decoratedRect: CGRect,
        radii: CaptureFrameStyle.CornerRadii,
        decoration: SelectionDecoration = .standard,
        activeHandle: SelectionHandle? = nil
    ) -> [Item] {
        var handles: [SelectionHandle]
        if decoration.usesCompactHandles(for: decoratedRect.size) {
            handles = [.topLeft, .topRight, .bottomRight, .bottomLeft]
            if let activeHandle, !handles.contains(activeHandle) {
                handles.append(activeHandle)
            }
        } else {
            handles = SelectionHandle.allCases
        }

        return handles.map { handle in
            // 命中半径必须覆盖**可见**的括号范围：贴屏幕角时臂长会跟着圆角变长
            // （可达 20pt+），命中半径若仍是 20pt，多出来那段就成了
            // 「看得见却点不到」——正是此前修过一次的那类缺陷。
            let hitRadius: CGFloat
            if isCorner(handle) {
                let arm = decoration.armLength(
                    for: decoratedRect.size,
                    cornerRadius: radius(of: handle, in: radii)
                )
                hitRadius = max(decoration.cornerHitRadius, arm)
            } else {
                hitRadius = decoration.midpointHitRadius
            }
            return Item(
                handle: handle,
                center: SelectionGeometry.center(of: handle, in: decoratedRect),
                hitRadius: hitRadius
            )
        }
    }

    /// 命中测试。多个手柄的判定区重叠时取**最近**的一个：
    /// 角附近两个手柄必然重叠，按固定顺序遍历会让「点的是中点」变成「拖的是角」。
    static func hit(at point: CGPoint, in items: [Item]) -> SelectionHandle? {
        var best: (handle: SelectionHandle, distance: CGFloat)?
        for item in items {
            // Chebyshev 距离：判定区是沿边界方向的方形邻域而非圆形，
            // 贴着边拖时不会因斜向偏差脱靶。
            let distance = max(abs(point.x - item.center.x), abs(point.y - item.center.y))
            guard distance <= item.hitRadius else { continue }
            // 已有一个更近（或同样近）的手柄时保留它：平手时取先出现的那个，
            // 结果稳定。写成 `if let` 而不是 `best == nil || distance < best!.distance`，
            // 避免对同一个值既判空又强解。
            if let best, distance >= best.distance { continue }
            best = (item.handle, distance)
        }
        return best?.handle
    }

    /// 手柄是否位于角上（同时推动水平与垂直两条边）。
    static func isCorner(_ handle: SelectionHandle) -> Bool {
        (handle.movesLeftEdge || handle.movesRightEdge)
            && (handle.movesTopEdge || handle.movesBottomEdge)
    }

    /// 某个手柄所在角的圆角半径（中点手柄不关心圆角）。
    static func radius(
        of handle: SelectionHandle,
        in radii: CaptureFrameStyle.CornerRadii
    ) -> CGFloat {
        switch handle {
        case .topLeft: return radii.minXMinY
        case .topRight: return radii.maxXMinY
        case .bottomLeft: return radii.minXMaxY
        case .bottomRight: return radii.maxXMaxY
        default: return 0
        }
    }
}
