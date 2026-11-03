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
        case .general: return "截图快捷键与启动方式。改动立即生效。"
        case .save: return "截图保存到哪里。改动立即生效。"
        case .pin: return "固定截图保留多少张，以及怎么一键收起。改动立即生效。"
        case .recognition: return "用什么识别图片里的文字。改动立即生效。"
        case .translation: return "把识别出的文字翻译成其他语言。改动立即生效。"
        case .about: return "版本、更新与诊断。改动立即生效。"
        }
    }
}

// MARK: - 表单控件外壳

/// 设置窗口需要的最小主菜单。
///
/// ── 一个「菜单栏辅助程序」为什么需要它 ─────────────────────
///
/// 本应用以 `.accessory` 策略运行，没有 Dock 图标，主菜单看起来多余。
/// 但 macOS 的文本编辑快捷键（⌘C / ⌘V / ⌘X / ⌘A）**不是** field editor
/// 自己处理的：它们以菜单项的 key equivalent 形式，经
/// `NSApplication.sendAction(_:to:from:)` 分发到 `paste:` 这类标准 selector。
///
/// 没有主菜单 = 没有这些菜单项 = 设置窗口里的输入框**无法粘贴**，
/// 而且不抛错、日志里什么都没有。代码上完全看不出问题，
/// 只有真的按一次 ⌘V 才会发现——所以它值得一条诊断断言。
///
/// ── 为什么只在设置窗口打开时安装 ──────────────────────────
///
/// 截图覆盖层自己也用 ⌘Z / ⌘C（撤销、拷贝），语义与编辑菜单不同。
/// 菜单的 key equivalent 先于窗口的第一响应者拿到事件：菜单项若可用，
/// 事件就被它截走，覆盖层的快捷键会静默失效；若不可用则继续下发。
/// 「恰好是 disabled」不是一个能依赖的前提，因此主菜单的存在
/// 严格跟随设置窗口的生命周期。
@MainActor
enum SettingsMainMenu {

    /// 安装。
    static func install() {
        NSApp.mainMenu = make()
    }

    /// 移除，回到「无菜单」状态。
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

        return mainMenu
    }
}

// MARK: - 输入框尾部图标按钮
