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

import AnShotCapture
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
        // Phase 5.2 契约：允许 F1–F20 在无修饰键下直接注册；普通字母/数字仍必须带强修饰键防抢占输入。
        if Self.functionKeyCodes.contains(keyCode) {
            return nil
        }
        let strong = UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)
        if modifiers & strong == 0 {
            return .missingStrongModifier
        }
        return nil
    }

    /// 功能键 F1–F20 键码集合（允许单键无修饰注册）。
    public static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
        UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
        UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
    ]

    /// 转换为 AppKit `NSMenuItem` 原生右对齐快捷键的 `(keyEquivalent, modifierMask)`。
    public var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }

        if let scalar = Self.functionKeyMenuScalars[keyCode] {
            return (String(scalar), flags)
        }
        if keyCode == UInt32(kVK_Space) { return (" ", flags) }
        if keyCode == UInt32(kVK_Return) { return ("\r", flags) }
        if keyCode == UInt32(kVK_Tab) { return ("\t", flags) }
        let name = Self.keyName(for: keyCode).lowercased()
        guard name.count == 1 else { return ("", []) }
        return (name, flags)
    }

    private static let functionKeyMenuScalars: [UInt32: UnicodeScalar] = [
        UInt32(kVK_F1): UnicodeScalar(NSF1FunctionKey)!,
        UInt32(kVK_F2): UnicodeScalar(NSF2FunctionKey)!,
        UInt32(kVK_F3): UnicodeScalar(NSF3FunctionKey)!,
        UInt32(kVK_F4): UnicodeScalar(NSF4FunctionKey)!,
        UInt32(kVK_F5): UnicodeScalar(NSF5FunctionKey)!,
        UInt32(kVK_F6): UnicodeScalar(NSF6FunctionKey)!,
        UInt32(kVK_F7): UnicodeScalar(NSF7FunctionKey)!,
        UInt32(kVK_F8): UnicodeScalar(NSF8FunctionKey)!,
        UInt32(kVK_F9): UnicodeScalar(NSF9FunctionKey)!,
        UInt32(kVK_F10): UnicodeScalar(NSF10FunctionKey)!,
        UInt32(kVK_F11): UnicodeScalar(NSF11FunctionKey)!,
        UInt32(kVK_F12): UnicodeScalar(NSF12FunctionKey)!,
        UInt32(kVK_F13): UnicodeScalar(NSF13FunctionKey)!,
        UInt32(kVK_F14): UnicodeScalar(NSF14FunctionKey)!,
        UInt32(kVK_F15): UnicodeScalar(NSF15FunctionKey)!,
        UInt32(kVK_F16): UnicodeScalar(NSF16FunctionKey)!,
        UInt32(kVK_F17): UnicodeScalar(NSF17FunctionKey)!,
        UInt32(kVK_F18): UnicodeScalar(NSF18FunctionKey)!,
        UInt32(kVK_F19): UnicodeScalar(NSF19FunctionKey)!,
        UInt32(kVK_F20): UnicodeScalar(NSF20FunctionKey)!,
    ]

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

/// 截图保存格式选项（契约 `ux-polish/model.md` §1.1 & §4.2）。
public enum ExportFormatOption: String, CaseIterable, Sendable {
    case png = "png"
    case jpeg = "jpeg"
    case heic = "heic"
    case webp = "webp"

    public var displayName: String {
        switch self {
        case .png:  return "PNG（无损）"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .webp: return "WebP（无损）"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png:  return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .webp: return "webp"
        }
    }

    public var supportsQuality: Bool {
        self == .jpeg || self == .heic
    }

    public func imageFormat(quality: Double) -> ImageFormat {
        let clamped = CGFloat(min(1.0, max(0.1, quality)))
        switch self {
        case .png:  return .png
        case .jpeg: return .jpeg(quality: clamped)
        case .heic: return .heic(quality: clamped)
        case .webp: return .webpLossless
        }
    }
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
    case windowCapture
    case longScreenshot
    case ocr
    case recording
    case ocrAutoTranslate
    case selectionTranslate
    case pinToggle

