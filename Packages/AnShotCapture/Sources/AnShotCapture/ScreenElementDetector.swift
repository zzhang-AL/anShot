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

/// 一次控件命中的结果。
public struct ControlHit: Equatable, Sendable {
    /// 全局左上原点屏幕坐标下的控件矩形。
    public let frame: CGRect
    /// AX 角色，例如 `AXButton`；读不到时为 `nil`。
    public let role: String?

    public init(frame: CGRect, role: String?) {
        self.frame = frame
        self.role = role
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
public final class SystemElementDetector: ScreenElementDetecting, @unchecked Sendable {
    /// 本进程 pid：用于把自己的窗口排除在识别结果之外。
    ///
    /// **这一步不能省。** 覆盖层本身就是本进程的一个（或多个）窗口，
    /// 它会出现在 `SCShareableContent.windows` 里；不过滤的话，
    /// 鼠标一移动就可能「识别到自己」，选中框永远是整屏。
    private let ownProcessID: pid_t

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

        return content.windows
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
    }

    /// 某个窗口是否应当作为识别候选。
    ///
    /// 三条过滤缺一不可，都由实测驱动：
    /// - `windowLayer == 0`：实测 7 个在屏窗口里只有 2 个是层 0，
    ///   其余是 Wallpaper / Backstop / Fullscreen Backdrop（层号是
    ///   -2147483622 这类极端负值）。不过滤就会把这些整屏背板识别成窗口。
    /// - `owningApplication != nil`：拿不到归属应用的条目没有意义，
    ///   也无法参与应用级聚合。
    /// - 排除本进程：见 `ownProcessID` 的说明。
    private func isSelectable(_ window: SCWindow, onDisplay displayID: CGDirectDisplayID) -> Bool {
        guard window.windowLayer == 0 else {
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

        guard let frame = frame(of: element) else {
            return nil
        }

        // 控件常常只有几个像素（分隔线、图标），太小的结果没有选中价值，
        // 交给窗口层更实用。
        guard frame.width >= 8, frame.height >= 8 else {
            return nil
        }

        return ControlHit(frame: frame, role: role(of: element))
    }

    /// 读取元素角色。
    private func role(of element: AXUIElement) -> String? {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success else {
            return nil
        }
        return roleValue as? String
    }

    /// 读取辅助功能元素的 frame。
    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero

        // AXValue 是 CFTypeRef，必须先确认类型再解引用；
        // 直接强转在部分应用上会崩（有的属性返回的是 CFString）。
        guard let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: origin, size: size)
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
