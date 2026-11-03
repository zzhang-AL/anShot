//
//  DetectionGeometryTests.swift
//  AnShotCoreTests
//
//  自动识别的坐标转换与聚合逻辑。
//
//  重点覆盖**副显示器负原点**这一路：开发机只有一台原点为 (0,0) 的显示器，
//  真实环境跑不到那条分支，只能靠这里的用例锁住行为。
//  这类偏差在多屏下表现为「高亮框和实际选中的区域差一个显示器原点」，
//  而单屏开发时永远看不到。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotCore

@Suite("识别几何")
struct DetectionGeometryTests {
    /// 主显示器：原点 (0,0)。
    private let mainBounds = CGRect(x: 0, y: 0, width: 1470, height: 956)

    /// 副显示器：**原点为负**，位于主显示器左侧。
    /// 这是 macOS 多屏的常见布局，也是转换最容易写错的地方。
    private let leftBounds = CGRect(x: -1920, y: -180, width: 1920, height: 1080)

    // MARK: - 全局 → 显示器内

    @Test("原点为零的显示器")
    func 主屏转换() {
        let global = CGRect(x: 100, y: 200, width: 300, height: 150)
        let local = DetectionGeometry.localRect(fromGlobal: global, displayBounds: mainBounds)
        #expect(local == CGRect(x: 100, y: 200, width: 300, height: 150))
    }

    @Test("负原点的显示器")
    func 副屏转换() {
        // 副屏左上角：全局 (-1920, -180) → 显示器内 (0, 0)
        let corner = DetectionGeometry.localRect(
            fromGlobal: CGRect(x: -1920, y: -180, width: 10, height: 10),
            displayBounds: leftBounds
        )
        #expect(corner == CGRect(x: 0, y: 0, width: 10, height: 10))

        // 副屏内靠右下的一块：全局 (-200, 100) → 显示器内 (1720, 280)
        let inner = DetectionGeometry.localRect(
            fromGlobal: CGRect(x: -200, y: 100, width: 50, height: 40),
            displayBounds: leftBounds
        )
        #expect(inner == CGRect(x: 1720, y: 280, width: 50, height: 40))
    }

    @Test("负原点显示器上的原点矩形落在边界外")
    func 副屏外一点为负() {
        // 主屏原点 (0,0) 相对副屏是 (1920, 180)，即副屏右侧之外。
        let local = DetectionGeometry.localRect(
            fromGlobal: CGRect(x: 0, y: 0, width: 10, height: 10),
            displayBounds: leftBounds
        )
        #expect(local.origin.x == 1920)
        #expect(local.origin.y == 180)
        // 越界应当由 intersection 负责裁掉，转换本身如实平移。
    }

    @Test("本地与全局互为逆运算")
    func 往返一致() {
        let original = CGRect(x: -500, y: 300, width: 200, height: 100)
        let local = DetectionGeometry.localRect(fromGlobal: original, displayBounds: leftBounds)
        let back = DetectionGeometry.globalRect(fromLocal: local, displayBounds: leftBounds)
        #expect(back == original)
    }

    // MARK: - 外接矩形

    @Test("多个窗口的外接矩形")
    func 外接矩形() {
        let rects = [
            CGRect(x: 100, y: 100, width: 200, height: 150),
            CGRect(x: 500, y: 300, width: 120, height: 80),
            CGRect(x: 150, y: 500, width: 60, height: 60)
        ]
        let box = DetectionGeometry.boundingBox(of: rects)
        // minX=100, minY=100, maxX=620, maxY=560
        #expect(box == CGRect(x: 100, y: 100, width: 520, height: 460))
    }

    @Test("单个矩形是它自己的外接矩形")
    func 单矩形外接() {
        let single = CGRect(x: 40, y: 50, width: 60, height: 70)
        #expect(DetectionGeometry.boundingBox(of: [single]) == single)
    }

    @Test("空集合没有外接矩形")
    func 空集合() {
        // 返回 nil 而不是零矩形：调用方要据此退回下一层，
        // 拿到面积 0 的选区会被不变量判定为非法。
        #expect(DetectionGeometry.boundingBox(of: []) == nil)
    }

