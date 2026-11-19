//
//  PNGOptimizer.swift
//  AnShotCapture
//
//  MIT 合规无损 PNG 两阶段压缩管线（基于 MIT 许可 `oxipng`，严格禁止引入 GPL `pngquant`）。
//
//  ── 两阶段设计（契约 `ux-polish/model.md` §1.3）───────────────────
//  - Phase 0（0ms 延迟）：主路径已同步写出完整合法、含 Retina `pHYs` DPI 与 ICC 的 PNG；
//  - Phase 1（后台异步）：在低优先级后台队列调用 `oxipng -o 4 --strip safe --out <tmp> <src>`，
//    压缩完成后严格校验：
//      1. 退出码 == 0 且临时文件存在、非空且体积严格小于原文件；
//      2. 若原文件包含 `pHYs` chunk，精压结果必须完好保留相同 `pHYs`（严防 144 DPI 丢失）；
//      3. 通过校验后使用 `FileManager.replaceItemAt` 原子替换目标文件；
//    任一条件不满足（含未安装 `oxipng`、超时、或开关关闭）均静默保留 Phase 0 产物，零报错零损坏风险。
//

import AnShotCore
import Foundation

/// 无损 PNG 精压结果。
public enum PNGOptimizationOutcome: Equatable, Sendable {
    /// 成功原子替换，附原始与精压后字节数。
    case optimized(originalBytes: Int, optimizedBytes: Int)
    /// 已跳过（功能关闭、未找到 `oxipng`、文件不存在、精压未缩小体积或被超时中止）。
    case skipped(reason: String)
}

/// MIT 许可 `oxipng` 无损 PNG 压缩管线。
public enum PNGOptimizer {

    /// 默认后台子进程超时时长（秒），防止超大长图在后台无限期占用 CPU。
    public static let defaultTimeoutSeconds: TimeInterval = 15.0

