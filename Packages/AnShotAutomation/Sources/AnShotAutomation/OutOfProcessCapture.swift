//
//  OutOfProcessCapture.swift
//  AnShotAutomation
//
//  让 anShot.app 自己执行截图/录屏/OCR/窗口探测，复用它已有的 TCC 授权。
//
//  ── 跨进程安全通信协议 ──────────────────────────────────────────
//
//  1. 父进程创建权限为 0700 的私有临时工作区，将结构化参数写入 request.json（0600）。
//  2. 通过 `open -n -g -W anShot.app --args --ipc-request <request.json>` 启动子实例，
//     彻底杜绝 `--app "-h"` / `"--mcp"` / `"--json-out"` 等命令行参数注入。
//  3. 子实例启动后立即将 PID 写入 child.pid（0600），并挂载进程内硬超时 Watchdog。
//  4. 父进程异步等待 report.json；发生超时或取消时读取 child.pid 发送 SIGTERM 回收孤儿进程。
//  5. 通过异步信号量限制并发子进程上限，防止高并发调用打爆系统资源。
//

import AnShotCapture
import AnShotCore
import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// 跨进程调用子实例控制器。
enum OutOfProcessCapture {

    /// 等待子实例返回结果的默认上限（秒）。
    static let defaultTimeout: TimeInterval = 30

    /// 最大并发子进程数（防止 AI 宿主并发发起大量截图导致进程风暴）。
    static let maxConcurrentProcesses = 2

    /// 全局并发节流信号量。
    private static let processSemaphore = AsyncSemaphore(limit: maxConcurrentProcesses)

    /// 轮询间隔。
    private static let pollInterval: TimeInterval = 0.02

    /// 子实例退出后，等待报告出现的宽限时间。
    private static let exitGracePeriod: TimeInterval = 0.5

