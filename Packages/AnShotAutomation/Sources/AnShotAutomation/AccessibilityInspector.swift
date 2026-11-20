//
//  AccessibilityInspector.swift
//  AnShotAutomation
//
//  应用与窗口内辅助功能（AX）UI 控件树探测：返回角色、标题、描述、逻辑点坐标框等，
//  在无辅助功能权限时返回清晰结构体与授权指引。
//

import ApplicationServices
import CoreGraphics
import Foundation

/// 控件树探测参数。
public struct InspectElementsParameters: Codable, Sendable, Equatable {

    /// 默认最大遍历深度。
    public static let defaultMaxDepth = 4
    /// 允许的最大遍历深度上限。
    public static let maximumAllowedDepth = 12
    /// 默认最大返回控件数量。
    public static let defaultMaxElements = 200
    /// 允许的最大返回控件数量上限。
    public static let maximumAllowedElements = 1000

    /// 目标窗口 ID。
    public var windowID: CGWindowID?

    /// 目标应用名。
    public var applicationName: String?

    /// 目标进程 PID。
    public var pid: Int32?

    /// 最大遍历深度（1...12）。
    public var maxDepth: Int

    /// 最大返回节点数（1...1000）。
    public var maxElements: Int

    public init(
        windowID: CGWindowID? = nil,
        applicationName: String? = nil,
        pid: Int32? = nil,
        maxDepth: Int = InspectElementsParameters.defaultMaxDepth,
        maxElements: Int = InspectElementsParameters.defaultMaxElements
    ) {
        self.windowID = windowID
        self.applicationName = applicationName
        self.pid = pid
        self.maxDepth = maxDepth
        self.maxElements = maxElements
    }

    /// 校验参数互斥与数值边界。
    public func validate() throws {
        let providedCount = [
            windowID != nil,
            applicationName != nil,
            pid != nil
        ].filter { $0 }.count

        guard providedCount == 1 else {
            throw AutomationError.invalidArgument(
                "window_id、app、pid 必须且只能指定其中一个。"
            )
        }

        if let applicationName,
           applicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AutomationError.invalidArgument("app 不能是空字符串。")
        }

        if let pid, pid <= 0 {
            throw AutomationError.invalidArgument("pid 必须是大于 0 的整数（收到 \(pid)）。")
        }

        guard (1...Self.maximumAllowedDepth).contains(maxDepth) else {
            throw AutomationError.invalidArgument(
                "max_depth 必须在 1 到 \(Self.maximumAllowedDepth) 之间（收到 \(maxDepth)）。"
            )
        }

        guard (1...Self.maximumAllowedElements).contains(maxElements) else {
            throw AutomationError.invalidArgument(
                "max_elements 必须在 1 到 \(Self.maximumAllowedElements) 之间（收到 \(maxElements)）。"
            )
        }
    }
}

/// 单个 UI 控件节点描述。
public struct UIElementNode: Codable, Sendable, Equatable {
    public let role: String
    public let subrole: String?
    public let title: String?
    public let description: String?
    public let identifier: String?
    public let value: String?
    public let enabled: Bool?
    public let frame: RectOutput
    public let depth: Int

    public struct RectOutput: Codable, Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }
}

/// 目标窗口/应用信息摘要。
public struct InspectionTargetInfo: Codable, Sendable, Equatable {
    public let pid: Int32
    public let applicationName: String?
    public let windowID: UInt32?
    public let windowTitle: String?
    public let windowFrame: UIElementNode.RectOutput?
}

/// 控件树探测结果。
public struct ElementsInspectionOutput: Codable, Sendable, Equatable {
    public let hasAccessibilityPermission: Bool
    public let permissionGuidance: String?
    public let coordinateSystem: String
    public let target: InspectionTargetInfo?
    public let elements: [UIElementNode]
    public let truncated: Bool
    public let totalVisited: Int
}

/// 辅助功能控件树探测服务。
public enum AccessibilityInspector {

    /// 单次 AX IPC 消息超时（秒），防止卡死应用拖挂主流程。
    private static let messagingTimeoutSeconds: Float = 0.5

    /// 缺少辅助功能权限时的清晰可操作指引。
    static let missingPermissionGuidance = """
        缺少辅助功能权限，无法读取目标窗口或应用的 UI 控件树。
        请前往「系统设置 → 隐私与安全性 → 辅助功能」，开启对应执行进程（anShot 或当前终端/AI 客户端）的开关后重试。
        """

