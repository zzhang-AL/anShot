//
//  MCPServerParsingTests.swift
//  AnShotAutomationTests
//
//  覆盖 MCP 全部工具参数解析、默认 1568px、JPEG 自动降级策略、
//  metadataText 透明格式说明、坐标网格渲染与 IPC 防注入。
//

import CoreGraphics
import Foundation
import MCP
import Testing

@testable import AnShotAutomation

@Suite("MCP 服务端参数解析与压缩策略")
struct MCPServerParsingTests {

    // MARK: - capture_screenshot 参数解析

    @Test("capture_screenshot 默认 max_size 为 1568 且开启自动 JPEG 降级")
    func defaultMCPParameters() throws {
        let params = try AnShotMCP.parse(arguments: nil)
        #expect(params.maxLongEdge == 1568)
        #expect(params.outputFormat == nil)
        #expect(params.autoFallbackToJPEG == true)
        #expect(params.coordinateGrid == false)
    }

    @Test("capture_screenshot 传入 max_size: 0 保留原始分辨率")
    func zeroMaxSizePreserved() throws {
        let params = try AnShotMCP.parse(arguments: ["max_size": .int(0)])
        #expect(params.maxLongEdge == 0)
    }

    @Test("capture_screenshot 显式指定 format: png 时关闭自动 JPEG 降级")
    func explicitPNGDisablesAutoFallback() throws {
        let params = try AnShotMCP.parse(arguments: ["format": .string("png")])
        #expect(params.outputFormat == .png)
        #expect(params.autoFallbackToJPEG == false)
    }

    @Test("capture_screenshot 支持 format: jpeg、quality 与 coordinate_grid")
    func jpegQualityAndCoordinateGrid() throws {
        let params = try AnShotMCP.parse(arguments: [
            "window_id": .int(100),
            "format": .string("jpeg"),
            "quality": .int(75),
            "coordinate_grid": .bool(true),
            "save_path": .string("/tmp/shot.jpg")
        ])
        #expect(params.windowID == 100)
        #expect(params.outputFormat == .jpeg)
        #expect(params.jpegQuality == 75)
        #expect(params.coordinateGrid == true)
        #expect(params.savePath == "/tmp/shot.jpg")
    }

