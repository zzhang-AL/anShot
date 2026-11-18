//
//  DesktopCatalog.swift
//  AnShotAutomation
//
//  macOS 没有公开的 Spaces 枚举 API。将动态解析的系统接口集中在此处，
//  接口不可用或数据结构变化时显式失败，不猜测桌面编号。
//

import AnShotCapture
import ColorSync
import CoreGraphics
import Darwin
import Foundation

/// 一个显示器上的桌面或全屏空间。ID 在系统会话内有效，调用前应重新枚举。
public struct DesktopInfo: Codable, Sendable, Equatable {
    public let id: UInt64
    public let displayID: UInt32
    /// Mission Control 中从左到右的位置，从 1 开始，包含全屏空间。
    public let position: Int
    /// 当前显示器内普通桌面的序号；全屏空间为 nil。
    public let desktopNumber: Int?
    /// `desktop`、`fullscreen` 或 `other`。
    public let kind: String
    public let isCurrent: Bool
}

/// 桌面枚举及显示器映射。
public enum DesktopCatalog {

    private typealias MainConnection = @convention(c) () -> UInt32
    private typealias CopyManagedSpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias CopyWindowSpaces = @convention(c) (UInt32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private typealias GetFocusedSpace = @convention(c) (UInt32) -> UInt64

    /// 一次性加载并缓存 SkyLight 符号，避免轮询期间重复 `dlopen` / `dlclose`。
    private struct SkyLightSymbols: Sendable {
        let mainConnection: MainConnection
        let copyManagedSpaces: CopyManagedSpaces?
        let copyWindowSpaces: CopyWindowSpaces?
        let getFocusedSpace: GetFocusedSpace?
    }

    /// 使用 `static let` 懒初始化并保持框架句柄常驻进程生命周期。
    private static let cachedSymbols: SkyLightSymbols? = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
              let connectionSymbol = dlsym(handle, "CGSMainConnectionID") else {
            return nil
        }
        let mainConnection = unsafeBitCast(connectionSymbol, to: MainConnection.self)
        let copyManagedSpaces = dlsym(handle, "CGSCopyManagedDisplaySpaces")
            .map { unsafeBitCast($0, to: CopyManagedSpaces.self) }
        let copyWindowSpaces = (dlsym(handle, "SLSCopySpacesForWindows")
            ?? dlsym(handle, "CGSCopySpacesForWindows"))
            .map { unsafeBitCast($0, to: CopyWindowSpaces.self) }
        let getFocusedSpace = (dlsym(handle, "SLSGetActiveSpace")
            ?? dlsym(handle, "CGSGetActiveSpace"))
            .map { unsafeBitCast($0, to: GetFocusedSpace.self) }
        return SkyLightSymbols(
            mainConnection: mainConnection,
            copyManagedSpaces: copyManagedSpaces,
            copyWindowSpaces: copyWindowSpaces,
            getFocusedSpace: getFocusedSpace
        )
    }()

    /// 查询当前桌面布局。该查询不切换桌面，也不要求辅助功能权限。
    public static func all() throws -> [DesktopInfo] {
        guard let symbols = cachedSymbols else {
            throw AutomationError.captureFailed("系统不支持桌面枚举。")
        }
        guard let copySpaces = symbols.copyManagedSpaces else {
            throw AutomationError.captureFailed("系统桌面枚举接口不可用，可能不兼容当前 macOS 版本。")
        }
        let connection = symbols.mainConnection()
        guard let raw = copySpaces(connection)?.takeRetainedValue(),
              let records = raw as NSArray as? [[String: Any]] else {
            throw AutomationError.captureFailed("无法读取系统桌面布局。")
        }

        let displays: [(id: UInt32, uuid: String)] = DisplayGeometry.activeDisplays().compactMap { id in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let text = CFUUIDCreateString(nil, uuid) else { return nil }
            return (id, String(describing: text).uppercased())
        }
        return try describe(records: records, displays: displays)
    }

    /// 查询窗口所属空间。接口不可用时返回空映射，窗口列表仍可正常使用。
    static func windowSpaceIDs(for windowIDs: [UInt32]) -> [UInt32: [UInt64]] {
        guard let symbols = cachedSymbols,
              let copySpaces = symbols.copyWindowSpaces else { return [:] }
        let connection = symbols.mainConnection()
        var result: [UInt32: [UInt64]] = [:]
        for id in windowIDs {
            let windows = [NSNumber(value: id)] as CFArray
            guard let raw = copySpaces(connection, 7, windows)?.takeRetainedValue(),
                  let numbers = raw as NSArray as? [NSNumber] else { continue }
            result[id] = numbers.map(\.uint64Value)
        }
        return result
    }

    /// 当前键盘焦点所在空间；无法读取时不使用快捷键切换。
    static func focusedSpaceID() -> UInt64? {
        guard let symbols = cachedSymbols,
              let getFocused = symbols.getFocusedSpace else { return nil }
        let connection = symbols.mainConnection()
        let id = getFocused(connection)
        return id == 0 ? nil : id
    }

    /// 把系统快照映射为稳定的外部字段；该转换不依赖真实显示器。
    static func describe(
        records: [[String: Any]],
        displays: [(id: UInt32, uuid: String)]
    ) throws -> [DesktopInfo] {
        guard !displays.isEmpty else {
            throw AutomationError.captureFailed("当前没有可用显示器，无法枚举桌面。")
        }

        var result: [DesktopInfo] = []
        for record in records {
            guard let displayIdentifier = record["Display Identifier"] as? String,
                  let spaces = record["Spaces"] as? [[String: Any]],
                  let current = record["Current Space"] as? [String: Any],
                  let currentID = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value else {
                throw AutomationError.captureFailed("系统返回了无法识别的桌面布局。")
            }

            // 未启用「显示器具有单独的空间」时，Main 表示各屏共享同一组空间。
            let matchingDisplays = displayIdentifier == "Main"
                ? displays.map(\.id)
                : displays.filter { $0.uuid.caseInsensitiveCompare(displayIdentifier) == .orderedSame }.map(\.id)
            guard !matchingDisplays.isEmpty else {
                throw AutomationError.captureFailed("无法将系统桌面映射到当前显示器，请重新枚举。")
            }

            var desktopNumber = 0
            for (offset, space) in spaces.enumerated() {
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value,
                      id > 0,
                      let type = (space["type"] as? NSNumber)?.intValue else {
                    throw AutomationError.captureFailed("系统返回了无法识别的桌面信息。")
                }
                let kind: String
                let number: Int?
                switch type {
                case 0:
                    desktopNumber += 1
                    kind = "desktop"
                    number = desktopNumber
                case 4:
                    kind = "fullscreen"
                    number = nil
                default:
                    kind = "other"
                    number = nil
                }
                for displayID in matchingDisplays {
                    result.append(DesktopInfo(
                        id: id,
                        displayID: displayID,
                        position: offset + 1,
                        desktopNumber: number,
                        kind: kind,
                        isCurrent: id == currentID
                    ))
                }
            }
        }
        return result
    }
}