    /// 执行控件树探测。
    public static func inspect(
        _ parameters: InspectElementsParameters,
        execution: CaptureExecution = .reuseApplicationAuthorization,
        authorizedByDaemon: Bool = false
    ) async throws -> ElementsInspectionOutput {
        try parameters.validate()

        // 若请求复用 anShot.app 权限、本进程尚未拿到辅助功能权限、且在 .app 内，
        // 委托给 anShot.app 常驻/子实例执行（它可能已获得用户的辅助功能与屏幕录制双授权）。
        if execution == .reuseApplicationAuthorization,
           !AXIsProcessTrusted(),
           let appURL = OutOfProcessCapture.currentAppURL {
            return try await OutOfProcessCapture.inspectElements(
                parameters: parameters,
                appURL: appURL,
                timeout: OutOfProcessCapture.defaultTimeout
            )
        }

        if !authorizedByDaemon {
            try AutomationSecurityGate.authorize(providedToken: AutomationSecurityGate.currentEnvironmentToken())
        }

        // 就地解析目标窗口/进程（确保走与窗口目录一致的解析策略）。
        let resolvedTarget = try resolveTarget(parameters)

        // 防线 4：禁止通过 AX 控件树读取受保护密码管理器/系统钥匙串的界面文本。
        try AutomationSecurityGate.validateTargetWindowAllowed(
            pid: resolvedTarget.pid,
            applicationName: resolvedTarget.applicationName
        )

        guard AXIsProcessTrusted() else {
            return ElementsInspectionOutput(
                hasAccessibilityPermission: false,
                permissionGuidance: missingPermissionGuidance,
                coordinateSystem: "global_points_top_left",
                target: resolvedTarget,
                elements: [],
                truncated: false,
                totalVisited: 0
            )
        }

        return await Task.detached(priority: .userInitiated) {
            performInspection(parameters: parameters, target: resolvedTarget)
        }.value
    }

    /// 解析目标进程与窗口上下文。
    private static func resolveTarget(_ parameters: InspectElementsParameters) throws -> InspectionTargetInfo {
        if let windowID = parameters.windowID {
            guard let info = WindowCatalog.info(for: windowID) else {
                throw AutomationError.windowUnavailable(
                    "窗口 #\(windowID) 不存在或已关闭。可用 list_windows 查看当前窗口。"
                )
            }
            return InspectionTargetInfo(
                pid: info.pid,
                applicationName: info.appName,
                windowID: info.id,
                windowTitle: info.title,
                windowFrame: UIElementNode.RectOutput(
                    x: info.frame.x,
                    y: info.frame.y,
                    width: info.frame.width,
                    height: info.frame.height
                )
            )
        }

        if let appName = parameters.applicationName {
            guard let info = WindowCatalog.resolve(applicationName: appName) else {
                let names = WindowCatalog.applicationNames()
                let preview = names.prefix(20).joined(separator: "、")
                let suffix = names.count > 20 ? "…（共 \(names.count) 个）" : ""
                throw AutomationError.windowUnavailable(
                    "没有找到应用「\(appName)」的窗口。"
                    + (names.isEmpty ? "当前没有任何可见窗口。" : "当前可用的应用：\(preview)\(suffix)。")
                )
            }
            return InspectionTargetInfo(
                pid: info.pid,
                applicationName: info.appName,
                windowID: info.id,
                windowTitle: info.title,
                windowFrame: UIElementNode.RectOutput(
                    x: info.frame.x,
                    y: info.frame.y,
                    width: info.frame.width,
                    height: info.frame.height
                )
            )
        }

        let pid = parameters.pid ?? 0
        let firstWindow = WindowCatalog.all().first(where: { $0.pid == pid })
        return InspectionTargetInfo(
            pid: pid,
            applicationName: firstWindow?.appName,
            windowID: firstWindow?.id,
            windowTitle: firstWindow?.title,
            windowFrame: firstWindow.map {
                UIElementNode.RectOutput(
                    x: $0.frame.x,
                    y: $0.frame.y,
                    width: $0.frame.width,
                    height: $0.frame.height
                )
            }
        )
    }

    /// 执行广度优先遍历，读取控件角色、文本与逻辑点坐标框。
    private static func performInspection(
        parameters: InspectElementsParameters,
        target: InspectionTargetInfo
    ) -> ElementsInspectionOutput {
        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeoutSeconds)

