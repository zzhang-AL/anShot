//
//  HistoryThumbnailTests.swift
//  AnShotUITests
//
//  历史记录缩略图的尺寸边界。
//
//  ── 为什么值得单测 ────────────────────────────────────────
//
//  旧实现只按宽度收敛，长截图（2940×32768）会生成约 360×4013 的缩略图，
//  每张数 MB，而列表行只有 96×64 的框。这类「尺寸按比例跑飞」的问题在
//  代码里读不出来：`min(1, maxWidth / width)` 看着完全合理，只有拿一张
//  极端长图跑一遍才会暴露。这里把输出固定为 192×128 的像素尺寸锁住。
//

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import AnShotUI

@Suite("历史记录 · 缩略图")
struct HistoryThumbnailTests {

    /// 造一张长截图：300×2000（1:6.67），上下两段不同颜色。
    private func makeTallImage(width: Int = 300, height: Int = 2000) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        return context.makeImage()
    }

    @Test("长截图缩略图固定为 192×128，不随原图比例变高")
    func tallImageIsCroppedToBoundedSize() throws {
        let image = try #require(makeTallImage())
        let data = try #require(HistoryThumbnail.makePNG(from: image))

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let thumbnail = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        // 默认 96×64 逻辑点 @2x：宽高都不该超过目标框。
        #expect(thumbnail.width == 192)
        #expect(thumbnail.height == 128)
    }

    @Test("空尺寸输入返回 nil，不生成 0 像素图")
    func zeroSizedOutputFails() throws {
        let image = try #require(makeTallImage())
        #expect(HistoryThumbnail.makePNG(from: image, maxWidth: 0) == nil)
        #expect(HistoryThumbnail.makePNG(from: image, maxHeight: 0) == nil)
    }
}
