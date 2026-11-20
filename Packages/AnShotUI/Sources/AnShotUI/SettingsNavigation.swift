//
//  SettingsNavigation.swift
//  AnShotUI
//
//  设置窗口的导航模型：8 大清晰分类页面清单（含语义色徽章与跨分类关键词检索）及全局主菜单。
//
import AppKit

/// 设置窗口的一页。
///
/// 侧边栏的每一项与这里的 case 一一对应；信息架构经梳理分为 8 大高内聚分类，
/// 将原先堆积在「通用」中的截图行为、长截图与工具栏自定义拆出为独立的「截图与标注」页。
enum SettingsPage: String, CaseIterable {

    case general
    case capture
    case shortcuts
    case save
    case pin
    case recognition
    case translation
    case about

    @MainActor
    var title: String {
        switch self {
        case .general: return L("settings.page.general", fallback: "通用")
        case .capture: return L("settings.page.capture", fallback: "截图与标注")
        case .shortcuts: return L("settings.page.shortcuts", fallback: "快捷键")
        case .save: return L("settings.page.save", fallback: "保存与导出")
        case .pin: return L("settings.page.pin", fallback: "固定截图")
        case .recognition: return L("settings.page.recognition", fallback: "文字识别")
        case .translation: return L("settings.page.translation", fallback: "翻译")
        case .about: return L("settings.page.about", fallback: "关于")
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .capture: return "viewfinder"
        case .shortcuts: return "command"
        case .save: return "tray.and.arrow.down.fill"
        case .pin: return "pin.fill"
        case .recognition: return "text.viewfinder"
        case .translation: return "character.book.closed.fill"
        case .about: return "info.circle"
        }
    }

    /// 现代 macOS 分类语义色（用于侧边栏 22×22 徽章与页头 40×40 渐变徽章）。
    var badgeColor: NSColor {
        switch self {
        case .general:
            return NSColor(srgbRed: 0.24, green: 0.52, blue: 0.96, alpha: 1) // 经典系统蓝
        case .capture:
            return NSColor(srgbRed: 0.36, green: 0.42, blue: 0.95, alpha: 1) // 活力靛蓝
        case .shortcuts:
            return NSColor(srgbRed: 0.58, green: 0.36, blue: 0.92, alpha: 1) // 优雅紫罗兰
        case .save:
            return NSColor(srgbRed: 0.16, green: 0.72, blue: 0.48, alpha: 1) // 翡翠绿
        case .pin:
            return NSColor(srgbRed: 0.95, green: 0.56, blue: 0.18, alpha: 1) // 琥珀橙
        case .recognition:
            return NSColor(srgbRed: 0.12, green: 0.66, blue: 0.78, alpha: 1) // 清澈青碧
        case .translation:
            return NSColor(srgbRed: 0.92, green: 0.34, blue: 0.52, alpha: 1) // 珊瑚玫瑰
        case .about:
            return NSColor(srgbRed: 0.46, green: 0.50, blue: 0.58, alpha: 1) // 沉稳石板灰
        }
    }

    @MainActor
    var subtitle: String {
        switch self {
        case .general:
            return L("settings.subtitle.general", fallback: "外观主题、界面语言、登录启动与系统权限自愈")
        case .capture:
            return L("settings.subtitle.capture", fallback: "窗体阴影、防误关保护、录屏提示框、滚动长截图与工具栏槽位")
        case .shortcuts:
            return L("settings.subtitle.shortcuts", fallback: "全局热键（支持解绑与 F1–F20）及覆盖层快捷键速查")
        case .save:
            return L("settings.subtitle.save", fallback: "保存位置、多格式导出、无损精压与剪贴板行为")
        case .pin:
            return L("settings.subtitle.pin", fallback: "固定截图保留上限、高对比边框与隐显热键")
        case .recognition:
            return L("settings.subtitle.recognition", fallback: "本地或云端文字识别引擎、默认语种与二维码扫描")
        case .translation:
            return L("settings.subtitle.translation", fallback: "系统离线翻译、云端翻译模型与划词悬浮翻译")
        case .about:
            return L("settings.subtitle.about", fallback: "应用版本、自动更新、崩溃诊断日志与项目主页")
        }
    }

    /// 跨分类搜索关键词表（中英双语覆盖，支持输入任意功能名/术语即时定位）。
    var searchKeywords: [String] {
        switch self {
        case .general:
            return ["通用", "general", "外观", "深色", "浅色", "dark", "light", "主题", "theme", "语言", "language", "english", "中文", "权限", "permission", "tcc", "tccutil", "自愈", "屏幕录制", "辅助功能", "麦克风", "提示", "toast", "启动", "开机", "login", "mcp", "自动化", "automation", "token", "令牌", "安全", "security", "隐私", "密码", "1password", "socket"]
        case .capture:
            return ["截图", "标注", "capture", "annotation", "阴影", "shadow", "esc", "防误关", "工具栏", "toolbar", "槽位", "长截图", "滚动", "自动翻页", "autoscroll", "速度", "范围框", "录屏", "recording"]
        case .shortcuts:
            return ["快捷键", "热键", "shortcut", "hotkey", "f1", "f12", "解绑", "清空", "窗体", "window", "截图", "录制", "长截图", "ocr", "翻译", "贴图", "速查"]
        case .save:
            return ["保存", "导出", "save", "export", "文件夹", "folder", "每次询问", "png", "jpeg", "jpg", "heic", "webp", "质量", "quality", "压缩", "oxipng", "无损", "剪贴板", "tiff", "pasteboard", "dpi"]
        case .pin:
            return ["固定", "贴图", "pin", "上限", "limit", "边框", "border", "穿透", "隐藏"]
        case .recognition:
            return ["识别", "文字", "ocr", "vision", "百度", "openai", "claude", "二维码", "qrcode", "barcode", "语言"]
        case .translation:
            return ["翻译", "translation", "apple", "系统", "云端", "划词", "悬浮", "目标语种", "语言"]
        case .about:
            return ["关于", "about", "版本", "version", "更新", "update", "崩溃", "crash", "日志", "github", "release"]
        }
    }

    /// 判断是否命中跨分类搜索查询词。
    @MainActor
    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }
        if title.lowercased().contains(trimmed) || subtitle.lowercased().contains(trimmed) {
            return true
        }
        return searchKeywords.contains { $0.contains(trimmed) }
    }
}

// MARK: - 应用级标准主菜单

/// 应用级标准主菜单（含「编辑」「窗口」菜单）。
@MainActor
enum SettingsMainMenu {

    /// 安装全局常驻主菜单。
    static func install() {
        NSApp.mainMenu = make()
    }

    /// 移除主菜单（仅保留用于测试或显式清理场景）。
    static func remove() {
        NSApp.mainMenu = nil
    }

    static func make() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: "anShot", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "anShot")
        appMenu.addItem(
            withTitle: "关于 anShot",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "隐藏 anShot",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 anShot",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        return mainMenu
    }
}

// MARK: - 前台激活策略协调器

@MainActor
enum ForegroundPolicyCoordinator {

    private static var activeTokens: Set<String> = []

    static var activeCount: Int { activeTokens.count }

    static func acquire(_ token: String) {
        activeTokens.insert(token)
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    static func release(_ token: String) {
        activeTokens.remove(token)
        if activeTokens.isEmpty, NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func resetForTesting() {
        activeTokens.removeAll()
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
