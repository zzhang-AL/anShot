//
//  SettingsNavigation.swift
//  AnShotUI
//
//  设置窗口的导航模型：页面清单与主菜单项。
//
//  纯数据与标识，不含任何视图代码。视图侧按这些标识决定显示哪一页。
//
import AppKit

/// 设置窗口的一页。
///
/// 侧边栏的每一项与这里的 case 一一对应；新增设置分组时，
/// 加一个 case 就会同时在侧边栏出现，不需要在两处各写一遍标题与图标。
enum SettingsPage: String, CaseIterable {

    case general
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
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .save: return "tray.and.arrow.down"
        case .pin: return "pin"
        case .recognition: return "text.viewfinder"
        case .translation: return "character.book.closed"
        case .about: return "info.circle"
        }
    }

    @MainActor
    var subtitle: String {
        switch self {
        case .general: return L("settings.subtitle.general", fallback: "外观、语言、系统权限、截图交互与登录启动")
        case .shortcuts: return L("settings.subtitle.shortcuts", fallback: "统一管理全局热键（支持解绑与 F1–F20）及覆盖层快捷键")
        case .save: return L("settings.subtitle.save", fallback: "保存位置、多格式导出、无损压缩与剪贴板行为")
        case .pin: return L("settings.subtitle.pin", fallback: "配置固定截图的数量上限、边框样式与隐显快捷键")
        case .recognition: return L("settings.subtitle.recognition", fallback: "选择本地或云端文字识别引擎与二维码识别")
        case .translation: return L("settings.subtitle.translation", fallback: "配置系统离线翻译与云端翻译模型")
        case .about: return L("settings.subtitle.about", fallback: "查看应用版本、更新与诊断信息")
        }
    }

    /// 跨分类搜索关键词表（中英双语覆盖，支持输入任意功能名/术语即时定位）。
    var searchKeywords: [String] {
        switch self {
        case .general:
            return ["通用", "general", "外观", "深色", "浅色", "dark", "light", "主题", "theme", "语言", "language", "english", "中文", "权限", "permission", "tcc", "tccutil", "自愈", "屏幕录制", "辅助功能", "麦克风", "阴影", "shadow", "esc", "工具栏", "toolbar", "长截图", "自动翻页", "autoscroll", "提示", "toast", "范围框", "录屏", "启动", "login"]
        case .shortcuts:
            return ["快捷键", "热键", "shortcut", "hotkey", "f1", "f12", "解绑", "清空", "窗体", "window", "截图", "录制", "长截图", "ocr", "翻译", "贴图"]
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

// MARK: - 表单控件外壳

/// 应用级标准主菜单（含「编辑」菜单）。
///
/// ── 一个「菜单栏辅助程序」为什么需要常驻主菜单 ──────────────
///
/// 本应用默认以 `.accessory` 策略运行，没有 Dock 图标。
/// macOS 的文本编辑快捷键（⌘C / ⌘V / ⌘X / ⌘A）是以菜单项 key equivalent
/// 经 `NSApplication.sendAction(_:to:from:)` 分发到标准 selector 的。
/// 若仅在设置窗口打开期间临时安装主菜单，其余窗口（OCR 面板、文字标注框、
/// 历史/窗口搜索框、取色器 Hex 框、崩溃与长截图日志窗）的文本快捷键会集体失效。
///
/// 因此在应用启动时全局常驻挂载本主菜单；截图覆盖层在非文本编辑态会在
/// `performKeyEquivalent` 中优先拦截画布级 `⌘C / ⌘Z / ⇧⌘Z`，两者互不冲突。
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

    /// 构造菜单。
    ///
    /// 独立于 `install` 暴露出来，是为了让诊断能直接检查它：
    /// 「有没有 `paste:` 项」这类缺失不检查就一定会漏。
    static func make() -> NSMenu {
        let mainMenu = NSMenu()

        // HIG 要求第一个菜单是应用名。
        //
        // 注意标题要同时设在 `NSMenuItem` 和它的 `NSMenu` 上：只设 `NSMenu`
        // 的话菜单栏上会渲染成一个**空白标题**的菜单（系统不会帮忙补），
        // 而按标题查找子菜单也会失败。
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

        // 编辑菜单：下面这几项就是 ⌘C/⌘V/⌘X/⌘A 的分发通道。
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

        // 窗口菜单：提供全局标准 ⌘W 关闭当前窗口通道，避免欢迎页/历史预览/日志等独立窗失灵。
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

/// 独立窗口的前台激活策略协调器。
///
/// 本应用空闲期以 `.accessory`（无 Dock 图标）运行；当任意独立窗口（欢迎页、设置、
/// 历史记录、预览、崩溃日志、长截图日志、更新窗）可见时，将其切换为 `.regular`，
/// 让用户可以通过 `⌘Tab` 与 Dock 找回被切走的窗口；所有独立窗口关闭后再切回 `.accessory`。
@MainActor
enum ForegroundPolicyCoordinator {

    /// 当前正处于可见状态的独立窗口标识集合。
    private static var activeTokens: Set<String> = []

    /// 测试或诊断可见的当前活跃窗口标识数量。
    static var activeCount: Int { activeTokens.count }

    /// 登记一个独立窗口进入可见态，并在需要时切换为 `.regular`。
    static func acquire(_ token: String) {
        activeTokens.insert(token)
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// 注销一个独立窗口；若已无其他独立窗口可见，则恢复为 `.accessory`。
    static func release(_ token: String) {
        activeTokens.remove(token)
        if activeTokens.isEmpty, NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// 清空全部登记状态（仅供测试复位使用）。
    static func resetForTesting() {
        activeTokens.removeAll()
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - 输入框尾部图标按钮
