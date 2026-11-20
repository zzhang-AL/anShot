//
//  AutomationSocketBridge.swift
//  AnShotAutomation
//
//  常驻 GUI 进程（anShot.app）内置私有 Unix Domain Socket 自动化代理。
//
//  ── 架构动机 ──────────────────────────────────────────────────
//
//  MCP / CLI 被 AI 宿主（Claude / Cursor / 终端等）直接 spawn 时，macOS TCC
//  会把屏幕录制与辅助功能权限算在宿主头上。旧方案每次调用都经由
//  `open -n -g -W anShot.app` 冷启动一个全新的独立 App 实例来复用授权：
//    - 每次调用产生 300–800ms 冷启动开销与 20ms 文件轮询；
//    - 反复在 LaunchServices 创建/销毁 App 实例，不够「后台无感」。
//
//  常驻菜单栏的 `anShot.app` 本来就一直在后台运行，且已持有完整 TCC 授权。
//  由它托管一个 `0o600` 权限、同 UID 鉴权的本机 Unix Domain Socket：
//    - 在线时：MCP / CLI 直连常驻进程，零进程孵化、零临时文件、毫秒级静默完成；
//    - 离线时：客户端自动无缝降级到原有 `open -n -g -W` 兜底路径，100% 兼容。
//
//  ── 线协议（极简两段式大端长度前缀帧）────────────────────────
//
//  请求：[UInt32 BE jsonLen][JSON(DaemonSocketRequest)]
//  响应：[UInt32 BE jsonLen][JSON(CommandReport)][UInt32 BE binLen][binaryBytes]
//

import Darwin
import Foundation

/// 常驻自动化代理 Socket 请求结构。
struct DaemonSocketRequest: Codable, Sendable, Equatable {
    let action: IPCRequest.Action
    let outputPath: String?
    let timeoutSeconds: TimeInterval
}

/// Socket 传输层错误（区分「常驻未运行可降级」与「已连接但中途通信异常」）。
enum DaemonClientTransportError: Error {
    /// 常驻服务未运行或 Socket 不可达，调用方应无感降级到 `open -n` 子进程。
    case unavailable
    /// 已连上常驻服务但读写异常或协议畸形。
    case protocolFailure(String)
}

/// 私有 Socket 路径计算与底层 POSIX I/O 工具。
enum AutomationSocketTransport {

    /// 单条 JSON 帧最大字节数（1 MiB，足够承载大型窗口列表与 AX 控件树，同时防止畸形帧）。
    static let maxJSONFrameBytes = 16 * 1024 * 1024
    /// 单条二进制载荷最大字节数（64 MiB，足以容纳 8K PNG，同时拦截异常内存分配）。
    static let maxBinaryFrameBytes = 64 * 1024 * 1024

    /// 默认 Socket 路径：优先置于应用私有 Support 目录；若超长用户名逼近 `sun_path` 104B 上限则回退 `/tmp`。
    static func defaultSocketPath() -> String {
        let supportDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/anShot", isDirectory: true)
        let preferred = supportDir.appendingPathComponent("automation.sock").path
        if preferred.utf8.count <= 96 {
            return preferred
        }
        return "/tmp/anshot-auto-\(geteuid()).sock"
    }

    /// 构造 Unix Domain Socket 地址结构。
    static func makeSockAddr(path: String) -> (addr: sockaddr_un, length: socklen_t)? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathBytes = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < maxPathBytes else {
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                raw[index] = byte
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + bytes.count + 1)
        return (addr, len)
    }

    /// 为 Socket 设置 `SO_NOSIGPIPE`（杜绝对端断开触发 SIGPIPE 杀掉进程）及读写超时。
    static func configureSocketOptions(_ fd: Int32, timeoutSeconds: TimeInterval) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let clamped = max(1.0, min(timeoutSeconds, 300.0))
        let sec = Int(clamped)
        let usec = Int32((clamped - Double(sec)) * 1_000_000)
        var tv = timeval(tv_sec: sec, tv_usec: usec)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// 精确写入全部字节（处理短写与 `EINTR`）。
    static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        if data.isEmpty { return true }
        return data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// 精确读取指定字节数（处理短读与 `EINTR`）。
    static func readExact(_ count: Int, from fd: Int32) -> Data? {
        if count == 0 { return Data() }
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        return ok ? data : nil
    }

    /// 写入带 4 字节大端长度前缀的单帧数据。
    static func writeFrame(_ payload: Data, to fd: Int32) -> Bool {
        var lengthBE = UInt32(payload.count).bigEndian
        let header = Data(bytes: &lengthBE, count: MemoryLayout<UInt32>.size)
        guard writeAll(header, to: fd) else { return false }
        return writeAll(payload, to: fd)
    }

    /// 读取带 4 字节大端长度前缀的单帧数据，并校验不超过上限。
    static func readFrame(from fd: Int32, maxBytes: Int) -> Data? {
        guard let header = readExact(MemoryLayout<UInt32>.size, from: fd) else {
            return nil
        }
        let lengthBE = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let length = Int(UInt32(bigEndian: lengthBE))
        guard length >= 0, length <= maxBytes else {
            return nil
        }
        return readExact(length, from: fd)
    }
}

