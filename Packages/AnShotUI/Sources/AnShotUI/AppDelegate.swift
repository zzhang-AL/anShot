//
//  AppDelegate.swift
//  AnShotUI
//
//  应用装配入口。App target 保持极薄，只做装配（plan.md §4）。
//
//  当前职责：菜单栏常驻、屏幕录制权限的观测/请求/引导、全局热键注册、
//  覆盖层会话的触发。
//  后续阶段在此挂载：标注工具条（P6）、导出入口（P7）。
//

import AppKit
import AnShotCapture
import AnShotCore
import ImageIO

/// 结构化日志。subsystem 固定为 bundle ID，便于用 log show 过滤：
///     log show --predicate 'subsystem == "com.anshot.app"' --last 5m
private let logger = AnShotLog.lifecycle
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    /// 历史记录（M3-6）：本机索引 + 缩略图，只记路径不存位图。
    private let historyStore = HistoryStore(directory: HistoryStore.defaultDirectory())

    /// 长截图日志窗口（懒建：不用就不占内存）。
    ///
    /// 它看的是 `ScrollshotLogStore` 里**跨会话**保留的最近逐帧结论。
    /// 放在菜单栏而非会话内浮层，是因为断层总是**事后**才被发现的：
    /// 会话结束时用户还不知道要不要排查，等看到了错图，浮层早就不在了。
    private lazy var scrollshotLogWindow = ScrollshotLogWindowController()

    /// 历史面板实例。**只有用户真的打开过才存在**。
    ///
    /// 不能直接在产物回调里读 `historyPanel`：`lazy` 会在第一次截图时
    /// 顺便把整个面板建出来（含窗口与列表），违反「空闲期零窗口」的约束。
    /// 所以刷新的入口只看 storage，真正需要展示时才走下面的 computed 属性。
    private var historyPanelStorage: HistoryPanel?

    private var historyPanel: HistoryPanel {
        if let historyPanelStorage { return historyPanelStorage }
        let panel = makeHistoryPanel()
        historyPanelStorage = panel
        return panel
    }

    private func makeHistoryPanel() -> HistoryPanel {
        let panel = HistoryPanel(store: historyStore)
        panel.onReveal = { entry in
            NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
        }
        panel.onClear = { [weak self] in
            self?.historyStore.clear()
            self?.historyPanel.refresh(self?.historyStore.entries ?? [])
        }
        // 「从历史重新钉一张」——历史只存路径，位图要重新读盘（见 `pinFromHistory`）。
        panel.onPin = { [weak self] entry in
            self?.pinFromHistory(entry)
        }
        panel.onCopy = { [weak self] entry in
            self?.copyHistoryEntry(entry)
        }
        panel.onEdit = { [weak self] entry in
            self?.editHistoryEntry(entry)
        }
        panel.onDelete = { [weak self] entry in
            guard let self else { return }
            self.historyStore.remove(entry.id)
            self.refreshHistoryPanel()
        }
        panel.onFavorite = { [weak self] entry, isFavorite in
            self?.historyStore.setFavorite(entry.id, isFavorite: isFavorite)
        }
        return panel
    }

    /// 从历史复制一张图（或一个录屏文件）。
    private func copyHistoryEntry(_ entry: HistoryEntry) {
        switch entry.kind {
        case .recording:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let ok = pasteboard.writeObjects([entry.fileURL as NSURL])
            ToastPresenter.show(ok ? "录屏文件已复制" : "复制失败")
        case .screenshot, .longScreenshot:
            guard entry.isFilePresent, let image = ImageSourceLauncher.loadImage(at: entry.fileURL) else {
                ToastPresenter.show("源文件已不在原位置")
                return
            }
            let ok = SessionExporter.copyToPasteboard(image)
            ToastPresenter.show(ok ? "已复制到剪贴板" : "复制失败")
        }
    }

    /// 从历史重新打开编辑器。录屏没有可编辑的位图，交给系统默认应用。
    private func editHistoryEntry(_ entry: HistoryEntry) {
        switch entry.kind {
        case .recording:
            NSWorkspace.shared.open(entry.fileURL)
        case .screenshot, .longScreenshot:
            guard entry.isFilePresent, let image = ImageSourceLauncher.loadImage(at: entry.fileURL) else {
                ToastPresenter.show("源文件已不在原位置")
                return
            }
            overlayController.present(image: image, sourceURL: entry.fileURL)
        }
    }

    private let permissionService = ScreenCapturePermissionService()

    /// 应用设置。导出流程与设置窗口共用同一个实例，
    /// 否则会出现「设置里改了保存位置，实际导出还在读旧值」。
    private let settings = AppSettings()

    /// 覆盖层会话控制器。构造时即创建捕获器，不在会话中重复建。
    private lazy var overlayController = OverlayController(settings: settings)

    /// 全局热键。持有引用是必须的：
    /// 释放即会在 deinit 中注销热键。
    private var globalHotKey: GlobalHotKey?

    /// 「隐藏/显示全部固定截图」的全局热键。
    ///
    /// 与截图热键**分开持有**：两个键位的注册状态是两个独立的可用性事实，
    /// 一个失败不应让另一个也失效。
    private var pinToggleHotKey: GlobalHotKey?

    /// Pin 热键注册失败的原因。与 `globalHotKeyError` 分开记。
    private var pinToggleHotKeyError: String?

    /// 录制 / 长截图 / OCR 的直达热键。
    ///
    /// 与截图、Pin 热键分开持有：五个键位的注册状态是五个独立的可用性事实，
    /// 一个被占用不该让其它四个一起静默失效。
    private var intentHotKeys: [GlobalShortcutAction: GlobalHotKey] = [:]
    private var intentHotKeyErrors: [GlobalShortcutAction: String] = [:]

    /// 因在设置里录制新组合而临时让出的直达热键。
    private var suspendedIntentShortcuts: [GlobalShortcutAction: Shortcut] = [:]

    /// 固定截图的非模态提示（懒建：不用就不占窗口）。
    private lazy var pinNotice = PinNotice()

    /// 因录制而临时让出的快捷键。非 nil 表示热键当前处于「已让出」状态。
    ///
    /// 必须先记下来才能恢复：`GlobalHotKey.invalidate()` 会拆掉系统级注册，
    /// 之后对象本身不再持有任何可复原的信息。
    private var suspendedShortcut: Shortcut?

    /// 因**在设置里录制新组合**而临时让出的 Pin 切换热键。
    ///
    /// 与上面那个分开记：两者让出的时机不同、恢复的时机也不同，
    /// 共用一个槽位会让「录制截图热键」把 Pin 热键的状态盖掉。
    private var suspendedPinToggleShortcut: Shortcut?

    /// 设置窗口。懒创建，**关闭即释放**（见 `onClose`）。
    private var settingsWindowController: SettingsWindowController?

    /// 首启引导窗口。只在首次启动或用户从菜单主动打开时存在。
    private var welcomeWindowController: WelcomeWindowController?

    /// 窗口选择器。选择期间持有；回调后释放。
    private var windowPicker: WindowPickerController?

    /// 录制会话的界面层控制器与控制条。
    private let recordingController = RecordingController()
    private let recordingBar = RecordingControlBar()

    /// GIF 导出进度（0…1）。nil 表示不在导出阶段。
    ///
    /// 菜单是 `menuWillOpen` 时现建的，没有可跟随的回调，因此这里缓存一份。
    private var exportProgress: Double?

