//
//  TestSupport.swift
//  AnShotCoreTests
//
//  像素级测试的共享工具。
//
//  放在共享文件而不是各测试文件里复制：这套「造图 → 读回像素 → 比对通道」
//  的辅助如果在多处各写一份，色彩空间或通道顺序一旦写得不一致，
//  测试之间会互相矛盾，而排查这种矛盾比写测试本身更费时间。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotCore

// MARK: - 像素工具

// 与渲染器使用同一色彩空间，否则 DeviceRGB ↔ sRGB 的转换
// 会让纯色像素产生几十级的通道偏移，测试会误判为缺陷。
let testColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    ?? CGColorSpaceCreateDeviceRGB()

/// 造一张纯色位图。
///
/// 一律用 `RGBAColor.cgColor`（显式 sRGB）而不是 `CGColor(red:green:blue:)`：
/// 后者走 Generic RGB 色彩空间，转到渲染器的 sRGB 上下文时会发生色域映射
/// （Generic RGB 的纯红在 sRGB 下是 (255,38,0)），让像素断言全部失准。
func solidImage(width: Int, height: Int, color: RGBAColor) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: testColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// 造一张上半 `top`、下半 `bottom` 的位图。
func splitImage(width: Int, height: Int, top: RGBAColor, bottom: RGBAColor) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: testColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    let half = height / 2
    // CGContext 是左下原点：先画底部再画顶部。
    context.setFillColor(bottom.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: half))
    context.setFillColor(top.cgColor)
    context.fill(CGRect(x: 0, y: half, width: width, height: height - half))
    return context.makeImage()!
}

/// 造一张底图：先铺背景色，再按顺序叠加若干矩形色块。
///
/// 矩形坐标用**左上原点**的像素坐标给出（与模型约定一致），
/// 内部负责翻转到 `CGContext` 的左下原点。
func regionedImage(
    width: Int,
    height: Int,
    background: RGBAColor,
    regions: [(x: Int, y: Int, width: Int, height: Int, color: RGBAColor)]
) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: testColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // 翻成左上原点，使传入的矩形坐标可以直接使用。
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)

    context.setFillColor(background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    for region in regions {
        context.setFillColor(region.color.cgColor)
        context.fill(CGRect(
            x: region.x,
            y: region.y,
            width: region.width,
            height: region.height
        ))
    }

    return context.makeImage()!
}

/// 把任意 `CGImage` 重绘到已知格式后读回 RGBA 分量。
///
/// 位图数据的第 0 行对应图像顶行，与模型的左上原点约定一致，
/// 因此调用方可以直接用模型坐标索引返回的数组。
struct PixelBuffer {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        // 用局部量而非 self 属性，避免闭包在 bytes 初始化前捕获 self。
        let pixelWidth = image.width
        let pixelHeight = image.height
        width = pixelWidth
        height = pixelHeight

        var buffer = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: testColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(
                image,
                in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
            )
        }
        bytes = buffer
    }

    /// 以左上原点坐标取一个像素的 RGB。
    func rgb(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let offset = (y * width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
}

func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PixelRect {
    PixelRect(origin: PixelPoint(x: x, y: y), size: PixelSize(width: w, height: h))
}

let white = RGBAColor(r: 1, g: 1, b: 1, a: 1)
let black = RGBAColor(r: 0, g: 0, b: 0, a: 1)
let red = RGBAColor(r: 1, g: 0, b: 0, a: 1)
let green = RGBAColor(r: 0, g: 1, b: 0, a: 1)
let blueColor = RGBAColor(r: 0, g: 0, b: 1, a: 1)
let yellow = RGBAColor(r: 1, g: 1, b: 0, a: 1)

/// 断言三个通道都落在期望值附近。
func expectColor(
    _ actual: (r: Int, g: Int, b: Int),
    _ expected: (r: Int, g: Int, b: Int),
    tolerance: Int = 3,
    _ label: String
) {
    let ok = abs(actual.r - expected.r) <= tolerance
        && abs(actual.g - expected.g) <= tolerance
        && abs(actual.b - expected.b) <= tolerance

    #expect(
        ok,
        "\(label)：期望 \(expected)±\(tolerance)，实际 \(actual)"
    )
}

// MARK: - 裁剪

@Suite("渲染管线 · 裁剪")
struct RenderCropTests {
    @Test("裁剪结果尺寸等于选区取整后的像素尺寸")
    func cropSize() throws {
        let backdrop = solidImage(width: 200, height: 100, color: white)
        let result = try #require(AnnotationRenderer.crop(
            backdrop: backdrop,
            selection: rect(20, 10, 60, 40)
        ))

        #expect(result.width == 60)
        #expect(result.height == 40)
    }

    @Test("裁剪取的是左上原点坐标")
    func cropUsesTopLeftOrigin() throws {
        // 100x100 全白，中间 20x20 为红。
        let context = CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: testColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(red.cgColor)
        // CGContext 左下原点：模型 y 80...100 对应这里 y 0...20。
        context.fill(CGRect(x: 40, y: 0, width: 20, height: 20))

        let backdrop = context.makeImage()!
        let result = try #require(AnnotationRenderer.crop(
            backdrop: backdrop,
            selection: rect(40, 80, 20, 20)
        ))

        let pixels = PixelBuffer(result)
        expectColor(pixels.rgb(x: 10, y: 10), (255, 0, 0), "裁剪区域中心应为红色")
    }

    @Test("裁剪不会重采样")
    func cropIsNotResampled() throws {
        // 2x2 四色图：验证 1:1 搬运后每个像素仍互不相同。
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: testColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red.cgColor)
        context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
        context.setFillColor(green.cgColor)
        context.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
        context.setFillColor(blueColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(yellow.cgColor)
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))

        let result = try #require(AnnotationRenderer.crop(
            backdrop: context.makeImage()!,
            selection: rect(0, 0, 2, 2)
        ))
        let pixels = PixelBuffer(result)

        expectColor(pixels.rgb(x: 0, y: 0), (255, 0, 0), "左上")
        expectColor(pixels.rgb(x: 1, y: 0), (0, 255, 0), "右上")
        expectColor(pixels.rgb(x: 0, y: 1), (0, 0, 255), "左下")
        expectColor(pixels.rgb(x: 1, y: 1), (255, 255, 0), "右下")
    }
}

