//
//  AppSettings.swift
//  AnShotUI
//
//  应用设置的持久化与广播。
//
//  ── 职责边界 ──────────────────────────────────────────────────
//
//  「设置」有三个使用者：设置窗口（读写）、菜单栏（间接反映状态）、导出流程（读保存位置）。
//  把存储塞进其中任何一个，另外两个就要反向依赖它。因此本类型**只管存取与广播**。
//
//  特别注意它**不做校验**：快捷键能不能真正注册成功是运行期事实，只有持有
//  `GlobalHotKey` 的那一方知道（Carbon 会因组合被占用而返回 -9878）。
//  所以校验留在应用层（`AppDelegate`），本类型只负责记录「用户想要什么」。
//

import AnShotCore
import AppKit
import Carbon.HIToolbox
import Foundation

private let logger = AnShotLog.settings
// MARK: - 快捷键

/// 一个可全局注册的快捷键。
///
/// 两个字段都用 **Carbon 编码**，刻意不暴露 `NSEvent` 类型：
/// 持久化格式必须稳定，而 `NSEvent.ModifierFlags` 是任意的 `OptionSet`，
/// 将来系统加入 `.function`、`.capsLock` 之类的位不会改变 Carbon 掩码，
/// 却会改变存进 UserDefaults 的整数。用 Carbon 编码可以避免这种静默腐化。
public struct Shortcut: Equatable, Sendable {

    /// Carbon 虚拟键码（`kVK_ANSI_1` 等）。
    ///
    /// 与 `NSEvent.keyCode` **同值**。Apple 文档原文：
    /// 「The value returned is the same as the value returned in the
    /// `kEventParamKeyCode` when using Carbon Events.」
    /// 因此录制到的键码可以直接拿去注册，**不需要**任何转换表。
    public let keyCode: UInt32

    /// Carbon 修饰键掩码。
    ///
    /// 与 `NSEvent.ModifierFlags` 的位值**不同**，两者不可混用，必须显式转换。
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

// MARK: - 修饰键转换

extension Shortcut {
    /// 把 AppKit 的修饰键标志转成 Carbon 掩码。
    ///
    /// 只取四个「有意按下」的修饰键。`.capsLock`、`.numericPad`、`.function`
    /// 一律忽略——它们是键盘状态的副产物，不是用户的意图：
    /// 大写锁定开着不该让快捷键失效。
    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        // 先过一遍 deviceIndependentFlagsMask：未过滤的 flags 含设备相关位
        // （左右修饰键的区分等），直接比较会得到不稳定结果。
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        return modifiers
    }
}

// MARK: - 可注册性判定

extension Shortcut {
    /// 这个组合能否安全地注册为全局热键。
    public enum RegistrationIssue: Equatable {
        /// 按下的只是修饰键本身（⌃、⌘ 单独按下）。
        case onlyModifiers
        /// 没有 ⌘/⌃/⌥ 中的任何一个。
        case missingStrongModifier

        /// 面向用户的中文说明。不写「非法输入」这类无信息量的话。
        public var message: String {
            switch self {
            case .onlyModifiers:
                return "请再按一个字母、数字或功能键——只有修饰键无法作为快捷键。"
            case .missingStrongModifier:
                return "请至少加上 ⌘、⌃ 或 ⌥。只用 ⇧ 会抢占正常输入，例如 ⇧A 就无法再打出来。"
            }
        }
    }