    /// 按优先级定位本机或 App Bundle 内嵌的 `oxipng` 可执行文件。
    ///
    /// 查找顺序：
    ///   1. 显式注入路径（便于测试或环境变量覆盖 `ANSHOT_OXIPNG_PATH`）；
    ///   2. App Bundle `Contents/Helpers/oxipng`（随包分发双架构 Helper）；
    ///   3. App Bundle `Contents/Resources/oxipng`；
    ///   4. 本机 Homebrew / 系统路径（`/opt/homebrew/bin/oxipng`、`/usr/local/bin/oxipng`）。
    public static func locateExecutable(
        explicitOverride: URL? = nil,
        bundle: Bundle = .main
    ) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let explicitOverride {
            candidates.append(explicitOverride)
        }
        if let envPath = ProcessInfo.processInfo.environment["ANSHOT_OXIPNG_PATH"], !envPath.isEmpty {
            candidates.append(URL(fileURLWithPath: envPath))
        }
        let bundleURL = bundle.bundleURL
        candidates.append(bundleURL.appendingPathComponent("Contents/Helpers/oxipng"))
        if let resourceURL = bundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("oxipng"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/oxipng"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/oxipng"))

        for url in candidates {
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// 后台触发已落盘 PNG 文件的两阶段无损精压（不阻塞调用方，失败或无二进制静默降级）。
    public static func scheduleBackgroundOptimization(
        for fileURL: URL,
        enabled: Bool,
        executableOverride: URL? = nil,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds
    ) {
        guard enabled else { return }
        guard fileURL.pathExtension.lowercased() == "png" else { return }
        guard let executable = locateExecutable(explicitOverride: executableOverride) else {
            return
        }
        Task.detached(priority: .utility) {
            _ = optimizeFileInPlace(
                at: fileURL,
                executableURL: executable,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    /// 同步对磁盘上的 PNG 文件执行一次安全精压与原子替换（可在后台队列或单元测试中直接调用）。
    @discardableResult
    public static func optimizeFileInPlace(
        at fileURL: URL,
        executableURL: URL? = nil,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds
    ) -> PNGOptimizationOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return .skipped(reason: "源文件不存在")
        }
        guard let binary = executableURL ?? locateExecutable() else {
            return .skipped(reason: "未检测到 oxipng 可执行文件")
        }
        guard let originalData = try? Data(contentsOf: fileURL), !originalData.isEmpty else {
            return .skipped(reason: "无法读取源 PNG")
        }
        let originalPHYS = extractPNGChunkPayload(named: "pHYs", from: originalData)

        let directory = fileURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).oxipng-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tempURL) }

        let exitStatus = runOxipng(
            executableURL: binary,
            inputURL: fileURL,
            outputURL: tempURL,
            timeoutSeconds: timeoutSeconds
        )
        guard exitStatus == 0 else {
            return .skipped(reason: "oxipng 执行未成功（退出码 \(exitStatus)）")
        }
        guard let optimizedData = try? Data(contentsOf: tempURL),
              !optimizedData.isEmpty,
              isValidPNGSignature(optimizedData) else {
            return .skipped(reason: "精压临时文件无效")
        }
        guard optimizedData.count < originalData.count else {
            return .skipped(reason: "精压后体积未缩减")
        }
        if let originalPHYS {
            let optimizedPHYS = extractPNGChunkPayload(named: "pHYs", from: optimizedData)
            guard optimizedPHYS == originalPHYS else {
                return .skipped(reason: "精压结果丢失或篡改了 pHYs 分辨率信息")
            }
        }

        do {
            _ = try fm.replaceItemAt(
                fileURL,
                withItemAt: tempURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
            return .optimized(originalBytes: originalData.count, optimizedBytes: optimizedData.count)
        } catch {
            return .skipped(reason: "原子替换失败：\(error.localizedDescription)")
        }
    }

    /// 对内存中的 PNG 数据执行一次精压（供后台剪贴板二次优化使用，不修改原文件）。
    public static func optimizeData(
        _ pngData: Data,
        executableURL: URL? = nil,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds
    ) -> Data? {
        guard !pngData.isEmpty, isValidPNGSignature(pngData) else { return nil }
        guard let binary = executableURL ?? locateExecutable() else { return nil }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        let token = UUID().uuidString
        let inputURL = tempDir.appendingPathComponent("anshot-in-\(token).png")
        let outputURL = tempDir.appendingPathComponent("anshot-out-\(token).png")
        defer {
            try? fm.removeItem(at: inputURL)
            try? fm.removeItem(at: outputURL)
        }

        do {
            try pngData.write(to: inputURL, options: .atomic)
        } catch {
            return nil
        }

        let status = runOxipng(
            executableURL: binary,
            inputURL: inputURL,
            outputURL: outputURL,
            timeoutSeconds: timeoutSeconds
        )
        guard status == 0,
              let optimized = try? Data(contentsOf: outputURL),
              isValidPNGSignature(optimized),
              optimized.count < pngData.count else {
            return nil
        }
        if let originalPHYS = extractPNGChunkPayload(named: "pHYs", from: pngData) {
            guard extractPNGChunkPayload(named: "pHYs", from: optimized) == originalPHYS else {
                return nil
            }
        }
        return optimized
    }

    // MARK: - 内部工具：进程执行与 PNG Chunk 校验

    private static func runOxipng(
        executableURL: URL,
        inputURL: URL,
        outputURL: URL,
        timeoutSeconds: TimeInterval
    ) -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        // 严格遵循契约：`-o 4 --strip safe` 保留 pHYs 与 ICC 色彩配置
        process.arguments = [
            "-o", "4",
            "--strip", "safe",
            "--quiet",
            "--out", outputURL.path,
            inputURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return -1
        }

        let waitResult = semaphore.wait(timeout: .now() + max(0.5, timeoutSeconds))
        if waitResult == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.5)
            return -2
        }
        return process.terminationStatus
    }

    /// 校验 8 字节标准 PNG 魔数签名。
    static func isValidPNGSignature(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return data.prefix(8).elementsEqual(sig)
    }

    /// 提取 PNG 中首个指定四字符 Chunk 的 payload（用于核验 `pHYs` 未丢失）。
    public static func extractPNGChunkPayload(named chunkName: String, from data: Data) -> Data? {
        guard isValidPNGSignature(data), chunkName.utf8.count == 4 else { return nil }
        let target = Array(chunkName.utf8)
        var offset = 8
        let total = data.count
        while offset + 12 <= total {
            let length =
                (Int(data[offset]) << 24) |
                (Int(data[offset + 1]) << 16) |
                (Int(data[offset + 2]) << 8) |
                Int(data[offset + 3])
            let typeStart = offset + 4
            let payloadStart = offset + 8
            let nextOffset = payloadStart + length + 4
            guard length >= 0, nextOffset <= total else { break }
            if data[typeStart] == target[0] &&
                data[typeStart + 1] == target[1] &&
                data[typeStart + 2] == target[2] &&
                data[typeStart + 3] == target[3] {
                return data.subdata(in: payloadStart..<(payloadStart + length))
            }
            offset = nextOffset
        }
        return nil
    }
}