    @Test("退化矩形没有外接矩形")
    func 零面积() {
        let degenerate = CGRect(x: 10, y: 10, width: 0, height: 50)
        #expect(DetectionGeometry.boundingBox(of: [degenerate]) == nil)
    }

    // MARK: - 裁剪

    @Test("越界矩形被裁到显示器内")
    func 裁剪越界() {
        let result = DetectionGeometry.intersection(
            CGRect(x: 1400, y: 900, width: 500, height: 500),
            with: mainBounds
        )
        #expect(result == CGRect(x: 1400, y: 900, width: 70, height: 56))
    }

    @Test("完全在外的矩形被丢弃")
    func 完全在外() {
        let result = DetectionGeometry.intersection(
            CGRect(x: 5000, y: 5000, width: 100, height: 100),
            with: mainBounds
        )
        #expect(result == nil)
    }

    @Test("亚像素交集被丢弃")
    func 亚像素交集() {
        // 只擦到 0.4 像素：捕获时取不到整像素，视为未命中。
        let result = DetectionGeometry.intersection(
            CGRect(x: 1469.6, y: 100, width: 50, height: 50),
            with: mainBounds
        )
        #expect(result == nil)
    }

    // MARK: - 先裁后并

    @Test("跨屏窗口只保留本屏部分")
    func 跨屏窗口裁剪() {
        // 一个横跨主屏与左侧副屏的窗口。
        let spanning = CGRect(x: -400, y: 100, width: 600, height: 300)

        let onLeft = DetectionGeometry.clampedLocalBounds(
            ofGlobalRects: [spanning],
            displayBounds: leftBounds
        )
        // 副屏右边界是 -1920 + 1920 = 0，所以窗口在副屏上的部分是
        // x ∈ [-400, 0)，宽 400；换算到显示器内即 x ∈ [1520, 1920)。
        #expect(onLeft == CGRect(x: 1520, y: 280, width: 400, height: 300))

        let onMain = DetectionGeometry.clampedLocalBounds(
            ofGlobalRects: [spanning],
            displayBounds: mainBounds
        )
        // 主屏部分是 x ∈ [0,200)
        #expect(onMain == CGRect(x: 0, y: 100, width: 200, height: 300))
    }

    @Test("必须先裁剪再求外接矩形")
    func 顺序不可颠倒() {
        // 两个矩形：一个在本屏内，一个完全在另一屏。
        // 若先求外接矩形再裁剪，结果会被远方那个撑到屏幕边缘。
        let inScreen = CGRect(x: 100, y: 100, width: 200, height: 100)
        let otherScreen = CGRect(x: -1900, y: 100, width: 100, height: 100)

        let result = DetectionGeometry.clampedLocalBounds(
            ofGlobalRects: [inScreen, otherScreen],
            displayBounds: mainBounds
        )
        #expect(result == CGRect(x: 100, y: 100, width: 200, height: 100))
    }

    @Test("应用的全部窗口都在别的屏上时无结果")
    func 应用在别屏() {
        let otherScreenWindows = [
            CGRect(x: -1800, y: 100, width: 300, height: 200),
            CGRect(x: -1000, y: 400, width: 300, height: 200)
        ]
        let result = DetectionGeometry.clampedLocalBounds(
            ofGlobalRects: otherScreenWindows,
            displayBounds: mainBounds
        )
        #expect(result == nil)
    }

    // MARK: - 识别结果

    @Test("识别结果保留层级与标题")
    func 结果模型() {
        let target = DetectionTarget(
            layer: .application,
            rect: CGRect(x: 10, y: 20, width: 30, height: 40),
            displayID: 1,
            title: "Xcode"
        )
        #expect(target.layer == .application)
        #expect(target.title == "Xcode")
        #expect(target.rect == CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    @Test("层级顺序由内到外")
    func 层级顺序() {
        // CaseIterable 的顺序即优先级：控件最内，显示器最外。
        #expect(DetectionTarget.Layer.allCases == [.control, .window, .application, .display])
    }
}
