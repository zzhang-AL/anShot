//
//  SelectionDecorationTests.swift
//  AnShotUITests
//
//  选区装饰的几何与命中判定测试。
//
//  ── 为什么这些测试必须存在 ────────────────────────────────────
//
//  `SelectionDecoration.swift` 的头部注释记录了两类**已发生过的**缺陷：
//
//    1. 「画在这里、要往那边点」——绘制与命中各算一遍布局
//    2. 「看不见却点得到」/「看得见却点不到」——命中半径与可见括号不匹配
//
//  二者都不会崩溃、不会报错，只在用户手上表现为「手柄点不中」，
//  而此前唯一的验证手段是 `-diagnoseSelection` 的截图比对。
//  本文件把这三条不变量（绘制=命中=光标、紧凑模式、命中取最近）
//  钉死在代码层面。
//
//  ── 入口选择 ──────────────────────────────────────────────────
//
//  刻意使用**不依赖显示器**的重载
//  `items(decoratedRect:radii:decoration:activeHandle:)`：
//  另一重载要读 `DisplayCornerGeometry`（真实屏幕圆角），在测试环境
//  取不到真值，会让断言随机器而变。几何逻辑本身与显示器无关，
//  传入手工构造的 `CornerRadii` 即可完整验证。
//

import AnShotCore
import CoreGraphics
import Testing

@testable import AnShotUI

private let decoration = SelectionDecoration.standard

private func makeRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: width, height: height)
}

@Suite("选区装饰 · 布局与命中")
struct SelectionDecorationLayoutTests {

    // MARK: - 紧凑模式

