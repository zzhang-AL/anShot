//
//  ScreenElementDetector.swift
//  AnShotCapture
//
//  屏幕元素识别：窗口、应用、界面控件。
//
//  这是「平台能力」层：它只回答「屏幕上有什么、各自在哪」，
//  不做任何交互决策（什么时候识别、识别结果怎么用，属于 UI 层）。
//  分开是因为识别依赖辅助功能权限与 ScreenCaptureKit，
//  而「什么时候该识别」是纯粹的产品逻辑——两者的测试方式完全不同。
//

import AnShotCore
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// 一个可识别的窗口。
///
/// 只保留识别需要的字段。刻意不持有 `SCWindow` 本身：
/// 那个对象与一次枚举的生命周期绑定，持有它会让过期数据留在调用方手里。
public struct DetectedWindow: Equatable, Sendable {
    public let windowID: CGWindowID
    /// 全局左上原点**点**坐标（与 `SCWindow.frame` 一致）。
    public let frame: CGRect
    public let layer: Int
    public let title: String?
    public let processID: pid_t
    public let applicationName: String?

    public init(
        windowID: CGWindowID,
        frame: CGRect,
        layer: Int,
        title: String?,
        processID: pid_t,
        applicationName: String?
    ) {
        self.windowID = windowID
        self.frame = frame
        self.layer = layer
        self.title = title
        self.processID = processID
        self.applicationName = applicationName
    }
}

/// 一次控件命中的结果（可选携带沿 AX 父级链收集到的面积递增祖先容器，供滚轮逐层扩大/缩小）。
public struct ControlHit: Equatable, Sendable {
    /// 全局左上原点屏幕坐标下的控件矩形。
    public let frame: CGRect
    /// AX 角色，例如 `AXButton`；读不到时为 `nil`。
    public let role: String?
    /// 包含当前点的祖先容器链（由内到外、面积递增，不含自身）。
    public let ancestors: [ControlAncestor]

    public struct ControlAncestor: Equatable, Sendable {
        public let frame: CGRect
        public let role: String?

        public init(frame: CGRect, role: String?) {
            self.frame = frame
            self.role = role
        }
    }

    public init(frame: CGRect, role: String?, ancestors: [ControlAncestor] = []) {
        self.frame = frame
        self.role = role
        self.ancestors = ancestors
    }
}

/// 识别失败的原因。
public enum DetectionError: Error, LocalizedError {
    /// 取不到可共享内容（通常是屏幕录制权限问题）。
    case shareableContentUnavailable
    /// 指定的显示器不在当前可共享内容里。
    case displayUnavailable(CGDirectDisplayID)

    public var errorDescription: String? {
        switch self {
        case .shareableContentUnavailable:
            return "无法读取屏幕内容，请确认屏幕录制权限"
        case let .displayUnavailable(displayID):
            return "找不到显示器 \(displayID)"
        }
    }
}

/// 屏幕元素识别能力。
public protocol ScreenElementDetecting: AnyObject, Sendable {
    /// 是否具备辅助功能权限（组件级识别的前提）。
    var hasAccessibilityPermission: Bool { get }

    /// 枚举指定显示器上可识别的窗口。
    ///
    /// 已过滤掉系统层窗口（壁纸、菜单栏背板等）与本进程自己的窗口。
    func windows(onDisplay displayID: CGDirectDisplayID) async throws -> [DetectedWindow]

    /// 在指定应用内命中界面控件。
    ///
    /// **必须指定目标应用，不能用 system-wide 元素。** 覆盖层是
    /// `level = .screenSaver` 的全屏面板、永远在最顶层，而 AX 命中测试
    /// 按窗口 z-order 进行——用 system-wide 元素时命中的永远是覆盖层自己
    /// （角色 `AXWindow`、矩形等于整屏），控件层于是永远返回整屏，
    /// 窗口层根本轮不到。实测日志正是如此。
    ///
    /// 传入目标应用的 AX 元素后，命中范围被限制在该应用内部，天然避开覆盖层。
    ///
    /// - Parameters:
    ///   - point: 全局左上原点屏幕坐标
    ///   - processID: 目标应用的进程号；通常来自鼠标下窗口的 `owningApplication`
    /// - Returns: 控件信息；无权限、该应用不接受 AX 或该点无控件时为 `nil`
    func control(atGlobalPoint point: CGPoint, inApplication processID: pid_t) -> ControlHit?
}