    public var displayName: String {
        switch self {
        case .capture: return "开始截图"
        case .windowCapture: return "独立窗体截图"
        case .recording: return "开始录制"
        case .longScreenshot: return "滚动长截图"
        case .ocr: return "识别文字"
        case .ocrAutoTranslate: return "框选翻译"
        case .selectionTranslate: return "划词翻译"
        case .pinToggle: return "收起 / 展开全部固定截图"
        }
    }

    public var hint: String {
        switch self {
        case .capture: return "按下组合键立即框选截图"
        case .windowCapture: return "直接进入独立窗体无遮挡捕获模式"
        case .recording: return "直接打开录屏准备面板"
        case .longScreenshot: return "框选后开始滚动拼接长图"
        case .ocr: return "框选后识别文字与二维码"
        case .ocrAutoTranslate: return "框选文字后立即自动翻译"
        case .selectionTranslate: return "读取选中文字并弹出翻译浮窗"
        case .pinToggle: return "收起或展开全部贴图"
        }
    }

    /// 新装防冲突默认热键（schema v2，避开 macOS `⌃1`–`⌃4` 切换桌面冲突）。
    public var defaultShortcut: Shortcut {
        switch self {
        case .capture: return AppSettings.defaultCaptureShortcut
        case .windowCapture: return AppSettings.defaultWindowCaptureShortcut
        case .recording: return AppSettings.defaultRecordingShortcut
        case .longScreenshot: return AppSettings.defaultLongScreenshotShortcut
        case .ocr: return AppSettings.defaultOCRShortcut
        case .ocrAutoTranslate: return AppSettings.defaultOCRAutoTranslateShortcut
        case .selectionTranslate: return AppSettings.defaultSelectionTranslateShortcut
        case .pinToggle: return AppSettings.defaultPinToggleShortcut
        }
    }

    /// 老用户升级兼容默认热键（schema v1，完整保留既有 `⌃1`–`⌃5` 肌肉记忆）。
    public var legacyDefaultShortcut: Shortcut? {
        switch self {
        case .capture: return AppSettings.legacyCaptureShortcut
        case .windowCapture: return nil
        case .recording: return AppSettings.legacyRecordingShortcut
        case .longScreenshot: return AppSettings.legacyLongScreenshotShortcut
        case .ocr: return AppSettings.legacyOCRShortcut
        case .ocrAutoTranslate: return AppSettings.defaultOCRAutoTranslateShortcut
        case .selectionTranslate: return AppSettings.defaultSelectionTranslateShortcut
        case .pinToggle: return AppSettings.legacyPinToggleShortcut
        }
    }

    /// UserDefaults 键前缀。历史键名 `settings.capture.*` / `settings.pin.*`
    /// 必须保留：已有用户的自定义组合不能因为重构而丢失。
    fileprivate var keyPrefix: String {
        switch self {
        case .capture: return "settings.capture"
        case .windowCapture: return "settings.windowCapture"
        case .recording: return "settings.recording"
        case .longScreenshot: return "settings.scrollshot"
        case .ocr: return "settings.ocr"
        case .ocrAutoTranslate: return "settings.ocrAutoTranslate"
        case .selectionTranslate: return "settings.selectionTranslate"
        case .pinToggle: return "settings.pin"
        }
    }
}

// MARK: - 设置存储

/// 应用设置的唯一存储点。
@MainActor
public final class AppSettings {

    /// 配置模式版本号：1 = 老用户兼容基线；2 = 新装默认（静默直存 + 防冲突热键 `⌃A/⌃S/⌃D/⌃F/⌃R/⌃G`）。
    public static let currentInstallSchemaVersion = 2

    // MARK: 新装防冲突默认热键（Schema v2）

