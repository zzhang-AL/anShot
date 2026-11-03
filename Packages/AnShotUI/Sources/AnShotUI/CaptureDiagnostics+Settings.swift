//
//  CaptureDiagnostics+Settings.swift
//
//  CaptureDiagnostics 按主题拆分的一部分（同一类型的多文件 extension）。
//  纯机械拆分：函数体未改动。
//

#if DEBUG

import AnShotCapture
import AnShotCore
@preconcurrency import AVFoundation
import AppKit
import ImageIO
import Carbon.HIToolbox
@preconcurrency import ScreenCaptureKit
import Foundation

extension CaptureDiagnostics {

    /// 设置诊断：验证快捷键规则、持久化往返、固定文件夹保存与命名冲突。
    ///
    /// 选这四项的理由：它们都能**静默失败**。
    ///   - 校验规则漏了一条，用户会发现自己再也打不出某个字符；
    ///   - 持久化写错字段，表现为「重启后设置没了」；
    ///   - 冲突处理写错，表现为截图被覆盖——而用户通常很晚才发现。
    ///
    /// 使用独立的 UserDefaults suite，不触碰真实偏好。
    static func runSettingsDiagnostic() async {
        var failures: [String] = []
        func check(_ label: String, _ passed: Bool, detail: String? = nil) {
            let suffix = detail.map { "（\($0)）" } ?? ""
            logger.notice("\(passed ? "✅" : "❌", privacy: .public) \(label, privacy: .public)\(suffix, privacy: .public)")
            if !passed { failures.append(label) }
        }

        // ── 1）快捷键校验规则 ──
        // 全局热键是抢占式的：放行一个坏组合，代价是全系统范围内该按键失效。
        let one = UInt32(kVK_ANSI_1)
        let a = UInt32(kVK_ANSI_A)
        let control = UInt32(controlKey)
        let shift = UInt32(shiftKey)
        let command = UInt32(cmdKey)

        check("⌃1 应被接受",
              Shortcut(keyCode: one, modifiers: control).registrationIssue == nil)
        check("⌘⇧5 应被接受",
              Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: command | shift).registrationIssue == nil)
        check("⇧A 应被拒（⇧ 不足以防止捕获正常输入）",
              Shortcut(keyCode: a, modifiers: shift).registrationIssue == .missingStrongModifier)
        check("无修饰键的 A 应被拒",
              Shortcut(keyCode: a, modifiers: 0).registrationIssue == .missingStrongModifier)
        check("纯修饰键 ⌃ 应被拒",
              Shortcut(keyCode: UInt32(kVK_Control), modifiers: control).registrationIssue == .onlyModifiers)