/// 常驻 GUI 进程内置的 Unix Domain Socket 自动化服务端。
///
/// 采用 `DispatchSource.makeReadSource` 事件驱动接受连接，无请求时零轮询、零 CPU 占用；
/// 仅接受同 UID 本机连接，并通过并发信号量防止突发请求风暴。
public final class AutomationDaemonServer: @unchecked Sendable {

    /// 默认全局单例（由 GUI `main.swift` 在获取单实例锁后启动）。
    public static let shared = AutomationDaemonServer()

    /// 最大并发执行任务数。
    static let maxConcurrentRequests = 4

    typealias RequestHandler = @Sendable (DaemonSocketRequest) async -> (report: CommandReport, binaryData: Data?)

    private let socketPath: String
    private let handler: RequestHandler
    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(label: "com.anshot.automation.daemon.accept", qos: .userInitiated)
    private let semaphore = AsyncSemaphore(limit: maxConcurrentRequests)

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var boundInode: ino_t?

    public convenience init() {
        self.init(
            socketPath: AutomationSocketTransport.defaultSocketPath(),
            handler: { request in
                await IPCActionExecutor.executeForDaemon(request)
            }
        )
    }

    init(socketPath: String, handler: @escaping RequestHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// 启动 Unix Domain Socket 监听（幂等；失败仅写 stderr 诊断，绝不阻塞 GUI 主路径）。
    @discardableResult
    public func start() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard listenFD < 0 else { return true }

        let parentDir = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            return false
        }

