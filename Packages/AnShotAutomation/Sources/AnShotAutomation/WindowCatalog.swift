//
//  WindowCatalog.swift
//  AnShotAutomation
//
//  窗口枚举与「按应用名解析目标窗口」。
//
//  ── 为什么需要它 ──────────────────────────────────────────────
//
//  只按显示器截图有一个硬约束：**内容必须是当前屏幕上可见的东西**。
//  而 AI 与脚本真正经常要的是「那个应用的窗口」——它可能被别的窗口盖住、
//  可能不在最顶层，甚至可能只露出一角。这类需求用「显示器 + 区域」表达不了：
//  区域坐标需要调用方先知道窗口在哪，而它恰恰看不到（看不到才要截图）。
//
//  所以这里提供「窗口」这一层寻址，与 `DisplayCatalog` 的「显示器」平行：
//
//      list_windows → window_id / app → capture_screenshot 按窗口截
//
//  ── 与 ScreenCaptureKit 的关系（重要）─────────────────────────
//
//  `CGWindowID` 与 `SCWindow.windowID` 是**同一个标识**，因此本文件枚举出的
//  ID 可以直接喂给 `CaptureScope.window`，不需要任何映射表。
//
//  枚举刻意使用 `CGWindowListCopyWindowInfo` 而非 `SCShareableContent`：
//  后者在有窗口被遮挡或系统繁忙时会整体失败（抛错即拿不到任何列表），
//  而前者是纯查询、不依赖捕获管道，失败时只返回空数组。
//
//  ── 标题字段的可见性（如实声明）───────────────────────────────
//
//  `kCGWindowName`（窗口标题）受屏幕录制权限管控：无权限的进程读到的是空串。
//  而 `kCGWindowOwnerName`（应用名）不受限，任何进程都能拿到。
//
//  因此本模块的使用方式是：**在拥有权限的进程（anShot.app）里枚举**，
//  才能得到可读的标题。MCP/CLI 侧一律经 `OutOfProcessCapture` 让 app 去枚举，
//  不就地调用——就地调用会得到一堆「有应用名、没标题」的窗口，
//  调用方据此选窗口只能靠猜。
//

import AnShotCapture
import CoreGraphics
import Foundation

/// 单个窗口的可序列化描述。
///
/// 字段单位约定与 `DisplayInfo` 保持一致（调用方是 AI，只能靠返回值自描述）：
/// `frame` 是**全局逻辑点、原点在主屏左上**，与 `CGWindowBounds` 同语义。
public struct WindowInfo: Codable, Sendable, Equatable {

    /// `CGWindowID`。截图时用它指定目标。
    public let id: UInt32

    /// 所属应用名（`kCGWindowOwnerName`）。不受屏幕录制权限限制。
    public let appName: String

    /// 窗口标题。**需要屏幕录制权限**，无权限时为空字符串。
    public let title: String?

    /// 所属进程 ID。
    public let pid: Int32

    /// 窗口层级。普通应用窗口为 0；菜单栏/Dock/悬浮面板为其它值。
    public let layer: Int

    /// 是否在当前可见的桌面上（被遮挡仍算在屏）。
    /// false 也可能表示窗口最小化、隐藏或位于其他桌面，不能仅凭此字段区分。
    public let isOnScreen: Bool

    /// 窗口在全局显示坐标系中的矩形（逻辑点，原点主屏左上）。
    public let frame: Rect

    /// 窗口所在显示器（按 frame 中心判定）；无归属时为 nil。
    public let displayID: UInt32?

    /// 窗口所属桌面 ID；系统无法查询时为 nil，窗口可能属于多个桌面。
    public let spaceIDs: [UInt64]?

    func withSpaceIDs(_ values: [UInt64]?) -> WindowInfo {
        WindowInfo(
            id: id, appName: appName, title: title, pid: pid, layer: layer,
            isOnScreen: isOnScreen, frame: frame, displayID: displayID, spaceIDs: values
        )
    }

    /// 可序列化的矩形。不用 `CGRect` 直接编码的理由同 `DisplayInfo.Rect`。
    public struct Rect: Codable, Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }
}