/// 基于 ScreenCaptureKit 与辅助功能 API 的实现。
///
/// 仅持有不可变值属性 `ownProcessID`，无需 `@unchecked Sendable`。
public final class SystemElementDetector: ScreenElementDetecting {
    /// 本进程 pid：用于把自己的窗口排除在识别结果之外。
    ///
    /// **这一步不能省。** 覆盖层本身就是本进程的一个（或多个）窗口，
    /// 它会出现在 `SCShareableContent.windows` 里；不过滤的话，
    /// 鼠标一移动就可能「识别到自己」，选中框永远是整屏。
    private let ownProcessID: pid_t

    /// 跨进程 AX IPC 单次超时上限（秒），杜绝无响应应用冻结主线程 6 秒。
    static let axMessagingTimeoutSeconds: Float = 0.04

    /// 允许向上回溯归并的碎片叶子与透明包装角色。
    static let fragmentLeafRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXImageRole as String,
        "AXUnknown"
    ]

    /// 高语义独立交互/卡片控件角色（遇到此类节点时优先吸附，不再盲目外扩）。
    static let semanticControlRoles: Set<String> = [
        kAXButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String,
        kAXMenuButtonRole as String,
        kAXComboBoxRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        "AXSearchField",
        kAXToolbarRole as String,
        kAXTabGroupRole as String,
        kAXCellRole as String,
        kAXRowRole as String,
        "AXOutlineRow",
        kAXSheetRole as String,
        "AXPopover",
        kAXMenuRole as String,
        kAXMenuItemRole as String
    ]

    /// 透明布局包装角色（常包在文字/图标外层，若其父级为高语义控件则继续穿透归并）。
    static let wrapperGroupRoles: Set<String> = [
        kAXGroupRole as String,
        "AXGenericElement",
        "AXLink"
    ]

    /// 回溯归并时应当止步的顶层/大容器角色，避免把控件直接放大成整个窗口。
    static let stopAscendRoles: Set<String> = [
        kAXWindowRole as String,
        kAXApplicationRole as String,
        kAXScrollAreaRole as String,
        "AXWebArea",
        kAXSplitGroupRole as String
    ]

    /// 向上回溯的最大层数（覆盖现代 Electron / Chromium / SwiftUI 深层嵌套包装）。
    static let maxAscendDepth = 6

    public init(ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.ownProcessID = ownProcessID
    }

    // MARK: - 权限

    public var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - 窗口枚举

    public func windows(onDisplay displayID: CGDirectDisplayID) async throws -> [DetectedWindow] {
        let content: SCShareableContent
        do {
            // onScreenWindowsOnly: true —— 只枚举屏幕上的窗口。
            // 用 false 会连同最小化、离屏窗口一起枚举，实测耗时差两个数量级
            // （约 1895ms vs 8.5ms），而识别根本用不到那些窗口。
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            throw DetectionError.shareableContentUnavailable
        }

        guard content.displays.contains(where: { $0.displayID == displayID }) else {
            throw DetectionError.displayUnavailable(displayID)
        }

        let detected = content.windows
            .filter { isSelectable($0, onDisplay: displayID) }
            .map { window in
                DetectedWindow(
                    windowID: window.windowID,
                    frame: window.frame,
                    layer: window.windowLayer,
                    title: window.title,
                    processID: window.owningApplication?.processID ?? 0,
                    applicationName: window.owningApplication?.applicationName
                )
            }

        // SCShareableContent.windows 不保证按屏幕 Z-Order 排序，
        // 必须结合 CGWindowListCopyWindowInfo 的权威前到后顺序表重排。
        let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        let orderMap = Self.zOrderMap(from: windowInfoList)
        return Self.sortWindowsByZOrder(detected, orderMap: orderMap)
    }

    /// 判断窗口层号是否属于可拾取的可见用户窗口层级。
    ///
    /// 放宽 `windowLayer == 0` 的限制，允许拾取置顶浮动窗口、模态面板与弹出菜单，
    /// 同时排除负值桌面背板（Wallpaper / Backstop）以及屏保/系统顶层遮罩。
    static func isSelectableLayer(_ layer: Int) -> Bool {
        let screenSaverLayer = Int(CGWindowLevelForKey(.screenSaverWindow))
        return layer >= 0 && layer < screenSaverLayer
    }

    /// 从 `CGWindowListCopyWindowInfo` 输出提取权威的 front-to-back 索引表。
    static func zOrderMap(from windowInfoList: [[String: Any]]?) -> [CGWindowID: Int] {
        guard let windowInfoList else { return [:] }
        var map: [CGWindowID: Int] = [:]
        map.reserveCapacity(windowInfoList.count)
        for (index, info) in windowInfoList.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            let windowID = CGWindowID(number.uint32Value)
            if map[windowID] == nil {
                map[windowID] = index
            }
        }
        return map
    }

    /// 按权威 Z-Order（前到后）重排窗口列表；未出现在索引表中的窗口维持原有相对顺序置于末尾。
    static func sortWindowsByZOrder(
        _ windows: [DetectedWindow],
        orderMap: [CGWindowID: Int]
    ) -> [DetectedWindow] {
        windows.enumerated().sorted { lhs, rhs in
            let leftOrder = orderMap[lhs.element.windowID] ?? Int.max
            let rightOrder = orderMap[rhs.element.windowID] ?? Int.max
            if leftOrder != rightOrder {
                return leftOrder < rightOrder
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 某个窗口是否应当作为识别候选。
    ///
    /// 三条过滤缺一不可：
    /// - 合理可见层级：排除负值桌面背板与全屏级以上系统遮罩，支持置顶浮动窗口。
    /// - `owningApplication != nil`：拿不到归属应用的条目没有意义，
    ///   也无法参与应用级聚合。
    /// - 排除本进程：见 `ownProcessID` 的说明。
    private func isSelectable(_ window: SCWindow, onDisplay displayID: CGDirectDisplayID) -> Bool {
        guard Self.isSelectableLayer(window.windowLayer) else {
            return false
        }
        guard let application = window.owningApplication else {
            return false
        }
        guard application.processID != ownProcessID else {
            return false
        }
        guard window.frame.width >= 1, window.frame.height >= 1 else {
            return false
        }
        // 窗口至少要和目标显示器有重合，否则不参与本屏识别。
        return window.frame.intersects(DisplayGeometry.bounds(for: displayID))
    }

    // MARK: - 控件识别

    public func control(atGlobalPoint point: CGPoint, inApplication processID: pid_t) -> ControlHit? {
        // 无权限时直接返回 nil，让调用方降级到窗口层。
        // 不去调 AX 接口：没有权限时它只会返回 -25211，
        // 白白走一次跨进程调用，也让日志里堆满噪声。
        guard hasAccessibilityPermission else {
            return nil
        }

        // 用目标应用的元素而不是 system-wide：见协议里的说明。
        let application = AXUIElementCreateApplication(processID)
        // 为应用句柄与后续命中的元素设置 40ms IPC 硬超时，彻底避免卡顿应用阻塞 6 秒。
        AXUIElementSetMessagingTimeout(application, Self.axMessagingTimeoutSeconds)

        var element: AXUIElement?
        // 坐标是**左上原点**的全局屏幕坐标（AXUIElement.h:334）。
        // 覆盖层视图的坐标也是左上原点，因此这里不需要翻转 y。
        let error = AXUIElementCopyElementAtPosition(
            application,
            Float(point.x),
            Float(point.y),
            &element
        )
        guard error == .success, let element else {
            return nil
        }

        return resolveControlHit(startingAt: element, queryPoint: point)
    }

    /// 一次性读取元素的 Position / Size / Role / Parent，并在命中过碎叶子/包装层时智能向上归并（限 6 层），
    /// 同时收集面积严格递增的合法父级链供滚轮逐层放大/缩小，并强制校验每个候选框必须包含鼠标坐标。
    private func resolveControlHit(startingAt element: AXUIElement, queryPoint: CGPoint) -> ControlHit? {
        guard var currentSnapshot = readSnapshot(of: element) else {
            return nil
        }

        // 收集从内到外全部合法且包含鼠标点的节点。
        var chain: [(frame: CGRect, role: String?)] = []
        func appendIfEligible(frame: CGRect?, role: String?) {
            guard let frame,
                  Self.isValidControlFrame(frame),
                  frame.insetBy(dx: -4, dy: -4).contains(queryPoint) else {
                return
            }
            // 与上一层几乎同框时：仅当新节点语义更强时替换，否则去重跳过。
            if let last = chain.last,
               abs(last.frame.minX - frame.minX) <= 2,
               abs(last.frame.minY - frame.minY) <= 2,
               abs(last.frame.width - frame.width) <= 4,
               abs(last.frame.height - frame.height) <= 4 {
                if let role, Self.semanticControlRoles.contains(role),
                   !(last.role.map(Self.semanticControlRoles.contains) ?? false) {
                    chain[chain.count - 1] = (frame, role)
                }
                return
            }
            chain.append((frame, role))
        }

        appendIfEligible(frame: currentSnapshot.frame, role: currentSnapshot.role)

        // 决定默认最合适的起点索引：
        // 若起点本身是非碎片、非包装的语义控件，先锁定它，但仍可继续向上采集祖先链供滚轮扩展。
        var preferredIndex: Int? = chain.isEmpty ? nil : 0
        var stillSeekingPreferred = (preferredIndex == nil)
            || Self.shouldAscendFromLeaf(role: currentSnapshot.role, frame: currentSnapshot.frame)
            || (currentSnapshot.role.map(Self.wrapperGroupRoles.contains) ?? false)

        var depth = 0
        var parentElement = currentSnapshot.parent
        while depth < Self.maxAscendDepth, let parent = parentElement {
            depth += 1
            guard let parentSnapshot = readSnapshot(of: parent) else {
                break
            }
            if Self.shouldStopAscending(parentRole: parentSnapshot.role) {
                break
            }

            let countBefore = chain.count
            appendIfEligible(frame: parentSnapshot.frame, role: parentSnapshot.role)
            let addedOrReplaced = chain.count > countBefore || (countBefore > 0 && chain[countBefore - 1].role == parentSnapshot.role)

            if stillSeekingPreferred, addedOrReplaced, !chain.isEmpty {
                let candidateIdx = chain.count - 1
                let candidate = chain[candidateIdx]
                let isSemantic = candidate.role.map(Self.semanticControlRoles.contains) ?? false
                let isWrapper = candidate.role.map(Self.wrapperGroupRoles.contains) ?? false
                let isLeaf = Self.shouldAscendFromLeaf(role: candidate.role, frame: candidate.frame)

                if let prevIdx = preferredIndex, prevIdx < candidateIdx {
                    let prevArea = chain[prevIdx].frame.width * chain[prevIdx].frame.height
                    let nextArea = candidate.frame.width * candidate.frame.height
                    // 防止为了归并一个小文字，把候选直接放大成 25 倍以上的巨型背景板。
                    let hugeJump = prevArea > 0 && (nextArea / prevArea > 25) && nextArea > 90_000
                    if !hugeJump || isSemantic {
                        preferredIndex = candidateIdx
                    }
                } else {
                    preferredIndex = candidateIdx
                }

                if isSemantic || (!isLeaf && !isWrapper) {
                    stillSeekingPreferred = false
                }
            }

            currentSnapshot = parentSnapshot
            parentElement = currentSnapshot.parent
        }

        guard let idx = preferredIndex, idx < chain.count else {
            return nil
        }
        let chosen = chain[idx]
        let ancestors = chain.dropFirst(idx + 1).map {
            ControlHit.ControlAncestor(frame: $0.frame, role: $0.role)
        }
        return ControlHit(frame: chosen.frame, role: chosen.role, ancestors: ancestors)
    }

    /// 判断节点尺寸是否满足控件最小有效阈值（过滤微小图标碎片、分隔线与细长滚动条）。
    static func isValidControlFrame(_ frame: CGRect) -> Bool {
        let width = frame.width
        let height = frame.height
        guard width >= 18, height >= 18 else { return false }
        let area = width * height
        guard area >= 480 else { return false }
        let shortSide = min(width, height)
        let longSide = max(width, height)
        // 过滤极细长分隔线 / 滚动条槽（如 1400×18 或 18×800）。
        if shortSide < 24, longSide / shortSide > 16 {
            return false
        }
        return true
    }

    /// 判断当前命中节点是否属于需要向上归并的碎片叶子或过小节点。
    static func shouldAscendFromLeaf(role: String?, frame: CGRect?) -> Bool {
        if let frame, !isValidControlFrame(frame) {
            return true
        }
        guard let role else { return false }
        return fragmentLeafRoles.contains(role)
    }

    /// 判断父节点是否已越过控件边界进入窗口或顶层大容器。
    static func shouldStopAscending(parentRole: String?) -> Bool {
        guard let parentRole else { return false }
        return stopAscendRoles.contains(parentRole)
    }

    /// 单个元素属性快照。
    private struct AXElementSnapshot {
        let frame: CGRect?
        let role: String?
        let parent: AXUIElement?
    }

    /// 使用 `AXUIElementCopyMultipleAttributeValues` 将 Position / Size / Role / Parent 合并为 1 次 IPC。
    private func readSnapshot(of element: AXUIElement) -> AXElementSnapshot? {
        AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeoutSeconds)

        let attributes = [
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
            kAXRoleAttribute as CFString,
            kAXParentAttribute as CFString
        ] as CFArray

        var valuesRef: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes,
            AXCopyMultipleAttributeOptions(),
            &valuesRef
        )
        guard status == .success,
              let values = valuesRef as? [AnyObject],
              values.count == 4 else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        let frame: CGRect?
        if CFGetTypeID(values[0]) == AXValueGetTypeID(),
           CFGetTypeID(values[1]) == AXValueGetTypeID(),
           AXValueGetValue(values[0] as! AXValue, .cgPoint, &origin),
           AXValueGetValue(values[1] as! AXValue, .cgSize, &size) {
            frame = CGRect(origin: origin, size: size)
        } else {
            frame = nil
        }

        let role = values[2] as? String
        let parent: AXUIElement?
        if CFGetTypeID(values[3]) == AXUIElementGetTypeID() {
            parent = (values[3] as! AXUIElement)
        } else {
            parent = nil
        }

        return AXElementSnapshot(frame: frame, role: role, parent: parent)
    }

}

// MARK: - 应用聚合

public extension SystemElementDetector {
    /// 某个 pid 在指定显示器内的全部窗口。
    ///
    /// 供应用级识别使用；窗口之间可能有别的东西（其它应用、桌面），
    /// 但外接矩形只关心最外边界。
    func windows(
        ofProcess pid: pid_t,
        onDisplay displayID: CGDirectDisplayID
    ) async throws -> [DetectedWindow] {
        try await windows(onDisplay: displayID).filter { $0.processID == pid }
    }
}