        guard let resolved = AutomationSocketTransport.makeSockAddr(path: socketPath) else {
            return false
        }
        var addr = resolved.addr
        let addrLen = resolved.length

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        // 防止被子进程继承，并关闭非阻塞以配合 DispatchSource 异步 accept。
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let currentFlags = fcntl(fd, F_GETFL, 0)
        if currentFlags >= 0 {
            _ = fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK)
        }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // 仅当旧路径不存在或已无存活监听者时覆盖，清除上次异常退出的陈旧 socket 文件。
        _ = unlink(socketPath)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            return false
        }

        // 收紧权限为仅当前用户可读写连接。
        _ = chmod(socketPath, 0o600)

        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            _ = unlink(socketPath)
            return false
        }

        var st = stat()
        if lstat(socketPath, &st) == 0 {
            boundInode = st.st_ino
        } else {
            boundInode = nil
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.drainIncomingConnections()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()

        listenFD = fd
        acceptSource = source
        return true
    }

    /// 停止监听并安全清理自己创建的 Socket 文件（校验 inode，不误删新实例的 Socket）。
    public func stop() {
        stateLock.lock()
        let source = acceptSource
        let fd = listenFD
        let expectedInode = boundInode
        acceptSource = nil
        listenFD = -1
        boundInode = nil
        stateLock.unlock()

        if let source {
            source.cancel()
        } else if fd >= 0 {
            Darwin.close(fd)
        }

        if let expectedInode {
            var st = stat()
            if lstat(socketPath, &st) == 0, st.st_ino == expectedInode {
                _ = unlink(socketPath)
            }
        }
    }

    private func drainIncomingConnections() {
        stateLock.lock()
        let fd = listenFD
        stateLock.unlock()
        guard fd >= 0 else { return }

        while true {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(fd, sockPtr, &clientLen)
                }
            }
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                if errno == EINTR {
                    continue
                }
                break
            }

            _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)

            // 严格鉴权：仅允许与当前进程同 UID 的本机客户端接入。
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(clientFD, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
                Darwin.close(clientFD)
                continue
            }

            // 切回阻塞模式并设置超时，避免单条连接阻塞 accept 队列。
            let flags = fcntl(clientFD, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)
            }
            AutomationSocketTransport.configureSocketOptions(clientFD, timeoutSeconds: 15)

            let handler = self.handler
            let semaphore = self.semaphore
            Task.detached(priority: .userInitiated) {
                await Self.handleClientConnection(
                    fd: clientFD,
                    semaphore: semaphore,
                    handler: handler
                )
            }
        }
    }

    private static func handleClientConnection(
        fd: Int32,
        semaphore: AsyncSemaphore,
        handler: @escaping RequestHandler
    ) async {
        defer { Darwin.close(fd) }

        guard let requestData = AutomationSocketTransport.readFrame(
            from: fd,
            maxBytes: AutomationSocketTransport.maxJSONFrameBytes
        ) else {
            return
        }

        let request: DaemonSocketRequest
        do {
            request = try JSONDecoder().decode(DaemonSocketRequest.self, from: requestData)
        } catch {
            let failure = CommandReport.failure("常驻服务无法解析自动化请求：\(error.localizedDescription)")
            sendResponse(report: failure, binaryData: nil, to: fd)
            return
        }

        // 按请求声明的超时拉齐写超时（例如录屏最长 15s + 编码）。
        AutomationSocketTransport.configureSocketOptions(fd, timeoutSeconds: max(15, request.timeoutSeconds + 5))

        do {
            try await semaphore.acquire()
        } catch {
            return
        }
        let result = await handler(request)
        await semaphore.release()

        sendResponse(report: result.report, binaryData: result.binaryData, to: fd)
    }

    private static func sendResponse(report: CommandReport, binaryData: Data?, to fd: Int32) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let reportData = try? encoder.encode(report) else {
            return
        }
        guard AutomationSocketTransport.writeFrame(reportData, to: fd) else {
            return
        }
        _ = AutomationSocketTransport.writeFrame(binaryData ?? Data(), to: fd)
    }
}

/// 线程安全的文件描述符包装盒，支持在 Swift Task 取消时立刻关闭 Socket 中断阻塞读写。
private final class CancellableFD: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(_ fd: Int32) {
        self.fd = fd
    }

    var current: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return fd
    }

    func closeIfOpen() {
        lock.lock()
        let toClose = fd
        fd = -1
        lock.unlock()
        if toClose >= 0 {
            _ = Darwin.shutdown(toClose, SHUT_RDWR)
            Darwin.close(toClose)
        }
    }

    deinit {
        closeIfOpen()
    }
}

/// 常驻 Unix Domain Socket 自动化客户端（供 MCP / CLI 优先直连常驻 `anShot.app`）。
enum AutomationDaemonClient {

    /// 向本机常驻 `anShot.app` 发送一次请求；常驻进程未运行时抛出 `.unavailable` 供调用方降级。
    static func send(
        action: IPCRequest.Action,
        outputPath: String? = nil,
        timeout: TimeInterval,
        socketPath: String = AutomationSocketTransport.defaultSocketPath()
    ) async throws -> (report: CommandReport, binaryData: Data?) {
        guard let resolved = AutomationSocketTransport.makeSockAddr(path: socketPath) else {
            throw DaemonClientTransportError.unavailable
        }
        var addr = resolved.addr
        let addrLen = resolved.length

        let rawFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard rawFD >= 0 else {
            throw DaemonClientTransportError.unavailable
        }
        _ = fcntl(rawFD, F_SETFD, FD_CLOEXEC)
        AutomationSocketTransport.configureSocketOptions(rawFD, timeoutSeconds: max(5, timeout))

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(rawFD, sockPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            Darwin.close(rawFD)
            throw DaemonClientTransportError.unavailable
        }

        let box = CancellableFD(rawFD)
        let request = DaemonSocketRequest(
            action: action,
            outputPath: outputPath,
            timeoutSeconds: timeout
        )
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            box.closeIfOpen()
            throw DaemonClientTransportError.protocolFailure("无法编码请求：\(error.localizedDescription)")
        }

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                defer { box.closeIfOpen() }
                let fd = box.current
                guard fd >= 0 else {
                    throw CancellationError()
                }
                guard AutomationSocketTransport.writeFrame(requestData, to: fd) else {
                    if Task.isCancelled { throw CancellationError() }
                    throw DaemonClientTransportError.unavailable
                }
                guard let reportData = AutomationSocketTransport.readFrame(
                    from: fd,
                    maxBytes: AutomationSocketTransport.maxJSONFrameBytes
                ) else {
                    if Task.isCancelled { throw CancellationError() }
                    throw DaemonClientTransportError.protocolFailure("常驻 anShot 响应中断或超时。")
                }
                guard let binaryData = AutomationSocketTransport.readFrame(
                    from: fd,
                    maxBytes: AutomationSocketTransport.maxBinaryFrameBytes
                ) else {
                    if Task.isCancelled { throw CancellationError() }
                    throw DaemonClientTransportError.protocolFailure("常驻 anShot 二进制载荷读取中断。")
                }

