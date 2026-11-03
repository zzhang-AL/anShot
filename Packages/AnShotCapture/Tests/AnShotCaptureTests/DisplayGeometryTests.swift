//
//  DisplayGeometryTests.swift
//  AnShotCaptureTests
//

import CoreGraphics
import Testing
@testable import AnShotCapture

@Suite("多显示器窗口归属")
struct DisplayGeometryTests {

    private let displays: [(id: CGDirectDisplayID, bounds: CGRect)] = [
        (1, CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        (2, CGRect(x: -1280, y: 0, width: 1280, height: 1024)),
        (3, CGRect(x: 2000, y: -100, width: 1000, height: 800))
    ]

    @Test("负坐标的左侧显示器和偏移的右侧显示器均可匹配")
    func displaysWithNegativeAndOffsetOrigins() {
        #expect(DisplayGeometry.displayContaining(
            CGRect(x: -1100, y: 100, width: 800, height: 600), in: displays
        ) == 2)
        #expect(DisplayGeometry.displayContaining(
            CGRect(x: 2100, y: 0, width: 600, height: 400), in: displays
        ) == 3)
    }

    @Test("窗口中心落在屏幕间隙时按最大相交面积选择")
    func centerInGapUsesLargestIntersection() {
        #expect(DisplayGeometry.displayContaining(
            CGRect(x: 1800, y: 0, width: 300, height: 400), in: displays
        ) == 1)
    }

    @Test("只接触屏幕边界而没有面积时不归属显示器")
    func touchingDisplayEdgeIsNotAnIntersection() {
        #expect(DisplayGeometry.displayContaining(
            CGRect(x: 1920, y: 0, width: 80, height: 100), in: displays
        ) == nil)
    }
}