    /// 校验这个组合是否适合做全局热键。
    ///
    /// 规则的由来：全局热键是**抢占式**的，注册成功后该组合在本机所有应用中失效。
    /// 因此必须拒绝两类组合：
    ///   - 纯修饰键：Carbon 不接受，且用户看到控件没反应会以为坏了；
    ///   - 缺少强修饰键：`⇧A`、`A` 这类一旦注册，用户就再也打不出那个字符。
    ///     ⇧ 不算「强修饰键」——它本身就是普通字符输入的一部分。
    public var registrationIssue: RegistrationIssue? {
        // 修饰键的 Carbon 掩码本身就是键码的判定依据：
        // 按下 ⌃ 时 keyCode 是 kVK_Control，而修饰位也是 controlKey。
        // 这里只需检查有没有「非修饰键」参与。
        if Self.modifierOnlyKeyCodes.contains(keyCode) {
            return .onlyModifiers
        }
        let strong = UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)
        if modifiers & strong == 0 {
            return .missingStrongModifier
        }
        return nil
    }

    /// 单独按下会产生的「键码」，这些键码不代表一个真实按键。
    private static let modifierOnlyKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_Shift), UInt32(kVK_Option), UInt32(kVK_Control),
        UInt32(kVK_RightCommand), UInt32(kVK_RightShift),
        UInt32(kVK_RightOption), UInt32(kVK_RightControl),
        UInt32(kVK_CapsLock), UInt32(kVK_Function)
    ]
}

// MARK: - 显示

extension Shortcut {
    /// 人类可读的表示，例如 `⌃1`、`⇧⌘5`。
    ///
    /// 修饰键顺序固定为 ⌃⌥⇧⌘——这是 macOS 的书写惯例，
    /// 与 System Settings 中的显示一致。
    public var displayName: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        text += Self.keyName(for: keyCode)
        return text
    }

    /// 键码到显示名的映射。
    ///
    /// 分两层，顺序有讲究：
    ///   1. 功能键与特殊键查静态表——它们在各种布局下名字相同，
    ///      而且 `UCKeyTranslate` 对它们返回的是控制字符；
    ///   2. 可打印键用**当前键盘布局**解析。
    ///
    /// 第 2 点是必须的：静态表记的是 US QWERTY 的物理位置关系，
    /// 在 AZERTY（法国）上 `kVK_ANSI_A` 实际打出的是 `Q`，Dvorak 错位更多。
    /// 显示错的键名比显示「键 12」更糟——用户会以为自己按错了键。
    static func keyName(for keyCode: UInt32) -> String {
        if let name = specialKeyNames[keyCode] {
            return name
        }
        if let name = layoutKeyName(for: keyCode) {
            return name
        }
        return "键 \(keyCode)"
    }

    /// 用当前键盘布局解析可打印键的显示字符。
    private static func layoutKeyName(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 8)
            var length = 0
            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0, // 不按任何修饰键
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length)
            // 只接受可打印字符。控制字符（Return、Escape 等）由静态表负责，
            // 漏到这里会让它们显示成一个不可见的方块。
            guard !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F })
            else {
                return nil
            }
            return text.uppercased()
        }
    }

    /// 与布局无关的特殊键。
    private static let specialKeyNames: [UInt32: String] = [
        UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "空格",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓", UInt32(kVK_UpArrow): "↑",

        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20"
    ]
}

// MARK: - 保存位置

/// 截图保存到哪。
public enum SaveDestination: Equatable, Sendable {
    /// 每次保存都弹系统面板（默认，也是本功能出现之前的行为）。
    case ask

    /// 直接写入固定文件夹，不再询问。
    case folder(URL)
}

// MARK: - 键帽拆分

