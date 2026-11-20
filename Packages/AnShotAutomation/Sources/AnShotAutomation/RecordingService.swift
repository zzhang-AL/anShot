//
//  RecordingService.swift
//  AnShotAutomation
//
//  有界时长屏幕录制自动化服务：复用 SCStreamRecorder 与 GIFExporter，
//  限制录制时长为 1...15 秒，支持输出 GIF 与 MP4 文件路径供 AI Agent 验收动画与交互。
//

import AnShotCapture
import AnShotCore
import CoreGraphics
import Foundation

/// 自动化录制输出格式。
public enum RecordingOutputFormat: String, Codable, Sendable, Equatable, CaseIterable {
    case gif
    case mp4

    public var fileExtension: String {
        rawValue
    }
}

/// 有界时长录制请求参数。
public struct RecordingParameters: Codable, Sendable, Equatable {

    /// 默认录制时长（秒）。
    public static let defaultDurationSeconds: TimeInterval = 3
    /// 最小允许录制时长（秒）。
    public static let minimumDurationSeconds: TimeInterval = 1
    /// 最大允许录制时长（秒）。
    public static let maximumDurationSeconds: TimeInterval = 15

    /// 目标显示器 ID。
    public var displayID: CGDirectDisplayID?

    /// 显示器内逻辑点区域。
    public var region: CGRect?

    /// 目标窗口 ID。
    public var windowID: CGWindowID?

    /// 目标应用名。
    public var applicationName: String?

    /// 录制时长（强制 1...15 秒）。
    public var durationSeconds: TimeInterval

    /// 输出格式（`gif` 或 `mp4`）。
    public var format: RecordingOutputFormat

    /// 帧率（`nil` 时 GIF 默认 12，MP4 默认 30）。
    public var fps: Int?

    /// GIF 长边像素上限（`nil` 时默认 800；仅 GIF 支持）。
    public var maxDimension: Int?

    /// 保存路径；`nil` 时自动落盘到 `~/Pictures/anShot/`。
    public var savePath: String?

    public init(
        displayID: CGDirectDisplayID? = nil,
        region: CGRect? = nil,
        windowID: CGWindowID? = nil,
        applicationName: String? = nil,
        durationSeconds: TimeInterval = RecordingParameters.defaultDurationSeconds,
        format: RecordingOutputFormat = .gif,
        fps: Int? = nil,
        maxDimension: Int? = nil,
        savePath: String? = nil
    ) {
        self.displayID = displayID
        self.region = region
        self.windowID = windowID
        self.applicationName = applicationName
        self.durationSeconds = durationSeconds
        self.format = format
        self.fps = fps
        self.maxDimension = maxDimension
        self.savePath = savePath
    }

    /// 校验数值范围与目标寻址互斥性。
    public func validate() throws -> ResolvedCaptureTarget {
        guard durationSeconds.isFinite,
              durationSeconds >= Self.minimumDurationSeconds,
              durationSeconds <= Self.maximumDurationSeconds else {
            throw AutomationError.invalidArgument(
                "duration 必须在 \(Int(Self.minimumDurationSeconds)) 到 \(Int(Self.maximumDurationSeconds)) 秒之间"
                + "（收到 \(durationSeconds)）。"
            )
        }

        if let fps {
            let maxFPS = format == .gif ? 30 : 60
            guard (1...maxFPS).contains(fps) else {
                throw AutomationError.invalidArgument(
                    "\(format.rawValue) 模式下 fps 必须在 1 到 \(maxFPS) 之间（收到 \(fps)）。"
                )
            }
        }

        if let maxDimension {
            guard format == .gif else {
                throw AutomationError.invalidArgument(
                    "max_size 仅在 format: \"gif\" 时支持（MP4 请勿传入 max_size）。"
                )
            }
            guard (100...1600).contains(maxDimension) else {
                throw AutomationError.invalidArgument(
                    "GIF max_size 必须在 100 到 1600 之间（收到 \(maxDimension)）。"
                )
            }
        }

        return try asCaptureParameters().resolveTarget()
    }

    func asCaptureParameters() -> CaptureParameters {
        CaptureParameters(
            displayID: displayID,
            region: region,
            windowID: windowID,
            applicationName: applicationName
        )
    }

    /// 实际生效帧率。
    var resolvedFPS: Int {
        fps ?? (format == .gif ? GIFSettings.defaultFrameRate : 30)
    }

    /// 实际生效 GIF 最大边长。
    var resolvedMaxDimension: Int {
        maxDimension ?? GIFSettings.defaultPixelDimension
    }
}

/// 录制结果输出结构。
public struct RecordingOutcomeOutput: Codable, Sendable, Equatable {
    public let savedPath: String
    public let format: String
    public let durationSeconds: Double
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameRate: Double
    public let fileSizeBytes: Int64
}

/// 自动化录屏执行入口。
public enum RecordingService {

