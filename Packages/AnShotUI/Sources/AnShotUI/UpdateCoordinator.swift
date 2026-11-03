//
//  UpdateCoordinator.swift
//  AnShotUI
//
//  更新流程的唯一状态机与调度者。
//
//  ── 为什么是单例 ─────────────────────────────────────────────
//
//  更新状态有三个读者：设置「关于」页（状态行与「检查更新」按钮）、
//  更新窗口、自动检查定时器。三者必须看到同一个结论——用户刚在设置页
//  看到「发现新版本」，点进更新窗口却显示「正在检查」，是最典型的
//  多份状态导致的错觉。因此这里集中持有检查结果，其它角色只读或订阅。
//
//  ── 自动 vs 手动 ────────────────────────────────────────────
//
//  自动检查是**后台行为**：发现新版本只发一条非激活的轻提示，绝不抢焦点；
//  检查失败完全安静（用户没要求，弹错就是打扰）。节流由
//  `UpdatePreferencesStore.shouldAutoCheck` 统一判断。
//
//  手动检查是**明确意图**：无论结果如何都打开更新窗口——「已是最新」
//  本身就是要给用户看的信息，只发一条两秒消失的提示等于什么都没说。
//
//  ── 状态划分 ────────────────────────────────────────────────
//
//  `UpdateState` 只描述「检查」这一层（设置页需要）。下载、校验、安装
//  的细节属于窗口自己的阶段（`UpdateWindowController.Phase`），
//  否则设置页的状态行会被迫理解它不关心的传输进度。
//

import AnShotCore
import AppKit

/// 检查结果的高层状态。设置页与窗口共用。
enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case noRelease
    case upToDate(AppVersion)
    case available(UpdateRelease)
    case failed(String)
}

@MainActor
final class UpdateCoordinator {

    static let shared = UpdateCoordinator(
        preferences: .shared,
        service: UpdateService(),
        installer: UpdateInstaller()
    )

    /// 两次自动检查的最小间隔。契约要求 24 小时。
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    /// 启动后首次自动检查的延迟。
    ///
    /// 启动瞬间应用要做权限检查、热键注册、图片预热；更新检查不该与之争抢。
    /// 8 秒也足够让首启窗口先出现，避免更新提示盖在欢迎页上。
    static let automaticCheckDelay: TimeInterval = 8

    private let preferences: UpdatePreferencesStore
    private let service: UpdateService
    private let installer: UpdateInstaller

    /// 最近一次检查的高层状态。
    private(set) var state: UpdateState = .idle {
        didSet { onStateChange?(state) }
    }

    /// 状态变化回调（设置页订阅）。
    ///
    /// 赋值时立即回放当前状态：订阅者通常在窗口构建完成后才设置回调，
    /// 若只等下一次变化，用户会先看到一段空白状态行。
    var onStateChange: ((UpdateState) -> Void)? {
        didSet { onStateChange?(state) }
    }

    private var windowController: UpdateWindowController?
    private var autoCheckTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?

    /// 当前展示中的发布版本（用于「稍后」与安装）。
    private var pendingRelease: UpdateRelease?
    /// 已下载并通过校验的 app（`ready` 阶段使用）。
    private var downloadedAppURL: URL?

    private var isChecking = false
    /// 本次检查结束后是否必须把结果展示到窗口。
    ///
    /// 自动检查在飞时用户点了「检查更新」：不能取消已在进行的请求，
    /// 但它的结果必须给用户看到，所以把「要展示」记在检查自己身上。
    private var shouldPresentResult = false
    /// 上一次失败来自下载而非检查：决定「重试」按钮重做哪一步。
    private var lastFailureWasDownload = false

    private init(
        preferences: UpdatePreferencesStore,
        service: UpdateService,
        installer: UpdateInstaller
    ) {
        self.preferences = preferences
        self.service = service
        self.installer = installer
    }

    // MARK: - 版本信息

    /// "1.0.0 (15)"。设置「关于」页直接显示这一串。
    var currentVersionDescription: String {
        guard let short = bundleString("CFBundleShortVersionString"), !short.isEmpty else {
            return "未知版本"
        }
        if let build = bundleString("CFBundleVersion"), !build.isEmpty {
            return "\(short) (\(build))"
        }
        return short
    }