/// 窗口目录。
public enum WindowCatalog {

    /// 小于这个尺寸的「窗口」不是用户认知里的窗口（图标、tooltip、分隔条）。
    ///
    /// 40 点：比它更小的可交互窗口在正常使用中不存在，而它足以滤掉
    /// 输入法候选框、拖拽指示器一类的辅助窗口。
    static let minimumSide: CGFloat = 40

    /// 枚举窗口。
    ///
    /// - Parameter onScreenOnly: true 时只返回当前在屏幕上的窗口（含被遮挡的）。
    ///   默认返回所有桌面的窗口，也可能包含最小化或隐藏的窗口。
    /// - Returns: 已按「在屏优先、面积降序」排好序的窗口列表。
    public static func all(onScreenOnly: Bool = false) -> [WindowInfo] {
        let options: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll, .excludeDesktopElements]

        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        let windows = rawList.compactMap { describe($0, ownPID: ownPID) }
        let spaces = DesktopCatalog.windowSpaceIDs(for: windows.map(\.id))
        return windows
            .map { $0.withSpaceIDs(spaces[$0.id]) }
            .sorted { lhs, rhs in
                if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
                let lhsArea = lhs.frame.width * lhs.frame.height
                let rhsArea = rhs.frame.width * rhs.frame.height
                return lhsArea > rhsArea
            }
    }

    /// 解析单条窗口记录；不合格（辅助窗口、尺寸过小、本进程自己的窗口）时返回 nil。
    static func describe(_ info: [String: Any], ownPID: Int32) -> WindowInfo? {
        // 逐键取值而不是 `CGRect(dictionaryRepresentation:)`：后者要 CFDictionary，
        // 而从 `Any` 条件转换到 CF 类型会被编译器判为「总是成功」并给出警告。
        guard let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
              let ownerName = info[kCGWindowOwnerName as String] as? String,
              !ownerName.isEmpty,
              let bounds = info[kCGWindowBounds as String] as? [String: NSNumber],
              let x = bounds["X"]?.doubleValue,
              let y = bounds["Y"]?.doubleValue,
              let width = bounds["Width"]?.doubleValue,
              let height = bounds["Height"]?.doubleValue else {
            return nil
        }

        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        // 本进程自己的窗口不该出现在候选里：真去截它会截到覆盖层或工具栏，
        // 而调用方（AI）无法从名字分辨那是不是「用户想看的东西」。
        guard pid != ownPID else { return nil }

        // 窗口层级：0 是普通应用窗口。Dock（~20）、菜单栏（24/25）、
        // 输入法候选（~1000）都必须排除，否则列表会被系统 UI 淹没。
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        guard layer == 0 else { return nil }

        // alpha 为 0 的窗口是「存在但不可见」的占位（很多应用会长期保留）。
        if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 {
            return nil
        }

        guard width >= Double(minimumSide), height >= Double(minimumSide) else { return nil }

        // optionAll 中非在屏窗口通常缺少此键；缺失不能当作 true。
        let isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false

        // 标题可能为空串（无权限，或窗口本就没有标题）。
        // 空串归一化成 nil，避免调用方把 "" 当成一个真实的标题去显示。
        let rawTitle = info[kCGWindowName as String] as? String
        let title = (rawTitle?.isEmpty == false) ? rawTitle : nil

        let frame = CGRect(x: x, y: y, width: width, height: height)
        let displayID = DisplayGeometry.displayContaining(frame)

        return WindowInfo(
            id: windowNumber.uint32Value,
            appName: ownerName,
            title: title,
            pid: pid,
            layer: layer,
            isOnScreen: isOnScreen,
            frame: WindowInfo.Rect(x: x, y: y, width: width, height: height),
            displayID: displayID,
            spaceIDs: nil
        )
    }

    /// 按窗口 ID 查询。
    ///
    /// 用 `.optionIncludingWindow` 精确查询：它只查这一个窗口，代价与列表枚举
    /// 无关，适合「已知 ID、只要确认它还在不在」的场景。
    ///
    /// 历史上这里有过一个缺陷：查询时带上 `.optionOnScreenOnly`，
    /// 于是**被完全遮挡的窗口查不到**——而那正是本功能要支持的场景
    /// （「不在最顶层的应用」）。所以这里刻意不带它。
    public static func info(for windowID: CGWindowID) -> WindowInfo? {
        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            windowID
        ) as? [[String: Any]] else {
            return nil
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in rawList where (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID {
            // 目标窗口由调用方显式指定，因此不做「辅助窗口」过滤：
            // 调用方说得出 ID，就说明它知道自己在要什么。
            // 仅排除本进程自己的窗口，理由同 `describe`。
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            guard pid != ownPID else { return nil }
            return describeRelaxed(info)
        }
        return nil
    }

    /// 不做层级/尺寸过滤的描述构造，供 `info(for:)` 使用。
    private static func describeRelaxed(_ info: [String: Any]) -> WindowInfo? {
        guard let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
              let ownerName = info[kCGWindowOwnerName as String] as? String,
              let bounds = info[kCGWindowBounds as String] as? [String: NSNumber],
              let x = bounds["X"]?.doubleValue,
              let y = bounds["Y"]?.doubleValue,
              let width = bounds["Width"]?.doubleValue,
              let height = bounds["Height"]?.doubleValue else {
            return nil
        }

        let rawTitle = info[kCGWindowName as String] as? String
        let frame = CGRect(x: x, y: y, width: width, height: height)

        return WindowInfo(
            id: windowNumber.uint32Value,
            appName: ownerName,
            title: (rawTitle?.isEmpty == false) ? rawTitle : nil,
            pid: (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
            layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
            frame: WindowInfo.Rect(x: x, y: y, width: width, height: height),
            displayID: DisplayGeometry.displayContaining(frame),
            spaceIDs: nil
        )
    }

    /// 按应用名解析出「该应用最值得截图的那个窗口」。
    ///
    /// 匹配策略（顺序即优先级）：
    ///   1. 应用名精确匹配（忽略大小写）—— `Safari` 不会误配 `Safari Technology Preview`
    ///   2. 应用名包含匹配 —— 让 `code` 能命中 `Visual Studio Code`
    ///
    /// 候选内排序：在屏优先，其次面积最大。
    ///
    /// 为什么取「面积最大」而不是「最靠前」：`CGWindowListCopyWindowInfo` 的
    /// 顺序是前到后，但应用常有一堆小浮窗（查找栏、工具面板）。
    /// 用户说「截 Safari」时想看的几乎总是主窗口。
    ///
    /// - Returns: 命中的窗口；找不到时为 nil（由调用方给出可操作错误）。
    public static func resolve(applicationName: String) -> WindowInfo? {
        resolve(applicationName: applicationName, among: all())
    }

    /// 先按名称匹配，再按在屏状态和面积选择；供枚举与回归测试共用。
    static func resolve(applicationName: String, among windows: [WindowInfo]) -> WindowInfo? {
        let query = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        let exact = windows.filter { $0.appName.caseInsensitiveCompare(query) == .orderedSame }
        if let best = bestCandidate(in: exact) {
            return best
        }

        let partial = windows.filter { $0.appName.localizedCaseInsensitiveContains(query) }
        return bestCandidate(in: partial)
    }

    /// 从候选里挑最合适的窗口：在屏优先，其次面积最大。
    private static func bestCandidate(in windows: [WindowInfo]) -> WindowInfo? {
        windows.max { lhs, rhs in
            if lhs.isOnScreen != rhs.isOnScreen { return !lhs.isOnScreen }
            let lhsArea = lhs.frame.width * lhs.frame.height
            let rhsArea = rhs.frame.width * rhs.frame.height
            return lhsArea < rhsArea
        }
    }

    /// 可供 `app` 参数直接使用的应用名列表（去重）。
    ///
    /// 让调用方在拼错应用名时能看到「有哪些可选」，而不是只得到一句
    /// 「没找到」——后者会让模型反复试同一个错名字。
    public static func applicationNames() -> [String] {
        Array(Set(all().map(\.appName))).sorted()
    }
}
