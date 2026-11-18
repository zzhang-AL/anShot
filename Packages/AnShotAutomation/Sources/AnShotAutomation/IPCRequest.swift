//
//  IPCRequest.swift
//  AnShotAutomation
//
//  跨进程结构化 IPC 请求协议：通过私有工作区内的 request.json 传递参数，
//  彻底消除 `--app "-h"` / `"--mcp"` / `"--json-out"` 等命令行参数注入攻击面，
//  并携带 child.pid 路径与进程内硬超时 Watchdog 配置防止孤儿进程残留。
//

import Darwin
import Foundation

/// 跨进程调用子实例的结构化请求。
struct IPCRequest: Codable, Sendable, Equatable {

    /// 请求动作。
    enum Action: Codable, Sendable, Equatable {
        case listWindows
        case capture(CaptureParameters)
        case ocr(OCRParameters)
        case inspectElements(InspectElementsParameters)
        case record(RecordingParameters)
    }

    let action: Action

    /// 中转产物路径（如截图图片、录屏临时文件）；无需中转文件的动作可为 nil。
    let outputPath: String?

    /// `report.json` 路径。
    let reportPath: String

    /// `child.pid` 路径，子实例启动后立即写入自身 PID 供父进程超时/取消回收。
    let pidFilePath: String

    /// 子实例硬超时上限（秒），用于挂载进程内 Watchdog 自毁兜底。
    let watchdogTimeoutSeconds: TimeInterval

    /// 以 `0o600` 权限写入请求 JSON。
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(self)
        } catch {
            throw AutomationError.outputFailed("无法编码跨进程请求：\(error.localizedDescription)")
        }
        try Self.writePrivateFile(data, to: url)
    }

    /// 从磁盘读取结构化请求。
    static func load(from path: String) throws -> IPCRequest {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AutomationError.invalidArgument("无法读取跨进程请求文件（\(url.path)）：\(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(IPCRequest.self, from: data)
        } catch {
            throw AutomationError.invalidArgument("跨进程请求格式非法（\(url.path)）：\(error.localizedDescription)")
        }
    }

    /// 子实例写入自身 PID 到 `child.pid`（权限 `0o600`）。
    static func writeCurrentPID(to path: String) {
        let pidText = "\(ProcessInfo.processInfo.processIdentifier)\n"
        try? writePrivateFile(Data(pidText.utf8), to: URL(fileURLWithPath: path))
    }

    /// 创建或原子覆写权限收紧为 `0o600` 的私有文件。
    static func writePrivateFile(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let descriptor = tempURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            throw AutomationError.outputFailed("无法创建私有文件 \(url.path)：\(String(cString: strerror(errno)))")
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            _ = chmod(tempURL.path, 0o600)
            // 原子替换目标路径，确保读端要么看到完整内容要么看到旧状态。
            guard rename(tempURL.path, url.path) == 0 else {
                throw AutomationError.outputFailed(
                    "原子替换私有文件 \(url.path) 失败：\(String(cString: strerror(errno)))"
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}
