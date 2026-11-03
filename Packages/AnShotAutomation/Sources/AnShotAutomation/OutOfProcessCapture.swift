import AnShotCapture
import AnShotCore
import CoreGraphics
import Foundation
import ImageIO

/// 让 anShot.app **自己**执行截图，而不是由当前进程直接截。
///
/// 存在的理由（这是本项目最容易做反的一处）：
///
/// TCC 把屏幕录制授权记在**发起进程**的代码身份上，而不是被执行的
/// 可执行文件上。被 AI 宿主 spawn 的 stdio MCP 服务器、终端里跑的 CLI，
/// 都没有自己的 TCC 身份——它们直接截图会归因给宿主，于是要求宿主
/// （终端 / AI 客户端）再单独授权一次。可 anShot.app 明明已经有这个授权了。
///
/// 那等于把一个已经解决的问题重新抛给用户，并且额外地扩大了授权面：
/// 给终端录屏权限，比复用一个已知 app 的既有授权更危险。
///
/// 经 `open -n` 启动的实例由 launchd 直接派生，其 responsible process 是
/// 它自己，因此复用的是 anShot.app 已有的授权。本机实测（无需任何新授权）：
/// 端到端 0.16–0.28 秒，并发 3 次互不干扰，`-g` 下不抢用户焦点。
///
/// ## 与子实例的约定
///
/// 子实例以 `--capture --direct` 启动：`--direct` 表示「就地执行、不要再转一手」，
/// 这是防止无限自我启动的关键。子实例把结果 JSON 写到本方法指定的临时路径，
/// 父进程轮询该文件后读出 PNG。
///
/// 之所以走文件而不是管道：`open` 无法把子进程的 stdout 接回来
/// （LaunchServices 启动的进程不继承调用方的描述符）。
enum OutOfProcessCapture {

    /// 等待子实例返回结果的上限。
    ///
    /// 实测端到端在 0.3 秒内，这里给的是「首次启动 + 系统繁忙 + 其它意外」的
    /// 余量。超过它说明子实例没有正常结束（例如崩溃），必须给调用方一个明确
    /// 失败——无限等待会让 AI 宿主整个卡住，比失败更难排查。
    static let defaultTimeout: TimeInterval = 30

    /// 轮询间隔。相对 0.3 秒的总耗时足够细，又不会空转烧 CPU。
    private static let pollInterval: TimeInterval = 0.02

