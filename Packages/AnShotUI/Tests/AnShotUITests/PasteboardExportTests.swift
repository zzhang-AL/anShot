//
//  PasteboardExportTests.swift
//  AnShotUITests
//
//  剪贴板写入：PNG 立即可读，TIFF 按需生成但同样可读、且尺寸一致。
//
//  用私有命名剪贴板：测试不能把用户系统剪贴板里的内容冲掉。
//

import AppKit
import ImageIO
import Testing

@testable import AnShotUI

@Suite("剪贴板导出")
@MainActor
struct PasteboardExportTests {

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test("PNG 与按需生成的 TIFF 都能读回，尺寸与原图一致")
    func pngAndLazyTIFFRoundTrip() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("anshot-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let image = try makeImage(width: 37, height: 21)

        #expect(SessionExporter.copyToPasteboard(image, to: pasteboard))

        #expect(pasteboard.types?.contains(.png) == true)
        #expect(pasteboard.types?.contains(.tiff) == true)

        let png = try #require(pasteboard.data(forType: .png))
        let pngImage = try #require(
            CGImageSourceCreateWithData(png as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        )
        #expect(pngImage.width == 37 && pngImage.height == 21)

        let tiff = try #require(pasteboard.data(forType: .tiff))
        let tiffRep = try #require(NSBitmapImageRep(data: tiff))
        #expect(tiffRep.pixelsWide == 37 && tiffRep.pixelsHigh == 21)
    }

    @Test("一次编码同时供剪贴板与历史缓存：返回的数据就是剪贴板里的 PNG")
    func encodedPNGIsSharedWithCaller() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("anshot-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let image = try makeImage(width: 37, height: 21)

        let result = try #require(
            SessionExporter.copyToPasteboardWithPNG(image, to: pasteboard)
        )
        #expect(result.didCopy)
        #expect(!result.pngData.isEmpty)
        // 历史缓存直接复用这份 Data，不能再编码一次；这里钉住「同一份字节」。
        #expect(pasteboard.data(forType: .png) == result.pngData)
    }
}