    @Test("短边低于阈值时使用紧凑手柄")
    func compactModeTriggersBelowThreshold() {
        let threshold = decoration.compactHandleThreshold

        #expect(decoration.usesCompactHandles(for: CGSize(width: threshold - 1, height: 500)))
        #expect(decoration.usesCompactHandles(for: CGSize(width: 500, height: threshold - 1)))
        #expect(
            !decoration.usesCompactHandles(for: CGSize(width: threshold, height: threshold)),
            "恰好等于阈值不算紧凑（判定是严格小于）"
        )
    }

    @Test("紧凑模式只保留四角手柄")
    func compactModeKeepsOnlyCorners() {
        let small = makeRect(0, 0, 20, 20)
        let items = SelectionHandleLayout.items(
            decoratedRect: small,
            radii: .uniform(0),
            decoration: decoration
        )

        #expect(items.count == 4, "紧凑模式应只留 4 个角手柄，实际 \(items.count)")
        #expect(
            items.allSatisfy { SelectionHandleLayout.isCorner($0.handle) },
            "紧凑模式下不得出现中点手柄：几十点的选区里控件会互相叠压"
        )
    }

    @Test("紧凑模式必须保留正在拖动的手柄")
    func compactModeKeepsActiveHandle() {
        let small = makeRect(0, 0, 20, 20)

        // 用户正拖着中点把选区缩小：若此时中点手柄被紧凑模式剔除，
        // 它会从指针下方消失，拖动立刻中断——这是必须防住的行为。
        let items = SelectionHandleLayout.items(
            decoratedRect: small,
            radii: .uniform(0),
            decoration: decoration,
            activeHandle: .top
        )

        #expect(items.count == 5, "紧凑模式 + 活动中点手柄应得到 5 个")
        #expect(
            items.contains { $0.handle == .top },
            "正在拖动的手柄必须保留，否则拖动会中断"
        )
    }

    @Test("紧凑模式下活动手柄若已是角手柄则不重复添加")
    func compactModeDoesNotDuplicateCornerActiveHandle() {
        let small = makeRect(0, 0, 20, 20)
        let items = SelectionHandleLayout.items(
            decoratedRect: small,
            radii: .uniform(0),
            decoration: decoration,
            activeHandle: .topLeft
        )
        #expect(items.count == 4)
        #expect(items.filter { $0.handle == .topLeft }.count == 1)
    }

    @Test("非紧凑模式给出全部八个手柄")
    func fullModeProvidesAllHandles() {
        let large = makeRect(0, 0, 400, 300)
        let items = SelectionHandleLayout.items(
            decoratedRect: large,
            radii: .uniform(0),
            decoration: decoration
        )
        #expect(items.count == SelectionHandle.allCases.count)
        #expect(Set(items.map(\.handle)) == Set(SelectionHandle.allCases), "八个手柄不得缺失或重复")
    }

    // MARK: - 绘制与命中共享几何

    @Test("手柄中心落在装饰矩形的边界上，而不是选区边界上")
    func handleCentersSitOnDecoratedRect() {
        let selection = makeRect(100, 100, 200, 150)
        let decorated = SelectionHandleLayout.decoratedRect(for: selection)
        let items = SelectionHandleLayout.items(
            decoratedRect: decorated,
            radii: .uniform(0),
            decoration: decoration
        )

        // 装饰矩形是选区向内缩半个描边之后的矩形；手柄中心必须落在它实际
        // 压着的那条边框线上，否则会重现「手柄看着在框上、命中却在框外」。
        for item in items {
            let onHorizontalEdge =
                abs(item.center.y - decorated.minY) < 0.001
                || abs(item.center.y - decorated.maxY) < 0.001
            let onVerticalEdge =
                abs(item.center.x - decorated.minX) < 0.001
                || abs(item.center.x - decorated.maxX) < 0.001
            #expect(
                onHorizontalEdge || onVerticalEdge,
                "手柄 \(item.handle) 的中心 \(item.center) 不在装饰矩形边界上"
            )
        }
    }

    @Test("装饰矩形向内缩半个最外层描边")
    func decoratedRectIsInsetByHalfStroke() {
        let selection = makeRect(50, 60, 200, 120)
        let decorated = SelectionHandleLayout.decoratedRect(for: selection)
        let outermost = CaptureFrameStyle.selectionStrokeWidth + CaptureFrameStyle.contrastExtraWidth
        let expected = CaptureFrameStyle.strokeInset(lineWidth: outermost)

        // 内缩量为正数：装饰矩形在选区**内部**，其边比选区边大（inset 是向里收）。
        #expect(abs((decorated.minX - selection.minX) - expected) < 0.001)
        #expect(abs((decorated.minY - selection.minY) - expected) < 0.001)
        #expect(
            decorated.width < selection.width,
            "装饰矩形必须比选区小：路径是描边的，外边缘会向外扩半个线宽"
        )
    }

    @Test("isCorner 只对角上的四个手柄为真")
    func isCornerMatchesDefinition() {
        let corners: [SelectionHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let midpoints: [SelectionHandle] = [.top, .right, .bottom, .left]

        for handle in corners {
            #expect(SelectionHandleLayout.isCorner(handle), "\(handle) 应被判为角手柄")
        }
        for handle in midpoints {
            #expect(!SelectionHandleLayout.isCorner(handle), "\(handle) 不应被判为角手柄")
        }
    }

    // MARK: - 命中半径

    @Test("角手柄命中半径覆盖可见括号：看得见的一定点得到")
    func cornerHitRadiusCoversVisibleBracket() {
        let decorated = makeRect(0, 0, 400, 300)
        let items = SelectionHandleLayout.items(
            decoratedRect: decorated,
            radii: .uniform(0),
            decoration: decoration
        )

        for item in items where SelectionHandleLayout.isCorner(item.handle) {
            let arm = decoration.armLength(for: decorated.size, cornerRadius: 0)
            #expect(
                item.hitRadius >= arm,
                "角手柄 \(item.handle) 的命中半径 \(item.hitRadius) 小于可见臂长 \(arm)：会出现「看得见却点不到」"
            )
            #expect(item.hitRadius >= decoration.cornerHitRadius)
        }
    }

    @Test("贴屏幕角时臂长随圆角变长，命中半径同步跟上")
    func hitRadiusTracksLongerArmLength() {
        let decorated = makeRect(0, 0, 400, 300)
        // 贴屏幕角时物理圆角可达 20pt+，臂长下限被抬到圆角半径
        let largeRadius: CGFloat = 30
        let items = SelectionHandleLayout.items(
            decoratedRect: decorated,
            radii: .uniform(largeRadius),
            decoration: decoration
        )

        let arm = decoration.armLength(for: decorated.size, cornerRadius: largeRadius)
        #expect(arm >= largeRadius, "臂长不得小于该角圆角半径，否则括号的圆弧会被截小")

        guard let topLeft = items.first(where: { $0.handle == .topLeft }) else {
            Issue.record("应存在左上角手柄")
            return
        }
        #expect(
            topLeft.hitRadius >= arm,
            "臂长被圆角抬高到 \(arm) 后，命中半径必须同步，否则多出来那段点不到"
        )
    }

    @Test("中点手柄命中半径独立于臂长")
    func midpointHitRadiusIsIndependent() {
        let decorated = makeRect(0, 0, 400, 300)
        let items = SelectionHandleLayout.items(
            decoratedRect: decorated,
            radii: .uniform(30),
            decoration: decoration
        )
        for item in items where !SelectionHandleLayout.isCorner(item.handle) {
            #expect(item.hitRadius == decoration.midpointHitRadius)
        }
    }

    // MARK: - 命中取最近

    @Test("判定区重叠时取最近的手柄，而不是遍历顺序上的第一个")
    func hitPicksNearestWhenRegionsOverlap() {
        // 角与相邻中点必然重叠。按固定顺序遍历会让「点的是中点」
        // 变成「拖的是角」——必须按距离裁决。
        let items = [
            SelectionHandleLayout.Item(
                handle: .topLeft,
                center: CGPoint(x: 0, y: 0),
                hitRadius: 20
            ),
            SelectionHandleLayout.Item(
                handle: .top,
                center: CGPoint(x: 10, y: 0),
                hitRadius: 20
            )
        ]

        // 距 topLeft 8pt、距 top 2pt → 应取 top
        #expect(SelectionHandleLayout.hit(at: CGPoint(x: 8, y: 0), in: items) == .top)
        // 距 topLeft 2pt、距 top 8pt → 应取 topLeft
        #expect(SelectionHandleLayout.hit(at: CGPoint(x: 2, y: 0), in: items) == .topLeft)
    }

    @Test("距离相等时取先出现的那个（结果稳定，不是随机）")
    func hitIsDeterministicOnTie() {
        let items = [
            SelectionHandleLayout.Item(handle: .top, center: CGPoint(x: 0, y: 0), hitRadius: 20),
            SelectionHandleLayout.Item(handle: .left, center: CGPoint(x: 10, y: 0), hitRadius: 20)
        ]
        let first = SelectionHandleLayout.hit(at: CGPoint(x: 5, y: 0), in: items)
        let second = SelectionHandleLayout.hit(at: CGPoint(x: 5, y: 0), in: items)
        #expect(first == second, "同一输入必须给出同一结果")
        #expect(first == .top, "平手时保留先出现的手柄")
    }

    @Test("全部判定区之外返回 nil")
    func hitOutsideAllRegionsReturnsNil() {
        let items = [
            SelectionHandleLayout.Item(
                handle: .topLeft,
                center: CGPoint(x: 0, y: 0),
                hitRadius: 10
            )
        ]
        #expect(SelectionHandleLayout.hit(at: CGPoint(x: 50, y: 50), in: items) == nil)
        #expect(
            SelectionHandleLayout.hit(at: CGPoint(x: 11, y: 0), in: items) == nil,
            "恰好超出半径即不命中（判定是小于等于）"
        )
        #expect(
            SelectionHandleLayout.hit(at: CGPoint(x: 10, y: 0), in: items) == .topLeft,
            "恰好落在半径上应命中"
        )
    }

    @Test("命中判定用 Chebyshev 距离：沿边界方向的方形邻域")
    func hitUsesChebyshevDistance() {
        let items = [
            SelectionHandleLayout.Item(
                handle: .top,
                center: CGPoint(x: 0, y: 0),
                hitRadius: 10
            )
        ]
        // Chebyshev：(9, 9) 的距离是 9 ≤ 10 → 命中；
        // 若误用欧氏距离，sqrt(162) ≈ 12.7 > 10 → 会脱靶。
        // 贴边拖动时指针常有斜向偏差，这决定了「贴着边拖会不会脱靶」。
        #expect(
            SelectionHandleLayout.hit(at: CGPoint(x: 9, y: 9), in: items) == .top,
            "必须用 Chebyshev 距离，否则贴边斜拖会脱靶"
        )
        #expect(SelectionHandleLayout.hit(at: CGPoint(x: 11, y: 0), in: items) == nil)
    }

    @Test("空布局不命中任何手柄")
    func emptyItemsNeverHit() {
        #expect(SelectionHandleLayout.hit(at: .zero, in: []) == nil)
    }
}