    /// 当前可执行文件所属的 app bundle。
    ///
    /// 自动化模式一定运行在 anShot.app 内部（MCP 客户端配置的就是
    /// `anShot.app/Contents/MacOS/anShot`），所以这里通常能拿到值。
    /// 拿不到的情况是单测、`swift run`，或有人把裸二进制拷出去单独运行。
    static var currentAppURL: URL? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            return nil
        }
        return bundleURL
    }

    /// 启动一个 anShot 实例完成截图，并把结果读回本进程。
    ///
    /// 本方法**不负责落盘**：子实例把 PNG 写进临时目录，父进程读回字节后
    /// 立刻删除。调用方若要保存，由 `CaptureRunner` 用与进程内路径**同一套**
    /// 排他编号逻辑补上——见 `CaptureService.save` 的说明。
    ///
    /// - Parameters:
    ///   - parameters: 调用方请求的截图参数（未经校验，由子实例校验）。
    ///   - appURL: 要启动的 app bundle。
    ///   - timeout: 等待上限。
    /// - Returns: 与进程内截图同构的结果，`savedURL` 恒为 `nil`。
    static func capture(
        parameters: CaptureParameters,
        appURL: URL,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> CaptureOutcome {

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("anshot-ipc-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        // 临时目录连同其中的中转 PNG 一起清理，所以调用方无需再管。
        defer { try? fileManager.removeItem(at: workspace) }

        let reportURL = workspace.appendingPathComponent("report.json")

        // 图片只能经文件传递：`open` 接不回子进程的 stdout。
        // 落在 workspace 内，函数返回时随目录一起删除。
        let transferURL = workspace.appendingPathComponent("transfer.png")

        let child = try launch(appURL: appURL, arguments: childArguments(
            parameters: parameters,
            outputURL: transferURL,
            reportURL: reportURL
        ))

        let report = try await waitForReport(at: reportURL, child: child, timeout: timeout)

        guard report.ok else {
            // 子实例的错误消息已经是完整可读的中文，直接透传，
            // 不再包一层「截图失败：」，否则会出现「捕获失败：捕获失败：…」。
            throw AutomationError.remoteFailure(report.error ?? "anShot 实例未说明失败原因。")
        }
        guard let capture = report.capture, let savedPath = capture.savedPath else {
            throw AutomationError.remoteFailure("anShot 实例报告成功，但没有给出截图文件路径。")
        }

        let pngURL = URL(fileURLWithPath: savedPath)
        guard let pngData = try? Data(contentsOf: pngURL), !pngData.isEmpty else {
            throw AutomationError.remoteFailure("无法读取 anShot 实例生成的截图文件：\(savedPath)")
        }
        guard let image = decodePNG(pngData) else {
            throw AutomationError.remoteFailure("anShot 实例生成的截图无法解码为图像：\(savedPath)")
        }

        return CaptureOutcome(
            image: image,
            pngData: pngData,
            displayID: capture.displayId,
            scaleFactor: CGFloat(capture.scaleFactor),
            region: capture.region?.rect,
            spaceID: capture.spaceId,
            // 窗口来源由子实例回报。整屏 / 区域截图时它为 nil。
            window: capture.window.map {
                WindowCaptureInfo(
                    windowID: CGWindowID($0.windowId),
                    title: $0.title,
                    applicationName: $0.applicationName,
                    frame: $0.frame,
                    displayID: capture.displayId,
                    isOnScreen: $0.isOnScreen
                )
            },
            // 中转文件马上会被上面的 defer 删掉，不能作为「已保存」回报。
            savedURL: nil,
            sourcePixelSize: CGSize(
                width: CGFloat(capture.sourcePixelWidth),
                height: CGFloat(capture.sourcePixelHeight)
            )
        )
    }

    /// 让 anShot.app 枚举窗口，并把结果读回本进程。
    ///
    /// ── 为什么不就地枚举 ─────────────────────────────────────────
    ///
    /// 窗口**标题**受屏幕录制权限管控：无权限的进程枚举出的窗口只有应用名。
    /// 而调用方（AI）要挑一个窗口，靠的正是标题——「Safari 的哪个标签页」
    /// 只能从标题看出来。就地枚举会让它拿到一列只有应用名的窗口。
    ///
    /// 走 app 内还带来一个附带的一致性：**枚举窗口的进程与截图窗口的进程
    /// 是同一个**，因此「列表里的窗口」与「能截的窗口」不会出现权限差异。
    ///
    /// - Returns: 已按「在屏优先、面积降序」排好序的窗口列表。
    static func listWindows(
        appURL: URL,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> [WindowInfo] {

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("anshot-ipc-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let reportURL = workspace.appendingPathComponent("report.json")

        let child = try launch(
            appURL: appURL,
            // `--direct` 是**防递归**的关键，不能省：
            // 子实例同样是这个 CLI，它若不改为就地枚举，就会再启动一个孙实例。
            // 与截图路径的 `--capture --direct` 是同一个约定。
            arguments: ["--list-windows", "--direct", "--json-out", reportURL.path]
        )

        let report = try await waitForReport(at: reportURL, child: child, timeout: timeout)

        guard report.ok else {
            throw AutomationError.remoteFailure(
                report.error ?? "anShot 实例未能枚举窗口，且未说明原因。"
            )
        }

        return report.windows ?? []
    }

    // MARK: - 子实例参数

    /// 组装子实例的命令行参数。
    ///
    /// `--direct` 是防自启动递归的关键：子实例收到它就地执行，不会再 `open`
    /// 一个孙实例。
    ///
    /// 可见性为 internal 而非 private，纯粹是为了让测试能直接断言这段字符串——
    /// 它上面每一个判断错掉都不会编译失败，只会让子实例悄悄多转一手或
    /// 把不缩放（`--max-size 0`）变成默认缩放。
    static func childArguments(
        parameters: CaptureParameters,
        outputURL: URL,
        reportURL: URL
    ) -> [String] {

        var arguments = ["--capture", "--direct"]

        if let displayID = parameters.displayID {
            arguments += ["--display", String(displayID)]
        }
        if let spaceID = parameters.spaceID {
            arguments += ["--space", String(spaceID)]
        }
        if parameters.allowDesktopSwitch {
            arguments.append("--switch-desktop")
        }
        if let region = parameters.region {
            arguments += ["--region", regionArgument(region)]
        }
        // 窗口寻址：ID 直接传；应用名原样传——**解析在子实例里做**。
        //
        // 为什么不在父进程解析成 ID 再传：窗口标题与列表的可见性取决于屏幕
        // 录制权限，而父进程（被 AI 宿主 spawn 的 MCP 进程）通常没有这个权限。
        // 在父进程解析，选中的可能只是「恰好能被无权限进程看到的那一个」；
        // 在子实例（anShot.app，有权限）解析，看到的才是真实的窗口列表。
        if let windowID = parameters.windowID {
            arguments += ["--window", String(windowID)]
        }
        if let applicationName = parameters.applicationName {
            arguments += ["--app", applicationName]
        }
        // 注意 `0` 是合法且有意义的取值（表示不缩放），所以这里不能用
        // 「非零才传」的写法，必须判空而不是判零。
        if let maxLongEdge = parameters.maxLongEdge {
            arguments += ["--max-size", String(maxLongEdge)]
        }

        arguments += ["--out", outputURL.path, "--json-out", reportURL.path]
        return arguments
    }

    /// 把区域格式化成 `x,y,width,height`。
    ///
    /// 必须用 POSIX 数字格式：某些区域设置的小数点是逗号，
    /// 那会把「四个分量」的分隔符和小数点混成同一个字符。
    static func regionArgument(_ rect: CGRect) -> String {
        [rect.origin.x, rect.origin.y, rect.width, rect.height]
            .map(number)
            .joined(separator: ",")
    }

    static func number(_ value: CGFloat) -> String {
        let rounded = value.rounded()
        if value == rounded, abs(rounded) < 1e15 {
            return String(Int(rounded))
        }
        return String(
            format: "%.4f",
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: [Double(value)]
        )
    }

    // MARK: - 启动与等待

    /// 已启动的子实例。
    ///
    /// 持有的是 `open -W` 这个进程：`-W` 让它一直等到子实例退出才返回，
    /// 于是「`open` 退出了」就等价于「子实例已经结束」。
    /// 子实例本身由 LaunchServices 派生，拿不到它的 PID（这正是复用授权的前提）。
    final class LaunchedChild: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var status: Int32?

        init(process: Process) {
            self.process = process
            // 调用方持有观察者；回调不能再把它与 Process 相互强引用。
            process.terminationHandler = { [weak self] finished in
                self?.markExited(finished.terminationStatus)
            }
        }

        /// `open` 已退出时的退出码；仍在运行时为 nil。
        var exitStatus: Int32? {
            lock.withLock { status }
        }

        fileprivate func markExited(_ code: Int32) {
            lock.withLock { status = code }
        }

        func stopWaiting() {
            if process.isRunning { process.terminate() }
        }
    }

    private static func launch(appURL: URL, arguments: [String]) throws -> LaunchedChild {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // `-n` 必须给：LaunchServices 对已在运行的实例会忽略 `--args`，
        // 于是参数传不进去。`-g` 让实例后台启动，不抢用户当前的焦点——
        // agent 截图时用户往往正在别的窗口里操作。
        //
        // `-W` 让 `open` 等到子实例退出才返回（实测：正常截图时它与报告同时结束，
        // 不增加耗时）。没有它，子实例启动即崩溃时只能干等满超时才知道失败；
        // 有了它，`open` 一退出而报告仍不在，就可以立刻判定失败。
        // 子实例退出得极快时 `open` 可能来不及挂上（会打印 "Unable to block on
        // application" 并直接返回 0），那同样意味着子实例已经结束，语义不变。
        process.arguments = ["-n", "-g", "-W", appURL.path, "--args"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let child = LaunchedChild(process: process)
        // 不再同步 `waitUntilExit()`：那会在 Swift 并发的协作线程上阻塞，
        // MCP 并发调用多了会把线程池占满。改由终止回调记下退出码。

        do {
            try process.run()
        } catch {
            throw AutomationError.remoteFailure(
                "无法启动 anShot 实例（\(appURL.path)）：\(error.localizedDescription)"
            )
        }
        return child
    }

    /// 子实例退出后，再等报告出现的宽限时间。
    ///
    /// 报告是原子写入、且在子实例退出**之前**完成的，理论上不需要宽限；
    /// 留一小段只是为了吸收文件系统可见性上的抖动，避免把成功误判成失败。
    private static let exitGracePeriod: TimeInterval = 0.5

    /// 轮询子实例写的报告。
    ///
    /// 不用文件监听（FSEvents / DispatchSource）的原因：这里只有一个很短的文件，
    /// 20ms 轮询在实测的 0.3 秒总耗时里只多花几毫秒，却省掉了一套监听生命周期的
    /// 管理，也避开了「文件先创建后写入」的竞态握手。
    static func waitForReport(
        at url: URL,
        child: LaunchedChild,
        timeout: TimeInterval
    ) async throws -> CommandReport {
        // 成功、取消或失败都结束 open -W 观察者；不会终止被截图的应用。
        defer { child.stopWaiting() }
        let deadline = Date().addingTimeInterval(timeout)
        let decoder = JSONDecoder()
        var exitedAt: Date?

        while Date() < deadline {
            if let data = try? Data(contentsOf: url), !data.isEmpty,
               let report = try? decoder.decode(CommandReport.self, from: data) {
                return report
            }

            // 子实例已退出而报告迟迟不来：它不会再来了，立刻失败而不是等满超时。
            if let status = child.exitStatus {
                let since = exitedAt ?? Date()
                exitedAt = since
                if Date().timeIntervalSince(since) >= exitGracePeriod {
                    throw AutomationError.remoteFailure("""
                    anShot 实例已退出，但没有返回结果（open 退出码 \(status)）。

                    子实例可能启动失败或异常退出。可手动执行以查看原因：
                        open -n "<anShot.app>" --args --capture --direct --out /tmp/a.png
                    """)
                }
            }

            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        // 超时：不再等 `open`。它只是个旁观者，结束它不会影响子实例本身。
        if child.process.isRunning {
            child.process.terminate()
        }
        throw AutomationError.remoteFailure("""
        等待 anShot 实例返回结果超时（\(Int(timeout)) 秒）。

        子实例可能启动失败或异常退出。可手动执行以查看原因：
            open -n "<anShot.app>" --args --capture --direct --out /tmp/a.png
        """)
    }

    // MARK: - 解码

    private static func decodePNG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
