//
//  Localization.swift
//  AnShotUI
//
//  轻量化双语本地化引擎（简体中文 / English / 跟随系统），支持运行期零重启热切换。
//

import Foundation

/// 应用界面语言选项（契约 `ux-polish/model.md` §4.2：`settings.appLanguage`）。
public enum AppLanguage: String, CaseIterable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    @MainActor
    public var displayName: String {
        switch self {
        case .system: return L("language.system", fallback: "跟随系统")
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    /// 解析当前生效的语言是否为英文。
    public var resolvesToEnglish: Bool {
        switch self {
        case .en:
            return true
        case .zhHans:
            return false
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "zh"
            return preferred.hasPrefix("en")
        }
    }
}

/// 轻量化界面文案注册与运行时热切换调度器。
@MainActor
public enum AnShotLocalization {

    /// 语言切换通知（各常驻窗口/设置页可监听刷新文案）。
    public static let didChangeNotification = Notification.Name("com.anshot.languageDidChange")

    /// 当前生效的语言配置（默认跟随系统）。
    public private(set) static var currentLanguage: AppLanguage = .system

    /// 是否以英文呈现文案。
    public static var isEnglish: Bool {
        currentLanguage.resolvesToEnglish
    }

    /// 切换运行期语言并广播通知。
    public static func apply(_ language: AppLanguage) {
        guard language != currentLanguage else { return }
        currentLanguage = language
        NotificationCenter.default.post(name: didChangeNotification, object: language)
    }

    /// 查询双语词典；未命中时返回中文回退文案，确保绝不输出裸键名。
    public static func text(_ key: String, fallback zh: String) -> String {
        guard isEnglish else { return zh }
        return englishTable[key] ?? zh
    }

    /// 高频主菜单、设置导航、通用按钮与核心交互的英文映射表。
    private static let englishTable: [String: String] = [
        // 语言与外观
        "language.system": "Follow System",
        "appearance.system": "Follow System",
        "appearance.light": "Light",
        "appearance.dark": "Dark",

        // 菜单栏高频入口
        "menu.capture": "Capture Area",
        "menu.windowCapture": "Capture Window",
        "menu.chooseWindow": "Choose Window…",
        "menu.longScreenshot": "Scrolling Capture…",
        "menu.ocr": "Recognize Text (OCR)…",
        "menu.ocrTranslate": "Capture & Translate…",
        "menu.selectionTranslate": "Translate Selection",
        "menu.recording": "Record Screen…",
        "menu.recordingFullScreen": "Record Full Screen",
        "menu.pin": "Pinned Screenshots",
        "menu.pinFromClipboard": "Pin from Clipboard",
        "menu.history": "History…",
        "menu.openImage": "Open Image…",
        "menu.moreTools": "More & Diagnostics",
        "menu.ocrFromClipboard": "OCR from Clipboard",
        "menu.ocrFromFile": "OCR Image File…",
        "menu.scrollshotLog": "Scrolling Capture Logs…",
        "menu.crashLog": "Crash Logs…",
        "menu.welcome": "Welcome & Permissions…",
        "menu.checkUpdate": "Check for Updates…",
        "menu.github": "GitHub Repository",
        "menu.relaunch": "Relaunch anShot",
        "menu.settings": "Settings…",
        "menu.quit": "Quit anShot",
        "menu.disableClickThrough": "Disable Pin Click-Through",

        // 设置分类页标题
        "settings.windowTitle": "anShot Settings",
        "settings.searchPlaceholder": "Search settings…",
        "settings.page.general": "General",
        "settings.page.capture": "Capture & Annotate",
        "settings.page.shortcuts": "Shortcuts",
        "settings.page.save": "Save & Export",
        "settings.page.pin": "Pinned",
        "settings.page.recognition": "OCR",
        "settings.page.translation": "Translation",
        "settings.page.about": "About",

        // 设置分类页副标题
        "settings.subtitle.general": "Appearance, language, startup and system permissions",
        "settings.subtitle.capture": "Window shadows, Esc guard, recording frame, scrollshot and toolbar slots",
        "settings.subtitle.shortcuts": "Configure global shortcuts, unbind keys or view overlay hotkeys",
        "settings.subtitle.save": "Output directory, format, lossless compression and clipboard",
        "settings.subtitle.pin": "Pinned screenshot limit, border styling and visibility",
        "settings.subtitle.recognition": "Local Vision OCR and cloud recognition providers",
        "settings.subtitle.translation": "System offline translation and cloud LLM translation",
        "settings.subtitle.about": "Version, updates, crash logs and project links",

        // 通用按钮与权限
        "common.close": "Close",
        "common.cancel": "Cancel",
        "common.copy": "Copy",
        "common.save": "Save",
        "common.edit": "Edit",
        "common.refresh": "Refresh",
        "common.revealInFinder": "Show in Finder",
        "common.resetDefault": "Reset",
        "common.clear": "Clear",
        "common.unbound": "Not Set",
        "permission.granted": "Granted",
        "permission.notGranted": "Not Granted",
        "permission.openSettings": "Open Settings",
        "permission.resetTCC": "Reset TCC & Repair",
    ]
}

/// 简写本地化读取函数（供 `AnShotUI` 各视图与菜单栏调用）。
@MainActor
public func L(_ key: String, fallback zh: String) -> String {
    AnShotLocalization.text(key, fallback: zh)
}