extension Shortcut {
    /// 拆成键帽标签，例如 `⌃⌥⇧⌘5` → `["⌃","⌥","⇧","⌘","5"]`。
    ///
    /// 与 `displayName` 拆开：后者是一个字符串，用于无障碍朗读与日志；
    /// 键帽需要逐个绘制，因此要分开的元素列表。两者必须保持同序。
    var keycapLabels: [String] {
        var labels: [String] = []
        if modifiers & UInt32(controlKey) != 0 { labels.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { labels.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { labels.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { labels.append("⌘") }
        labels.append(Shortcut.keyName(for: keyCode))
        return labels
    }
}

// MARK: - 全局动作

/// 可以绑定全局快捷键的动作。
///
/// 与 `GlobalHotKey.Role` 一一对应，但刻意不共用类型：
/// 前者是「用户想做什么」，后者是「Carbon 事件用哪个 id 认领」。
/// 把两者合并会让设置窗口依赖 Carbon，而注册细节只属于应用层。
public enum GlobalShortcutAction: String, CaseIterable, Sendable {
    case capture
    case recording
    case longScreenshot
    case ocr
    case pinToggle

    public var displayName: String {
        switch self {
        case .capture: return "开始截图"
        case .recording: return "开始录制"
        case .longScreenshot: return "滚动长截图"
        case .ocr: return "识别文字"
        case .pinToggle: return "收起 / 展开全部固定截图"
        }
    }

    public var hint: String {
        switch self {
        case .capture: return "按下组合键立即截图"
        case .recording: return "直接打开准备面板"
        case .longScreenshot: return "框选后开始拼接"
        case .ocr: return "框选后识别文字"
        case .pinToggle: return "收起或展开全部贴图"
        }
    }

    public var defaultShortcut: Shortcut {
        switch self {
        case .capture: return AppSettings.defaultCaptureShortcut
        case .recording: return AppSettings.defaultRecordingShortcut
        case .longScreenshot: return AppSettings.defaultLongScreenshotShortcut
        case .ocr: return AppSettings.defaultOCRShortcut
        case .pinToggle: return AppSettings.defaultPinToggleShortcut
        }
    }

    /// UserDefaults 键前缀。历史键名 `settings.capture.*` / `settings.pin.*`
    /// 必须保留：已有用户的自定义组合不能因为重构而丢失。
    fileprivate var keyPrefix: String {
        switch self {
        case .capture: return "settings.capture"
        case .recording: return "settings.recording"
        case .longScreenshot: return "settings.scrollshot"
        case .ocr: return "settings.ocr"
        case .pinToggle: return "settings.pin"
        }
    }
}

// MARK: - 设置存储

/// 应用设置的唯一存储点。
///
/// 刻意**不**做变更广播：两个使用者都不需要它。
/// 导出流程在每次保存时即时读 `saveDestination`（改完立即生效，无需通知），
/// 设置窗口的所有改动都从它自身发起、改完自己刷新。
/// 在真的出现第三方写入者之前，广播只是一个没人订阅的回调。
@MainActor
public final class AppSettings {

    /// 默认截图快捷键 `⌃1`。与 `AppSettings` 出现之前的行为一致。
    nonisolated public static let defaultCaptureShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_1),
        modifiers: UInt32(controlKey)
    )

    /// 默认「开始录制」快捷键 `⌃2`。
    ///
    /// 与 README 早已公开的编号一致：⌃1 截图、⌃2 录制、⌃3 长截图、⌃4 OCR。
    /// 这些动作原先只能「先截图、再点工具栏」，而文档却已经把它们写成直达入口；
    /// 把代码补成文档的样子，比改文档让用户忘掉既有肌肉记忆更划算。
    nonisolated public static let defaultRecordingShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_2),
        modifiers: UInt32(controlKey)
    )

    /// 默认「滚动长截图」快捷键 `⌃3`。
    nonisolated public static let defaultLongScreenshotShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_3),
        modifiers: UInt32(controlKey)
    )

    /// 默认「识别文字」快捷键 `⌃4`。
    nonisolated public static let defaultOCRShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_4),
        modifiers: UInt32(controlKey)
    )

    /// 默认「隐藏/显示全部固定截图」快捷键 `⌃5`。
    ///
    /// 从 ⌃2 移到 ⌃5：⌃2 已经承诺给录制。已经显式改过这个键的用户
    /// 仍读回自己的组合；只有从未改过的用户才会落到新的默认值。
    nonisolated public static let defaultPinToggleShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_5),
        modifiers: UInt32(controlKey)
    )

    /// 固定截图同时保留数量的默认上限。
    ///
    /// 20 张全尺寸截图约 0.5 GB（一张 3000×2000 约 24 MB）：
    /// 这是「够用」与「不失控」之间的保守取值。
    public static let defaultPinMaximumCount = 20

    /// 上限的合法区间。
    ///
    /// 下限必须是 1 而非 0：上限为 0 会让「钉住」永久失效，
    /// 而界面上没有任何东西能解释「为什么点了没反应」。
    /// 上限 100 是「随手可及」与「不可能用完」的分界。
    public static let pinLimitRange = 1...100

    private let store: UserDefaults

    /// - Parameter store: 注入以便测试使用独立 suite，避免污染真实偏好。
    public init(store: UserDefaults = .standard) {
        self.store = store
        self.rememberedSaveFolder = Self.readFolder(from: store)
        // 模式与文件夹分开读：模式是「现在怎么存」，文件夹是「上次选的目录」。
        // 两者一旦合并成一个值，「切回每次询问」就会把目录忘掉。
        let mode = store.string(forKey: Key.saveMode) ?? Mode.ask
        if mode == Mode.folder, let folder = rememberedSaveFolder {
            self.saveDestination = .folder(folder)
        } else {
            self.saveDestination = .ask
        }
        // 五个动作共用同一套读法：前缀 + keyCode/modifiers 两个键。
        // 用字典而不是五个平行字段，新增动作时不必再复制一遍
        // 「读到一半怎么办」的判定。
        var shortcuts: [GlobalShortcutAction: Shortcut] = [:]
        for action in GlobalShortcutAction.allCases {
            shortcuts[action] = Self.readShortcut(
                from: store,
                keyPrefix: action.keyPrefix,
                fallback: action.defaultShortcut
            )
        }
        self.shortcuts = shortcuts
        self.pinMaximumCount = Self.readPinLimit(from: store)
    }

    /// 读文件夹。路径缺失或为空时返回 `nil`。
    private static func readFolder(from store: UserDefaults) -> URL? {
        guard let path = store.string(forKey: Key.saveFolderPath), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// 读快捷键。只有两个键都读到才认；读到一半说明数据被外部改坏了，
    /// 此时退回默认值而不是拼出一个半残的组合。
    private static func readShortcut(
        from store: UserDefaults,
        keyPrefix: String,
        fallback: Shortcut
    ) -> Shortcut {
        let keyCodeKey = "\(keyPrefix).keyCode"
        let modifiersKey = "\(keyPrefix).modifiers"
        guard let keyCode = store.object(forKey: keyCodeKey) as? NSNumber,
              let modifiers = store.object(forKey: modifiersKey) as? NSNumber else {
            return fallback
        }
        return Shortcut(keyCode: keyCode.uint32Value, modifiers: modifiers.uint32Value)
    }

    /// 读固定截图上限。
    ///
    /// 越界值一律夹回合法区间而不是沿用：上限被写坏（0 或负数）会让
    /// 「钉住」永久失效，且界面上没有任何东西能解释这件事。
    private static func readPinLimit(from store: UserDefaults) -> Int {
        guard let value = store.object(forKey: Key.pinMaximumCount) as? NSNumber else {
            return defaultPinMaximumCount
        }
        return clampPinLimit(value.intValue)
    }

    /// 把上限夹进合法区间。
    private static func clampPinLimit(_ value: Int) -> Int {
        min(pinLimitRange.upperBound, max(pinLimitRange.lowerBound, value))
    }

    // MARK: 全局快捷键

    /// 当前五个全局动作的组合。
    ///
    /// 读的时候总是回落到默认值：字典只保存「用户显式改过的动作」，
    /// 这样将来新增动作时不必做数据迁移。
    private var shortcuts: [GlobalShortcutAction: Shortcut] = [:]

    public func shortcut(for action: GlobalShortcutAction) -> Shortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    /// 记录某个动作的新组合。
    ///
    /// **不做注册尝试**——调用方必须在 `GlobalHotKey` 注册成功之后才调用本方法，
    /// 否则会出现「设置里显示 ⌃2，实际热键还是 ⌃1」这种状态分叉。
    public func setShortcut(_ shortcut: Shortcut, for action: GlobalShortcutAction) {
        guard shortcut != self.shortcut(for: action) else { return }
        shortcuts[action] = shortcut
        store.set(NSNumber(value: shortcut.keyCode), forKey: "\(action.keyPrefix).keyCode")
        store.set(NSNumber(value: shortcut.modifiers), forKey: "\(action.keyPrefix).modifiers")
        logger.notice("""
            shortcut updated; action=\(action.rawValue, privacy: .public) \
            keyCode=\(shortcut.keyCode, privacy: .public) \
            modifiers=\(shortcut.modifiers, privacy: .public)
            """)
    }

    /// 恢复某个动作的默认组合。与 `setShortcut` 一样，注册成功后才应调用。
    public func resetShortcut(_ action: GlobalShortcutAction) {
        setShortcut(action.defaultShortcut, for: action)
    }

    // 兼容既有调用点：截图与固定截图是本次改造前仅有的两个动作。
    // 保留这些名字，避免把设置窗口、诊断与 AppDelegate 一次性全部改签名。
    public var captureShortcut: Shortcut { shortcut(for: .capture) }
    public var pinToggleShortcut: Shortcut { shortcut(for: .pinToggle) }
    public var recordingShortcut: Shortcut { shortcut(for: .recording) }
    public var longScreenshotShortcut: Shortcut { shortcut(for: .longScreenshot) }
    public var ocrShortcut: Shortcut { shortcut(for: .ocr) }

    public func setCaptureShortcut(_ shortcut: Shortcut) {
        setShortcut(shortcut, for: .capture)
    }

    public func resetCaptureShortcutToDefault() {
        resetShortcut(.capture)
    }

    public func setPinToggleShortcut(_ shortcut: Shortcut) {
        setShortcut(shortcut, for: .pinToggle)
    }

    public func resetPinToggleShortcutToDefault() {
        resetShortcut(.pinToggle)
    }

    // MARK: 固定截图

    /// 固定截图同时保留的数量上限。
    public private(set) var pinMaximumCount: Int

    /// 记录新的上限。越界值被夹进合法区间而非拒绝——
    /// 设置界面用步进器，越界只可能来自外部写入。
    public func setPinMaximumCount(_ count: Int) {
        let clamped = Self.clampPinLimit(count)
        guard clamped != pinMaximumCount else { return }
        pinMaximumCount = clamped
        store.set(NSNumber(value: clamped), forKey: Key.pinMaximumCount)
        logger.notice("pin limit updated; count=\(clamped, privacy: .public)")
    }

    // MARK: 保存位置

    /// 最后一次选定的文件夹。
    ///
    /// **与当前模式无关**：切到「每次询问」不清除它。
    /// 清除的话，用户切回去时就得重新选一遍目录，
    /// 而且在 UI 上表现为「第二次图标突然变灰、无法选中」。
    public private(set) var rememberedSaveFolder: URL?

    /// 当前的保存位置。
    public private(set) var saveDestination: SaveDestination

    /// 设置保存到固定文件夹，并记住它。
    public func setSaveFolder(_ url: URL) {
        // 归一化：去掉尾随斜杠等，保证相同目录的两次选择得到相等的 URL。
        let normalized = url.standardizedFileURL
        store.set(normalized.path, forKey: Key.saveFolderPath)
        store.set(Mode.folder, forKey: Key.saveMode)
        rememberedSaveFolder = normalized
        saveDestination = .folder(normalized)
        logger.notice("save destination set to folder: \(normalized.path, privacy: .public)")
    }

    /// 切到「每次询问」。**保留**记住的文件夹。
    public func setSaveDestinationToAsk() {
        store.set(Mode.ask, forKey: Key.saveMode)
        saveDestination = .ask
        logger.notice("save destination set to ask (remembered folder kept)")
    }

    /// 切回记住的文件夹。没记住过则什么都不做。
    public func activateRememberedSaveFolder() {
        guard let folder = rememberedSaveFolder else { return }
        store.set(Mode.folder, forKey: Key.saveMode)
        saveDestination = .folder(folder)
        logger.notice("save destination re-activated remembered folder")
    }

    // MARK: 键名

    private enum Key {
        static let saveMode = "settings.save.mode"
        static let saveFolderPath = "settings.save.folderPath"
        static let pinMaximumCount = "settings.pin.maximumCount"
    }

    private enum Mode {
        static let ask = "ask"
        static let folder = "folder"
    }
}
