//
//  ScreenElementDetectorTests.swift
//  AnShotCaptureTests
//
//  窗口 Z-Order 排序、可见层级放宽、AX 碎片叶子归并规则与 DetectionSession 后台去抖查询单测。
//

import AnShotCore
import CoreGraphics
import Foundation
import Testing
@testable import AnShotCapture

@Suite("智能拾取 · Z-Order 与层级规则")
struct ScreenElementDetectorTests {

    private func makeWindow(id: CGWindowID, layer: Int = 0, pid: pid_t = 100) -> DetectedWindow {
        DetectedWindow(
            windowID: id,
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            layer: layer,
            title: "Win-\(id)",
            processID: pid,
            applicationName: "App-\(pid)"
        )
    }

    @Test("依据 CGWindowListCopyWindowInfo 权威 front-to-back 顺序重排窗口")
    func sortsWindowsByAuthoritativeZOrder() {
        let infoList: [[String: Any]] = [
            [kCGWindowNumber as String: NSNumber(value: 30)],
            [kCGWindowNumber as String: NSNumber(value: 10)],
            [kCGWindowNumber as String: NSNumber(value: 20)]
        ]
        let orderMap = SystemElementDetector.zOrderMap(from: infoList)

        let unordered = [
            makeWindow(id: 10),
            makeWindow(id: 99),
            makeWindow(id: 20),
            makeWindow(id: 30),
            makeWindow(id: 88)
        ]
        let sorted = SystemElementDetector.sortWindowsByZOrder(unordered, orderMap: orderMap)
        // 在权威榜上的按前到后排列，未上榜的维持原有相对顺序置于末尾。
        #expect(sorted.map(\.windowID) == [30, 10, 20, 99, 88])
    }

    @Test("允许普通窗与置顶浮动窗，排除负值桌面背板与屏保级及以上系统遮罩")
    func selectableLayerBounds() {
        #expect(SystemElementDetector.isSelectableLayer(0))
        #expect(SystemElementDetector.isSelectableLayer(Int(CGWindowLevelForKey(.floatingWindow))))
        #expect(SystemElementDetector.isSelectableLayer(Int(CGWindowLevelForKey(.modalPanelWindow))))
        #expect(SystemElementDetector.isSelectableLayer(Int(CGWindowLevelForKey(.popUpMenuWindow))))

        // 桌面背板与屏保遮罩必须被排除。
        #expect(!SystemElementDetector.isSelectableLayer(-2_147_483_622))
        #expect(!SystemElementDetector.isSelectableLayer(-1))
        #expect(!SystemElementDetector.isSelectableLayer(Int(CGWindowLevelForKey(.screenSaverWindow))))
    }

    @Test("过碎叶子角色或过小尺寸触发向上归并，遇到窗口或滚动大容器止步")
    func fragmentAscendAndStopRules() {
        let validFrame = CGRect(x: 10, y: 10, width: 100, height: 24)
        let tinyFrame = CGRect(x: 10, y: 10, width: 4, height: 12)

        #expect(SystemElementDetector.shouldAscendFromLeaf(role: "AXStaticText", frame: validFrame))
        #expect(SystemElementDetector.shouldAscendFromLeaf(role: "AXImage", frame: validFrame))
        #expect(SystemElementDetector.shouldAscendFromLeaf(role: "AXButton", frame: tinyFrame))
        #expect(!SystemElementDetector.shouldAscendFromLeaf(role: "AXButton", frame: validFrame))

        #expect(SystemElementDetector.shouldStopAscending(parentRole: "AXWindow"))
        #expect(SystemElementDetector.shouldStopAscending(parentRole: "AXApplication"))
        #expect(SystemElementDetector.shouldStopAscending(parentRole: "AXScrollArea"))
        #expect(!SystemElementDetector.shouldStopAscending(parentRole: "AXButton"))
        #expect(!SystemElementDetector.shouldStopAscending(parentRole: "AXGroup"))
    }
}

@Suite("识别会话 · 权限缓存与后台去抖")
struct DetectionSessionAsyncTests {

    private final class MockDetector: ScreenElementDetecting, @unchecked Sendable {
        private let lock = NSLock()
        private var _permission: Bool
        private var _windows: [DetectedWindow]
        private(set) var permissionCheckCount = 0
        private(set) var controlLookupPoints: [CGPoint] = []

        init(permission: Bool, windows: [DetectedWindow]) {
            self._permission = permission
            self._windows = windows
        }

        var hasAccessibilityPermission: Bool {
            lock.withLock {
                permissionCheckCount += 1
                return _permission
            }
        }

        func setPermission(_ value: Bool) {
            lock.withLock { _permission = value }
        }

        func windows(onDisplay displayID: CGDirectDisplayID) async throws -> [DetectedWindow] {
            lock.withLock { _windows }
        }