/// 录制范围框。录制期间在屏幕上标出「正在录哪一块」——
/// 覆盖层收起后屏幕上没有别的东西能表达这个边界。
private let recordingFrame = RecordingRegionFrame()

    /// 热键注册失败的原因。非 nil 时菜单显示不可用提示，而非静默失效。
    private var globalHotKeyError: String?

    /// 本次启动时观测到的权限状态。
    ///
    /// 仅用于启动日志与「启动后状态发生变化」的对比，不作为任何行为的依据——
    /// 尤其是**不**用它判断「需要重启」。观测到 `.granted` 本身即说明
    /// 当前进程能与 TCC 正常通信，此时再声明「必须重启」是没有依据的断言。
    private var permissionAtLaunch: ScreenCapturePermission = .notRequested

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 所有交付都先登记产物，再决定怎么提示。
        //
        // 旧实现只在「保存成功」时写历史，于是复制、钉住、长截图都不留痕：
        // 剪贴板一被覆盖，那张图就永久丢了。现在复制/钉住会缓存一份副本，
        // 保存仍引用用户文件，录屏也走同一本账。
        overlayController.onArtifact = { [weak self] artifact in
            self?.handleArtifact(artifact)
        }

        // 固定截图达到上限时的提示。不走模态框：用户此刻要么在继续标注，
        // 要么正要去关掉几张再回来钉——两种情形都不该被一个对话框截断。
        overlayController.onPinLimitReached = { [weak self] limit in
            self?.showPinLimitNotice(limit: limit)
        }

        // 一块屏幕都没截到：覆盖层已放弃展示，这里负责告诉用户原因与出路。
        overlayController.onBackdropUnavailable = { [weak self] in
            self?.handleBackdropUnavailable()
        }

        // 覆盖层的录制请求经由通知送达（见 observeRecordingRequests）
        #if DEBUG
        // 流程诊断只验证「通知被正确发出并携带了正确的 scope/矩形/音频」。
        // 若这里照常去录，它会写文件、开麦克风、还与诊断抢捕获资源，
        // 而诊断本身并不验证成片质量（那是 `-diagnoseRecording` 的事）。
        if CaptureDiagnostics.shouldSkipRecordingRequests() {
            logger.notice("recording requests ignored: diagnoseRecordFlow 模式")
        } else {
            observeRecordingRequests()
        }
        #else
        observeRecordingRequests()
        #endif
        permissionAtLaunch = permissionService.current()
        logger.notice("launched; screenCapturePermission=\(String(describing: self.permissionAtLaunch), privacy: .public)")
        installStatusItem()
        showWelcomeIfNeeded()
        // 诊断运行**绝不注册全局热键**。
        //
        // 全局热键是**进程级独占**的系统资源：同 bundle 的第二个进程（诊断实例）同样
        // 能“注册成功”，但按键只会交给其中一个，而“哪一个”不由我们决定。
        // 实测证据：日志里一串短命实例（16:14/16:15/16:18…，每次诊断一个）
        // 都在注册 ⌃1/⌃2；而用户的正式实例在那之后报「快捷键失灵」。
        // 诊断根本不需要热键：它自己直接调入口函数。
        if isDiagnosticRun {
            logger.notice("global hotkeys skipped: diagnostic run")
        } else {
            installGlobalHotKey()
        }
        scheduleOCRPreheat()

        // 自动检查更新：诊断/验收进程不联网，避免测试环境产生副作用。
        if !isDiagnosticRun {
            UpdateCoordinator.shared.startAutomaticChecks()
        }

        #if DEBUG
        // `-showSettings` 只打开设置窗口并保持，供截图与人工评估使用。
        // 与其它诊断入口存在的理由相同：菜单项无法脚本化点击。
        if CommandLine.arguments.contains("-showSettings") {
            openSettings()
        } else if CommandLine.arguments.contains("-showWelcome") {
            openWelcome()
        } else if CommandLine.arguments.contains("-showHistory") {
            openHistory()
        } else if CommandLine.arguments.contains("-showCrashLogs") {
            CrashLogWindowController.shared.show()
        } else if CommandLine.arguments.contains("-showAbout") {
            openSettings()
            settingsWindowController?.showPageForDiagnostics(.about)
        } else if CommandLine.arguments.contains("-checkUpdates") {
            Task { await UpdateCoordinator.shared.check(manual: true) }
        } else if let imagePath = Self.editImageArgument(),
                  let image = ImageSourceLauncher.loadImage(at: URL(fileURLWithPath: imagePath)) {
            overlayController.present(image: image, sourceURL: URL(fileURLWithPath: imagePath))
        } else {
            CaptureDiagnostics.handleCommandLineArguments()
        }
        #endif
    }

    // MARK: - 后台预热

    /// 在后台把识别能力先加载好。
    ///
    /// 为什么需要：进程内**第一次**识别要十几秒（实测见 `TextRecognizer.prewarm`），
    /// 那笔成本总得有人付。不预热的话付账的是用户——他点下「识别文字」，
    /// 然后盯着一个毫无反应的界面等下去。
    ///
    /// 三个刻意的选择：
    /// - **延迟几秒再开始**：预热是十几秒的重活，跟启动时的菜单栏图标、
    ///   热键注册抢资源会让「刚点开这个应用」变钝。
    /// - **`.utility` 优先级**：用户真在用的时候（手动截图、标注）不能被它抢走算力。
    /// - **失败不上抛**：预热纯属预热，它坏了不能影响任何真实功能。
    private func scheduleOCRPreheat() {
        // 预热只对 Apple Vision 有意义。
        //
        // 云端 provider（本机实际配置的是 baiduPPOCR）根本不加载本地识别模型，
        // 跑一遍 Vision 预热等于白白付出约 48MB 的神经网络峰值内存与十几秒算力。
        // 诊断进程同样跳过：它不验证预热带来的延迟改善，却会跟真实会话抢资源。
        guard !isDiagnosticRun else {
            logger.notice("OCR 预热跳过：诊断运行")
            return
        }
        guard OCRProviderSettings().selectedKind == .appleVision else {
            logger.notice("OCR 预热跳过：当前 provider 不是 Apple Vision")
            return
        }

        // 不持有这个 Task：预热没有需要取消的下游资源，进程退出时它自然消失。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }

            let startedAt = Date()
            await Task.detached(priority: .utility) {
                await TextRecognizer.prewarm()
            }.value

            logger.notice("OCR 预热完成：\(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public)ms")
        }
    }

    // MARK: - 产物账本

    /// 交付产物：先记账，再提示。
    ///
    /// 两个动作刻意分开：
    /// - 历史是**事实**，必须覆盖所有交付方式，即使写盘失败也要留日志；
    /// - toast 是**反馈**，不能等缩略图/缓存写盘完成才出现，
    ///   否则用户会先看到会话关闭、过一会儿才看到提示。
    private func handleArtifact(_ artifact: CaptureArtifact) {
        switch artifact.delivery {
        case .saved:
            if let url = artifact.fileURL {
                recordSavedArtifact(
                    url: url,
                    image: artifact.image,
                    kind: artifact.kind,
                    source: artifact.source
                )
                ToastPresenter.show(
                    "已保存：\(url.lastPathComponent)",
                    actionTitle: "在访达中显示"
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }

        case .copied:
            cacheArtifact(artifact)
            ToastPresenter.show("已复制到剪贴板")

        case .pinned:
            cacheArtifact(artifact)
            ToastPresenter.show("已固定在屏幕上")

        case .longShot:
            // 长截图由结果窗口承担复制/保存/钉住的后续反馈；
            // 这里只负责把它登记进历史，保证窗口关掉也不会丢。
            cacheArtifact(artifact)
        }
    }

    /// 保存类产物：引用用户文件，不复制第二份。
    private func recordSavedArtifact(
        url: URL,
        image: CGImage?,
        kind: HistoryEntryKind,
        source: HistorySource?
    ) {
        guard let image else { return }
        Task { @MainActor [weak self] in
            let thumbnail = await Task.detached(priority: .utility) {
                HistoryThumbnail.makePNG(from: image)
            }.value
            guard let self else { return }
            self.historyStore.add(
                fileURL: url,
                thumbnailPNG: thumbnail,
                pixelWidth: image.width,
                pixelHeight: image.height,
                kind: kind,
                source: source,
                cached: false
            )
            self.refreshHistoryPanel()
        }
    }

    /// 复制 / 钉住 / 长截图：把位图复制进历史缓存。
    ///
    /// 这些交付没有用户文件可引用，不缓存就等于「关了会话即丢」。
    private func cacheArtifact(_ artifact: CaptureArtifact) {
        guard let image = artifact.image else { return }
        let kind = artifact.kind
        let source = artifact.source
        // 复制/长截图的交付路径已经编码过 PNG：直接复用，避免同一张图
        // 在这里再全量编码一次。只取需要的字段，不把整个产物带进后台任务。
        let preEncodedPNG = artifact.pngData

        Task { @MainActor [weak self] in
            let payload = await Task.detached(priority: .utility) {
                (
                    preEncodedPNG ?? Exporter.pngData(from: image),
                    HistoryThumbnail.makePNG(from: image)
                )
            }.value
            guard let self else { return }
            guard let png = payload.0 else {
                logger.error("artifact cache failed: PNG encode returned nil")
                ToastPresenter.show("这张图没能存入历史")
                return
            }
            guard let entry = self.historyStore.addCachedImage(
                pngData: png,
                thumbnailPNG: payload.1,
                pixelWidth: image.width,
                pixelHeight: image.height,
                kind: kind,
                source: source
            ) else {
                logger.error("artifact cache failed: \(self.historyStore.lastError ?? "unknown", privacy: .public)")
                ToastPresenter.show("这张图没能存入历史")
                return
            }
            logger.notice("artifact cached; id=\(entry.id.uuidString, privacy: .public) kind=\(kind.rawValue, privacy: .public)")
            self.refreshHistoryPanel()
        }
    }

    private func refreshHistoryPanel() {
        guard let panel = historyPanelStorage, panel.isVisible else { return }
        panel.refresh(historyStore.entries)
    }

    // MARK: - 菜单栏

    /// 安装菜单栏图标。本应用以 `.accessory` 激活策略运行（无 Dock 图标），
    /// 菜单栏图标是唯一的常驻界面。
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "anShot"
        )
        item.button?.toolTip = "anShot"

        let menu = NSMenu()
        // 每次展开菜单时重建，保证权限状态实时准确
        menu.delegate = self
        item.menu = menu

        statusItem = item
    }

    /// 重建菜单内容。菜单每次展开都会调用，因此无需额外刷新机制。
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let permission = permissionService.current()

        append(makeStatusSection(permission), to: menu)
        append(makeHistorySection(), to: menu)
        append(makeScrollshotLogSection(), to: menu)
        append(makePermissionGuideSection(permission), to: menu)
        append(makeAccessibilitySection(), to: menu)
        #if DEBUG
        append(makeDiagnosticSection(), to: menu)
        #endif
        append(makeHelpSection(), to: menu)
        append(makeSettingsSection(), to: menu)
        append(makeSessionSection(), to: menu)
    }

    /// 帮助与更新。与设置分开：这三项是「去看看」，不是「改配置」。
    private func makeHelpSection() -> [NSMenuItem] {
        [
            makeAction("检查更新…", #selector(checkForUpdates)),
            makeAction("崩溃日志…", #selector(openCrashLogs)),
            makeAction("GitHub 项目主页", #selector(openProjectPage)),
            .separator(),
        ]
    }

    @objc private func checkForUpdates() {
        Task { await UpdateCoordinator.shared.check(manual: true) }
    }

    @objc private func openCrashLogs() {
        CrashLogWindowController.shared.show()
    }

    @objc private func openProjectPage() {
        guard let url = URL(string: "https://github.com/zzhang-AL/anShot") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 菜单区块

    /// 把一个区块的菜单项追加到菜单。
    ///
    /// 区块方法一律返回 `[NSMenuItem]`（含其后的分隔线），由这里统一追加：
    /// 把「构建什么」与「加进哪里」分开，区块之间就不必互相知道对方的存在。
    private func append(_ items: [NSMenuItem], to menu: NSMenu) {
        for item in items {
            menu.addItem(item)
        }
    }

    /// 构造可点击的菜单项。
    ///
    /// 抽出来的理由：下面十几个项都是「标题 + selector + target = self」
    /// 这同一套样板。逐处展开会把菜单的**结构**淹没在重复代码里——
    /// 而结构正是读这段代码时真正要看的东西。
    private func makeAction(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// 构造不可点击的展示项（状态行、导出进度、热键故障提示）。
    private func makeStatus(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 屏幕录制权限状态行。
    ///
    /// 文案一律用「尚未授权」而非「已拒绝」：API 无法区分
    /// 「用户拒绝」「授权仍在等待」「曾授权后撤销」三种情形。
    private func makeStatusSection(_ permission: ScreenCapturePermission) -> [NSMenuItem] {
        let title: String
        switch permission {
        case .granted:
            title = "屏幕录制权限：已授权"
        case .notRequested:
            title = "屏幕录制权限：尚未授权"
        case .notGranted:
            title = "屏幕录制权限：尚未授权（此前请求过）"
        }
        return [makeStatus(title), .separator()]
    }

    /// 历史记录入口。有条目时在标题里显示数量。
    private func makeHistorySection() -> [NSMenuItem] {
        let history = makeAction("历史记录…", #selector(openHistory))
        if !historyStore.entries.isEmpty {
            history.title = "历史记录（\(historyStore.entries.count)）…"
        }
        return [history, .separator()]
    }

    /// 长截图日志入口。有记录时在标题里带上异常条数。
    ///
    /// Release 也保留（不放在 `#if DEBUG` 诊断区）：断层是**普通用户**会遇到的
    /// 体验问题，让他们能把现场发出来，比我们自己猜测多少轮都有用。
    private func makeScrollshotLogSection() -> [NSMenuItem] {
        let log = makeAction("长截图日志…", #selector(openScrollshotLog))
        let problems = ScrollshotLogStore.shared.entries.filter(\.isProblem).count
        if problems > 0 {
            log.title = "长截图日志（\(problems) 条异常）…"
        }
        return [log, .separator()]
    }

    /// 权限引导：未授权时给引导入口，已授权时给实际功能入口。
    private func makePermissionGuideSection(
        _ permission: ScreenCapturePermission
    ) -> [NSMenuItem] {
        switch permission {
        case .notRequested:
            // 从未请求过：可以触发系统授权对话框
            return [makeAction("请求屏幕录制权限…", #selector(requestPermission))]

        case .notGranted:
            // 已请求过：系统不会再弹窗，只能引导到系统设置
            return [makeAction("打开系统设置检查权限…", #selector(openScreenRecordingSettings))]

        case .granted:
            return makeCaptureSection()
        }
    }

    /// 已授权时的功能入口：截图、固定截图、热键故障提示、录制。
    ///
    /// 热键不可用**不**影响手动截图：菜单入口与热键是两条独立路径。
    /// 早期版本在热键失败时把「截图」项也藏了起来，于是一个故障同时废掉了
    /// 两个入口——用户只剩「重启」可选。
    private func makeCaptureSection() -> [NSMenuItem] {
        // 本应用无 Dock 图标也无应用菜单，菜单栏是唯一能常驻的管理入口。
        var items: [NSMenuItem] = [
            makeAction("截图", #selector(startCapture)),
            makeAction("选择窗口…", #selector(chooseWindow)),
            makeAction("打开图片…", #selector(openImageFile)),
            makeAction("滚动长截图…", #selector(startLongScreenshotFlow)),
            makeAction("识别文字…", #selector(startOCRCaptureFlow)),
            makeAction("开始录制…", #selector(startRecordingFlow)),
            makePinMenuItem()
        ]

        if let globalHotKeyError {
            items.append(makeStatus("截图快捷键不可用：\(globalHotKeyError)"))
        }
        // 每个直达热键的失败单独说清：五个键位是五个独立事实，
        // 把「录制键被占用」笼统写成「快捷键不可用」会让用户
        // 去改截图快捷键，改完发现录制还是不工作。
        for action in [GlobalShortcutAction.recording, .longScreenshot, .ocr] {
            if let error = intentHotKeyErrors[action] {
                items.append(makeStatus("\(action.displayName)快捷键不可用：\(error)"))
            }
        }
        return items
    }

    /// 录制区块：录制中给「停止 / 暂停」，否则给「开始（全屏）」。
    ///
    /// 录制期间菜单项切换为「停止录制」并显示计时：控制条可能被用户移到
    /// 看不见的位置，菜单必须始终是一个可用的入口。
    private func makeRecordingSection() -> [NSMenuItem] {
        guard recordingController.isActive else {
            // 主入口是上面的「开始录制…」：它经过覆盖层与准备面板，
            // 能选区域/窗口/应用。这里只保留全屏快捷入口，
            // 方便「马上录整个屏幕」的场景少两步。
            return [makeAction("开始录制（全屏）", #selector(startFullScreenRecording))]
        }

        // 导出期间不可能停、不可能暂停：流已停、转码不可中断。
        // 留着可点的「停止录制」会与控制条（那两个按钮已置灰）自相矛盾。
        if let progress = exportProgress {
            let percent = Int((progress * 100).rounded())
            return [makeStatus("正在生成 GIF…（\(percent)%）")]
        }

        let elapsed = RecordingControlBar.format(recordingController.elapsed)
        let pauseTitle = recordingController.state == .paused ? "继续录制" : "暂停录制"
        return [
            makeAction("停止录制（\(elapsed)）", #selector(stopRecording)),
            makeAction(pauseTitle, #selector(toggleRecordingPause))
        ]
    }

    /// 辅助功能权限（可选能力）。未授权时出现，已授权时整块不出现。
    ///
    /// 它对应的只是「识别界面元素」这一项增强，缺了它截图主流程完全可用，
    /// 因此不做任何强制引导、也不在会话中打扰。
    private func makeAccessibilitySection() -> [NSMenuItem] {
        guard !SystemElementDetector().hasAccessibilityPermission else { return [] }
        return [
            makeAction("授权辅助功能以识别界面元素…", #selector(openAccessibilitySettings)),
            .separator()
        ]
    }

    #if DEBUG
    /// 临时诊断入口：验证 P2 捕获层能真实抓图。P3 用真正的截图功能替换它。
    private func makeDiagnosticSection() -> [NSMenuItem] {
        [makeAction("诊断：抓取全屏为 PNG", #selector(diagnoseCapture)), .separator()]
    }
    #endif

    /// 设置入口。
    ///
    /// 本应用无 Dock 图标、无应用菜单，因此没有地方放 HIG 规定的
    /// 「anShot → 设置…」菜单项；状态菜单是唯一入口。
    ///
    /// keyEquivalent 给 ⌘,：它在菜单展开时生效，与 HIG 的约定一致。
    /// **不**把它注册成全局热键——⌘, 在大量应用里都有含义，
    /// 抢过来会破坏用户已有的习惯。
    private func makeSettingsSection() -> [NSMenuItem] {
        [
            makeAction("欢迎与权限…", #selector(openWelcome)),
            makeAction("设置…", #selector(openSettings), key: ","),
            .separator(),
        ]
    }

    /// 排障与退出。
    ///
    /// 重启作为**排障手段**常驻，而非「刚授权所以必须重启」的强制流程：
    /// 授权生效是否需要新进程，取决于 TCC 与 ScreenCaptureKit 的连接状态，
    /// 无法先验判定。需要时用户可主动使用。
    private func makeSessionSection() -> [NSMenuItem] {
        // quit **不设 target**：走响应链交给 NSApplication 处理。
        let quit = NSMenuItem(
            title: "退出 anShot",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return [makeAction("重启 anShot", #selector(relaunch)), quit]
    }


    // MARK: - 权限动作

    /// 请求屏幕录制权限。
    ///
    /// 不额外弹模态框：`CGRequestScreenCaptureAccess()` 自身会弹出系统授权对话框
    /// 并引导用户，再弹一个只会让一次操作出现两个对话框。
    @objc private func requestPermission() {
        let observed = permissionService.requestAccess()
        logger.notice("permission requested; observed=\(String(describing: observed), privacy: .public)")

        // 系统对话框返回时用户通常尚未完成授权（授权是异步的）。
        // 菜单下次展开时会重新计算状态，无需在此预判。
        // 若系统未弹窗（该权限此前已处理过），菜单项会变为「打开系统设置检查权限…」。
    }

    /// 截图会话因拿不到任何屏幕画面而放弃时的引导。
    ///
    /// 按权限状态分三路：从未请求过 → 直接触发系统授权对话框；
    /// 请求过但未授权 → 引导到系统设置（系统不会再弹窗）；
    /// 已授权却仍失败 → 多半是 TCC / ScreenCaptureKit 连接状态异常，给出重启入口。
    private func handleBackdropUnavailable() {
        let permission = permissionService.current()
        logger.error("capture unavailable; permission=\(String(describing: permission), privacy: .public)")

        if permission == .notRequested {
            requestPermission()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法截图"
        if permission == .granted {
            alert.informativeText = "未能获取屏幕画面。屏幕录制服务的连接状态可能异常，重启 anShot 通常可以恢复。"
            alert.addButton(withTitle: "重启 anShot")
        } else {
            alert.informativeText = "anShot 没有屏幕录制权限。请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」中允许 anShot，然后重新截图。"
            alert.addButton(withTitle: "打开系统设置")
        }
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if permission == .granted {
            relaunch()
        } else {
            openScreenRecordingSettings()
        }
    }

    // MARK: - 截图会话

    /// 注册全局热键。键位来自设置，默认 `⌃1`。
    ///
    /// 注册失败不阻止应用运行：菜单栏仍提供入口，且失败原因会显示在菜单中。
    private func installGlobalHotKey() {
        do {
            globalHotKey = try makeHotKey(for: settings.captureShortcut)
            globalHotKeyError = nil
        } catch {
            let message = error.localizedDescription
            globalHotKeyError = message
            logger.error("global hotkey unavailable: \(message, privacy: .public)")
        }
        installPinToggleHotKey(for: settings.pinToggleShortcut)

        // 直达入口：录制 / 长截图 / OCR。
        //
        // 三个动作都复用同一条覆盖层与选区链路，区别只是选区确定后
        // 执行哪一个动作（见 `OverlaySessionIntent`）。因此这里只登记
        // 「意图」，不各写一套捕获代码。
        installIntentHotKey(.recording, role: .recording)
        installIntentHotKey(.longScreenshot, role: .longScreenshot)
        installIntentHotKey(.ocr, role: .ocr)
    }

    /// 安装一个「直达动作」热键。
    private func installIntentHotKey(_ action: GlobalShortcutAction, role: GlobalHotKey.Role) {
        do {
            intentHotKeys[action] = try makeIntentHotKey(
                action: action,
                role: role,
                shortcut: settings.shortcut(for: action)
            )
            intentHotKeyErrors[action] = nil
        } catch {
            let message = error.localizedDescription
            intentHotKeyErrors[action] = message
            logger.error("""
                intent hotkey unavailable; action=\(action.rawValue, privacy: .public) \
                error=\(message, privacy: .public)
                """)
        }
    }

    /// 构造直达动作热键。构造成功即完成系统级注册。
    private func makeIntentHotKey(
        action: GlobalShortcutAction,
        role: GlobalHotKey.Role,
        shortcut: Shortcut
    ) throws -> GlobalHotKey {
        try GlobalHotKey(
            role: role,
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers
        ) { [weak self] in
            guard let self else { return }
            switch action {
            case .recording:
                self.overlayController.present(intent: .recording)
            case .longScreenshot:
                self.overlayController.present(intent: .longScreenshot)
            case .ocr:
                self.overlayController.present(intent: .ocr)
            case .capture, .pinToggle:
                break
            }
        }
    }

    /// 注册「隐藏/显示全部固定截图」热键。
    ///
    /// 失败只记状态，**不**影响截图主流程：这是一项便利功能，
    /// 缺了它截图、标注、Pin 本身全都照常。
    private func installPinToggleHotKey(for shortcut: Shortcut) {
        do {
            pinToggleHotKey = try makePinToggleHotKey(for: shortcut)
            pinToggleHotKeyError = nil
        } catch {
            let message = error.localizedDescription
            pinToggleHotKeyError = message
            logger.error("pin toggle hotkey unavailable: \(message, privacy: .public)")
        }
    }

    /// 本次启动是不是诊断（或仅用于人工验收的）运行。
    ///
    /// 用途只有一个：这些进程不得注册全局热键（见 `applicationDidFinishLaunching`）。
    private var isDiagnosticRun: Bool {
        #if DEBUG
        return CaptureDiagnostics.hasDiagnosticRequest()
            || CommandLine.arguments.contains("-showSettings")
            || CommandLine.arguments.contains("-showWelcome")
            || CommandLine.arguments.contains("-editImage")
            || CommandLine.arguments.contains("-showHistory")
            || CommandLine.arguments.contains("-showCrashLogs")
            || CommandLine.arguments.contains("-checkUpdates")
            || CommandLine.arguments.contains("-showAbout")
        #else
        return false
        #endif
    }

    /// 按给定组合构造 Pin 切换热键。构造成功即已完成系统级注册。
    private func makePinToggleHotKey(for shortcut: Shortcut) throws -> GlobalHotKey {
        try GlobalHotKey(
            role: .pinToggle,
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers
        ) { [weak self] in
            self?.toggleAllPins()
        }
    }

    /// 按给定组合构造一个热键对象。构造成功即已完成系统级注册。
    private func makeHotKey(for shortcut: Shortcut) throws -> GlobalHotKey {
        try GlobalHotKey(
            role: .capture,
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers
        ) { [weak self] in
            self?.overlayController.present()
        }
    }

    /// `-editImage <path>`：调试入口，验证「编辑已有图片」而不依赖菜单点击。
    private static func editImageArgument() -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-editImage"),
              index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    // MARK: - 首启引导

    /// 首次启动展示权限检查表；之后只在菜单里主动打开。
    ///
    /// 不在「未授权」时每次启动都弹：菜单栏应用最烦人的行为之一就是
    /// 每次登录都被一个窗口拦住。真正需要时（截图失败）已有独立引导。
    private func showWelcomeIfNeeded() {
        guard !isDiagnosticRun else { return }
        let key = "welcome.shown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        openWelcome()
    }

    /// 打开欢迎与权限窗口。
    @objc private func openWelcome() {
        if let existing = welcomeWindowController {
            existing.show()
            return
        }
        let controller = WelcomeWindowController(
            permission: permissionService,
            settings: settings,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onRelaunch: { [weak self] in self?.relaunch() },
            onTryCapture: { [weak self] in self?.overlayController.present() }
        )
        controller.onClose = { [weak self] in
            self?.welcomeWindowController = nil
        }
        welcomeWindowController = controller
        controller.show()
    }

    // MARK: - 设置

    @objc private func openSettings() {
        if let existing = settingsWindowController {
            existing.show()
            return
        }
        let controller = SettingsWindowController(
            settings: settings,
            shortcutHost: self,
            // 设置窗口用它做「已有数量超过新上限」的提示。
            // 传闭包而不是管理器：设置窗口只需要一个数字。
            pinCountProvider: { [weak self] in self?.overlayController.pinManager.pins.count ?? 0 }
        )
        // 设置窗口里的输入框需要主菜单才能粘贴（理由见 SettingsMainMenu）。
        SettingsMainMenu.install()
        // 关闭后释放控制器与窗口，而不是永久持着。
        // 本应用是常驻菜单栏的辅助程序，「空闲期零窗口」是既定约束
        //（见 m1-capture/plan.md §2.1）；窗口位置由 autosave 记住，
        // 不依赖对象存活。
        controller.onClose = { [weak self] in
            SettingsMainMenu.remove()
            self?.settingsWindowController = nil
        }
        settingsWindowController = controller
        controller.show()
    }

    /// 菜单栏的截图入口，与热键走同一条路径。
    // MARK: - 录制

    /// 开始全屏录制。
    ///
    /// 当前只提供全屏：区域/窗口/应用范围需要一套「选区后直接进入录制」的交互，
    /// 与 M1 截图「选区后进入标注」的流程不同，属独立工作。
    /// 监听来自覆盖层的录制请求。
    private func observeRecordingRequests() {
        NotificationCenter.default.addObserver(
            forName: .anShotStartRecording,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // 先把通知里的值取出来。
            //
            // 它们都是 Sendable 值类型，可安全跨隔离域；而 `Notification` 本身
            // 不是 Sendable，若在 `assumeIsolated` 里继续用它，会触发
            // `#SendingRisksDataRace`——那不是误报，而是在指出
            // 「不该把非 Sendable 的引用带进主线程域」。
            guard let scope = note.userInfo?[NotificationUserInfoKey.captureScope] as? CaptureScope else {
                return
            }
            let controlBarRect = note.userInfo?[NotificationUserInfoKey.recordingRect] as? CGRect
            // 音频设置由准备面板确认后随通知传入；缺省时与面板默认值一致（都勾选）。
            let audio = note.userInfo?[NotificationUserInfoKey.audioSettings] as? AudioSettings
                ?? AudioSettings(systemAudio: true, microphone: true)
            // 输出格式同样由面板确认；缺省为 MP4（与面板的初始选项一致）。
            let output = note.userInfo?[NotificationUserInfoKey.outputChoice] as? RecordingOutputChoice
                ?? .movie

            // `queue: .main` 保证闭包在主线程执行，但 `addObserver` 的闭包在类型上
            // 是 nonisolated（`@Sendable`），编译器无从得知这一点。
            //
            // `assumeIsolated` 把「已知在主线程」显式表达出来，并附**运行期断言**：
            // 若将来有人把 queue 改成非主队列，它会立刻崩在出错处，
            // 而不是静默地在后台线程上碰 AppKit（那类缺陷只在偶发时机暴露）。
            MainActor.assumeIsolated {
                guard let self else { return }
                self.startRecording(
                    scope: scope,
                    audio: audio,
                    output: output,
                    controlBarRect: controlBarRect
                )
            }
        }
    }

    /// 菜单入口：全屏录制。
    ///
    /// **固定 MP4**，不给菜单加 GIF 入口：这条路径不经过准备面板，
    /// 若在这里就能一键录 GIF，用户既看不到时长上限、也无法选档位，
    /// 而到达上限会自动停录——参数必须在开始前可见（GIF 只能从面板发起）。
    @objc private func startFullScreenRecording() {
        startRecording(scope: .display(DisplayGeometry.mainDisplay()), output: .movie)
    }

    /// 窗口录制时的范围框跟随器（其它范围不需要）。
    ///
    /// 窗口会移动/缩放，而范围框是静态窗口；不跟随的话框停在旧位置，
    /// 它指示的边界与成片不符。
    private var windowFollower: WindowFrameFollower?

    private func startRecording(
        scope: CaptureScope,
        // 与准备面板的默认值保持一致（都勾选）。菜单栏入口不经过面板，
        // 若这里仍用全关的默认值，同样叫「开始录制」的两条路径行为却不同。
        audio: AudioSettings = AudioSettings(systemAudio: true, microphone: true),
        output: RecordingOutputChoice,
        controlBarRect: CGRect? = nil
    ) {
        guard !recordingController.isActive else { return }
        let outputURL = RecordingController.defaultOutputURL(for: settings, output: output)
        logger.notice("开始录制：\(outputURL.path, privacy: .public)")

        recordingController.onUpdate = { [weak self] state, elapsed in
            self?.recordingBar.update(state: state, elapsed: elapsed)
            // 暂停时边框换色：边框位置不变，颜色是唯一能区分「在录」与「暂停」的手段
            self?.recordingFrame.update(appearance: state == .paused ? .paused : .recording)
            self?.refreshMenuTitle()
        }
        // 进度单独一根管子（见 `RecordingController.onExportProgress`）。
        // 同时缓存一份：菜单是在 `menuWillOpen` 时现建的，没有回调可跟。
        recordingController.onExportProgress = { [weak self] value in
            self?.exportProgress = value
            self?.recordingBar.updateExportProgress(value)
        }
        recordingController.onFinish = { [weak self] outcome in
            self?.stopWindowFollowing()
            self?.recordingBar.hide()
            self?.recordingFrame.hide()
            self?.exportProgress = nil
            self?.refreshMenuTitle()
            self?.reportRecordingOutcome(outcome)
        }

        recordingBar.onTogglePause = { [weak self] in
            guard let self else { return }
            Task { await self.recordingController.togglePause() }
        }
        recordingBar.onStop = { [weak self] in
            guard let self else { return }
            Task { await self.recordingController.stop() }
        }

        // 顺序要紧：**先摆好录制 UI，再启动捕获**。
        // 排除窗口需要窗口号，而 windowNumber 只在 orderFront 之后才有值；
        // 先启动的话拿到的是空列表，范围框与控制条就会被录进成片。
        recordingBar.update(state: .preparing, elapsed: 0)
        // GIF 时把上限交给控制条：录制中它要显示倒计时，因为到达上限会**自动停止**。
        let gifLimit: TimeInterval?
        if case .gif(let gifSettings) = output {
            gifLimit = gifSettings.maximumDuration
        } else {
            gifLimit = nil
        }
        // 录制所在的屏幕按**录制范围**确定，而不是 `NSScreen.main`
        //（那是键盘焦点所在屏，多屏时与录制目标无关）。
        let targetScreen = Self.screen(for: scope, rect: controlBarRect)
        recordingBar.show(near: controlBarRect, on: targetScreen, gifLimit: gifLimit)
        // 范围框与录制区域一致；全屏录制没有具体矩形，用目标显示器的整屏范围。
        recordingFrame.show(
            rect: controlBarRect ?? targetScreen?.frame ?? .zero,
            appearance: .recording
        )

        // 窗口范围：让范围框跟着窗口走。
        startWindowFollowing(scope: scope)

        // 把本应用自己的录制 UI 排除在画面之外。不能只靠窗口层级或
        // nonactivatingPanel——那些都不影响 SCStream 是否采集该窗口。
        let excludedWindowIDs = [recordingBar.windowID, recordingFrame.windowID]
            .compactMap { $0 }
        logger.notice("排除录制 UI 窗口：\(excludedWindowIDs.map(String.init).joined(separator: ","), privacy: .public)")

        recordingController.start(
            scope: scope,
            audio: audio,
            output: output,
            excludedWindowIDs: excludedWindowIDs,
            outputURL: outputURL
        )
        // 菜单在 `menuWillOpen` 时自动重建，此处无需手动刷新
    }

    /// 录制范围所在的屏幕。
    ///
    /// 显示器 / 区域 / 应用范围自带 displayID，直接按它找；窗口范围没有，
    /// 用录制矩形的重叠面积判断；都取不到时退回主屏（`screens.first` 即菜单栏所在屏，
    /// 与 `CGMainDisplayID()` 一致）。
    private static func screen(for scope: CaptureScope, rect: CGRect?) -> NSScreen? {
        let displayID: CGDirectDisplayID?
        switch scope {
        case .display(let id), .region(let id, _), .application(_, let id):
            displayID = id
        default:
            displayID = nil
        }
        if let displayID, let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            return screen
        }
        return rect.flatMap(RecordingControlBar.screen(overlapping:)) ?? NSScreen.screens.first
    }

    /// 窗口范围时启动范围框跟随；其它范围不启（全屏/区域/应用的范围不随窗口变）。
    private func startWindowFollowing(scope: CaptureScope) {
        stopWindowFollowing()
        guard case .window(let windowID) = scope else { return }
        let follower = WindowFrameFollower(windowID: windowID) { [weak self] rect in
            // 跟随同时会重算贴屏幕角的圆角（`RecordingRegionFrame.update` 内部处理）。
            self?.recordingFrame.update(rect: rect)
        }
        follower.start()
        windowFollower = follower
    }

    private func stopWindowFollowing() {
        windowFollower?.stop()
        windowFollower = nil
    }

    @objc private func stopRecording() {
        Task { await recordingController.stop() }
    }

    @objc private func toggleRecordingPause() {
        Task { await recordingController.togglePause() }
    }

    /// 会话结束后的反馈。
    ///
    /// 失败时必须让用户看到原因（磁盘满、流中断、权限不足），
    /// 静默结束会让用户以为录到了东西。
    private func reportRecordingOutcome(_ outcome: RecordingController.Outcome) {
        switch outcome {
        case .finished(let url, let duration, let reachedLimit):
            logger.notice("录制完成：\(url.path, privacy: .public) 时长=\(duration, privacy: .public)s")
            // 录屏产物也进历史：历史若只收截图，用户想找回刚录的片段
            // 只能去访达里翻，而访达未必记得住保存目录。
            historyStore.add(
                fileURL: url,
                thumbnailPNG: nil,
                pixelWidth: 0,
                pixelHeight: 0,
                kind: .recording,
                source: HistorySource(mode: "recording"),
                cached: false
            )
            refreshHistoryPanel()
            // 非阻塞提示：录制结束后用户往往马上要回到刚才的应用，
            // 一个模态弹窗会把焦点和节奏一起打断。
            let message = reachedLimit
                ? "录制完成（已达 GIF 上限）：\(url.lastPathComponent)"
                : "录制完成：\(url.lastPathComponent)"
            ToastPresenter.show(message, actionTitle: "在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            logger.notice("recording duration=\(duration, privacy: .public)s")
        case .cancelled:
            // 用户自己取消的会话：没有产物，也没有失败，不需要再弹一个
            // 「录制失败」去通知他刚刚做了什么。界面已由 onFinish 的
            // 收尾逻辑收起，这里只留一条日志便于排查。
            logger.notice("录制已取消")
        case .failed(let message, let kept, let missingPermission):
            logger.error("录制失败：\(message, privacy: .public) 保留产物=\(kept?.url.path ?? "无", privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "录制失败"
            // 失败时磁盘上可能已经躺着一个可用文件。不说出来，用户就只会
            // 看到一个错误——他花时间录的东西存在与否，不该只有日志知道。
            var lines = [message]
            if let kept {
                lines.append(kept.isAtRequestedLocation
                    ? "影片已保留：\(kept.url.path)"
                    : "影片已生成，但未能移到保存目录，仍在临时目录（可能被系统清理）：\(kept.url.path)")
            }
            if missingPermission != nil {
                lines.append("可在「系统设置 › 隐私与安全性」中开启后重试。")
            }
            alert.informativeText = lines.joined(separator: "\n\n")
            alert.addButton(withTitle: "好")
            // 按钮序号随「是否保留产物」而变，所以记下每个按钮的**真实**位置，
            // 而不是假设「第二个一定是…」——权限失败恰好是 kept 为 nil 的情况。
            var revealButton: Int?
            if kept != nil {
                revealButton = alert.buttons.count
                alert.addButton(withTitle: "在访达中显示")
            }
            var settingsButton: Int?
            if missingPermission != nil {
                settingsButton = alert.buttons.count
                alert.addButton(withTitle: "打开系统设置")
            }
            // 本应用是菜单栏程序（默认非活跃），不先激活的话弹窗可能出现在
            // 其它窗口后面，用户根本看不到失败原因。
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            // 用实际序号反查点了哪个按钮：`alertSecondButtonReturn` 只在
            // 恰好两个按钮时才有意义。
            let clicked = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if let revealButton, clicked == revealButton, let kept {
                NSWorkspace.shared.activateFileViewerSelecting([kept.url])
            } else if let settingsButton, clicked == settingsButton, let missingPermission {
                openPrivacySettings(for: missingPermission)
            }
        }
    }

    /// 打开系统设置里对应权限的隐私面板。
    ///
    /// 用户被弹窗告知「缺少麦克风权限」后，要自己在系统设置里找到那一行；
    /// 直接把他送到对应面板，是这条链路里唯一能省掉的一步。
    private func openPrivacySettings(for permission: RecordingController.MissingPermission) {
        let pane: String
        switch permission {
        case .screenRecording:
            pane = "Privacy_ScreenCapture"
        case .microphone:
            pane = "Privacy_Microphone"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            logger.error("无法构造隐私设置链接：\(pane, privacy: .public)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// 刷新菜单栏图标的计时显示。
    private func refreshMenuTitle() {
        guard let button = statusItem?.button else { return }
        if recordingController.isActive {
            button.title = " ● " + RecordingControlBar.format(recordingController.elapsed)
        } else {
            button.title = ""
        }
    }

    @objc private func startCapture() {
        overlayController.present()
    }

    /// 菜单入口：编辑磁盘上已有的图片。
    ///
    /// 不经过截图：用户已经有图时，再截一次屏只会得到一张画质更差的副本。
    @objc private func openImageFile() {
        guard let choice = ImageSourceLauncher.chooseImage() else { return }
        overlayController.present(image: choice.image, sourceURL: choice.url)
    }

    /// 菜单入口：从窗口列表选一个窗口截图（含被遮挡/其它桌面）。
    @objc private func chooseWindow() {
        windowPicker?.show()
        guard windowPicker == nil else { return }
        let picker = WindowPickerController(
            onChoose: { [weak self] choice in
                guard let self else { return }
                self.windowPicker = nil
                self.overlayController.present(
                    windowID: choice.windowID,
                    appName: choice.appName,
                    windowTitle: choice.title
                )
            },
            onCancel: { [weak self] in
                self?.windowPicker = nil
            }
        )
        windowPicker = picker
        picker.show()
    }

    /// 菜单入口：直接进入长截图，选区确定即开始滚动。
    @objc private func startLongScreenshotFlow() {
        overlayController.present(intent: .longScreenshot)
    }

    /// 菜单入口：直接进入 OCR，选区确定即识别。
    @objc private func startOCRCaptureFlow() {
        overlayController.present(intent: .ocr)
    }

    /// 菜单入口：直接进入录制准备，选区确定即弹面板。
    @objc private func startRecordingFlow() {
        overlayController.present(intent: .recording)
    }

    // MARK: - 固定截图

    /// 构造菜单栏的「固定截图」子菜单。
    ///
    /// 用勾选态而不是「点击定位」：用户来这里最常见的两个目的是
    /// 「把挡着的那张收起来」与「把刚才藏起来的拿回来」，
    /// 勾选态 + 点击切换是这两件事的最短路径。
    private func makePinMenuItem() -> NSMenuItem {
        let manager = overlayController.pinManager
        let count = manager.pins.count
        let limit = manager.maximumPins
        // 标题直接写出用量：不展开子菜单也能知道还剩几张。
        let parent = NSMenuItem(
            title: count == 0 ? "固定截图" : "固定截图（\(count)/\(limit)）",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()

        if manager.isAtLimit {
            // 与截图被拒时报的必须是同一件事的两个说法：这里说清去哪解决。
            // 而且必须指向**真正腾出名额**的动作：取消固定后再关闭（或菜单栏「全部关闭」）。
            // 「隐藏」不算——隐藏中的 Pin 仍计入上限（契约 §6），按旧文案用户会白试一轮。
            let tip = NSMenuItem(
                title: "已达上限（\(count)/\(limit)）：取消固定后再关闭，或「全部关闭」",
                action: nil,
                keyEquivalent: ""
            )
            tip.isEnabled = false
            submenu.addItem(tip)
            submenu.addItem(.separator())
        }

        if let error = pinToggleHotKeyError {
            let failed = NSMenuItem(
                title: "切换快捷键不可用：\(error)",
                action: nil,
                keyEquivalent: ""
            )
            failed.isEnabled = false
            submenu.addItem(failed)
            submenu.addItem(.separator())
        }

        if manager.pins.isEmpty {
            let empty = NSMenuItem(title: "暂无固定截图", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for pin in manager.pins {
                let item = NSMenuItem(
                    title: pin.descriptor,
                    action: #selector(togglePinFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                // ✔ = 正在屏幕上显示；无勾 = 已隐藏但位图还在（可恢复）。
                item.state = pin.isUserHidden ? .off : .on
                item.image = pin.menuThumbnail()
                item.representedObject = pin
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            submenu.addItem(makePinBulkItem(title: "显示全部", action: #selector(showAllPins)))
            submenu.addItem(makePinBulkItem(title: "隐藏全部", action: #selector(hideAllPins)))
            submenu.addItem(makePinBulkItem(title: "全部关闭", action: #selector(closeAllPins)))
        }

        parent.submenu = submenu
        return parent
    }

    private func makePinBulkItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// 单个 Pin 的显示/隐藏切换。
    @objc private func togglePinFromMenu(_ sender: NSMenuItem) {
        guard let pin = sender.representedObject as? PinWindow else { return }
        overlayController.pinManager.toggleVisibility(of: pin)
        logger.notice("""
            pin toggled from menu: \(pin.descriptor, privacy: .public) \
            hidden=\(pin.isUserHidden, privacy: .public)
            """)
    }

    @objc private func showAllPins() {
        overlayController.pinManager.showAll()
    }

    @objc private func hideAllPins() {
        overlayController.pinManager.hideAll()
    }

    @objc private func closeAllPins() {
        let manager = overlayController.pinManager
        let count = manager.pins.count
        guard count > 0 else { return }
        // 「全部关闭」会**释放全部位图**且不可撤销，因此必须确认。
        //（单个关闭不确认：固定中它只是隐藏（可恢复），已取消固定时才释放——
        //  而那是用户刚按下图钉明确表达过的意图。）
        let alert = NSAlert()
        alert.messageText = "关闭全部固定截图？"
        alert.informativeText = "共 \(count) 张。关闭会释放它们占用的内存，此操作不可撤销。"
        alert.addButton(withTitle: "全部关闭")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.closeAll()
        logger.notice("closed all pins: \(count, privacy: .public) 张")
    }

    /// 一键隐藏/显示全部固定截图（全局热键）。
    private func toggleAllPins() {
        let manager = overlayController.pinManager
        guard !manager.pins.isEmpty else {
            NSSound.beep()
            pinNotice.show("当前没有固定截图")
            return
        }
        let hiding = manager.hasVisiblePin
        let count = hiding ? manager.visibleCount : manager.hiddenCount
        manager.toggleAllVisibility()
        // 隐藏时必须带上「怎么恢复」：这个热键一按，屏幕上可能什么都不剩，
        // 没有这句话用户会以为 Pin 被弄丢了。
        if hiding {
            pinNotice.show("已隐藏 \(count) 张固定截图（按 \(settings.pinToggleShortcut.displayName) 可恢复）")
        } else {
            pinNotice.show("已显示 \(count) 张固定截图")
        }
        logger.notice("""
            pin toggled by hotkey: hiding=\(hiding, privacy: .public) count=\(count, privacy: .public)
            """)
    }

    /// 达上限的统一提示。两条入口（截图钉住、历史记录重钉）必须说同一句话。
    ///
    /// 文案必须指向**真正腾出名额**的动作：「取消固定后再关闭」。按旧文案去菜单栏
    /// 「关闭」只会隐藏，名额一个也不会腾出（契约 §6：隐藏中的 Pin 仍计入上限）。
    private func showPinLimitNotice(limit: Int) {
        pinNotice.show("固定截图已达上限（\(limit) 张）：先取消固定再关闭几张，或菜单栏「全部关闭」")
    }

    /// 从历史记录重新钉一张。
    ///
    /// 历史条目**只存路径**（M3-6 存储契约），所以这里必须重新读盘。
    /// 读失败不静默：用户刚点了按钮，没反应会让他以为应用坏了。
    private func pinFromHistory(_ entry: HistoryEntry) {
        // 录屏没有可钉的静态位图；直接打开，而不是报「文件已丢失」。
        guard entry.kind != .recording else {
            NSWorkspace.shared.open(entry.fileURL)
            return
        }
        guard let image = Self.loadImage(at: entry.fileURL) else {
            logger.error("history pin failed: \(entry.filePath, privacy: .public)")
            NSSound.beep()
            pinNotice.show("这张截图的文件已不在原位置，无法钉住")
            return
        }
        // 历史记录不带「原屏幕」，用主屏缩放换算：图像像素与文件一致，
        // 只有多屏缩放不一致时初始显示大小才可能不同。
        let scale = DisplayGeometry.scaleFactor(for: DisplayGeometry.mainDisplay())
        switch overlayController.pinManager.pin(image: image, screenScale: scale) {
        case .created(let pin):
            logger.notice("""
                history pin: \(entry.filePath, privacy: .public) → \(pin.descriptor, privacy: .public)
                """)
        case .limitReached(let limit):
            NSSound.beep()
            showPinLimitNotice(limit: limit)
        }
    }

    /// 从磁盘读回全尺寸位图。
    ///
    /// 用 ImageIO 而不是 `NSImage(contentsOf:)`：后者会按当前显示环境做
    /// 色彩转换与尺寸拟合，钉出来的像素可能与原文件不再逐位相同。
    private static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 打开系统设置的「屏幕与系统音频录制」面板。
    /// 打开系统设置的辅助功能面板。
    ///
    /// 用 URL 跳转而不是 `AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt)`：
    /// 后者会弹系统自带提示，而本应用已决定不主动打扰——
    /// 只在用户自己点这个菜单项时才跳转。
    @objc private func openAccessibilitySettings() {
        SystemElementDetector.openAccessibilitySettings()
    }

    @objc private func openScreenRecordingSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 重启应用。排障手段：用于 TCC 或 ScreenCaptureKit 的连接状态异常时。
    ///
    /// ── 为什么不能让新旧实例重叠（实测教训）─────────────────
    ///
    /// 早期实现是「先 `open -n` 起新实例，再 `NSApp.terminate`」。两者会重叠
    /// 约 0.4 秒，而重叠期间新实例注册的全局热键会失效：新实例的日志里
    /// 写着「hotkey registered」（`RegisterEventHotKey` 确实返回了 noErr），
    /// 但按键不再触发任何回调——它握着 `hotKeyRef`，系统却已不把它当成持有者。
    /// 外部表现就是「点了重启，快捷键就没反应了」，而重开一次又可能好了。
    ///
    /// 修法：**先退出自己，再由一个独立的 shell 延迟启动新实例**，
    /// 保证任何时刻只有一个 anShot 参与热键注册。
    @objc private func relaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 延迟 1.5 秒：留出本进程退出（含 Carbon 资源清理）的时间。
        // `-n` 仍然保留：万一本进程尚未完全退出，也必须由新实例接管，
        // 而不是去唤醒一个正在死去的进程。
        task.arguments = ["-c", "sleep 1.5; /usr/bin/open -n \(Self.shellQuoted(bundlePath))"]
        do {
            try task.run()
        } catch {
            logger.error("relaunch failed: \(String(describing: error), privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    /// 给 shell 用的单引号包裹（bundle 路径可能含空格）。
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 诊断（仅 Debug 构建）

    #if DEBUG
    /// 从菜单触发的诊断入口（命令行入口见 CaptureDiagnostics）。
    @objc private func diagnoseCapture() {
        CaptureDiagnostics.runFromMenu()
    }
    #endif
}

#if DEBUG
/// 诊断入口：验证接线存在（单测看不到这层）。
///
/// 整个扩展必须在 `#if DEBUG` 内：它引用的访问器只存在于 DEBUG 里，
/// 放出去会让 Release 构建直接失败（实测）。
extension AppDelegate {

    var overlayControllerForDiagnosticsHasSavedHandler: Bool {
        overlayController.debugHasSavedHandlerForDiagnostics
    }

    var historyStoreForDiagnostics: HistoryStore { historyStore }
}
#endif

/// 打开历史记录面板。
extension AppDelegate {

    /// 每次打开都重读磁盘：用户可能在访达里删过文件，
    /// 而「文件已丢失」正是列表要如实反映的状态。
    @objc func openHistory() {
        historyStore.reload()
        historyPanel.show(historyStore.entries)
    }

    /// 打开长截图日志。`show()` 自己会先 `refresh()`，所以这里不预读。
    @objc func openScrollshotLog() {
        scrollshotLogWindow.show()
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    /// 菜单即将展开时重建内容，使权限状态始终反映最新观测结果。
    public func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }
}

// MARK: - ShortcutHosting

/// 快捷键变更的**事务性**执行者。
///
/// 这里每个方法的顺序都是有意的，不是可以随意重排的实现细节：
/// 全局热键的注册与注销都是系统级副作用，一旦顺序搞反，
/// 用户会以「快捷键突然没了」的形式受到伤害，而这正是最难归因的故障类型。
extension AppDelegate: ShortcutHosting {

    func applyCaptureShortcut(_ shortcut: Shortcut) -> String? {
        // 组合没变**且该注册确实处于活跃状态** → 无需重新注册。
        //（Carbon 对同一组合的二次注册返回 -9878）
        //
        // `globalHotKey != nil` 这个条件不能省：启动期注册失败时它是 nil，
        // 此时用户「改成」同一个值必须真的去注册，
        // 否则会得到一个成功假象（设置里一直是 ⌃1，而 ⌃1 根本没生效）。
        if shortcut == settings.captureShortcut, globalHotKey != nil {
            return nil
        }

        // 先注册新的。（旧的可能仍在注册状态，也可能已被录制让出。）
        do {
            let hotKey = try makeHotKey(for: shortcut)
            globalHotKey = hotKey
            globalHotKeyError = nil
            settings.setCaptureShortcut(shortcut)

            // 提交成功就不再需要恢复了。不清掉的话，录制结束时
            // resume 会把热键改回旧值，把用户刚设的覆盖掉。
            suspendedShortcut = nil

            logger.notice("capture shortcut changed to \(shortcut.displayName, privacy: .public)")
            return nil
        } catch {
            let message = error.localizedDescription
            // 只在**确定没有活跃热键**时才记入菜单状态。
            // 录制期间旧注册已被让出、即将在 resume 时装回；
            // 非录制期间旧注册仍然活跃——两种情况下报
            //「快捷键不可用」都是假的。
            if globalHotKey == nil, suspendedShortcut == nil {
                globalHotKeyError = message
            }
            logger.error("shortcut change rejected: \(message, privacy: .public)")
            return message
        }
    }

    func suspendCaptureShortcut() -> Bool {
        // 已经让出过就不重复处理。
        guard suspendedShortcut == nil else { return true }

        guard let hotKey = globalHotKey else {
            // 启动时就没注册成功（组合被占用等）。此时没有热键可让出，
            // 但设置功能**必须**仍然可用——否则一次启动期冲突
            // 会把用户永久锁在旧快捷键上，连改都改不了。
            logger.notice("suspend requested but no hotkey is active; recording allowed")
            return true
        }

        // 先记下当前值再拆注册：`invalidate()` 之后对象不再持有可复原的信息。
        suspendedShortcut = settings.captureShortcut
        hotKey.invalidate()
        globalHotKey = nil
        logger.notice("capture shortcut suspended for recording")
        return true
    }

    func resumeCaptureShortcut() -> String? {
        guard let shortcut = suspendedShortcut else { return nil }
        suspendedShortcut = nil

        if let reason = applyCaptureShortcut(shortcut) {
            // 恢复失败意味着用户的热键消失了。不自吞：
            // 调用方（设置窗口）会把它显示出来。
            logger.error("failed to restore hotkey after recording: \(reason, privacy: .public)")
            return reason
        }
        logger.notice("capture shortcut restored after recording")
        return nil
    }

    /// 更换 Pin 切换热键。
    ///
    /// **不参与录制的让出/恢复**：录制期间按它隐藏/显示 Pin 是有用的行为
    /// （Pin 是浮窗，会被录进画面），而没有哪条录制交互在抢这个组合。
    func applyPinToggleShortcut(_ shortcut: Shortcut) -> String? {
        // 组合未变且注册确实活跃 → 无需重新注册（Carbon 二次注册返回 -9878）。
        if shortcut == settings.pinToggleShortcut, pinToggleHotKey != nil {
            return nil
        }
        do {
            pinToggleHotKey = try makePinToggleHotKey(for: shortcut)
            pinToggleHotKeyError = nil
            settings.setPinToggleShortcut(shortcut)
            // 提交成功就不再需要恢复了。不清掉的话，录制结束时
            // resume 会把热键改回旧值，把用户刚设的覆盖掉。
            suspendedPinToggleShortcut = nil
            logger.notice("pin toggle shortcut changed to \(shortcut.displayName, privacy: .public)")
            return nil
        } catch {
            let message = error.localizedDescription
            // 只在确定没有活跃热键时才记入菜单状态，否则会报出假故障。
            if pinToggleHotKey == nil, suspendedPinToggleShortcut == nil {
                pinToggleHotKeyError = message
            }
            logger.error("pin toggle shortcut change rejected: \(message, privacy: .public)")
            return message
        }
    }

    func suspendPinToggleShortcut() -> Bool {
        guard suspendedPinToggleShortcut == nil else { return true }
        guard let hotKey = pinToggleHotKey else {
            // 启动时就没注册成功（组合被占用）。此时没有热键可让出，
            // 但设置功能**必须**仍然可用，否则用户永远改不了它。
            logger.notice("pin toggle suspend requested but no hotkey is active")
            return true
        }
        suspendedPinToggleShortcut = settings.pinToggleShortcut
        hotKey.invalidate()
        pinToggleHotKey = nil
        logger.notice("pin toggle shortcut suspended for recording")
        return true
    }

    func resumePinToggleShortcut() -> String? {
        guard let shortcut = suspendedPinToggleShortcut else { return nil }
        suspendedPinToggleShortcut = nil
        if let reason = applyPinToggleShortcut(shortcut) {
            logger.error("failed to restore pin toggle hotkey: \(reason, privacy: .public)")
            return reason
        }
        logger.notice("pin toggle shortcut restored after recording")
        return nil
    }

    // MARK: 直达动作热键

    /// 五个动作的统一入口。截图 / Pin 仍走既有方法，直达动作走新表。
    func applyGlobalShortcut(_ shortcut: Shortcut, for action: GlobalShortcutAction) -> String? {
        switch action {
        case .capture:
            return applyCaptureShortcut(shortcut)
        case .pinToggle:
            return applyPinToggleShortcut(shortcut)
        case .recording, .longScreenshot, .ocr:
            // 组合未变且注册活跃：Carbon 二次注册返回 -9878，不能重试。
            if shortcut == settings.shortcut(for: action), intentHotKeys[action] != nil {
                return nil
            }
            do {
                let hotKey = try makeIntentHotKey(
                    action: action,
                    role: role(for: action),
                    shortcut: shortcut
                )
                intentHotKeys[action] = hotKey
                intentHotKeyErrors[action] = nil
                settings.setShortcut(shortcut, for: action)
                // 提交成功就不需要恢复了，理由同截图快捷键。
                suspendedIntentShortcuts[action] = nil
                logger.notice("""
                    intent shortcut changed; action=\(action.rawValue, privacy: .public) \
                    shortcut=\(shortcut.displayName, privacy: .public)
                    """)
                return nil
            } catch {
                let message = error.localizedDescription
                if intentHotKeys[action] == nil, suspendedIntentShortcuts[action] == nil {
                    intentHotKeyErrors[action] = message
                }
                logger.error("""
                    intent shortcut change rejected; action=\(action.rawValue, privacy: .public) \
                    error=\(message, privacy: .public)
                    """)
                return message
            }
        }
    }

    func suspendGlobalShortcut(for action: GlobalShortcutAction) -> Bool {
        switch action {
        case .capture:
            return suspendCaptureShortcut()
        case .pinToggle:
            return suspendPinToggleShortcut()
        case .recording, .longScreenshot, .ocr:
            guard suspendedIntentShortcuts[action] == nil else { return true }
            guard let hotKey = intentHotKeys[action] else {
                // 启动期就注册失败：没有可让出的热键，但设置必须仍可改。
                logger.notice(
                    "intent suspend requested but no hotkey is active; action=\(action.rawValue, privacy: .public)"
                )
                return true
            }
            suspendedIntentShortcuts[action] = settings.shortcut(for: action)
            hotKey.invalidate()
            intentHotKeys[action] = nil
            logger.notice("intent shortcut suspended; action=\(action.rawValue, privacy: .public)")
            return true
        }
    }

    func resumeGlobalShortcut(for action: GlobalShortcutAction) -> String? {
        switch action {
        case .capture:
            return resumeCaptureShortcut()
        case .pinToggle:
            return resumePinToggleShortcut()
        case .recording, .longScreenshot, .ocr:
            guard let shortcut = suspendedIntentShortcuts[action] else { return nil }
            suspendedIntentShortcuts[action] = nil
            if let reason = applyGlobalShortcut(shortcut, for: action) {
                logger.error("""
                    failed to restore intent hotkey; action=\(action.rawValue, privacy: .public) \
                    error=\(reason, privacy: .public)
                    """)
                return reason
            }
            logger.notice("intent shortcut restored; action=\(action.rawValue, privacy: .public)")
            return nil
        }
    }

    private func role(for action: GlobalShortcutAction) -> GlobalHotKey.Role {
        switch action {
        case .recording: return .recording
        case .longScreenshot: return .longScreenshot
        case .ocr: return .ocr
        case .capture: return .capture
        case .pinToggle: return .pinToggle
        }
    }
}
