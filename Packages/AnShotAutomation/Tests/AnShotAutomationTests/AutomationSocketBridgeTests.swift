//
//  AutomationSocketBridgeTests.swift
//  AnShotAutomationTests
//
//  常驻 Unix Domain Socket 自动化代理、免解码透传与静默落盘参数的单元测试。
//

import CoreGraphics
import Darwin
import Foundation
import MCP
import Testing

@testable import AnShotAutomation

@Suite("常驻 Unix Socket 无感代理与静默落盘")
struct AutomationSocketBridgeTests {

    @Test("Socket 服务端与客户端端到端透传 JSON 与 2MB 二进制图像，且严格 0600 权限并在 stop 后自动清理")
    func socketRoundTripLargeBinaryAndCleanup() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-sock-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let socketPath = tempDir.appendingPathComponent("auto.sock").path
        let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 & 0xFF) })

        let server = AutomationDaemonServer(socketPath: socketPath) { request in
            switch request.action {
            case .capture:
                let outcome = CaptureOutcome(
                    pixelSize: CGSize(width: 1470, height: 956),
                    imageData: payload,
                    imageFormat: .png,
                    displayID: 1,
                    scaleFactor: 2,
                    region: nil,
                    spaceID: nil,
                    window: nil,
                    savedURL: nil,
                    sourcePixelSize: CGSize(width: 2940, height: 1912)
                )
                return (CommandReport(ok: true, capture: CaptureOutput(outcome: outcome)), payload)
            case .listWindows:
                return (CommandReport(ok: true, windows: []), nil)
            default:
                return (CommandReport.failure("unsupported"), nil)
            }
        }

        #expect(server.start(), "常驻 Socket 服务端应成功监听")

        // 权限核验：Socket 文件必须收紧为 0600（仅当前用户可连接）
        var st = stat()
        #expect(lstat(socketPath, &st) == 0)
        #expect((st.st_mode & 0o777) == 0o600)

        // 1. 大二进制图像往返校验（2MB）
        let (captureReport, binaryData) = try await AutomationDaemonClient.send(
            action: .capture(CaptureParameters()),
            timeout: 10,
            socketPath: socketPath
        )
        #expect(captureReport.ok)
        #expect(captureReport.capture?.pixelWidth == 1470)
        #expect(captureReport.capture?.pixelHeight == 956)
        #expect(binaryData == payload, "2MB 图像二进制经 Socket 透传后必须逐字节一致")

        // 2. 纯 JSON 动作往返校验（无二进制载荷）
        let (windowsReport, emptyBinary) = try await AutomationDaemonClient.send(
            action: .listWindows,
            timeout: 10,
            socketPath: socketPath
        )
        #expect(windowsReport.ok)
        #expect(windowsReport.windows == [])
        #expect(emptyBinary == nil)

        // 3. stop 后自动清理 socket 文件，后续连接立即返回 .unavailable 供无缝降级
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath), "stop() 必须清理自己绑定的 socket 文件")

        do {
            _ = try await AutomationDaemonClient.send(
                action: .listWindows,
                timeout: 5,
                socketPath: socketPath
            )
            Issue.record("服务端停止后连接应抛出 unavailable")
        } catch DaemonClientTransportError.unavailable {
            // 符合预期：客户端据此自动降级到 open -n 兜底路径
        }
    }

    @Test("CaptureOutcome 免解码构造器不持有 CGImage 仍可精确提供 pixelSize 与 CaptureOutput")
    func zeroDecodeCaptureOutcomePreservesMetadata() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let outcome = CaptureOutcome(
            pixelSize: CGSize(width: 1568, height: 1020),
            imageData: bytes,
            imageFormat: .jpeg,
            jpegQuality: 82,
            didAutoFallbackToJPEG: true,
            originalPNGByteCount: 4_000_000,
            displayID: 1,
            scaleFactor: 2.0,
            region: nil,
            spaceID: nil,
            window: nil,
            savedURL: nil,
            sourcePixelSize: CGSize(width: 2940, height: 1912)
        )
        #expect(outcome.image == nil)
        #expect(outcome.pixelSize == CGSize(width: 1568, height: 1020))

        let output = CaptureOutput(outcome: outcome)
        #expect(output.pixelWidth == 1568)
        #expect(output.pixelHeight == 1020)
        #expect(output.imageFormat == "jpeg")
        #expect(output.didAutoFallbackToJPEG == true)
    }

    @Test("MCP capture_screenshot 的 include_image 参数解析：默认 true，设为 false 时强制要求 save_path")
    func parseIncludeImageParameter() throws {
        // 默认 include_image 为 true
        let defaultParsed = try AnShotMCP.parseCaptureRequest(arguments: [:])
        #expect(defaultParsed.includeImage == true)

        // include_image: false + save_path 合法
        let silentParsed = try AnShotMCP.parseCaptureRequest(arguments: [
            "include_image": .bool(false),
            "save_path": .string("/tmp/silent-shot.png")
        ])
        #expect(silentParsed.includeImage == false)
        #expect(silentParsed.parameters.savePath == "/tmp/silent-shot.png")

        // include_image: false 但未给 save_path 必须拒绝
        #expect(throws: AutomationError.self) {
            _ = try AnShotMCP.parseCaptureRequest(arguments: [
                "include_image": .bool(false)
            ])
        }
    }
}