        let roots = rootElements(for: appElement, target: target)
        var queue: [(element: AXUIElement, depth: Int)] = roots.map { ($0, 0) }
        var nodes: [UIElementNode] = []
        var totalVisited = 0
        var truncated = false
        var cursor = 0

        while cursor < queue.count {
            let (current, depth) = queue[cursor]
            cursor += 1
            totalVisited += 1

            if let node = makeNode(from: current, depth: depth) {
                nodes.append(node)
                if nodes.count >= parameters.maxElements {
                    truncated = cursor < queue.count || !children(of: current).isEmpty
                    break
                }
            }

            guard depth < parameters.maxDepth else {
                if !children(of: current).isEmpty {
                    truncated = true
                }
                continue
            }

            let childElements = children(of: current)
            for child in childElements {
                queue.append((child, depth + 1))
            }

            // 防御极端大 DOM 树队列膨胀，限制未访问队列长度上限。
            if queue.count > parameters.maxElements * 8 {
                truncated = true
                break
            }
        }

        return ElementsInspectionOutput(
            hasAccessibilityPermission: true,
            permissionGuidance: nil,
            coordinateSystem: "global_points_top_left",
            target: target,
            elements: nodes,
            truncated: truncated,
            totalVisited: totalVisited
        )
    }

    /// 选择遍历起始窗口元素（优先匹配目标窗口，否则使用焦点窗/全部可见窗）。
    private static func rootElements(
        for appElement: AXUIElement,
        target: InspectionTargetInfo
    ) -> [AXUIElement] {
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        let windows = (status == .success ? (windowsRef as? [AXUIElement]) : nil) ?? []

        if let targetFrame = target.windowFrame, !windows.isEmpty {
            let expected = CGRect(
                x: targetFrame.x,
                y: targetFrame.y,
                width: targetFrame.width,
                height: targetFrame.height
            )
            // 先按标题与坐标容差精确匹配对应窗口。
            if let matched = windows.first(where: { win in
                guard let rect = frame(of: win) else { return false }
                let delta = abs(rect.origin.x - expected.origin.x)
                    + abs(rect.origin.y - expected.origin.y)
                    + abs(rect.width - expected.width)
                    + abs(rect.height - expected.height)
                return delta < 8
            }) {
                return [matched]
            }
        }

        if let targetTitle = target.windowTitle,
           let matchedByTitle = windows.first(where: { stringAttribute(kAXTitleAttribute, of: $0) == targetTitle }) {
            return [matchedByTitle]
        }

        if !windows.isEmpty {
            return Array(windows.prefix(3))
        }

        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef {
            return [focused as! AXUIElement]
        }

        return [appElement]
    }

    private static func makeNode(from element: AXUIElement, depth: Int) -> UIElementNode? {
        guard let rect = frame(of: element),
              rect.width > 0, rect.height > 0 else {
            return nil
        }

        let role = stringAttribute(kAXRoleAttribute, of: element) ?? "AXUnknown"
        let subrole = nonEmpty(stringAttribute(kAXSubroleAttribute, of: element))
        let title = nonEmpty(stringAttribute(kAXTitleAttribute, of: element))
        let description = nonEmpty(stringAttribute(kAXDescriptionAttribute, of: element))
        let identifier = nonEmpty(stringAttribute(kAXIdentifierAttribute, of: element))
        let value = truncatedValue(of: element)
        let enabled = boolAttribute(kAXEnabledAttribute, of: element)

        return UIElementNode(
            role: role,
            subrole: subrole,
            title: title,
            description: description,
            identifier: identifier,
            value: value,
            enabled: enabled,
            frame: UIElementNode.RectOutput(
                x: Double(rect.origin.x),
                y: Double(rect.origin.y),
                width: Double(rect.width),
                height: Double(rect.height)
            ),
            depth: depth
        )
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else {
            return []
        }
        return list
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func truncatedValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let raw = value else {
            return nil
        }
        let text: String?
        if let s = raw as? String {
            text = s
        } else if let n = raw as? NSNumber {
            text = n.stringValue
        } else {
            text = nil
        }
        guard let cleaned = nonEmpty(text) else { return nil }
        if cleaned.count <= 120 { return cleaned }
        return String(cleaned.prefix(120)) + "…"
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
