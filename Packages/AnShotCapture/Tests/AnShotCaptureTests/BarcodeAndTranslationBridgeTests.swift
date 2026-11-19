//
//  BarcodeAndTranslationBridgeTests.swift
//  AnShotCaptureTests
//
//  Phase 3 捕获层专项测试：真图二维码同步识别、语言偏好透传与 macOS 15 翻译桥接注册表。
//

import AnShotCore
import CoreGraphics
import CoreImage
import Testing

@testable import AnShotCapture

@Suite("Phase 3 · 二维码识别与本机翻译桥接")
struct BarcodeAndTranslationBridgeTests {

    /// 用系统 CoreImage 动态生成一张高对比真实 QR 二维码图像（无外部素材依赖）。
    private func makeQRCodeImage(payload: String, size: Int = 320) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator"),
              let data = payload.data(using: .utf8) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scaleX = CGFloat(size - 40) / max(1, output.extent.width)
        let scaleY = CGFloat(size - 40) / max(1, output.extent.height)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        guard let qrCG = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: size,
                  height: size,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.interpolationQuality = .none
        ctx.draw(qrCG, in: CGRect(x: 20, y: 20, width: size - 40, height: size - 40))
        return ctx.makeImage()
    }

    @Test("真实二维码图像经 TextRecognizer 同步扫出 URL 载荷")
    func detectsRealQRCodePayload() async throws {
        let targetURL = "https://github.com/zzhang-AL/anShot"
        let qrImage = try #require(makeQRCodeImage(payload: targetURL))

        let result = try await TextRecognizer.recognize(
            in: qrImage,
            languagePreference: .auto,
            detectBarcodes: true
        )
        #expect(result.hasContent)
        #expect(result.barcodes.contains(where: { $0.payload == targetURL && $0.isWebURL }))
    }

    @Test("关闭二维码检测开关时不输出条码列表")
    func respectsDisabledBarcodeDetectionFlag() async throws {
        let qrImage = try #require(makeQRCodeImage(payload: "https://example.com"))
        let result = try await TextRecognizer.recognize(
            in: qrImage,
            languagePreference: .auto,
            detectBarcodes: false
        )
        #expect(result.barcodes.isEmpty)
    }

    @Test("AppleTranslationProvider 在 macOS 15+ 优先委托已注册的桥接执行器")
    func appleTranslationProviderDelegatesToRegisteredBridge() async {
        struct StubBridge: AppleTranslationBridgeExecutor {
            func translate(
                _ lines: [OCRTextLine],
                from source: String?,
                to target: String
            ) async -> TranslationExecutionResult {
                let translated = lines.map { "[\(target)] \($0.text)" }
                let aligned = TranslationAligner.align(
                    lines: lines,
                    translations: translated,
                    sourceLanguage: source ?? "en",
                    targetLanguage: target
                )
                return TranslationExecutionResult(result: aligned, errorMessage: nil)
            }
        }

        let previous = AppleTranslationBridgeRegistry.executor
        defer { AppleTranslationBridgeRegistry.register(previous) }

        AppleTranslationBridgeRegistry.register(StubBridge())
        let line = OCRTextLine(text: "Hello anShot", candidates: ["Hello anShot"], confidence: 1, boundingBox: .zero)
        let execution = await AppleTranslationProvider().translateWithDiagnostics(
            [line],
            from: "en",
            to: "zh-Hans"
        )

        if #available(macOS 15.0, *) {
            #expect(execution.errorMessage == nil)
            #expect(execution.result.segments.count == 1)
            #expect(execution.result.segments[0].translatedText == "[zh-Hans] Hello anShot")
        } else {
            #expect(execution.errorMessage != nil)
        }
    }
}
