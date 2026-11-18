//
//  AutomationOCRService.swift
//  AnShotAutomation
//
//  离线文字识别（OCR）自动化服务：支持截取屏幕/窗口/区域或读取本地图像文件，
//  调用 AnShotCapture.TextRecognizer 返回全文与逐行精确像素包围盒。
//

import AnShotCapture
import AnShotCore
import CoreGraphics
import Foundation
import ImageIO

/// OCR 请求参数。
public struct OCRParameters: Codable, Sendable, Equatable {

    /// 本地图像文件路径（与截屏定位参数互斥）。
    public var imagePath: String?

    /// 目标显示器 ID；`nil` 表示主显示器。
    public var displayID: CGDirectDisplayID?

    /// 目标桌面 ID；`nil` 表示当前桌面。
    public var spaceID: UInt64?

    /// 是否允许为了识别其他桌面而短暂切换并恢复。
    public var allowDesktopSwitch: Bool

    /// 显示器内逻辑点区域 `[x, y, width, height]`。
    public var region: CGRect?

    /// 目标窗口 ID。
    public var windowID: CGWindowID?

    /// 目标应用名。
    public var applicationName: String?

    /// 偏好识别语言代码（如 `["zh-Hans", "en-US"]`）；`nil` 使用系统默认偏好集。
    public var languages: [String]?

    public init(
        imagePath: String? = nil,
        displayID: CGDirectDisplayID? = nil,
        spaceID: UInt64? = nil,
        allowDesktopSwitch: Bool = false,
        region: CGRect? = nil,
        windowID: CGWindowID? = nil,
        applicationName: String? = nil,
        languages: [String]? = nil
    ) {
        self.imagePath = imagePath
        self.displayID = displayID
        self.spaceID = spaceID
        self.allowDesktopSwitch = allowDesktopSwitch
        self.region = region
        self.windowID = windowID
        self.applicationName = applicationName
        self.languages = languages
    }

    /// 校验参数组合与数值合法性。
    public func validate() throws {
        if let languages {
            let trimmed = languages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if trimmed.contains(where: \.isEmpty) {
                throw AutomationError.invalidArgument("languages 不能包含空字符串。")
            }
        }

        if let imagePath {
            let cleaned = imagePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                throw AutomationError.invalidArgument("image_path 不能为空字符串。")
            }
            if displayID != nil || spaceID != nil || allowDesktopSwitch || region != nil
                || windowID != nil || applicationName != nil {
                throw AutomationError.invalidArgument(
                    "image_path 与截屏目标参数（display_id / space_id / allow_switch / region / window_id / app）不能同时使用。"
                )
            }
            return
        }

        // 复用 CaptureParameters 统一校验屏幕/窗口/区域寻址规则。
        _ = try asCaptureParameters().resolveTarget()
    }

    /// 转换为等效的原始分辨率截图参数（OCR 强制不缩放以保障小字识别精度）。
    func asCaptureParameters() -> CaptureParameters {
        CaptureParameters(
            displayID: displayID,
            spaceID: spaceID,
            allowDesktopSwitch: allowDesktopSwitch,
            region: region,
            windowID: windowID,
            applicationName: applicationName,
            maxLongEdge: 0
        )
    }
}

/// OCR 识别单行结构化输出。
public struct OCRLineOutput: Codable, Sendable, Equatable {
    public let text: String
    public let confidence: Double
    public let boundingBox: RectOutput
    public let candidates: [String]

    public struct RectOutput: Codable, Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }
}

/// OCR 识别结构化响应。
public struct OCRResponseOutput: Codable, Sendable, Equatable {
    public let fullText: String
    public let imagePixelWidth: Int
    public let imagePixelHeight: Int
    public let coordinateSystem: String
    public let lines: [OCRLineOutput]
}

/// 自动化离线 OCR 执行入口。
public enum AutomationOCRService {

    /// 执行离线文字识别。
    public static func recognize(
        _ parameters: OCRParameters,
        execution: CaptureExecution = .reuseApplicationAuthorization
    ) async throws -> OCRResponseOutput {
        try parameters.validate()

        // 1. 本地图像路径：直接在本进程读取文件并运行 Vision OCR（无需屏幕录制权限）。
        if let imagePath = parameters.imagePath {
            let image = try loadImage(at: imagePath)
            return try await runVisionOCR(on: image, languages: parameters.languages)
        }

        // 2. 屏幕捕获路径：优先跨进程复用 anShot.app 已有的屏幕录制权限。
        let timeout = parameters.spaceID == nil ? OutOfProcessCapture.defaultTimeout : 60
        if execution == .reuseApplicationAuthorization,
           let appURL = OutOfProcessCapture.currentAppURL {
            return try await OutOfProcessCapture.ocr(
                parameters: parameters,
                appURL: appURL,
                timeout: timeout
            )
        }

        // 3. 就地执行（--direct 或子实例或单测）。
        let captureParameters = parameters.asCaptureParameters()
        let raw = try await CaptureService.captureRawFrame(captureParameters, lockTimeout: timeout)
        return try await runVisionOCR(on: raw.frame.image, languages: parameters.languages)
    }

    /// 运行本地 Vision 文字识别并映射为结构化结果。
    private static func runVisionOCR(
        on image: CGImage,
        languages: [String]?
    ) async throws -> OCRResponseOutput {
        let result: OCRResult
        do {
            let cleanedLanguages = languages?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            result = try await TextRecognizer.recognize(in: image, languages: cleanedLanguages)
        } catch {
            throw AutomationError.captureFailed("离线文字识别失败：\(error.localizedDescription)")
        }

        let lines = result.lines.map { line in
            OCRLineOutput(
                text: line.text,
                confidence: line.confidence,
                boundingBox: OCRLineOutput.RectOutput(
                    x: line.boundingBox.origin.x,
                    y: line.boundingBox.origin.y,
                    width: line.boundingBox.size.width,
                    height: line.boundingBox.size.height
                ),
                candidates: line.candidates
            )
        }

        return OCRResponseOutput(
            fullText: result.plainText,
            imagePixelWidth: Int(result.imagePixelSize.width),
            imagePixelHeight: Int(result.imagePixelSize.height),
            coordinateSystem: "image_pixels_top_left",
            lines: lines
        )
    }

    /// 从本地磁盘读取并解码图像。
    private static func loadImage(at rawPath: String) throws -> CGImage {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AutomationError.invalidArgument("找不到图像文件：\(url.path)")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AutomationError.invalidArgument("无法解码图像文件（不支持的格式或文件已损坏）：\(url.path)")
        }
        return image
    }
}