    /// 执行有界时长屏幕录制并落盘，绝不覆盖已有文件。
    public static func record(
        _ parameters: RecordingParameters,
        execution: CaptureExecution = .reuseApplicationAuthorization,
        reservedOutputPaths: Set<String> = []
    ) async throws -> RecordingOutcomeOutput {
        _ = try parameters.validate()

        let requestedSavePath = (parameters.savePath?.isEmpty == false)
            ? parameters.savePath!
            : defaultOutputPath(format: parameters.format)

        // 优先走跨进程复用 anShot.app 已有的屏幕录制授权。
        if execution == .reuseApplicationAuthorization,
           let appURL = OutOfProcessCapture.currentAppURL {
            // 留足 GIF 转码缓冲时间：录制时长 + 60 秒。
            let timeout = parameters.durationSeconds + 60
            return try await OutOfProcessCapture.record(
                parameters: parameters,
                savePath: requestedSavePath,
                reservedOutputPaths: reservedOutputPaths,
                appURL: appURL,
                timeout: timeout
            )
        }

        // 就地录制（--direct、子实例或单测）。
        let outcome = try await recordLocallyToTemporaryFile(parameters)
        defer { try? FileManager.default.removeItem(at: outcome.temporaryURL.deletingLastPathComponent()) }

        // 使用与截图相同的排他占位策略复制到最终路径，绝不覆盖已有文件。
        let savedURL = try saveRecordingExclusively(
            from: outcome.temporaryURL,
            to: requestedSavePath,
            reservedPaths: reservedOutputPaths
        )

        return RecordingOutcomeOutput(
            savedPath: savedURL.path,
            format: outcome.format,
            durationSeconds: outcome.durationSeconds,
            pixelWidth: outcome.pixelWidth,
            pixelHeight: outcome.pixelHeight,
            frameRate: outcome.frameRate,
            fileSizeBytes: outcome.fileSizeBytes
        )
    }

    /// 内部本地录制结果（指向临时目录中的产物，调用方负责清理或搬运）。
    struct LocalRecordingArtifact: Sendable {
        let temporaryURL: URL
        let format: String
        let durationSeconds: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let frameRate: Double
        let fileSizeBytes: Int64
    }

    /// 使用 `SCStreamRecorder` 在私有临时目录中完成录制。
    static func recordLocallyToTemporaryFile(
        _ parameters: RecordingParameters,
        authorizedByDaemon: Bool = false
    ) async throws -> LocalRecordingArtifact {
        if !authorizedByDaemon {
            try AutomationSecurityGate.authorize(providedToken: AutomationSecurityGate.currentEnvironmentToken())
        }
        let target = try parameters.validate()
        // 防线 4：禁止对受保护的密码管理器与系统隐私应用发起后台单窗录屏。
        if case .window(let windowID) = target.scope {
            try AutomationSecurityGate.validateWindowIDAllowed(windowID)
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw AutomationError.permissionDenied
        }

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("anshot-rec-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let tempFileURL = tempDir.appendingPathComponent("recording.\(parameters.format.fileExtension)")

        let output: RecordingOutput
        switch parameters.format {
        case .gif:
            let gifSettings = GIFSettings(
                frameRate: parameters.resolvedFPS,
                maximumDuration: parameters.durationSeconds,
                maximumPixelDimension: parameters.resolvedMaxDimension,
                loopCount: GIFSettings.defaultLoopCount
            )
            output = .gif(tempFileURL, settings: gifSettings)
        case .mp4:
            output = .movie(tempFileURL, container: .mp4)
        }

        let videoSettings = VideoSettings(
            frameRate: parameters.resolvedFPS,
            codec: .h264,
            showsCursor: true
        )
        let configuration = RecordingConfiguration(
            scope: target.scope,
            video: videoSettings,
            audio: AudioSettings(),
            output: output
        )

        let recorder = SCStreamRecorder()
        let duration = parameters.durationSeconds

        // 到期自动触发 stop()（stop 幂等，即使 GIF 已自动停流也安全无副作用）。
        let stopTask = Task {
            try await Task.sleep(nanoseconds: UInt64((duration * 1_000_000_000).rounded()))
            await recorder.stop()
        }

        do {
            let result = try await withTaskCancellationHandler {
                try await recorder.record(configuration: configuration)
            } onCancel: {
                stopTask.cancel()
                Task { await recorder.stop() }
            }
            stopTask.cancel()

            return LocalRecordingArtifact(
                temporaryURL: result.url,
                format: parameters.format.rawValue,
                durationSeconds: result.duration,
                pixelWidth: Int(result.pixelSize.width),
                pixelHeight: Int(result.pixelSize.height),
                frameRate: result.frameRate,
                fileSizeBytes: result.fileSize
            )
        } catch let error as RecordingError {
            stopTask.cancel()
            try? fileManager.removeItem(at: tempDir)
            if case .permissionDenied = error {
                throw AutomationError.permissionDenied
            }
            throw AutomationError.captureFailed("屏幕录制失败：\(error.localizedDescription)")
        } catch {
            stopTask.cancel()
            try? fileManager.removeItem(at: tempDir)
            throw AutomationError.captureFailed("屏幕录制失败：\(error.localizedDescription)")
        }
    }

    /// 以排他占位方式把录制产物落盘到目标路径（绝不覆盖已有文件与保留路径）。
    static func saveRecordingExclusively(
        from sourceURL: URL,
        to savePath: String,
        reservedPaths: Set<String> = []
    ) throws -> URL {
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        } catch {
            throw AutomationError.outputFailed("读取录制产物失败：\(error.localizedDescription)")
        }
        return try CaptureService.save(data, to: savePath, reservedPaths: reservedPaths)
    }

    static func defaultOutputPath(format: RecordingOutputFormat, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/\(CommandLineInterface.defaultOutputDirectoryName)/anshot-record-\(formatter.string(from: now)).\(format.fileExtension)"
    }
}