    /// 新装默认截图快捷键 `⌃A`（避开 macOS Mission Control `⌃1` 冲突）。
    nonisolated public static let defaultCaptureShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_A),
        modifiers: UInt32(controlKey)
    )

    /// 新装默认独立窗体截图快捷键 `⌃S`。
    nonisolated public static let defaultWindowCaptureShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(controlKey)
    )

    /// 新装默认滚动长截图快捷键 `⌃D`。
    nonisolated public static let defaultLongScreenshotShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey)
    )

    /// 新装默认识别文字快捷键 `⌃F`。
    nonisolated public static let defaultOCRShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_F),
        modifiers: UInt32(controlKey)
    )

    /// 新装默认开始录制快捷键 `⌃R`。
    nonisolated public static let defaultRecordingShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(controlKey)
    )

    /// 新装默认隐显全部贴图快捷键 `⌃G`。
    nonisolated public static let defaultPinToggleShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_G),
        modifiers: UInt32(controlKey)
    )

    /// 默认「框选翻译」快捷键 `⌥S`（框选 OCR 后立即自动翻译）。
    nonisolated public static let defaultOCRAutoTranslateShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(optionKey)
    )

    /// 默认「划词翻译」快捷键 `⌥D`（读取选中文本并弹出独立翻译浮窗）。
    nonisolated public static let defaultSelectionTranslateShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(optionKey)
    )

    // MARK: 老用户升级兼容默认热键（Schema v1）

    nonisolated public static let legacyCaptureShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_1),
        modifiers: UInt32(controlKey)
    )
    nonisolated public static let legacyRecordingShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_2),
        modifiers: UInt32(controlKey)
    )
    nonisolated public static let legacyLongScreenshotShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_3),
        modifiers: UInt32(controlKey)
    )
    nonisolated public static let legacyOCRShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_4),
        modifiers: UInt32(controlKey)
    )
    nonisolated public static let legacyPinToggleShortcut = Shortcut(
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

    /// 本实例生效的架构版本号（`1` = 老用户升级基线；`2` = 新装防冲突热键与默认静默直存）。
    public let installSchemaVersion: Int

    /// - Parameter store: 注入以便测试使用独立 suite，避免污染真实偏好。
    public init(store: UserDefaults = .standard) {
        self.store = store

        // ── 新装 vs 老用户判定与兼容迁移（契约 `ux-polish/model.md` §4.1–§4.2）──
        let persistedSchema = store.integer(forKey: Key.installSchemaVersion)
        let resolvedSchema: Int
        if persistedSchema > 0 {
            resolvedSchema = persistedSchema
        } else if Self.hasLegacyInstallationKeys(in: store) {
            resolvedSchema = 1
            store.set(1, forKey: Key.installSchemaVersion)
        } else {
            resolvedSchema = Self.currentInstallSchemaVersion
            store.set(resolvedSchema, forKey: Key.installSchemaVersion)
        }
        self.installSchemaVersion = resolvedSchema

        // ── 保存位置 ──
        var remembered = Self.readFolder(from: store)
        if let mode = store.string(forKey: Key.saveMode) {
            if mode == Mode.folder, let folder = remembered {
                self.saveDestination = .folder(folder)
            } else {
                self.saveDestination = .ask
            }
        } else if resolvedSchema >= 2 {
            // 新装默认静默直存：优先采用系统截图目录（com.apple.screencapture location），否则 ~/Downloads。
            let defaultFolder = Self.resolveDefaultScreenshotFolder()
            remembered = defaultFolder
            self.saveDestination = .folder(defaultFolder)
            store.set(defaultFolder.path, forKey: Key.saveFolderPath)
            store.set(Mode.folder, forKey: Key.saveMode)
        } else {
            // 老用户未写过 saveMode 键时沿用历史默认「每次询问」。
            self.saveDestination = .ask
        }
        self.rememberedSaveFolder = remembered

        // ── 全局快捷键（支持新老默认策略与显式解绑）──
        var shortcuts: [GlobalShortcutAction: Shortcut] = [:]
        var unbound: Set<GlobalShortcutAction> = []
        for action in GlobalShortcutAction.allCases {
            if store.bool(forKey: "\(action.keyPrefix).unbound") {
                unbound.insert(action)
                continue
            }
            let fallback: Shortcut? = resolvedSchema >= 2 ? action.defaultShortcut : action.legacyDefaultShortcut
            if let loaded = Self.readShortcut(from: store, keyPrefix: action.keyPrefix) {
                shortcuts[action] = loaded
            } else if let fallback {
                shortcuts[action] = fallback
            } else {
                unbound.insert(action)
            }
        }
        self.shortcuts = shortcuts
        self.unboundShortcuts = unbound

        self.pinMaximumCount = Self.readPinLimit(from: store)
        self.windowCaptureShadow = store.object(forKey: Key.windowCaptureShadow) as? Bool ?? true
        self.confirmCancelWithAnnotations = store.object(forKey: Key.confirmCancelWithAnnotations) as? Bool ?? true
        self.toolbarHiddenSlots = Set(store.stringArray(forKey: Key.toolbarHiddenSlots) ?? [])
        self.ocrLanguage = store.string(forKey: Key.ocrLanguage)
            .flatMap(OCRLanguagePreference.init(rawValue:)) ?? .auto
        self.ocrMergeLineBreaks = store.object(forKey: Key.ocrMergeLineBreaks) as? Bool ?? false
        self.ocrDetectBarcodes = store.object(forKey: Key.ocrDetectBarcodes) as? Bool ?? true
        let savedTarget = store.string(forKey: Key.translationTargetLanguage) ?? "zh-Hans"
        self.translationTargetLanguage = TranslationLanguage.commonTargetLanguages.contains(where: { $0.id == savedTarget })
            ? savedTarget
            : "zh-Hans"
        self.selectionTranslateFloatingButton = store.object(forKey: Key.selectionTranslateFloatingButton) as? Bool ?? false
        self.pinShowBorder = store.object(forKey: Key.pinShowBorder) as? Bool ?? true
        self.longshotAutoScrollEnabled = store.object(forKey: Key.longshotAutoScrollEnabled) as? Bool ?? true
        self.longshotAutoScrollSpeed = store.string(forKey: Key.longshotAutoScrollSpeed)
            .flatMap(AutoScrollSpeed.init(rawValue:)) ?? .normal
        self.exportFormat = store.string(forKey: Key.exportFormat)
            .flatMap(ExportFormatOption.init(rawValue:)) ?? .png
        let rawQuality = store.object(forKey: Key.exportQuality) as? Double ?? 0.88
        self.exportQuality = min(1.0, max(0.1, rawQuality))
        self.pngLosslessOptimize = store.object(forKey: Key.pngLosslessOptimize) as? Bool ?? true
        self.pasteboardLazyTIFF = store.object(forKey: Key.pasteboardLazyTIFF) as? Bool ?? true
        self.appearanceMode = store.string(forKey: Key.appearanceMode)
            .flatMap(AppAppearanceMode.init(rawValue:)) ?? .system
        self.appLanguage = store.string(forKey: Key.appLanguage)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        self.showCompletionToast = store.object(forKey: Key.showCompletionToast) as? Bool ?? true
        self.recordingShowRegionFrame = store.object(forKey: Key.recordingShowRegionFrame) as? Bool ?? true
    }

    /// 检测 `UserDefaults` 是否存在任意历史版本设置键（用于无损区分老用户升级与全新安装）。
    private static func hasLegacyInstallationKeys(in store: UserDefaults) -> Bool {
        let legacyKeys = [
            Key.saveMode,
            Key.saveFolderPath,
            Key.pinMaximumCount,
            "settings.capture.keyCode",
            "settings.pin.keyCode",
            "settings.recording.keyCode",
            "settings.scrollshot.keyCode",
            "settings.ocr.keyCode",
        ]
        return legacyKeys.contains { store.object(forKey: $0) != nil }
    }

    /// 解析新装默认静默直存目录：优先读取系统截图目录 `com.apple.screencapture location`，否则回落 `~/Downloads`。
    public static func resolveDefaultScreenshotFolder() -> URL {
        let fm = FileManager.default
        if let systemPrefs = UserDefaults(suiteName: "com.apple.screencapture"),
           let rawLocation = systemPrefs.string(forKey: "location"),
           !rawLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (rawLocation as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: expanded, isDirectory: &isDir),
               isDir.boolValue,
               fm.isWritableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
        }
        if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: downloads.path, isDirectory: &isDir), isDir.boolValue {
                return downloads.standardizedFileURL
            }
        }
        if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            return desktop.standardizedFileURL
        }
        return URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
    }

    /// 读文件夹。路径缺失或为空时返回 `nil`。
    private static func readFolder(from store: UserDefaults) -> URL? {
        guard let path = store.string(forKey: Key.saveFolderPath), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// 读快捷键。只有两个键都读到才认；读到一半返回 nil 让调用方按迁移策略回落。
    private static func readShortcut(
        from store: UserDefaults,
        keyPrefix: String
    ) -> Shortcut? {
        let keyCodeKey = "\(keyPrefix).keyCode"
        let modifiersKey = "\(keyPrefix).modifiers"
        guard let keyCode = store.object(forKey: keyCodeKey) as? NSNumber,
              let modifiers = store.object(forKey: modifiersKey) as? NSNumber else {
            return nil
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

    private var shortcuts: [GlobalShortcutAction: Shortcut] = [:]
    private var unboundShortcuts: Set<GlobalShortcutAction> = []

    /// 返回当前架构版本下某动作的默认组合（新装 v2 走防冲突组合，老用户 v1 走历史组合）。
    public func defaultShortcut(for action: GlobalShortcutAction) -> Shortcut? {
        installSchemaVersion >= 2 ? action.defaultShortcut : action.legacyDefaultShortcut
    }

    /// 返回某动作当前的有效快捷键；若已被用户清空/解绑则返回 `nil`。
    public func optionalShortcut(for action: GlobalShortcutAction) -> Shortcut? {
        guard !unboundShortcuts.contains(action) else { return nil }
        return shortcuts[action] ?? defaultShortcut(for: action)
    }

    /// 兼容旧的非空读取入口；若动作已解绑则回落到其默认组合。
    public func shortcut(for action: GlobalShortcutAction) -> Shortcut {
        optionalShortcut(for: action) ?? action.defaultShortcut
    }

    /// 记录某个动作的新组合（自动解除未绑定状态）。
    public func setShortcut(_ shortcut: Shortcut, for action: GlobalShortcutAction) {
        let wasUnbound = unboundShortcuts.contains(action)
        guard wasUnbound || shortcut != shortcuts[action] else { return }
        unboundShortcuts.remove(action)
        shortcuts[action] = shortcut
        store.set(false, forKey: "\(action.keyPrefix).unbound")
        store.set(NSNumber(value: shortcut.keyCode), forKey: "\(action.keyPrefix).keyCode")
        store.set(NSNumber(value: shortcut.modifiers), forKey: "\(action.keyPrefix).modifiers")
        logger.notice("""
            shortcut updated; action=\(action.rawValue, privacy: .public) \
            keyCode=\(shortcut.keyCode, privacy: .public) \
            modifiers=\(shortcut.modifiers, privacy: .public)
            """)
    }

    /// 清空并解绑某个全局动作的快捷键。
    public func clearShortcut(for action: GlobalShortcutAction) {
        unboundShortcuts.insert(action)
        shortcuts.removeValue(forKey: action)
        store.set(true, forKey: "\(action.keyPrefix).unbound")
        store.removeObject(forKey: "\(action.keyPrefix).keyCode")
        store.removeObject(forKey: "\(action.keyPrefix).modifiers")
        logger.notice("shortcut cleared; action=\(action.rawValue, privacy: .public)")
    }

    /// 恢复某个动作的默认组合。
    public func resetShortcut(_ action: GlobalShortcutAction) {
        if let fallback = defaultShortcut(for: action) {
            setShortcut(fallback, for: action)
        } else {
            clearShortcut(for: action)
        }
    }

    // 兼容既有调用点
    public var captureShortcut: Shortcut { shortcut(for: .capture) }
    public var windowCaptureShortcut: Shortcut? { optionalShortcut(for: .windowCapture) }
    public var pinToggleShortcut: Shortcut { shortcut(for: .pinToggle) }
    public var recordingShortcut: Shortcut { shortcut(for: .recording) }
    public var longScreenshotShortcut: Shortcut { shortcut(for: .longScreenshot) }
    public var ocrShortcut: Shortcut { shortcut(for: .ocr) }
    public var ocrAutoTranslateShortcut: Shortcut { shortcut(for: .ocrAutoTranslate) }
    public var selectionTranslateShortcut: Shortcut { shortcut(for: .selectionTranslate) }

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

    // MARK: 截图与工具栏交互偏好

    /// 独立窗体截图默认是否合成柔和阴影（默认开启；窗体捕获时按住 `⌥` 可临时反转）。
    public private(set) var windowCaptureShadow: Bool

    public func setWindowCaptureShadow(_ enabled: Bool) {
        guard enabled != windowCaptureShadow else { return }
        windowCaptureShadow = enabled
        store.set(enabled, forKey: Key.windowCaptureShadow)
    }

    /// 画有标注时按 `Esc` 是否需要二次确认以防误关（默认开启）。
    public private(set) var confirmCancelWithAnnotations: Bool

    public func setConfirmCancelWithAnnotations(_ enabled: Bool) {
        guard enabled != confirmCancelWithAnnotations else { return }
        confirmCancelWithAnnotations = enabled
        store.set(enabled, forKey: Key.confirmCancelWithAnnotations)
    }

    /// 用户隐藏的截图主工具栏槽位标识集合（隐藏按钮但保留快捷键）。
    public private(set) var toolbarHiddenSlots: Set<String>

    public func setToolbarHiddenSlots(_ slots: Set<String>) {
        guard slots != toolbarHiddenSlots else { return }
        toolbarHiddenSlots = slots
        store.set(Array(slots).sorted(), forKey: Key.toolbarHiddenSlots)
    }

    public func setToolbarSlot(_ slotID: String, visible: Bool) {
        var next = toolbarHiddenSlots
        if visible {
            next.remove(slotID)
        } else {
            next.insert(slotID)
        }
        setToolbarHiddenSlots(next)
    }

    // MARK: OCR、翻译与贴图外观偏好

    /// OCR 首选识别语言（默认自动多语）。
    public private(set) var ocrLanguage: OCRLanguagePreference

    public func setOCRLanguage(_ language: OCRLanguagePreference) {
        guard language != ocrLanguage else { return }
        ocrLanguage = language
        store.set(language.rawValue, forKey: Key.ocrLanguage)
    }

    /// OCR 面板是否默认合并段内软换行（默认关闭，保持逐行）。
    public private(set) var ocrMergeLineBreaks: Bool

    public func setOCRMergeLineBreaks(_ enabled: Bool) {
        guard enabled != ocrMergeLineBreaks else { return }
        ocrMergeLineBreaks = enabled
        store.set(enabled, forKey: Key.ocrMergeLineBreaks)
    }

    /// OCR 时是否同步检测二维码与条形码（默认开启）。
    public private(set) var ocrDetectBarcodes: Bool

    public func setOCRDetectBarcodes(_ enabled: Bool) {
        guard enabled != ocrDetectBarcodes else { return }
        ocrDetectBarcodes = enabled
        store.set(enabled, forKey: Key.ocrDetectBarcodes)
    }

    /// 翻译面板记忆的目标语种（默认简体中文 `zh-Hans`）。
    public private(set) var translationTargetLanguage: String

    public func setTranslationTargetLanguage(_ identifier: String) {
        guard !identifier.isEmpty, identifier != translationTargetLanguage else { return }
        translationTargetLanguage = identifier
        store.set(identifier, forKey: Key.translationTargetLanguage)
    }

    /// 划词后是否在光标附近展示悬浮「译」按钮（默认关闭，开启需辅助功能权限）。
    public private(set) var selectionTranslateFloatingButton: Bool

    /// 划词悬浮按钮开关变化时的回调（供 `AppDelegate` 即时启停全局鼠标拖选监听）。
    public var onSelectionTranslateFloatingButtonChanged: ((Bool) -> Void)?

    public func setSelectionTranslateFloatingButton(_ enabled: Bool) {
        guard enabled != selectionTranslateFloatingButton else { return }
        selectionTranslateFloatingButton = enabled
        store.set(enabled, forKey: Key.selectionTranslateFloatingButton)
        onSelectionTranslateFloatingButtonChanged?(enabled)
    }

    /// 新建贴图默认是否显示高对比双层边框（默认开启）。
    public private(set) var pinShowBorder: Bool

    public func setPinShowBorder(_ enabled: Bool) {
        guard enabled != pinShowBorder else { return }
        pinShowBorder = enabled
        store.set(enabled, forKey: Key.pinShowBorder)
    }

    /// 长截图是否默认开启像素级自动平滑翻页（默认开启；缺辅助功能权限自动零中断降级手动）。
    public private(set) var longshotAutoScrollEnabled: Bool

    public func setLongshotAutoScrollEnabled(_ enabled: Bool) {
        guard enabled != longshotAutoScrollEnabled else { return }
        longshotAutoScrollEnabled = enabled
        store.set(enabled, forKey: Key.longshotAutoScrollEnabled)
    }

    /// 长截图自动翻页速度档位（慢 / 标准 / 快，默认标准）。
    public private(set) var longshotAutoScrollSpeed: AutoScrollSpeed

    public func setLongshotAutoScrollSpeed(_ speed: AutoScrollSpeed) {
        guard speed != longshotAutoScrollSpeed else { return }
        longshotAutoScrollSpeed = speed
        store.set(speed.rawValue, forKey: Key.longshotAutoScrollSpeed)
    }

    // MARK: 导出压缩、外观与双语偏好（Phase 5）

    /// 默认导出图像格式（PNG / JPEG / HEIC / WebP 无损）。
    public private(set) var exportFormat: ExportFormatOption

    public func setExportFormat(_ format: ExportFormatOption) {
        guard format != exportFormat else { return }
        exportFormat = format
        store.set(format.rawValue, forKey: Key.exportFormat)
    }

    /// JPEG / HEIC 导出质量（`0.1...1.0`，默认 `0.88`）。
    public private(set) var exportQuality: Double

    public func setExportQuality(_ quality: Double) {
        let clamped = min(1.0, max(0.1, quality))
        guard abs(clamped - exportQuality) > 0.001 else { return }
        exportQuality = clamped
        store.set(clamped, forKey: Key.exportQuality)
    }

    /// 当前解析出的 `ImageFormat`。
    public var resolvedImageFormat: ImageFormat {
        exportFormat.imageFormat(quality: exportQuality)
    }

    /// 是否开启 MIT `oxipng` 后台无损 PNG 二阶段精压（默认开启）。
    public private(set) var pngLosslessOptimize: Bool

    public func setPNGLosslessOptimize(_ enabled: Bool) {
        guard enabled != pngLosslessOptimize else { return }
        pngLosslessOptimize = enabled
        store.set(enabled, forKey: Key.pngLosslessOptimize)
    }

    /// 复制到剪贴板时是否同时声明按需 TIFF 兼容老应用（默认开启）。
    public private(set) var pasteboardLazyTIFF: Bool

    public func setPasteboardLazyTIFF(_ enabled: Bool) {
        guard enabled != pasteboardLazyTIFF else { return }
        pasteboardLazyTIFF = enabled
        store.set(enabled, forKey: Key.pasteboardLazyTIFF)
    }

    /// 应用外观模式（跟随系统 / 浅色 / 深色）。
    public private(set) var appearanceMode: AppAppearanceMode

    public func setAppearanceMode(_ mode: AppAppearanceMode) {
        guard mode != appearanceMode else { return }
        appearanceMode = mode
        store.set(mode.rawValue, forKey: Key.appearanceMode)
        AnShotTheme.apply(appearanceMode: mode)
    }

    /// 应用界面语言（跟随系统 / 简体中文 / English）。
    public private(set) var appLanguage: AppLanguage

    public func setAppLanguage(_ language: AppLanguage) {
        guard language != appLanguage else { return }
        appLanguage = language
        store.set(language.rawValue, forKey: Key.appLanguage)
        AnShotLocalization.apply(language)
    }

    /// 操作完成轻提示 Toast 开关（默认开启）。
    public private(set) var showCompletionToast: Bool

    public func setShowCompletionToast(_ enabled: Bool) {
        guard enabled != showCompletionToast else { return }
        showCompletionToast = enabled
        store.set(enabled, forKey: Key.showCompletionToast)
        ToastPresenter.isEnabled = enabled
    }

    /// 录制屏幕期间是否显示边界提示范围框（默认开启；隐藏后仍可正常录制）。
    public private(set) var recordingShowRegionFrame: Bool

    public func setRecordingShowRegionFrame(_ enabled: Bool) {
        guard enabled != recordingShowRegionFrame else { return }
        recordingShowRegionFrame = enabled
        store.set(enabled, forKey: Key.recordingShowRegionFrame)
    }

    // MARK: 键名

    private enum Key {
        static let installSchemaVersion = "settings.installSchemaVersion"
        static let saveMode = "settings.save.mode"
        static let saveFolderPath = "settings.save.folderPath"
        static let pinMaximumCount = "settings.pin.maximumCount"
        static let windowCaptureShadow = "settings.windowCaptureShadow"
        static let confirmCancelWithAnnotations = "settings.confirmCancelWithAnnotations"
        static let toolbarHiddenSlots = "settings.toolbarHiddenSlots"
        static let ocrLanguage = "settings.ocrLanguage"
        static let ocrMergeLineBreaks = "settings.ocrMergeLineBreaks"
        static let ocrDetectBarcodes = "settings.ocrDetectBarcodes"
        static let translationTargetLanguage = "settings.translationTargetLanguage"
        static let selectionTranslateFloatingButton = "settings.selectionTranslateFloatingButton"
        static let pinShowBorder = "settings.pinShowBorder"
        static let longshotAutoScrollEnabled = "settings.longshotAutoScrollEnabled"
        static let longshotAutoScrollSpeed = "settings.longshotAutoScrollSpeed"
        static let exportFormat = "settings.exportFormat"
        static let exportQuality = "settings.exportQuality"
        static let pngLosslessOptimize = "settings.pngLosslessOptimize"
        static let pasteboardLazyTIFF = "settings.pasteboardLazyTIFF"
        static let appearanceMode = "settings.appearanceMode"
        static let appLanguage = "settings.appLanguage"
        static let showCompletionToast = "settings.showCompletionToast"
        static let recordingShowRegionFrame = "settings.recordingShowRegionFrame"
    }

    private enum Mode {
        static let ask = "ask"
        static let folder = "folder"
    }
}