    /// 当前可执行文件所属的 app bundle。
    static var currentAppURL: URL? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            return nil
        }
        return bundleURL
    }

    // MARK: - 跨进程入口

    /// 让 anShot.app 执行截图并把结果读回本进程（不直接落盘）。
    static func capture(
        parameters: CaptureParameters,
        appURL: URL,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> CaptureOutcome {
        let (report, transferData) = try await runIPC(
            appURL: appURL,
            timeout: timeout,
            outputFileName: "transfer.\((parameters.outputFormat ?? .png).fileExtension)",
            makeAction: { .capture(parameters) }
        )

        guard let capture = report.capture else {
            throw AutomationError.remoteFailure("anShot 实例报告成功，但没有给出截图元数据。")
        }

        let imageData: Data
        if let transferData, !transferData.isEmpty {
            imageData = transferData
        } else if let savedPath = capture.savedPath {
            let fileURL = URL(fileURLWithPath: savedPath)
            guard let loaded = try? Data(contentsOf: fileURL), !loaded.isEmpty else {
                throw AutomationError.remoteFailure("无法读取 anShot 实例生成的截图文件：\(savedPath)")
            }
            imageData = loaded
        } else {
            throw AutomationError.remoteFailure("anShot 实例报告成功，但未返回截图数据。")
        }

        let pixelSize = CGSize(width: capture.pixelWidth, height: capture.pixelHeight)
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            throw AutomationError.remoteFailure("anShot 实例返回的截图尺寸非法（\(capture.pixelWidth)×\(capture.pixelHeight)）。")
        }

        let format = capture.imageFormat.flatMap(CaptureImageFormat.init(rawValue:)) ?? .png
        let gridOrigin = capture.coordinateGridOrigin.map { CGPoint(x: $0.x, y: $0.y) }

        return CaptureOutcome(
            pixelSize: pixelSize,
            imageData: imageData,
            imageFormat: format,
            jpegQuality: capture.jpegQuality,
            didAutoFallbackToJPEG: capture.didAutoFallbackToJPEG ?? false,
            originalPNGByteCount: capture.originalPNGByteCount,
            coordinateGridEnabled: capture.coordinateGridEnabled ?? false,
            coordinateGridOrigin: gridOrigin,
            displayID: capture.displayId,
            scaleFactor: CGFloat(capture.scaleFactor),
            region: capture.region?.rect,
            spaceID: capture.spaceId,
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
            savedURL: nil,
            sourcePixelSize: CGSize(
                width: CGFloat(capture.sourcePixelWidth),
                height: CGFloat(capture.sourcePixelHeight)
            )
        )
    }

    /// 让 anShot.app 枚举窗口列表。
    static func listWindows(
        appURL: URL,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> [WindowInfo] {
        let (report, _) = try await runIPC(
            appURL: appURL,
            timeout: timeout,
            outputFileName: nil,
            makeAction: { .listWindows }
        )
        return report.windows ?? []
    }

    /// 让 anShot.app 截屏并运行本地 Vision OCR。
    static func ocr(
        parameters: OCRParameters,
        appURL: URL,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> OCRResponseOutput {
        let (report, _) = try await runIPC(
            appURL: appURL,
            timeout: timeout,
            outputFileName: nil,
            makeAction: { .ocr(parameters) }
        )
        guard let ocr = report.ocr else {
            throw AutomationError.remoteFailure("anShot 实例报告成功，但未返回 OCR 结果。")
        }
        return ocr
    }

    /// 让 anShot.app 探测窗口或应用的辅助功能控件树。
    static func inspectElements(
        parameters: InspectElementsParameters,
        appURL: URL,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> ElementsInspectionOutput {
        let (report, _) = try await runIPC(
            appURL: appURL,
            timeout: timeout,
            outputFileName: nil,
            makeAction: { .inspectElements(parameters) }
        )
        guard let elements = report.elements else {
            throw AutomationError.remoteFailure("anShot 实例报告成功，但未返回控件树探测结果。")
        }
        return elements
    }

    /// 让 anShot.app 执行有界时长屏幕录制并将临时产物排他落盘到指定路径。
    static func record(
        parameters: RecordingParameters,
        savePath: String,
        reservedOutputPaths: Set<String>,
        appURL: URL,
        timeout: TimeInterval
    ) async throws -> RecordingOutcomeOutput {
        var sanitized = parameters
        sanitized.savePath = nil

        let outputFileName = "transfer.\(parameters.format.fileExtension)"

        // 优先走常驻 anShot.app 私有 Unix Domain Socket 直连录屏（零冷启动、零进程闪现）；
        // 若常驻 App 未启动，自动无感降级到 `open -n -g -W` 兜底路径。
        let workspace = try createPrivateWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let transferURL = workspace.appendingPathComponent(outputFileName)

        let report: CommandReport
        do {
            let (daemonReport, _) = try await AutomationDaemonClient.send(
                action: .record(sanitized),
                outputPath: transferURL.path,
                timeout: timeout
            )
            guard daemonReport.ok else {
                throw AutomationError.remoteFailure(daemonReport.error ?? "anShot 常驻实例未说明录屏失败原因。")
            }
            report = daemonReport
        } catch DaemonClientTransportError.unavailable {
            let (fallbackReport, _, fallbackWorkspace) = try await runIPCWithWorkspace(
                appURL: appURL,
                timeout: timeout,
                outputFileName: outputFileName,
                makeAction: { .record(sanitized) }
            )
            defer { try? FileManager.default.removeItem(at: fallbackWorkspace) }
            guard let recording = fallbackReport.recording else {
                throw AutomationError.remoteFailure("anShot 实例报告成功，但未返回录制元数据。")
            }
            let sourceURL = URL(fileURLWithPath: recording.savedPath)
            let savedURL = try RecordingService.saveRecordingExclusively(
                from: sourceURL,
                to: savePath,
                reservedPaths: reservedOutputPaths
            )
            return RecordingOutcomeOutput(
                savedPath: savedURL.path,
                format: recording.format,
                durationSeconds: recording.durationSeconds,
                pixelWidth: recording.pixelWidth,
                pixelHeight: recording.pixelHeight,
                frameRate: recording.frameRate,
                fileSizeBytes: recording.fileSizeBytes
            )
        } catch let error as DaemonClientTransportError {
            if case .protocolFailure(let message) = error {
                throw AutomationError.remoteFailure(message)
            }
            throw error
        }

        guard let recording = report.recording else {
            throw AutomationError.remoteFailure("anShot 实例报告成功，但未返回录制元数据。")
        }

        let sourceURL = URL(fileURLWithPath: recording.savedPath)
        let savedURL = try RecordingService.saveRecordingExclusively(
            from: sourceURL,
            to: savePath,
            reservedPaths: reservedOutputPaths
        )

        return RecordingOutcomeOutput(
            savedPath: savedURL.path,
            format: recording.format,
            durationSeconds: recording.durationSeconds,
            pixelWidth: recording.pixelWidth,
            pixelHeight: recording.pixelHeight,
            frameRate: recording.frameRate,
            fileSizeBytes: recording.fileSizeBytes
        )
    }

    // MARK: - 统一 IPC 调度

    private static func runIPC(
        appURL: URL,
        timeout: TimeInterval,
        outputFileName: String?,
        makeAction: () -> IPCRequest.Action
    ) async throws -> (report: CommandReport, outputData: Data?) {
        let action = makeAction()

        // 优先走常驻 GUI 进程（anShot.app）内置私有 Unix Domain Socket：
        // 零进程冷启动、零临时磁盘 I/O、零 20ms 文件轮询，真正后台无感执行。
        do {
            let (report, binaryData) = try await AutomationDaemonClient.send(
                action: action,
                outputPath: nil,
                timeout: timeout
            )
            guard report.ok else {
                throw AutomationError.remoteFailure(report.error ?? "anShot 常驻实例未说明失败原因。")
            }
            return (report, binaryData)
        } catch DaemonClientTransportError.unavailable {
            // 常驻 anShot.app 未运行时无缝回落至原有 `open -n -g -W` 兜底路径。
        } catch let error as DaemonClientTransportError {
            if case .protocolFailure(let message) = error {
                throw AutomationError.remoteFailure(message)
            }
            throw error
        }

        let (report, outputData, workspace) = try await runIPCWithWorkspace(
            appURL: appURL,
            timeout: timeout,
            outputFileName: outputFileName,
            makeAction: { action }
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        return (report, outputData)
    }

    private static func runIPCWithWorkspace(
        appURL: URL,
        timeout: TimeInterval,
        outputFileName: String?,
        makeAction: () -> IPCRequest.Action
    ) async throws -> (report: CommandReport, outputData: Data?, workspace: URL) {
        try await processSemaphore.acquire()
        do {
            let workspace = try createPrivateWorkspace()
            do {
                let requestURL = workspace.appendingPathComponent("request.json")
                let reportURL = workspace.appendingPathComponent("report.json")
                let pidURL = workspace.appendingPathComponent("child.pid")
                let transferURL = outputFileName.map { workspace.appendingPathComponent($0) }

                let request = IPCRequest(
                    action: makeAction(),
                    outputPath: transferURL?.path,
                    reportPath: reportURL.path,
                    pidFilePath: pidURL.path,
                    watchdogTimeoutSeconds: timeout
                )
                try request.write(to: requestURL)

                let child = try launch(appURL: appURL, arguments: childLaunchArguments(requestURL: requestURL))
                let report = try await waitForReport(
                    at: reportURL,
                    pidFileURL: pidURL,
                    child: child,
                    timeout: timeout
                )

                guard report.ok else {
                    throw AutomationError.remoteFailure(report.error ?? "anShot 实例未说明失败原因。")
                }

                let outputData: Data?
                if let actualPath = report.capture?.savedPath ?? transferURL?.path,
                   FileManager.default.fileExists(atPath: actualPath) {
                    outputData = try? Data(contentsOf: URL(fileURLWithPath: actualPath))
                } else {
                    outputData = nil
                }

                await processSemaphore.release()
                return (report, outputData, workspace)
            } catch {
                try? FileManager.default.removeItem(at: workspace)
                throw error
            }
        } catch {
            await processSemaphore.release()
            throw error
        }
    }

    /// 创建权限严格为 `0o700` 的私有 IPC 临时目录（禁止 `try?` 吞错）。
    static func createPrivateWorkspace() throws -> URL {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("anshot-ipc-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: workspace,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            // 显式 chmod 兜底，消除进程 umask 导致的权限偏差。
            _ = chmod(workspace.path, 0o700)
        } catch {
            throw AutomationError.outputFailed(
                "无法创建私有 IPC 临时目录 \(workspace.path)：\(error.localizedDescription)"
            )
        }
        return workspace
    }

    // MARK: - 子实例启动参数（防注入）

    /// 构造启动子实例的命令行参数：仅传递 `--ipc-request <request.json>`，完全避免参数注入。
    static func childLaunchArguments(requestURL: URL) -> [String] {
        ["--ipc-request", requestURL.path]
    }

    /// 把区域格式化成 `x,y,width,height`（保留供测试与格式化复用）。
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

    // MARK: - 启动与等待（含 PID 孤儿回收）

    /// 已启动的子实例观察者（封装 `open -n -g -W` 进程）。
    final class LaunchedChild: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var status: Int32?

        init(process: Process) {
            self.process = process
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
        process.arguments = ["-n", "-g", "-W", appURL.path, "--args"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let child = LaunchedChild(process: process)

        do {
            try process.run()
        } catch {
            throw AutomationError.remoteFailure(
                "无法启动 anShot 实例（\(appURL.path)）：\(error.localizedDescription)"
            )
        }
        return child
    }

    /// 轮询子实例写的报告；若超时或任务取消，读取 `child.pid` 发送 `SIGTERM` 回收真实子进程。
    static func waitForReport(
        at url: URL,
        pidFileURL: URL? = nil,
        child: LaunchedChild,
        timeout: TimeInterval
    ) async throws -> CommandReport {
        defer { child.stopWaiting() }
        let deadline = Date().addingTimeInterval(timeout)
        let decoder = JSONDecoder()
        var exitedAt: Date?

        do {
            while Date() < deadline {
                try Task.checkCancellation()

                if let data = try? Data(contentsOf: url), !data.isEmpty,
                   let report = try? decoder.decode(CommandReport.self, from: data) {
                    return report
                }

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
        } catch is CancellationError {
            terminateRealChildIfPresent(pidFileURL: pidFileURL)
            throw CancellationError()
        } catch {
            throw error
        }

        // 超时：结束 `open` 观察者并通过 child.pid 回收真实 anShot 子进程。
        if child.process.isRunning {
            child.process.terminate()
        }
        terminateRealChildIfPresent(pidFileURL: pidFileURL)

        throw AutomationError.remoteFailure("""
        等待 anShot 实例返回结果超时（\(Int(timeout)) 秒）。

        子实例可能启动失败或异常退出。可手动执行以查看原因：
            open -n "<anShot.app>" --args --capture --direct --out /tmp/a.png
        """)
    }

    /// 读取 `child.pid` 并向真实子进程发送 `SIGTERM` 防止孤儿进程残留。
    static func terminateRealChildIfPresent(pidFileURL: URL?) {
        guard let pidFileURL,
              let raw = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              pid != getpid() else {
            return
        }
        _ = kill(pid, SIGTERM)
    }
}

/// 支持取消的异步并发控制信号量（用于限制跨进程与常驻 Socket 最大并发数）。
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        self.available = max(1, limit)
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release() {
        if let first = waiters.first {
            waiters.removeFirst()
            first.continuation.resume()
        } else {
            available += 1
        }
    }
}