                let report: CommandReport
                do {
                    report = try JSONDecoder().decode(CommandReport.self, from: reportData)
                } catch {
                    throw DaemonClientTransportError.protocolFailure("无法解析常驻 anShot 响应：\(error.localizedDescription)")
                }
                return (report, binaryData.isEmpty ? nil : binaryData)
            }.value
        } onCancel: {
            box.closeIfOpen()
        }
    }
}

/// 统一的自动化动作执行器：供常驻 Socket 服务端与 `--ipc-request` 兜底子进程共用同一套实现。
enum IPCActionExecutor {

    /// 供常驻 Unix Domain Socket 服务端执行：截图数据纯内存返回，零临时磁盘中转。
    static func executeForDaemon(
        _ request: DaemonSocketRequest
    ) async -> (report: CommandReport, binaryData: Data?) {
        switch request.action {
        case .listWindows:
            return (CommandReport(ok: true, windows: WindowCatalog.all()), nil)

        case .capture(var params):
            params.savePath = nil
            do {
                let timeout = max(10, request.timeoutSeconds)
                let outcome = try await CaptureService.capture(params, lockTimeout: timeout)
                let report = CommandReport(
                    ok: true,
                    capture: CaptureOutput(outcome: outcome, overrideSavedPath: nil)
                )
                return (report, outcome.imageData)
            } catch let error as AutomationError {
                return (CommandReport.failure(error.localizedDescription), nil)
            } catch {
                return (CommandReport.failure("截图失败：\(error.localizedDescription)"), nil)
            }

        case .ocr(let params):
            do {
                let ocr = try await AutomationOCRService.recognize(params, execution: .currentProcess)
                return (CommandReport(ok: true, ocr: ocr), nil)
            } catch let error as AutomationError {
                return (CommandReport.failure(error.localizedDescription), nil)
            } catch {
                return (CommandReport.failure("离线文字识别失败：\(error.localizedDescription)"), nil)
            }

        case .inspectElements(let params):
            do {
                let elements = try await AccessibilityInspector.inspect(params, execution: .currentProcess)
                return (CommandReport(ok: true, elements: elements), nil)
            } catch let error as AutomationError {
                return (CommandReport.failure(error.localizedDescription), nil)
            } catch {
                return (CommandReport.failure("控件树探测失败：\(error.localizedDescription)"), nil)
            }

        case .record(let params):
            do {
                let artifact = try await RecordingService.recordLocallyToTemporaryFile(params)
                defer {
                    try? FileManager.default.removeItem(
                        at: artifact.temporaryURL.deletingLastPathComponent()
                    )
                }
                guard let outputPath = request.outputPath else {
                    throw AutomationError.outputFailed("常驻录制请求缺少中转输出路径。")
                }
                let data = try Data(contentsOf: artifact.temporaryURL, options: [.mappedIfSafe])
                try IPCRequest.writePrivateFile(data, to: URL(fileURLWithPath: outputPath))
                let rec = RecordingOutcomeOutput(
                    savedPath: outputPath,
                    format: artifact.format,
                    durationSeconds: artifact.durationSeconds,
                    pixelWidth: artifact.pixelWidth,
                    pixelHeight: artifact.pixelHeight,
                    frameRate: artifact.frameRate,
                    fileSizeBytes: artifact.fileSizeBytes
                )
                return (CommandReport(ok: true, recording: rec), nil)
            } catch let error as AutomationError {
                return (CommandReport.failure(error.localizedDescription), nil)
            } catch {
                return (CommandReport.failure("屏幕录制失败：\(error.localizedDescription)"), nil)
            }
        }
    }
}