// MARK: - 臂长

@Suite("选区装饰 · 角括号臂长")
struct SelectionDecorationArmLengthTests {

    @Test("大选区用基准臂长")
    func largeSelectionUsesStandardArm() {
        let size = CGSize(width: 400, height: 300)
        #expect(decoration.armLength(for: size, cornerRadius: 0) == decoration.cornerArmLength)
    }

    @Test("小选区的臂长按短边收窄，避免括号占满整圈")
    func smallSelectionShrinksArm() {
        // 实测 58×42pt 的选区上 16pt 臂长会让蓝色边框只剩几段碎片
        let size = CGSize(width: 58, height: 42)
        let arm = decoration.armLength(for: size, cornerRadius: 0)
        #expect(arm < decoration.cornerArmLength, "小选区应把臂长收窄")
        #expect(arm > 0)
    }

    @Test("臂长不小于该角圆角半径")
    func armNeverShorterThanCornerRadius() {
        // 贴屏幕角时圆角可达 20pt+；臂长若仍是 16pt，
        // 边框沿屏幕圆弧走、白色括号却停在另一条弧上，圆弧会被截小。
        let size = CGSize(width: 400, height: 300)
        let radius: CGFloat = 24
        let arm = decoration.armLength(for: size, cornerRadius: radius)
        #expect(arm >= radius, "臂长必须覆盖圆角，否则括号圆弧与边框圆弧错位")
    }

    @Test("零尺寸选区臂长为零")
    func zeroSizeYieldsZeroArm() {
        #expect(decoration.armLength(for: .zero, cornerRadius: 0) == 0)
        #expect(decoration.armLength(for: CGSize(width: 0, height: 100), cornerRadius: 0) == 0)
    }
}