        func control(atGlobalPoint point: CGPoint, inApplication processID: pid_t) -> ControlHit? {
            lock.withLock { controlLookupPoints.append(point) }
            return ControlHit(
                frame: CGRect(x: point.x - 20, y: point.y - 10, width: 80, height: 32),
                role: "AXButton"
            )
        }
    }

    @MainActor
    @Test("load() 缓存辅助功能权限，即时窗口命中不触发 AX IPC，去抖只执行最新坐标")
    func cachesPermissionAndDebouncesControlLookup() async throws {
        let displayBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = DetectedWindow(
            windowID: 42,
            frame: CGRect(x: 100, y: 100, width: 800, height: 600),
            layer: 0,
            title: "Editor",
            processID: 555,
            applicationName: "Editor"
        )
        let detector = MockDetector(permission: true, windows: [window])
        let session = DetectionSession(detector: detector, displayID: 1, displayBounds: displayBounds)
        await session.load()

        let checksAfterLoad = detector.permissionCheckCount
        #expect(session.canDetectControls)
        // 阶段一即时命中不触发权限 IPC，也不触发控件 AX IPC。
        let immediate = session.immediateTarget(atGlobalPoint: CGPoint(x: 200, y: 200), preference: .automatic)
        #expect(immediate?.layer == .window)
        #expect(detector.permissionCheckCount == checksAfterLoad)
        #expect(detector.controlLookupPoints.isEmpty)

        // 快速连发三次坐标：前两次应当被去抖取消，只有最后一次执行控件识别。
        var updates: [DetectionTarget?] = []
        session.scheduleControlTarget(
            atGlobalPoint: CGPoint(x: 210, y: 210),
            preference: .automatic,
            debounce: .milliseconds(30)
        ) { updates.append($0) }
        session.scheduleControlTarget(
            atGlobalPoint: CGPoint(x: 220, y: 220),
            preference: .automatic,
            debounce: .milliseconds(30)
        ) { updates.append($0) }
        session.scheduleControlTarget(
            atGlobalPoint: CGPoint(x: 250, y: 260),
            preference: .automatic,
            debounce: .milliseconds(30)
        ) { updates.append($0) }

        let deadline = ContinuousClock.now + .seconds(2)
        while updates.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(updates.count == 1)
        #expect(updates.first??.layer == .control)
        #expect(detector.controlLookupPoints == [CGPoint(x: 250, y: 260)])

        // 关闭权限后刷新缓存，不再发起 AX 查询。
        detector.setPermission(false)
        session.refreshAccessibilityPermission()
        #expect(!session.canDetectControls)
        let resolved = await session.resolveTargetAsync(atGlobalPoint: CGPoint(x: 300, y: 300), preference: .automatic)
        #expect(resolved?.layer == .window)
        #expect(detector.controlLookupPoints.count == 1)
    }

    @MainActor
    @Test("普通区域模式抑制最大化窗口吸附且不穿透底层半屏窗口，窗体候选栈按 Z-order 完整返回")
    func suppressesMaximizedWindowAndReturnsOrderedWindowCandidates() async {
        let displayBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // 顶层最大化窗口：占满 96% 宽、94% 高、90% 面积
        let maximized = DetectedWindow(
            windowID: 100,
            frame: CGRect(x: 20, y: 30, width: 1380, height: 850),
            layer: 0,
            title: "Safari",
            processID: 100,
            applicationName: "Safari"
        )
        // 底层半屏窗口：被最大化窗口完全遮挡
        let behind = DetectedWindow(
            windowID: 200,
            frame: CGRect(x: 100, y: 100, width: 600, height: 500),
            layer: 0,
            title: "Notes",
            processID: 200,
            applicationName: "Notes"
        )
        let detector = MockDetector(permission: false, windows: [maximized, behind])
        let session = DetectionSession(detector: detector, displayID: 1, displayBounds: displayBounds)
        session.suppressesMaximizedWindow = true
        await session.load()

        #expect(DetectionSession.isMaximizedLike(maximized.frame, in: displayBounds))
        #expect(!DetectionSession.isMaximizedLike(behind.frame, in: displayBounds))

        // 光标在重叠点：抑制最大化窗口后应返回 nil，既不吸附 Safari 也不穿透吸附 Notes。
        let hit = session.immediateTarget(atGlobalPoint: CGPoint(x: 300, y: 300), preference: .automatic)
        #expect(hit == nil)

        // 独立窗体模式下 `windowCandidates` 按 Z-order 完整返回所有叠放窗口。
        let candidates = session.windowCandidates(atGlobalPoint: CGPoint(x: 300, y: 300))
        #expect(candidates.map(\.windowID) == [100, 200])
        #expect(candidates.first?.applicationName == "Safari")
        #expect(candidates.last?.applicationName == "Notes")
    }
}