        // ── 2）显示格式 ──
        check("⌃1 应显示为「⌃1」",
              Shortcut(keyCode: one, modifiers: control).displayName == "⌃1")
        check("⌘⇧5 的修饰符顺序应为 ⌘ 在最后",
              Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: command | shift).displayName == "⇧⌘5")

        // ── 3）持久化往返 ──
        // 用独立 suite：诊断不得写脏用户的真实偏好。
        let suiteName = "com.anshot.app.diagnostic.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suiteName) else {
            logger.error("settings diag: 无法创建测试 suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(store: store)
        check("默认快捷键应为 ⌃1", settings.captureShortcut == AppSettings.defaultCaptureShortcut)
        check("默认保存位置应为「每次询问」", settings.saveDestination == .ask)

        let custom = Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: command | shift)
        settings.setCaptureShortcut(custom)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-diag-\(UUID().uuidString)")
        settings.setSaveFolder(folder)

        // 关键：「模拟重启」——重新读同一个 store，而不是看同一个实例的内存值。
        // 内存值对不代表写对了字段。
        let reloaded = AppSettings(store: UserDefaults(suiteName: suiteName) ?? store)
        check("重新读取后快捷键应保持", reloaded.captureShortcut == custom)
        check("重新读取后保存位置应保持",
              reloaded.activeSaveFolder?.path == folder.standardizedFileURL.path)
        // ~ 缩写：用家目录下的路径才能真的验证，临时目录在 ~ 之外。
        let homeFolder = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Pictures/Screenshots")
        settings.setSaveFolder(homeFolder)
        let abbreviated = (homeFolder.path as NSString).abbreviatingWithTildeInPath
        check("家目录下的路径应缩写为 ~ 开头", abbreviated.hasPrefix("~/"),
              detail: "实际=\(abbreviated)")

        // ── 4）固定文件夹保存 + 命名冲突 ──
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        guard let image = makeDiagnosticImage() else {
            logger.error("settings diag: 无法构造测试图像")
            return
        }
        let name = "截图 2026-09-12 18-30-05.png"

        let first = SessionExporter.save(image, suggestedName: name, destination: .folder(folder))
        guard case .saved(let firstURL) = first else {
            check("写入固定文件夹应成功", false)
            reportSettingsDiagnostic(failures)
            return
        }
        check("写入固定文件夹应成功", true)
        check("首次写入应用原名", firstURL.lastPathComponent == name)

        // 同一秒内再存一次：必须改名，不得覆盖。
        let second = SessionExporter.save(image, suggestedName: name, destination: .folder(folder))
        guard case .saved(let secondURL) = second else {
            check("冲突时应改名而非失败", false)
            reportSettingsDiagnostic(failures)
            return
        }
        check("冲突时应改名而非覆盖", secondURL.lastPathComponent != name)
        check("改名后的文件应带 -1 序号", secondURL.lastPathComponent == "截图 2026-09-12 18-30-05-1.png")

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        check("目录中应存在两个文件（首张未被覆盖）", contents.count == 2)

        // ── 5）目录失效的错误分支 ──
        // 用户可能在设置之后把文件夹删掉。必须报错，不能静默不存。
        let missing = folder.appendingPathComponent("does-not-exist")
        let failed = SessionExporter.save(image, suggestedName: name, destination: .folder(missing))
        if case .failed = failed {
            check("目录不存在时应报错", true)
        } else {
            check("目录不存在时应报错", false)
        }

        reportSettingsDiagnostic(failures)
    }

    // MARK: - 设置窗口诊断

    /// 验证设置窗口本身能否工作。
    ///
    /// 重点只有一个：**无 Dock 图标的应用，窗口能不能拿到键盘焦点**。
    /// 这是整个快捷键录制功能的前提——拿不到焦点就收不到 keyDown，
    /// 录制控件会永远停在「请按快捷键」那一屏。
    ///
    /// 用 stub host 而不是真实 `AppDelegate`：诊断不得改动用户的真实热键。
    static func runSettingsWindowDiagnostic() async {
        var failures: [String] = []
        func check(_ label: String, _ passed: Bool, detail: String? = nil) {
            let suffix = detail.map { "（\($0)）" } ?? ""
            logger.notice("\(passed ? "✅" : "❌", privacy: .public) \(label, privacy: .public)\(suffix, privacy: .public)")
            if !passed { failures.append(label) }
        }

        let suiteName = "com.anshot.app.diagnostic.window.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suiteName) else {
            logger.error("settings window diag: 无法创建测试 suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let host = DiagnosticShortcutHost(initial: AppSettings.defaultCaptureShortcut)
        let settings = AppSettings(store: store)
        let controller = SettingsWindowController(
            settings: settings,
            shortcutHost: host
        )
        controller.show()

        // 给激活与建窗留出时间。这是一次真实的窗口显示，
        // 不是可以假设「调用完就完成了」的同步操作。
        try? await Task.sleep(for: .milliseconds(800))

        guard let window = controller.window else {
            check("设置窗口应存在", false)
            reportSettingsDiagnostic(failures)
            return
        }

        check("设置窗口应可见", window.isVisible)

        // 打开设置期间应临时切到 `.regular`。
        //
        // 本应用平时是 `.accessory`（菜单栏常驻、无 Dock 图标），切换器里
        // 看不到它——用户切到别的 app 之后就切不回设置窗口。这条断言守的
        // 就是这个：设置打开时必须在 ⌘Tab 里看得到。
        check(
            "打开设置应切到 regular 策略（Dock 出现、⌘Tab 可见）",
            NSApp.activationPolicy() == .regular,
            detail: "实际 \(NSApp.activationPolicy().rawValue)"
        )
        check("设置窗口应成为 key window（无 Dock 图标下的关键风险）", window.isKeyWindow)

        // 关于「失焦后窗口是否仍可见」：这里**不做断言**。
        //
        // 试过两种写法，在诊断进程里都不行：`NSApp.deactivate()` 要跟窗口
        // 服务器做 app 级激活握手，直接永久阻塞；`window.resignKey()` 直接
        // 段错误（exitCode 139）。诊断是命令行启动的进程，没有真实 UI 会话，
        // 窗口的 key 状态相关操作在这里不安全。
        //
        // 改用「窗口自身的配置」守住这个不变式：`hidesOnDeactivate` 必须是
        // false。它一旦为 true，症状就是用户报的「失焦窗口就不见了」。
        check("窗口不应启用失焦隐藏", !window.hidesOnDeactivate)
        check("标题应为「anShot 设置」", window.title == "anShot 设置")
        check("应只有关闭按钮",
              window.styleMask.contains(.closable)
              && !window.styleMask.contains(.miniaturizable)
              && !window.styleMask.contains(.resizable))

        guard let contentView = window.contentView,
              let recorder = findShortcutRecorder(in: contentView) else {
            check("应能找得到快捷键录制控件", false)
            window.close()
            reportSettingsDiagnostic(failures)
            return
        }
        check("应能找得到快捷键录制控件", true)
        check("录制控件初始应显示默认快捷键 ⌃1", recorder.shortcut == AppSettings.defaultCaptureShortcut)

        // 初始化就必须反映当前模式。
        // 缺失这个刷新时，打开窗口会看到「两个选项都没选中」。
        let initialState = controller.saveControlsState
        check(
            "初始状态应反映当前保存模式（默认每次询问）",
            initialState.askSelected && !initialState.folderSelected,
            detail: "ask=\(initialState.askSelected) folder=\(initialState.folderSelected)"
        )
        check("未选过目录时文件夹选项应禁用", !initialState.folderEnabled)
        check(
            "未选过目录时应显示空状态",
            initialState.primaryText == "尚未选择文件夹",
            detail: "实际=\(initialState.primaryText)"
        )

        // ── 固定截图分组 ──
        //
        // 这里的风险不在「控件存不存在」，而在**界面与设置会不会分叉**：
        // 上限是存在 `UserDefaults` 里的，而用户看到的是步进器与那行文案。
        // 两者一旦不一致，用户就会按界面上的数字去预期行为。
        let pinState = controller.pinControlsState
        check(
            "固定截图：默认上限应为 \(AppSettings.defaultPinMaximumCount)",
            pinState.limit == AppSettings.defaultPinMaximumCount,
            detail: "实际 \(pinState.limit)"
        )
        check(
            "固定截图：步进器、文案与设置三者一致",
            pinState.stepperValue == pinState.limit && pinState.limitText == "\(pinState.limit) 张",
            detail: "stepper=\(pinState.stepperValue) text=\(pinState.limitText)"
        )
        check(
            "固定截图：收起热键应显示默认值 \(AppSettings.defaultPinToggleShortcut.displayName)",
            pinState.toggleShortcut == AppSettings.defaultPinToggleShortcut.displayName,
            detail: "实际=\(pinState.toggleShortcut)"
        )
        check("固定截图：初始无提示", pinState.message.isEmpty, detail: "实际=\(pinState.message)")

        // 设置被外部改掉后，重新同步必须把控件拉回来。
        settings.setPinMaximumCount(AppSettings.pinLimitRange.upperBound)
        controller.reloadFromSettings()
        let reloadedPin = controller.pinControlsState
        check(
            "固定截图：重新同步后控件跟上设置",
            reloadedPin.limit == AppSettings.pinLimitRange.upperBound
            && reloadedPin.stepperValue == AppSettings.pinLimitRange.upperBound,
            detail: "limit=\(reloadedPin.limit) stepper=\(reloadedPin.stepperValue)"
        )
        settings.setPinMaximumCount(AppSettings.defaultPinMaximumCount)
        controller.reloadFromSettings()

        // 热键事务：失败时不得把「当前注册着的组合」改掉。
        let pinCandidate = AppSettings.defaultCaptureShortcut   // 任意一个与当前不同的组合
        host.rejectNextApply = false
        check(
            "固定截图：注册成功的组合会被记录",
            host.applyPinToggleShortcut(pinCandidate) == nil
            && host.activePinToggleShortcut == pinCandidate
        )
        host.rejectNextApply = true
        let pinRejection = host.applyPinToggleShortcut(AppSettings.defaultPinToggleShortcut)
        check(
            "固定截图：注册失败会返回原因，且不动已注册的组合",
            pinRejection != nil && host.activePinToggleShortcut == pinCandidate,
            detail: "reason=\(pinRejection ?? "nil")"
        )
        // 让出/恢复：让出后没有活跃组合，恢复后回到原值。
        _ = host.suspendPinToggleShortcut()
        check("固定截图：让出后没有活跃热键", host.activePinToggleShortcut == nil)
        _ = host.resumePinToggleShortcut()
        check(
            "固定截图：恢复后回到让出前的组合",
            host.activePinToggleShortcut == pinCandidate,
            detail: "实际=\(String(describing: host.activePinToggleShortcut))"
        )

        // 布局已改为「侧边栏 + 单页内容」，原来那组「一页里有两张卡片」的断言
        // 描述的结构已不复存在（现在同时只渲染当前页的卡片）。
        // 新的等价不变量：侧边栏存在且项数与页面数一致、默认停在首页、
        // 当前页渲染出了卡片、卡片贴着**内容区**的边距——
        // 注意内容区从侧边栏右侧开始，所以左边距是「侧边栏宽 + margin」，
        // 而不是窗口 margin。
        let sidebarItems = measureSidebarItems(in: contentView)
        check(
            "侧边栏项数应等于页面数",
            sidebarItems.count == SettingsPage.allCases.count,
            detail: "实际 \(sidebarItems.count)，期望 \(SettingsPage.allCases.count)"
        )
        check(
            "默认应停在「通用」页",
            controller.currentPageForDiagnostics == .general,
            detail: "实际 \(controller.currentPageForDiagnostics.rawValue)"
        )

        // 窗口高度必须**恒定**：切页时窗口跳动比多点留白更分心。
        //
        // 曾经做成「按当前页内容自适应」（想让内容少的页不留白），实测代价
        // 更大：切页时窗口高度跳、侧边栏跟着伸缩。现在改成「取最高的一页固定
        // 住」——既不跳，也不会把任何一页挤扁。
        var pageHeights: [String: CGFloat] = [:]
        for item in sidebarItems {
            item.performClick(nil)
            try? await Task.sleep(for: .milliseconds(150))
            pageHeights[item.page.rawValue] = window.contentLayoutRect.height
        }
        let distinctHeights = Set(pageHeights.values.map { Int($0.rounded()) })
        check(
            "窗口高度应恒定（切页不跳动）",
            distinctHeights.count == 1,
            detail: pageHeights.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(Int($0.value))" }
                .joined(separator: " ")
        )
        check(
            "窗口高度应为设计值",
            distinctHeights == [Int(SettingsTheme.windowHeight)],
            detail: "实际 \(distinctHeights.map(String.init).sorted().joined(separator: ","))"
                + "，期望 \(Int(SettingsTheme.windowHeight))"
        )
        // 回到首页，后面的断言依赖它。
        sidebarItems.first { $0.page == .general }?.performClick(nil)
        try? await Task.sleep(for: .milliseconds(150))

        let cards = measureCards(in: contentView)
        check("当前页应渲染出卡片", !cards.isEmpty, detail: "实际 \(cards.count)")
        if let card = cards.first {
            let expectedLeading = SettingsTheme.sidebarWidth + SettingsTheme.margin
            let expectedTrailing = SettingsTheme.windowWidth - SettingsTheme.margin
            check(
                "卡片左边缘应贴内容区边距（侧边栏宽 + margin）",
                abs(card.leading - expectedLeading) < 1,
                detail: "实际 \(card.leading)，期望 \(expectedLeading)"
            )
            check(
                "卡片右边缘应贴窗口右边距",
                abs(card.trailing - expectedTrailing) < 1,
                detail: "实际 \(card.trailing)，期望 \(expectedTrailing)"
            )
        }

        // ── 主菜单：⌘V 的分发通道 ──
        // 这条断言挡的是一类「不会报错的缺失」：没有 Edit 菜单时，
        // 输入框照样能打字，只有粘贴（以及 ⌘C / ⌘X / ⌘A）静默失效——
        // 功能测试、日志、编译期都看不出来。
        let menu = SettingsMainMenu.make()
        let editMenu = menu.item(withTitle: "编辑")?.submenu
        check("主菜单应含「编辑」子菜单", editMenu != nil)
        check(
            "编辑菜单应含「粘贴」项（否则输入框无法粘贴）",
            editMenu?.items.contains {
                $0.keyEquivalent == "v" && $0.action == #selector(NSText.paste(_:))
            } ?? false
        )
        check(
            "编辑菜单应含「拷贝」项",
            editMenu?.items.contains {
                $0.keyEquivalent == "c" && $0.action == #selector(NSText.copy(_:))
            } ?? false
        )
        check("主菜单应含应用菜单（HIG：第一项为应用名）", menu.items.count >= 2)

        // 合成鼠标点击的**隐含前提**：应用必须处于激活态。
        //
        // 不激活时 AppKit 会把这次 mouseDown 用于激活窗口，事件到不了控件，
        // 表现为「点击类断言集体失败」——看起来像控件坏了，实际是环境问题。
        // 把前提写成断言，下次失败时能一眼分清是哪一类。
        check("应用应处于激活态（合成鼠标点击的前提）", NSApp.isActive)
        click(recorder, in: window)
        check("点击后应进入录制态", recorder.isRecording)
        check("进入录制态应让出全局热键（否则热键会截走按键）", host.suspendCount == 1)

        // 合成一次真实按键：⌘⇧5。
        // 用 sendEvent 而不是直接调 keyDown，走的是与真实按键相同的路径。
        sendKeyEvent(to: window, keyCode: UInt32(kVK_ANSI_5), flags: [.command, .shift], characters: "5")
        try? await Task.sleep(for: .milliseconds(200))

        check("按 ⌘⇧5 后应退出录制态", !recorder.isRecording)
        check("录制结果应为 ⇧⌘5", recorder.shortcut.displayName == "⇧⌘5")
        check("提交后应恢复热键", host.resumeCount == 1)
        check("宿主应收到新快捷键", host.applied == recorder.shortcut)

        // ── Esc 取消 ──
        click(recorder, in: window)
        check("再次点击应重新进入录制态", recorder.isRecording)

        sendKeyEvent(to: window, keyCode: UInt32(kVK_Escape), flags: [], characters: "\u{1B}")
        try? await Task.sleep(for: .milliseconds(200))

        check("Esc 应退出录制态", !recorder.isRecording)
        check("Esc 后快捷键应保持原值", recorder.shortcut.displayName == "⇧⌘5")
        check("Esc 后也应恢复热键", host.resumeCount == 2)

        // ── 非法组合应被拒且不退出录制态 ──
        click(recorder, in: window)
        // ⇧A：缺少强修饰键，必须被拒。
        sendKeyEvent(to: window, keyCode: UInt32(kVK_ANSI_A), flags: [.shift], characters: "A")
        try? await Task.sleep(for: .milliseconds(200))
        check("⇧A 应被拒且保持录制态（静态校验不碰系统状态，可以就地重按）",
              recorder.isRecording && recorder.shortcut.displayName == "⇧⌘5")

        // ── 键盘可达：Space 启动录制、Tab 退出 ──
        // 这两项不实现的话，纯键盘用户永远进不去也出不来录制态。
        recorder.cancelRecordingExternally()
        try? await Task.sleep(for: .milliseconds(100))
        window.makeFirstResponder(recorder)
        sendKeyEvent(to: window, keyCode: UInt32(kVK_Space), flags: [], characters: " ")
        try? await Task.sleep(for: .milliseconds(150))
        check("空闲时按空格应进入录制态（键盘可达）", recorder.isRecording)

        sendKeyEvent(to: window, keyCode: UInt32(kVK_Tab), flags: [], characters: "\t")
        try? await Task.sleep(for: .milliseconds(150))
        check("录制态按 Tab 应退出录制并恢复热键（否则用户会被困住）",
              !recorder.isRecording && host.activeShortcut != nil)

        // ── 注册失败的事务语义 ──
        // 这是全流程最关键的一条：录制开始已让出旧热键，
        // 注册失败后若不退出录制并恢复，用户的热键就真的没了。
        let resumeBefore = host.resumeCount
        host.rejectNextApply = true
        click(recorder, in: window)
        check("失败路径前置：应已进入录制态", recorder.isRecording)
        check("失败路径前置：让出后应无活跃热键", host.activeShortcut == nil)

        sendKeyEvent(to: window, keyCode: UInt32(kVK_ANSI_6), flags: [.command, .shift], characters: "6")
        try? await Task.sleep(for: .milliseconds(250))
        check("注册失败后应**退出录制态**（停在录制会让热键一直未注册）", !recorder.isRecording)
        check("注册失败后应调用恢复", host.resumeCount == resumeBefore + 1)
        check("注册失败后旧热键应真的装回去了", host.activeShortcut != nil)
        check("注册失败的原因应显示在界面上",
              controller.currentMessage.contains("诊断注入的注册失败"))

        // ── 恢复失败的可见性 ──
        // 恢复失败意味着用户的热键消失了，绝不能只写日志。
        host.failNextResume = true
        click(recorder, in: window)
        sendKeyEvent(to: window, keyCode: UInt32(kVK_Escape), flags: [], characters: "\u{1B}")
        try? await Task.sleep(for: .milliseconds(250))
        check("恢复失败应在界面上暴露原因，而不是静默丢热键",
              controller.currentMessage.contains("恢复失败"))

        recorder.cancelRecordingExternally()

        // ── 视觉快照 ──
        // 直接渲染视图层级而不是调 `screencapture`：后者需要终端具备屏幕录制权限，
        // 而渲染自己的视图不需要任何权限，也不受调用方 TCC 状态影响。
        // 深浅两套都出一张，因为语义色是否用对只有在深色下才看得出来。
        //
        // 先把快捷键复原：诊断把它改成了 ⇧⌘5，而快照要反映
        // 用户**首次打开**会看到的样子，不是一个永远看不到的中间态。
        settings.resetCaptureShortcutToDefault()
        controller.reloadContent()
        try? await Task.sleep(for: .milliseconds(200))
        captureViewHierarchy(window, to: "/tmp/anshot-settings-light.png", appearance: nil)
        captureViewHierarchy(
            window,
            to: "/tmp/anshot-settings-dark.png",
            appearance: NSAppearance(named: .darkAqua)
        )

        // 固定截图页也出一张：这一页的控件（上限步进器 + 第二个热键录制器）
        // 是本次新增，断言只能证明状态对，**布局是否被挤扁、控件是否重叠**
        // 只能看图。同一条结论：渲染自己的视图不需要任何权限。
        controller.showPageForDiagnostics(.pin)
        try? await Task.sleep(for: .milliseconds(250))
        captureViewHierarchy(window, to: "/tmp/anshot-settings-pin.png", appearance: nil)
        captureViewHierarchy(
            window,
            to: "/tmp/anshot-settings-pin-dark.png",
            appearance: NSAppearance(named: .darkAqua)
        )
        controller.showPageForDiagnostics(.general)
        try? await Task.sleep(for: .milliseconds(150))

        // ── 保存模式的往返 ──
        // 回归项：曾经把「当前模式」与「记住的目录」合并成一个值，
        // 于是「选目录 → 切回每次询问」之后文件夹选项会变灰，用户再也切不回去。
        let pictures = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Pictures/Screenshots")
        settings.setSaveFolder(pictures)
        controller.reloadContent()
        var state = controller.saveControlsState
        check("选目录后文件夹选项应选中", state.folderSelected && !state.askSelected)
        check("家目录下的路径应显示为 ~ 缩写", state.pathText.hasPrefix("~/"),
              detail: "实际=\(state.pathText)")
        // 两级信息：目录名作为主标题（人认得出的是最后一段），
        // 完整路径在下方。只给路径的话，长路径被截断后就认不出是哪个目录。
        check("目录名应作为主标题显示", state.primaryText == "Screenshots",
              detail: "实际=\(state.primaryText)")

        settings.setSaveDestinationToAsk()
        controller.reloadContent()
        state = controller.saveControlsState
        check("切回「每次询问」后应选中询问项", state.askSelected && !state.folderSelected)
        check("切回「每次询问」后仍需记得目录", settings.rememberedSaveFolder != nil)
        check("切回后文件夹选项**仍应可用**（否则用户切不回来）", state.folderEnabled)
        check("切回后目录信息仍应可见（只是压暗）", state.primaryText == "Screenshots",
              detail: "实际=\(state.primaryText)")

        settings.activateRememberedSaveFolder()
        controller.reloadContent()
        state = controller.saveControlsState
        check("应能切回固定文件夹", state.folderSelected)
        check("切回后应为选定状态", settings.saveDestination == .folder(pictures))

        // 重建 store：验证往返结果真的写进了持久化，而不只是内存值。
        let rebuilt = AppSettings(store: UserDefaults(suiteName: suiteName) ?? store)
        check("重建后应仍为固定文件夹模式", rebuilt.saveDestination == .folder(pictures))
        check("重建后应仍记得目录", rebuilt.rememberedSaveFolder != nil)

        // ── 关闭时的清理 ──
        // 菜单栏程序要求空闲期零窗口，宿主靠 onClose 释放控制器。
        var closeCallbackFired = false
        controller.onClose = { closeCallbackFired = true }
        click(recorder, in: window)
        check("关闭前应处于录制态（用于验证关闭会收尾）", recorder.isRecording)

        window.close()
        try? await Task.sleep(for: .milliseconds(250))
        check("关闭应触发 onClose（宿主据此释放窗口）", closeCallbackFired)
        check("关闭应收尾进行中的录制（否则热键一直未注册）", !recorder.isRecording)

        // ── 第二张：已配置文件夹的状态 ──
        // 路径行与「在访达中显示」只在已配置时才有内容，值得单独看一眼。
        await captureConfiguredState()

        // 关闭之后必须退回 `.accessory`：设置期间切到 `.regular` 只是为了
        // 让 ⌘Tab 能切回来，用完不还回去，菜单栏程序就永久多出一个 Dock 图标。
        // 断言放在这里而不是 `captureConfiguredState()` 里——那个函数是独立的
        // static func，拿不到本函数的 `check`。
        try? await Task.sleep(for: .milliseconds(400))
        check(
            "关闭设置后应恢复 accessory 策略",
            NSApp.activationPolicy() == .accessory,
            detail: "实际 \(NSApp.activationPolicy().rawValue)"
        )

        reportSettingsDiagnostic(failures)
    }

    /// 截一张「已选定保存文件夹」的快照。
    private static func captureConfiguredState() async {
        let suiteName = "com.anshot.app.diagnostic.configured.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suiteName) else { return }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(store: store)
        // 用一个真实存在的长路径，才能看出截断行为是否正确。
        settings.setSaveFolder(FileManager.default.temporaryDirectory)

        let controller = SettingsWindowController(
            settings: settings,
            shortcutHost: DiagnosticShortcutHost(initial: AppSettings.defaultCaptureShortcut)
        )
        controller.show()
        try? await Task.sleep(for: .milliseconds(600))

        if let window = controller.window {
            captureViewHierarchy(window, to: "/tmp/anshot-settings-configured.png", appearance: nil)
            window.close()
        }
    }

    /// 把窗口内容区渲染成 PNG。
    ///
    /// 为什么不能只用 `cacheDisplay(in:to:)`：`contentView` 本身是透明的，
    /// 正常显示时背景由 window 提供。离线渲染没有 window 参与，
    /// 深色模式下就会得到「白底白字」——文字用的是深色模式的语义色（白），
    /// 而底子没跟上。因此必须自己铺背景，且要在**同一个外观上下文**里铺。
    private static func captureViewHierarchy(
        _ window: NSWindow,
        to path: String,
        appearance: NSAppearance?
    ) {
        guard let view = window.contentView else { return }
        let bounds = view.bounds
        let target = appearance ?? NSApp.effectiveAppearance

        view.appearance = appearance
        view.layoutSubtreeIfNeeded()
        defer { view.appearance = nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width),
            pixelsHigh: Int(bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            logger.error("settings UI snapshot: 无法创建渲染上下文")
            return
        }
        rep.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        target.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: bounds).fill()
            view.displayIgnoringOpacity(bounds, in: context)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            logger.error("settings UI snapshot: 无法编码 PNG")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            logger.notice("settings UI snapshot: \(path, privacy: .public)")
        } catch {
            logger.error("settings UI snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 测量所有设置卡片的左右边缘。
    ///
    /// 这是新布局版的「列对齐」：卡片是整窗口唯一的结构单元，
    /// 它们必须共享同一条左边缘与右边缘，否则视觉上会散掉。
    private static func measureCards(in root: NSView)
        -> [(leading: CGFloat, trailing: CGFloat)] {
        var result: [(CGFloat, CGFloat)] = []
        func walk(_ view: NSView) {
            if view is SettingsCardView {
                let frame = view.convert(view.bounds, to: nil)
                result.append((frame.minX, frame.maxX))
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return result
    }

    /// 收集侧边栏项。
    ///
    /// 分页结构本身是这次改动的主角，值得一条断言锚住它：
    /// 少了它，把侧边栏整个删掉（只剩内容区）也能「全部通过」。
    private static func measureSidebarItems(in root: NSView) -> [SettingsSidebarItem] {
        var result: [SettingsSidebarItem] = []
        func walk(_ view: NSView) {
            if let item = view as? SettingsSidebarItem { result.append(item) }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return result
    }

    private static func findShortcutRecorder(in view: NSView) -> ShortcutRecorderView? {
        if let recorder = view as? ShortcutRecorderView {
            return recorder
        }
        for subview in view.subviews {
            if let found = findShortcutRecorder(in: subview) {
                return found
            }
        }
        return nil
    }

    /// 诊断用的快捷键宿主 stub。
    ///
    /// **支持故障注入**。只计数是不够的：计数只能证明回调接线对，
    /// 而快捷键事务的全部风险在失败路径上（注册失败后旧热键是否还在、
    /// 恢复失败会不会静默）。因此它模拟一个真实的注册槽：
    /// `activeShortcut` 非 nil 才表示当前真的有热键在工作。
    @MainActor

    final class DiagnosticShortcutHost: ShortcutHosting {
        /// 让下一次注册失败。
        var rejectNextApply = false
        /// 让下一次恢复失败。
        var failNextResume = false

        private(set) var applied: Shortcut?
        private(set) var suspendCount = 0
        private(set) var resumeCount = 0
        /// 当前真正注册着的快捷键。nil 表示没有热键在工作。
        private(set) var activeShortcut: Shortcut?

        /// 上一次被让出、待恢复的组合。
        private var suspended: Shortcut?

        /// Pin 切换热键当前注册着的组合。nil 表示没有热键在工作。
        private(set) var activePinToggleShortcut: Shortcut?

        /// Pin 热键被让出的次数。
        private(set) var pinSuspendCount = 0

        /// 被让出、待恢复的 Pin 热键。
        private var suspendedPinToggle: Shortcut?

        func applyPinToggleShortcut(_ shortcut: Shortcut) -> String? {
            if rejectNextApply {
                rejectNextApply = false
                return "诊断注入的注册失败"
            }
            activePinToggleShortcut = shortcut
            return nil
        }

        func suspendPinToggleShortcut() -> Bool {
            pinSuspendCount += 1
            suspendedPinToggle = activePinToggleShortcut
            activePinToggleShortcut = nil
            return true
        }

        func resumePinToggleShortcut() -> String? {
            if failNextResume {
                failNextResume = false
                return "诊断注入的恢复失败"
            }
            activePinToggleShortcut = suspendedPinToggle
            suspendedPinToggle = nil
            return nil
        }

        init(initial: Shortcut) {
            activeShortcut = initial
            applied = initial
        }

        func applyCaptureShortcut(_ shortcut: Shortcut) -> String? {
            if rejectNextApply {
                rejectNextApply = false
                return "诊断注入的注册失败"
            }
            applied = shortcut
            activeShortcut = shortcut
            return nil
        }

        func suspendCaptureShortcut() -> Bool {
            suspendCount += 1
            suspended = activeShortcut
            activeShortcut = nil
            return true
        }

        func resumeCaptureShortcut() -> String? {
            resumeCount += 1
            if failNextResume {
                failNextResume = false
                return "诊断注入的恢复失败"
            }
            activeShortcut = suspended
            suspended = nil
            return nil
        }
    }

    /// 输出结果并**结束进程**。
    ///
    /// 退出放在函数内部，而不是让调用方在外部用 `pkill` 收拾：
    /// `pkill -f` 会连带杀掉用户正在使用的 anShot 实例，
    /// 从这里退出只影响本次诊断进程。
    /// fail-fast 的 `return` 路径也经过这里，因此它们同样会正确退出。
    private static func reportSettingsDiagnostic(_ failures: [String]) {
        if failures.isEmpty {
            logger.notice("settings diag: 全部通过")
        } else {
            logger.error("settings diag: \(failures.count, privacy: .public) 项未通过")
            for failure in failures {
                logger.error("  ❌ \(failure, privacy: .public)")
            }
        }
        exit(0)
    }
}

#endif