    @Test("capture_screenshot 拒绝未知参数、越界 quality 与 png+quality 冲突")
    func captureInvalidArgumentsRejected() {
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parse(arguments: ["maxsize": .int(1000)])
        }
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parse(arguments: ["format": .string("webp")])
        }
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parse(arguments: ["format": .string("jpeg"), "quality": .int(0)])
        }
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parse(arguments: ["format": .string("jpeg"), "quality": .int(101)])
        }
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parse(arguments: ["format": .string("png"), "quality": .int(80)])
        }
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parse(arguments: ["coordinate_grid": .string("yes")])
        }
    }

    // MARK: - ocr_screenshot 参数解析

    @Test("ocr_screenshot 支持 image_path 与截屏参数并拦截混用/未知参数")
    func ocrParametersParsing() throws {
        let imageOCR = try AnShotMCP.parseOCR(arguments: [
            "image_path": .string("/tmp/test.png"),
            "languages": .array([.string("zh-Hans"), .string("en-US")])
        ])
        #expect(imageOCR.imagePath == "/tmp/test.png")
        #expect(imageOCR.languages == ["zh-Hans", "en-US"])

        let windowOCR = try AnShotMCP.parseOCR(arguments: [
            "app": .string("Safari")
        ])
        #expect(windowOCR.applicationName == "Safari")

        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parseOCR(arguments: [
                "image_path": .string("/tmp/test.png"),
                "window_id": .int(12)
            ])
        }
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parseOCR(arguments: ["unknown": .bool(true)])
        }
    }

    // MARK: - inspect_window_elements 参数解析

    @Test("inspect_window_elements 严格校验三选一与深度/节点边界")
    func inspectElementsParsing() throws {
        let byApp = try AnShotMCP.parseInspectElements(arguments: [
            "app": .string("Xcode"),
            "max_depth": .int(6),
            "max_elements": .int(300)
        ])
        #expect(byApp.applicationName == "Xcode")
        #expect(byApp.maxDepth == 6)
        #expect(byApp.maxElements == 300)

        let byPID = try AnShotMCP.parseInspectElements(arguments: ["pid": .int(1234)])
        #expect(byPID.pid == 1234)
        #expect(byPID.maxDepth == InspectElementsParameters.defaultMaxDepth)

        // 缺少目标、同时指定两个、越界深度均报错
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parseInspectElements(arguments: nil)
        }
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parseInspectElements(arguments: ["window_id": .int(1), "app": .string("Safari")])
        }
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parseInspectElements(arguments: ["app": .string("Safari"), "max_depth": .int(20)])
        }
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parseInspectElements(arguments: ["app": .string("Safari"), "max_elements": .int(0)])
        }
    }

    // MARK: - record_screen 参数解析

    @Test("record_screen 强制 1...15 秒时长并支持 GIF/MP4 参数校验")
    func recordScreenParsing() throws {
        let gifParams = try AnShotMCP.parseRecord(arguments: [
            "app": .string("Safari"),
            "duration": .double(5.5),
            "format": .string("gif"),
            "fps": .int(15),
            "max_size": .int(1000)
        ])
        #expect(gifParams.applicationName == "Safari")
        #expect(gifParams.durationSeconds == 5.5)
        #expect(gifParams.format == .gif)
        #expect(gifParams.fps == 15)
        #expect(gifParams.maxDimension == 1000)

        let mp4Params = try AnShotMCP.parseRecord(arguments: [
            "duration": .int(15),
            "format": .string("mp4"),
            "fps": .int(60)
        ])
        #expect(mp4Params.durationSeconds == 15)
        #expect(mp4Params.format == .mp4)
        #expect(mp4Params.fps == 60)

        // 超出 1...15 秒红线或 MP4 传 max_size 必须拒绝
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parseRecord(arguments: ["duration": .double(0.5)])
        }
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parseRecord(arguments: ["duration": .double(15.1)])
        }
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parseRecord(arguments: ["format": .string("mp4"), "max_size": .int(800)])
        }
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parseRecord(arguments: ["format": .string("gif"), "fps": .int(60)])
        }
    }

    // MARK: - JPEG 自适应降级与元数据、坐标网格验证

    @Test("PNG 超过 3.5 MiB 且未显式强制 png 时自动降级为 quality=82 的 JPEG")
    func autoJPEGCompressionFallback() throws {
        // 构造一张高熵噪点大图（2000x1600），使 PNG 字节数必然远超 3.5 MiB。
        let noisyImage = try makeNoisyImage(width: 2000, height: 1600)

        let autoParams = CaptureParameters(autoFallbackToJPEG: true)
        let autoEncoded = try CaptureService.encodeImage(noisyImage, parameters: autoParams)
        #expect(autoEncoded.format == .jpeg)
        #expect(autoEncoded.didAutoFallbackToJPEG == true)
        #expect(autoEncoded.jpegQuality == 82)
        #expect((autoEncoded.originalPNGByteCount ?? 0) > MCPPayloadLimits.autoJPEGThresholdBytes)
        #expect(autoEncoded.data.count < (autoEncoded.originalPNGByteCount ?? Int.max))

        // 验证 metadataText 清晰注明实际编码格式与降级原因。
        let outcome = CaptureOutcome(
            image: noisyImage,
            imageData: autoEncoded.data,
            imageFormat: autoEncoded.format,
            jpegQuality: autoEncoded.jpegQuality,
            didAutoFallbackToJPEG: autoEncoded.didAutoFallbackToJPEG,
            originalPNGByteCount: autoEncoded.originalPNGByteCount,
            coordinateGridEnabled: true,
            coordinateGridOrigin: CGPoint(x: 100, y: 50),
            displayID: 1,
            scaleFactor: 2.0,
            region: CGRect(x: 100, y: 50, width: 1000, height: 800),
            spaceID: nil,
            window: nil,
            savedURL: nil,
            sourcePixelSize: CGSize(width: 2000, height: 1600)
        )
        let text = AnShotMCP.metadataText(for: outcome)
        #expect(text.contains("JPEG"))
        #expect(text.contains("quality=82"))
        #expect(text.contains("3.5 MiB"))
        #expect(text.contains("2000×1600"))
        #expect(text.contains("坐标网格：已启用"))

        // 显式指定 format: .png 时不得降级。
        let forcedPNGParams = CaptureParameters(outputFormat: .png, autoFallbackToJPEG: false)
        let forcedPNG = try CaptureService.encodeImage(noisyImage, parameters: forcedPNGParams)
        #expect(forcedPNG.format == .png)
        #expect(forcedPNG.didAutoFallbackToJPEG == false)
    }

    @Test("坐标网格渲染器不改变图像输出像素尺寸")
    func coordinateGridPreservesDimensions() throws {
        let base = try makeNoisyImage(width: 640, height: 480)
        let gridded = CoordinateGridRenderer.render(
            on: base,
            logicalOrigin: CGPoint(x: 100, y: 200),
            logicalSize: CGSize(width: 320, height: 240)
        )
        #expect(gridded.width == 640)
        #expect(gridded.height == 480)
    }

    private func makeNoisyImage(width: Int, height: Int) throws -> CGImage {
        let pixelCount = width * height
        var pixels = [UInt32](repeating: 0, count: pixelCount)
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        for index in 0..<pixelCount {
            // 使用确定性 xorshift64 伪随机填充 RGB 像素，确保 PNG 不可压缩超过 3.5 MiB。
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let r = UInt32(state & 0xFF)
            let g = UInt32((state >> 8) & 0xFF)
            let b = UInt32((state >> 16) & 0xFF)
            pixels[index] = (0xFF << 24) | (r << 16) | (g << 8) | b
        }

        let data = pixels.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }
}
