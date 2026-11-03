//
//  GlobalHotKey.swift
//  AnShotUI
//
//  全局热键注册（P3）。使用 Carbon `RegisterEventHotKey`。
//
//  ── 为什么是 Carbon ────────────────────────────────────────────
//
//  `RegisterEventHotKey` 在 Xcode 26.0 SDK 的可用性标注为
//  `AVAILABLE_MAC_OS_X_VERSION_10_0_AND_LATER`，**没有** deprecated 或
//  obsolete 标记（对比：`CGWindowListCreateImage` 标注为
//  `SCREEN_CAPTURE_OBSOLETE(10.5, 14.0, 15.0)`）。它是系统提供的
//  「无需辅助功能权限即可注册全局热键」的唯一公开 API。
//
//  替代方案的缺陷：
//    - `NSEvent.addGlobalMonitorForEvents`：键盘事件需要辅助功能权限
//      （NSEvent.h 原文：「Key-related events may only be monitored if
//      accessibility is enabled or if your application is trusted for
//      accessibility access」），且该 API **收不到发给本进程的事件**。
//    - 第三方热键库内部同样是调用 Carbon，只是加了一层包装。
//
//  因此直接用 Carbon：零依赖、零额外权限。
//

import AnShotCore
import Carbon.HIToolbox
import Foundation

private let logger = AnShotLog.hotkey
@MainActor
public final class GlobalHotKey {

    /// 注册失败的原因。Carbon 的 `OSStatus` 直接透出，不翻译成模糊描述。
    public enum RegistrationError: Error, LocalizedError {
        case handlerInstallFailed(OSStatus)
        case registrationFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .handlerInstallFailed(let status):
                return "热键事件处理器安装失败（OSStatus \(status)）"
            case .registrationFailed(let status):
                // eventHotKeyExistsErr = -9878：该组合已被其它应用占用
                let hint = status == -9878 ? "，该组合可能已被其它应用占用" : ""
                return "热键注册失败（OSStatus \(status)\(hint)）"
            }
        }
    }

    /// 四字符签名 'anSt'，用于把本应用的热键事件与其它 Carbon 事件区分开。
    private static let signature: OSType = 0x616E_5374

    /// 热键的**角色**。
    ///
    /// id 必须按角色固定，不能用一个全局自增计数器——系统侧对「注销后重新注册同一组合」
    /// 的映射存在滞后，实测出现过「事件带着上一次注册的 id 到达」的情形：
    /// 那时按 id 严格匹配会把它当成陌生事件丢掉，表现为「按了没反应，日志里什么也没发生」。
    /// 按角色固定 id 后，旧注册与新注册属于同一角色，事件不会被丢。
    public enum Role: UInt32 {
        case capture = 1
        case pinToggle = 2
        // 二〇二六年十一月「流程闭环」：把录制 / 长截图 / OCR 从
        // 「先截图、再点工具栏」提升为可直达的全局入口。
        //
        // 仍用 Carbon 的单一角色 id，而不是复用 capture：Carbon 按
        // (signature, id) 分发热键事件，共用 id 会让同一按键的两个角色
        // 互相认领，表现为「按录制却弹出截图」。每个动作一个固定 id，
        // 与 `AppSettings` 的五个快捷键一一对应。
        case recording = 3
        case longScreenshot = 4
        case ocr = 5
    }

    private let action: () -> Void

    /// 本对象负责的角色 id（即 `EventHotKeyID.id`）。
    let roleID: UInt32

    // Carbon 的注册句柄。标记 nonisolated(unsafe) 以便 deinit 能完成清理：
    // `UnregisterEventHotKey` / `RemoveEventHandler` 不访问本对象的其它状态。
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var eventHandlerRef: EventHandlerRef?

    /// 注册一个全局热键。
    ///
    /// - Parameters:
    ///   - role: 热键角色。它同时决定 `EventHotKeyID.id`（见 `Role` 的说明）。
    ///   - keyCode: Carbon 虚拟键码。与 `NSEvent.keyCode` 同值，因此录制到的键码可直接传入
    ///   - modifiers: Carbon 修饰键掩码。与 `NSEvent.ModifierFlags` 位值不同，须显式转换
    ///   - action: 热键触发时的回调，在主 actor 上执行
    /// - Throws: `RegistrationError`，携带原始 `OSStatus` 以便定位冲突
    public init(role: Role, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) throws {
        self.action = action
        self.roleID = role.rawValue

        // 事件处理器必须先于热键注册安装，否则热键生效瞬间的按键可能无人接收。
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyEventHandler,
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            throw RegistrationError.handlerInstallFailed(handlerStatus)
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: role.rawValue)
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        // 注册失败时必须撤掉刚装上的处理器，否则会留下一个永不触发的空处理器。
        guard registrationStatus == noErr else {
            if let handler = eventHandlerRef {
                RemoveEventHandler(handler)
                eventHandlerRef = nil
            }
            throw RegistrationError.registrationFailed(registrationStatus)
        }

        logger.notice("""
            hotkey registered; role=\(role.rawValue, privacy: .public) \
            keyCode=\(keyCode, privacy: .public) modifiers=\(modifiers, privacy: .public)
            """)
    }

    deinit {
        // 事件处理器持有的是 self 的**非持有**指针（passUnretained），
        // 因此对象释放前必须注销，否则热键再次触发会访问已释放内存。
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }

    /// 主动注销热键并拆除事件处理器。重复调用安全。
    public func invalidate() {
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    fileprivate func invokeAction() {
        action()
    }

    /// 这个事件是不是本对象负责的角色。
    fileprivate func ownsRole(_ incomingIdentifier: UInt32) -> Bool {
        incomingIdentifier == roleID
    }
}

/// Carbon 事件处理器必须是 C 函数指针，因此需要这个顶层函数。
///
/// 返回 `eventNotHandledErr` 表示「不是我要处理的事件」，让 Carbon 继续分发。
private func globalHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == 0x616E_5374 else {
        return OSStatus(eventNotHandledErr)
    }

    // `hotKeyID` 是可变结构体：先取出只读的 id（`UInt32` 是 Sendable），
    // 否则把它捕进主 actor 闭包会被并发检查判为 data race。
    let identifier = hotKeyID.id
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    // Carbon 热键事件经主 run loop 投递，所以可以在主 actor 上断言隔离。
    //
    // 角色判断必须在这个块**里面**：`GlobalHotKey` 是 `@MainActor`，
    // 在外面调它的方法就是跨隔离域访问。
    var handled = false
    MainActor.assumeIsolated {
        guard hotKey.ownsRole(identifier) else { return }
        // 这一行是「按键到底有没有到达本进程」的唯一证据：
        // 用户报「按了没反应」时，日志里**没有**它说明系统没投递（注册没被采用），
        // 有它但没后续动作则说明问题在动作里——两种处置完全不同。
        logger.notice("hotkey event received; id=\(identifier, privacy: .public)")
        hotKey.invokeAction()
        handled = true
    }
    guard handled else {
        // 同进程里还有别的热键处理器（截图与 Pin 各一个），它们会各自看一遍这个事件：
        // 不是自己的角色就交回给 Carbon 继续分发，否则会把另一个热键吃掉。
        // 记 debug 而非 notice：这是每次按键都会发生的正常交错，不是异常。
        logger.debug("hotkey event for another role; id=\(identifier, privacy: .public)")
        return OSStatus(eventNotHandledErr)
    }
    return noErr
}