    /// 用于比较的当前版本。
    ///
    /// 解析失败时返回 `0`：Infoplist 里写了非法版本号属于打包错误，
    /// 此时「把任何 release 都当成更新」比「静默认为已是最新」更容易被发现。
    private var installedVersion: AppVersion {
        if let raw = bundleString("CFBundleShortVersionString"), let version = AppVersion(raw) {
            return version
        }
        return AppVersion("0")!
    }

    private func bundleString(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 检查

    /// 检查更新。
    ///
    /// - Parameter manual: `true` 表示用户主动触发：一定打开窗口展示结果。
    func check(manual: Bool) async {
        // 下载/校验/安装期间不允许再发起检查：窗口正处在会变的状态机上，
        // 用「检查中」覆盖它会丢掉「已下载待安装」。手动点击只把窗口带到前面。
        if downloadTask != nil {
            if manual { windowController?.show() }
            return
        }

        guard !isChecking else {
            // 已经有一次检查在飞：手动请求时把窗口带到前面，并记下
            // 「这次结果必须展示」，让在飞的检查完成后补上结果。
            shouldPresentResult = shouldPresentResult || manual
            if manual {
                showWindow(.checking)
            }
            return
        }

        isChecking = true
        shouldPresentResult = manual
        lastFailureWasDownload = false
        state = .checking
        if shouldPresentResult {
            // 手动检查立即开窗：让「点了没反应」变成「正在检查」。
            showWindow(.checking)
        }
        defer {
            isChecking = false
            shouldPresentResult = false
        }

        do {
            let result = try await service.check(currentVersion: installedVersion)
            // 只有成功完成才算「检查过」，失败不应把下一次自动检查推迟 24 小时。
            preferences.lastCheckAt = Date()

            switch result {
            case .noRelease:
                state = .noRelease
                if shouldPresentResult { showWindow(.noRelease) }

            case .upToDate(let version):
                state = .upToDate(version)
                if shouldPresentResult { showWindow(.upToDate(version)) }

            case .available(let release):
                pendingRelease = release
                downloadedAppURL = nil
                state = .available(release)
                if shouldPresentResult {
                    showWindow(.available(release))
                } else {
                    notifyAutomatically(about: release)
                }
            }
        } catch {
            let message = readableMessage(for: error)
            state = .failed(message)
            if shouldPresentResult {
                showWindow(.failed(message: message, canRetry: true))
            }
            // 自动检查失败保持安静。
        }
    }

    /// 自动检查的新版本提示。
    ///
    /// 用户点过「稍后」的版本不再打扰；手动检查不受此限制
    ///（用户主动问“有没有新版本”时不回答才是错的）。
    private func notifyAutomatically(about release: UpdateRelease) {
        guard preferences.skippedVersion != release.version.description else { return }
        ToastPresenter.show(
            "发现新版本 \(release.version)",
            actionTitle: "查看"
        ) { [weak self] in
            self?.presentAvailableUpdate()
        }
    }

    /// 打开更新窗口（有可展示的发布时直接展示，否则按手动检查处理）。
    func presentAvailableUpdate() {
        switch state {
        case .available(let release):
            pendingRelease = release
            showWindow(.available(release))
        case .checking:
            showWindow(.checking)
        case .noRelease:
            showWindow(.noRelease)
        case .upToDate(let version):
            showWindow(.upToDate(version))
        case .failed(let message):
            showWindow(.failed(message: message, canRetry: true))
        case .idle:
            Task { await check(manual: true) }
        }
    }

    /// 启动后延迟检查，此后每 24 小时一次。
    ///
    /// 幂等：`AppDelegate` 只需调用一次；重复调用不会叠加定时器
    ///（叠加会让请求次数成倍增长，并可能触发 GitHub 的速率限制）。
    func startAutomaticChecks() {
        guard autoCheckTask == nil else { return }

        autoCheckTask = Task { [weak self] in
            if Self.automaticCheckDelay > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.automaticCheckDelay * 1_000_000_000)
                )
            }
            while !Task.isCancelled {
                guard let self else { return }
                if self.preferences.shouldAutoCheck(
                    now: Date(),
                    interval: Self.automaticCheckInterval
                ) {
                    await self.check(manual: false)
                }
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.automaticCheckInterval * 1_000_000_000)
                )
            }
        }
    }

    // MARK: - 下载 / 安装

    private func startDownload() {
        guard let release = pendingRelease else {
            // 没有发布版本时「下载」无意义，退回到检查。
            Task { await check(manual: true) }
            return
        }
        guard downloadTask == nil else { return }

        downloadedAppURL = nil
        windowController?.render(.downloading(progress: 0))

        installer.onStageChange = { [weak self] stage in
            guard let self else { return }
            switch stage {
            case .downloading:
                // 进度由 download 的 progress 回调驱动，这里不覆盖。
                break
            case .verifyingChecksum:
                self.windowController?.render(.verifying("正在校验 SHA256…"))
            case .unpacking:
                self.windowController?.render(.verifying("正在解压安装包…"))
            case .validatingSignature:
                self.windowController?.render(.verifying("正在校验代码签名与版本…"))
            }
        }

        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloadTask = nil }
            do {
                let appURL = try await self.installer.download(release) { progress in
                    self.windowController?.render(.downloading(progress: progress))
                }
                self.downloadedAppURL = appURL
                self.lastFailureWasDownload = false
                self.windowController?.render(.ready)
            } catch {
                self.lastFailureWasDownload = true
                let message = self.readableMessage(for: error)
                self.windowController?.render(.failed(message: message, canRetry: true))
            }
        }
    }

    /// 用户确认后安装并退出。
    ///
    /// 确认框不可省略：安装会让应用**立即退出**，这是会丢失未保存状态的
    /// 破坏性动作，必须由用户明确同意。
    private func install() {
        guard let appURL = downloadedAppURL else {
            Task { await check(manual: true) }
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "anShot 将退出并重新打开"
        alert.informativeText = "新版本已下载并通过校验。安装会退出当前版本、替换「应用程序」中的 anShot，然后自动重新启动。"
        alert.addButton(withTitle: "立即重启安装")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        windowController?.render(.installing)
        do {
            try installer.installAndRelaunch(appURL: appURL)
            // 脚本会等本进程退出后再替换 bundle。
            NSApp.terminate(nil)
        } catch {
            let message = readableMessage(for: error)
            windowController?.render(.failed(message: message, canRetry: false))
            // 契约要求：无法自安装时给出原因**并**打开发布页。
            openReleasePageIfNeeded(for: error)
        }
    }

    private func retry() {
        if lastFailureWasDownload, pendingRelease != nil {
            startDownload()
        } else {
            Task { await check(manual: true) }
        }
    }

    /// 用户点「稍后」：记住版本，自动检查不再提示同一个版本。
    private func postpone() {
        if let release = pendingRelease {
            preferences.skippedVersion = release.version.description
        }
        windowController?.close()
    }

    private func openReleasePage() {
        let url = pendingRelease?.pageURL ?? UpdateService.releasesPage
        NSWorkspace.shared.open(url)
    }

    private func openReleasePageIfNeeded(for error: Error) {
        guard let installError = error as? UpdateInstallError else { return }
        switch installError {
        case .notInApplications, .notWritable:
            openReleasePage()
        case .noAsset, .checksumUnavailable, .checksumMismatch, .unzipFailed,
             .signatureInvalid, .installFailed:
            // 这些情况窗口已经给出「打开发布页」按钮，不替用户做决定。
            break
        }
    }

    // MARK: - 窗口

    private func showWindow(_ phase: UpdateWindowController.Phase) {
        let controller = windowController ?? makeWindowController()
        windowController = controller
        controller.render(phase)
        controller.show()
    }

    private func makeWindowController() -> UpdateWindowController {
        let controller = UpdateWindowController(
            currentVersionDescription: currentVersionDescription
        )
        controller.onRequestCheck = { [weak self] in
            guard let self else { return }
            Task { await self.check(manual: true) }
        }
        controller.onRequestDownload = { [weak self] in
            self?.startDownload()
        }
        controller.onRequestInstall = { [weak self] in
            self?.install()
        }
        controller.onRequestLater = { [weak self] in
            self?.postpone()
        }
        controller.onRequestOpenPage = { [weak self] in
            self?.openReleasePage()
        }
        controller.onRequestRetry = { [weak self] in
            self?.retry()
        }
        return controller
    }

    // MARK: - 错误文案

    /// 把任何错误变成用户能读懂的一句话。
    ///
    /// `LocalizedError` 优先；其余（URLError、文件系统错误）退回到系统描述，
    /// 至少比「操作无法完成」多一点信息。
    private func readableMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return "更新失败：\(error.localizedDescription)"
    }
}
