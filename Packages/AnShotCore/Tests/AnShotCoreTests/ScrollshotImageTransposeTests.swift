//
//  ScrollshotImageTransposeTests.swift
//  AnShotCoreTests
//
//  图像转置：横向长截图的几何支点。
//
//  ── 为什么这一层值得单独测 ────────────────────────────────
//
//  横向滚动不重写配准/会话/拼接，而是把「横向问题」转置成「竖直问题」后复用
//  全部已验证算法。这意味着**转置是整条横向链路的唯一假设**：
//  它对，横向就等于竖直；它错，所有复用都建立在错误的坐标上，而且错得很安静
//  ——长图依旧拼得出来，只是内容被镜像/错行。
//
//  所以这里不测「能转置」，测三条它会悄悄破坏的不变式：
//  尺寸互换、两次转置还原、横向位移在转置后等于竖直位移。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotCore

@Suite("滚动截图图像 · 转置")
struct ScrollshotImageTransposeTests {

    @Test("尺寸互换：宽高对调，缓冲长度不变")
    func swapsDimensions() throws {
        let image = makeGradient(width: 120, height: 40)
        let transposed = try #require(image.transposed())

        #expect(transposed.width == 40, "宽应为原高，实际 \(transposed.width)")
        #expect(transposed.height == 120, "高应为原宽，实际 \(transposed.height)")
        #expect(transposed.data.count == image.data.count)
    }

    @Test("两次转置逐字节还原（对调用方透明）")
    func doubleTransposeIsIdentity() throws {
        let image = makeGradient(width: 64, height: 37)
        let roundTrip = try #require(image.transposed()?.transposed())

        #expect(roundTrip.width == image.width)
        #expect(roundTrip.height == image.height)
        #expect(roundTrip.data == image.data, "两次转置未回到原图")
    }

    @Test("像素搬到 (y, x)：不是翻转、不是旋转")
    func mapsPixelCoordinates() throws {
        let image = makeGradient(width: 8, height: 5)
        let transposed = try #require(image.transposed())

        // 抽查若干点：原图 (x, y) 必须出现在转置图的 (y, x)。
        for (x, y) in [(0, 0), (3, 2), (7, 4), (1, 4)] {
            let source = pixel(image, x: x, y: y)
            let moved = pixel(transposed, x: y, y: x)
            #expect(source == moved, "原图 (\(x),\(y)) 未落到转置图 (\(y),\(x))")
        }
    }

    @Test("横向位移在转置后等同于竖直位移（复用配准的前提）")
    func horizontalDeltaBecomesVertical() throws {
        // 一整页只有横向滚动的内容：宽度 1200、高度 300。
        let page = makeGradient(width: 1200, height: 300)
        let viewportWidth = 600
        let shift = 120

        // 两帧：第二帧相对第一帧向右滚动 120px（左侧内容被推出视口）。
        let first = sliceColumns(page, offset: 0, width: viewportWidth)
        let second = sliceColumns(page, offset: shift, width: viewportWidth)

        // 转置后就是一对「竖直位移 = 120」的帧，可以直接交给竖向内核。
        let previous = try #require(first.transposed())
        let next = try #require(second.transposed())

        let match = try VerticalOverlap.estimate(previous: previous, next: next)
        #expect(
            match.deltaY == shift,
            "转置后应解出竖直位移 \(shift)，实际 \(match.deltaY)"
        )
    }

    // MARK: - 夹具

    /// 造一张非周期纹理图：每个像素由坐标决定，避免配准被周期性骗到。
    private func makeGradient(width: Int, height: Int) -> ScrollshotImage {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                data[offset] = UInt8((x * 7 + y * 13) % 251)
                data[offset + 1] = UInt8((x * 31 + y * 5) % 253)
                data[offset + 2] = UInt8((x * 11 + y * 17) % 249)
                data[offset + 3] = 255
            }
        }
        return ScrollshotImage(width: width, height: height, data: data)!
    }

    private func pixel(_ image: ScrollshotImage, x: Int, y: Int) -> [UInt8] {
        let offset = (y * image.width + x) * 4
        return Array(image.data[offset..<(offset + 4)])
    }

    /// 从整页里按列切出一帧（横向滚动的取样方式）。
    private func sliceColumns(_ page: ScrollshotImage, offset: Int, width: Int) -> ScrollshotImage {
        var buffer = [UInt8](repeating: 0, count: width * page.height * 4)
        for y in 0..<page.height {
            for x in 0..<width {
                let sourceX = offset + x
                guard sourceX < page.width else { continue }
                let from = (y * page.width + sourceX) * 4
                let to = (y * width + x) * 4
                buffer[to] = page.data[from]
                buffer[to + 1] = page.data[from + 1]
                buffer[to + 2] = page.data[from + 2]
                buffer[to + 3] = page.data[from + 3]
            }
        }
        return ScrollshotImage(width: width, height: page.height, data: buffer)!
    }
}