/// 水平渐变底图：红色分量随 x 从 0 递增到 255。
///
/// 专用于验证马赛克块的**网格位置**：块内值恒定、块与块之间必然变化，
/// 于是扫描一行就能直接读出「值突变处」＝ 块边界落在哪个坐标。
func horizontalGradientImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: testColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    let buffer = context.data!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = context.bytesPerRow

    for y in 0 ..< height {
        for x in 0 ..< width {
            // premultipliedLast = RGBA；alpha 恒为 255 时预乘不改变分量。
            let level = UInt8(x * 255 / max(1, width - 1))
            let offset = y * bytesPerRow + x * 4
            buffer[offset] = level
            buffer[offset + 1] = 0
            buffer[offset + 2] = 0
            buffer[offset + 3] = 255
        }
    }

    return context.makeImage()!
}

/// 一行中值发生变化的 x 坐标，即马赛克块边界。
func blockBoundaries(
    in pixels: PixelBuffer,
    y: Int,
    from x0: Int,
    to x1: Int
) -> [Int] {
    var boundaries: [Int] = []
    var previous = pixels.rgb(x: x0, y: y).r
    for x in (x0 + 1) ..< x1 {
        let current = pixels.rgb(x: x, y: y).r
        if current != previous {
            boundaries.append(x)
            previous = current
        }
    }
    return boundaries
}

// MARK: - 长截图夹具
//
// 放在共享文件：`ScrollStitcherTests`（几何粘合）与 `ScrollshotSessionTests`（世界坐标追踪）
// 必须用**同一套**造图逻辑，否则「配准错了」和「测试图不一致」会互相伪装。

struct PageRandom {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((state >> 33) % 1_000) / 1_000
    }
}

/// 渲染一整页：行距规律（默认 10px），每行内容只由**世界坐标**决定。
///
/// `rowSpacing` 可调是为了构造「结构不同」的另一页：只改 `seed` 不够——
/// 那只会改行内细节，行距仍相同，配准依旧能对上（实测会把两页当成同一页），
/// 而这正是「内容变了但配准错误地成功」的真实现象。
func makePage(
    width: Int = 300, pageHeight: Int = 2000, seed: UInt64 = 11, rowSpacing: Int = 10
) -> ScrollshotImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: width, height: pageHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: pageHeight))
    context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1))

    let spacing = max(2, rowSpacing)
    for row in 0..<(pageHeight / spacing) {
        let worldY = row * spacing
        let y = CGFloat(pageHeight - worldY)
        var random = PageRandom(state: UInt64(worldY) &* 2_654_435_761 &+ seed)
        var x = 10
        while x < width - 12 {
            if random.next() < 0.9 {
                context.fill(CGRect(x: CGFloat(x), y: y - 8, width: 7, height: 8))
            }
            x += 8
        }
    }
    return ScrollshotImage(context.makeImage()!)!
}

/// 从整页里切出一帧（左上原点像素坐标）。
func slice(_ page: ScrollshotImage, offset: Int, height: Int) -> ScrollshotImage {
    let bytesPerRow = page.width * 4
    var buffer = [UInt8](repeating: 0, count: page.width * height * 4)
    buffer.withUnsafeMutableBytes { raw in
        guard let out = raw.baseAddress else { return }
        page.withPixels { source in
            guard let src = source.baseAddress else { return }
            for row in 0..<height {
                let sourceRow = offset + row
                guard sourceRow < page.height else { break }
                memcpy(out + row * bytesPerRow, src + sourceRow * bytesPerRow, bytesPerRow)
            }
        }
    }
    return ScrollshotImage(width: page.width, height: height, data: buffer)!
}

/// 逐像素比较两幅同尺寸图像，返回不同像素数与最大通道误差。
func compare(_ a: ScrollshotImage, _ b: ScrollshotImage) -> (differentPixels: Int, maxError: Int) {
    guard a.width == b.width, a.height == b.height else { return (Int.max, Int.max) }
    var different = 0
    var worst = 0
    a.withPixels { pa in
        b.withPixels { pb in
            for index in stride(from: 0, to: pa.count, by: 4) {
                let error = max(
                    abs(Int(pa[index]) - Int(pb[index])),
                    abs(Int(pa[index + 1]) - Int(pb[index + 1])),
                    abs(Int(pa[index + 2]) - Int(pb[index + 2]))
                )
                if error > 12 {
                    different += 1
                    worst = max(worst, error)
                }
            }
        }
    }
    return (different, worst)
}
