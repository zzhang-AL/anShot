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
    case save
    case pin
    case recognition
    case translation
    /// 版本、更新与诊断入口。
    ///
    /// 放在最后而不是最前：设置页的顺序是「先改行为，再看状态」，
    /// 关于页是只读信息与诊断入口，放在末尾不会把常用项挤下去。
    case about

    var title: String {
        switch self {
        case .general: return "通用"
        case .save: return "保存"
        case .pin: return "固定截图"
        case .recognition: return "文字识别"
        case .translation: return "翻译"
        case .about: return "关于"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .save: return "tray.and.arrow.down"
        case .pin: return "pin"
        case .recognition: return "text.viewfinder"
        case .translation: return "character.book.closed"
        case .about: return "info.circle"
        }
    }

    /// 页面右上角的说明。
    var subtitle: String {
        switch self {
        case .general: return "管理全局快捷键与登录启动方式"
        case .save: return "设置截图保存位置与输出行为"
        case .pin: return "配置固定截图的数量上限与隐显快捷键"
        case .recognition: return "选择本地或云端文字识别引擎"
        case .translation: return "配置系统翻译与云端翻译模型"
        case .about: return "查看应用版本、更新与诊断信息"
        }
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
