//
//  Phase5ExportPipelineTests.swift
//  AnShotCaptureTests
//
//  Phase 5.1 专项单测：
//    - 纯 Swift 无损 WebP（VP8L + VP8X + EXIF DPI）经 macOS ImageIO 逐像素无损往返校验与 144 DPI 验证；
//    - ImageEncoding 支持 PNG / JPEG / HEIC / WebP 多格式导出与超 16384px 自动降级；
//    - MIT `oxipng` 无损压缩管线：两阶段原子替换、`pHYs` 完好性保护、篡改拦截与缺二进制静默降级。
//

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import AnShotCapture

@Suite("Phase 5.1 · 无损 WebP 编码与 MIT oxipng 压缩管线")
struct Phase5ExportPipelineTests {

    private func makeRGBAImage(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> (CGImage, [UInt8]) {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let offset = (y * width + x) * 4
                // CGContext premultipliedLast 需要预乘输入
                let alpha = Int(a)
                bytes[offset] = UInt8((Int(r) * alpha + 127) / 255)
                bytes[offset + 1] = UInt8((Int(g) * alpha + 127) / 255)
                bytes[offset + 2] = UInt8((Int(b) * alpha + 127) / 255)
                bytes[offset + 3] = a
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = bytes.withUnsafeMutableBytes { raw -> CGImage in
            let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return ctx.makeImage()!
        }
        return (image, bytes)
    }

    private func extractPremultipliedRGBA(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        out.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return out
    }

    @Test("纯 Swift 无损 WebP 对纯色、渐变、随机纹理及透明通道经系统 ImageIO 逐像素无损还原且保留 144 DPI")
    func losslessWebPRoundTripsThroughSystemImageIOWithRetinaDPI() throws {
        // 1. 复杂渐变 + 纯色区块 + 透明像素混合图（同时压测 Simple/Normal Huffman 与 LZ77）
        let width = 73
        let height = 59
        let (sourceImage, sourcePremul) = makeRGBAImage(width: width, height: height) { x, y in
            if x < 20 && y < 20 {
                // 纯色块（触发水平/垂直 LZ77 拷贝）
                return (34, 128, 240, 255)
            }
            if x >= 50 && y >= 40 {
                // 全透明与半透明像素
                return (x % 2 == 0) ? (0, 0, 0, 0) : (200, 80, 40, 128)
            }
            // 伪随机丰富色彩（触发完整 256 符号 Normal Canonical Huffman）
            let r = UInt8((x &* 37 &+ y &* 17) & 0xFF)
            let g = UInt8((x &* 13 ^ y &* 53) & 0xFF)
            let b = UInt8((x &* 71 &+ y &* 29) & 0xFF)
            return (r, g, b, 255)
        }

        let webpData = try ImageEncoding.data(from: sourceImage, format: .webpLossless, backingScale: 2.0)
        // 验证 RIFF/WEBP 头与 VP8X + VP8L + EXIF 结构
        #expect(String(decoding: webpData.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: webpData[8..<12], as: UTF8.self) == "WEBP")
        #expect(String(decoding: webpData[12..<16], as: UTF8.self) == "VP8X")

        let source = try #require(CGImageSourceCreateWithData(webpData as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == width)
        #expect(decoded.height == height)

        // 校验 EXIF 写入的 Retina 144 DPI
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let dpiW = props[kCGImagePropertyDPIWidth] as? Double ?? 0
        let dpiH = props[kCGImagePropertyDPIHeight] as? Double ?? 0
        #expect(abs(dpiW - 144.0) < 0.5, "WebP DPIWidth 应为 144，实际 \(dpiW)")
        #expect(abs(dpiH - 144.0) < 0.5, "WebP DPIHeight 应为 144，实际 \(dpiH)")

        // 逐像素校验无损一致性（非半透明像素 0 误差，半透明因预乘/反预乘整数取整允许 ≤1）
        let decodedPremul = extractPremultipliedRGBA(decoded)
        #expect(decodedPremul.count == sourcePremul.count)
        for i in stride(from: 0, to: sourcePremul.count, by: 4) {
            let srcA = sourcePremul[i + 3]
            let dstA = decodedPremul[i + 3]
            #expect(srcA == dstA)
            let tol = (srcA == 255 || srcA == 0) ? 0 : 1
            #expect(abs(Int(sourcePremul[i]) - Int(decodedPremul[i])) <= tol)
            #expect(abs(Int(sourcePremul[i + 1]) - Int(decodedPremul[i + 1])) <= tol)
            #expect(abs(Int(sourcePremul[i + 2]) - Int(decodedPremul[i + 2])) <= tol)
        }
    }

    @Test("纯色极简图（1x1 与单色块）WebP 无损编码体积小且可无损解码")
    func losslessWebPHandlesSolidAndTinyImages() throws {
        let (solid, _) = makeRGBAImage(width: 120, height: 80) { _, _ in (250, 250, 250, 255) }
        let data = try WebPEncoder.encodeLossless(solid, backingScale: 1.0)
        // 纯色 120×80（原始 38400 字节）经 VP8L 压缩后应远小于 1KB
        #expect(data.count < 512, "纯色图 VP8L 体积应极小，实际 \(data.count) bytes")
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(img.width == 120 && img.height == 80)

        let (tiny, _) = makeRGBAImage(width: 1, height: 1) { _, _ in (12, 34, 56, 255) }
        let tinyData = try WebPEncoder.encodeLossless(tiny, backingScale: 2.0)
        let tinySrc = try #require(CGImageSourceCreateWithData(tinyData as CFData, nil))
        let tinyImg = try #require(CGImageSourceCreateImageAtIndex(tinySrc, 0, nil))
        let rgba = extractPremultipliedRGBA(tinyImg)
        #expect(rgba == [12, 34, 56, 255])
    }

    @Test("PNGOptimizer 缺二进制静默跳过；精压成功且保留 pHYs 时原子替换；若 pHYs 丢失则拦截不破坏原文件")
    func pngOptimizerAtomicallyReplacesAndProtectsPHYS() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anshot-oxipng-test-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let (img, _) = makeRGBAImage(width: 64, height: 64) { x, y in
            (UInt8((x * 3) & 0xFF), UInt8((y * 3) & 0xFF), 180, 255)
        }
        let png2x = try ImageEncoding.data(from: img, format: .png, backingScale: 2.0)
        let physOriginal = try #require(PNGOptimizer.extractPNGChunkPayload(named: "pHYs", from: png2x))

        // 给原始文件尾部附加一个无害 tEXt 辅助 chunk 使其体积比真实精压输出更大
        var bloated = Data()
        bloated.append(png2x.prefix(png2x.count - 12)) // 去掉末尾 IEND (12B)
        // 构造一个 200 字节的 zTXt/tEXt 占位（用合法 PNG chunk 格式即可，只为测试体积对比）
        let textPayload = Data(repeating: 0x41, count: 200)
        var chunk = Data()
        var lenBE = UInt32(textPayload.count).bigEndian
        withUnsafeBytes(of: &lenBE) { chunk.append(contentsOf: $0) }
        chunk.append(contentsOf: Array("tEXt".utf8))
        chunk.append(textPayload)
        chunk.append(contentsOf: [0, 0, 0, 0]) // 模拟 CRC（本测试不校验 tEXt CRC）
        bloated.append(chunk)
        bloated.append(png2x.suffix(12)) // 补回 IEND

        let targetURL = dir.appendingPathComponent("shot.png")
        try bloated.write(to: targetURL)

        // 1. 缺二进制时静默降级
        let missingBin = dir.appendingPathComponent("nonexistent-oxipng")
        let skipped = PNGOptimizer.optimizeFileInPlace(at: targetURL, executableURL: missingBin)
        if case .skipped = skipped {
            #expect(try Data(contentsOf: targetURL) == bloated)
        } else {
            Issue.record("缺少二进制时应返回 skipped")
        }

        // 2. 模拟丢失 pHYs 的劣质压缩脚本 → 必须被拦截，原文件完好无损
        let png1xNoPHYS = try ImageEncoding.data(from: img, format: .png, backingScale: 1.0)
        let strippedURL = dir.appendingPathComponent("stripped.png")
        try png1xNoPHYS.write(to: strippedURL)
        let badScript = dir.appendingPathComponent("mock-oxipng-bad.sh")
        try "#!/bin/sh\nout=\"\"\nwhile [ $# -gt 0 ]; do if [ \"$1\" = \"--out\" ]; then out=\"$2\"; shift 2; else shift; fi; done\ncp \"\(strippedURL.path)\" \"$out\"\n"
            .write(to: badScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: badScript.path)

        let blocked = PNGOptimizer.optimizeFileInPlace(at: targetURL, executableURL: badScript)
        if case .skipped(let reason) = blocked {
            #expect(reason.contains("pHYs"))
            #expect(try Data(contentsOf: targetURL) == bloated)
        } else {
            Issue.record("篡改 pHYs 的精压产物必须被拦截")
        }

        // 3. 模拟合规 `oxipng --strip safe`（保留原 pHYs 且更小）→ 原子替换成功
        let cleanURL = dir.appendingPathComponent("clean.png")
        try png2x.write(to: cleanURL)
        let goodScript = dir.appendingPathComponent("mock-oxipng-good.sh")
        try "#!/bin/sh\nout=\"\"\nwhile [ $# -gt 0 ]; do if [ \"$1\" = \"--out\" ]; then out=\"$2\"; shift 2; else shift; fi; done\ncp \"\(cleanURL.path)\" \"$out\"\n"
            .write(to: goodScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: goodScript.path)

        let ok = PNGOptimizer.optimizeFileInPlace(at: targetURL, executableURL: goodScript)
        #expect(ok == .optimized(originalBytes: bloated.count, optimizedBytes: png2x.count))
        let finalData = try Data(contentsOf: targetURL)
        #expect(finalData == png2x)
        #expect(PNGOptimizer.extractPNGChunkPayload(named: "pHYs", from: finalData) == physOriginal)
    }
}
