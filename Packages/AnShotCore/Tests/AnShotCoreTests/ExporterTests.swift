//
//  ExporterTests.swift
//  AnShotCoreTests
//
//  导出管线的验证。
//
//  重点不在「能不能存出文件」——那只要编码器不报错就行——
//  而在**取整与落位规则**：选区天然带小数（逻辑点 × scaleFactor），
//  对齐方式差一像素，导出的图就和用户看到的不是同一块内容。
//  这类偏差在返回值层面完全看不出来，必须逐像素核对。
//

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import AnShotCore

@Suite("导出管线")
struct ExporterTests {
    // MARK: - 取整规则

    @Test("选区向外取整，不小于用户选中区域")
    func 向外取整() {
        // origin 向下、右/下边界向上：结果必须完整覆盖 (10.4, 20.7)-(109.6, 70.3)
        let image = solidImage(width: 200, height: 200, color: white)
        let selection = rect(10.4, 20.7, 99.2, 49.6)

        let rendered = AnnotationRenderer.render(
            backdrop: image,
            selection: selection,
            annotations: []
        )

        let unwrapped = rendered
        // x0=10, y0=20, x1=ceil(109.6)=110, y1=ceil(70.3)=71
        #expect(unwrapped?.width == 100)
        #expect(unwrapped?.height == 51)
    }

    @Test("取整方向不同于四舍五入")
    func 取整方向显著区别于四舍五入() {
        // 四舍五入会得到宽 2（10.6→11, 12.6→13），向外取整得到宽 3。
        // 这个用例一改就红，专门用来锁住「不许退回 rounded()」。
        let image = solidImage(width: 100, height: 100, color: white)
        let selection = rect(10.6, 10.6, 2.0, 2.0)

        let rendered = AnnotationRenderer.render(
            backdrop: image,
            selection: selection,
            annotations: []
        )

        let unwrapped = rendered
        #expect(unwrapped?.width == 3)
        #expect(unwrapped?.height == 3)
    }

    @Test("对齐后按整数像素落位，不产生重采样")
    func 整数像素落位不重采样() {
        // 逐列红通道递增的底图：一旦发生重采样，通道值会出现中间值。
        let image = horizontalGradientImage(width: 64, height: 8)

        let fractional = AnnotationRenderer.render(
            backdrop: image,
            selection: rect(10.4, 2.7, 20.0, 4.0),
            annotations: []
        )
        let integral = AnnotationRenderer.render(
            backdrop: image,
            selection: rect(10.0, 2.0, 21.0, 5.0),
            annotations: []
        )

        let fracImage = fractional
        let intImage = integral

        #expect(fracImage?.width == intImage?.width)
        #expect(fracImage?.height == intImage?.height)

        guard let fracImage, let intImage else { return }

        let fracPixels = PixelBuffer(fracImage)
        let intPixels = PixelBuffer(intImage)

        // 逐像素完全相同：说明小数选区被整体对齐，而没有做插值采样。
        var mismatch = 0
        for y in 0..<fracPixels.height {
            for x in 0..<fracPixels.width {
                if fracPixels.rgb(x: x, y: y) != intPixels.rgb(x: x, y: y) {
                    mismatch += 1
                }
            }
        }
        #expect(mismatch == 0, "小数选区与对齐后的整数选区结果不一致，共 \(mismatch) 个像素")
    }

    @Test("选区越界时夹到底图范围内，不崩溃")
    func 越界选区被夹住() {
        let image = solidImage(width: 40, height: 30, color: white)

        // x1 超出宽度、y1 超出高度。
        let rendered = AnnotationRenderer.render(
            backdrop: image,
            selection: rect(30, 20, 100, 100),
            annotations: []
        )

        let unwrapped = rendered
        #expect(unwrapped?.width == 10)
        #expect(unwrapped?.height == 10)
    }

    // MARK: - 边界

    @Test("1x1 像素选区可用")
    func 最小选区() {
        let image = solidImage(width: 40, height: 40, color: red)
        let rendered = AnnotationRenderer.render(
            backdrop: image,
            selection: rect(10, 10, 1, 1),
            annotations: []
        )

        let unwrapped = rendered
        #expect(unwrapped?.width == 1)
        #expect(unwrapped?.height == 1)
    }

    @Test("亚像素选区向外取整后至少 1 像素")
    func 亚像素选区() {
        // 0.3 像素：向下取整会让尺寸变 0 而整块消失。
        // 向外取整保证「选到了就一定拿到像素」。
        let image = solidImage(width: 40, height: 40, color: red)
        let rendered = AnnotationRenderer.render(
            backdrop: image,
            selection: rect(10.7, 10.7, 0.3, 0.3),
            annotations: []
        )

        let unwrapped = rendered
        #expect(unwrapped?.width == 1)
        #expect(unwrapped?.height == 1)
    }

    @Test("贴左上角 (0,0) 的选区")
    func 贴左上角() {
        let image = regionedImage(
            width: 40,
            height: 40,
            background: white,
            regions: [(x: 0, y: 0, width: 5, height: 5, color: red)]
        )
        let rendered = AnnotationRenderer.render(
            backdrop: image,
            selection: rect(0, 0, 5, 5),
            annotations: []
        )

        let unwrapped = rendered
        guard let unwrapped else { return }

        let pixels = PixelBuffer(unwrapped)
        // 角落必须是那块红色：坐标原点处理错位就会取到白色。
        expectColor(pixels.rgb(x: 0, y: 0), (255, 0, 0), "左上角")
    }

    @Test("贴右下角的选区")
    func 贴右下角() {
        let image = regionedImage(
            width: 40,
            height: 40,
            background: white,
            regions: [(x: 35, y: 35, width: 5, height: 5, color: red)]
        )
        let rendered = AnnotationRenderer.render(
            backdrop: image,
            selection: rect(35, 35, 5, 5),
            annotations: []
        )

        let unwrapped = rendered
        guard let unwrapped else { return }

        let pixels = PixelBuffer(unwrapped)
        expectColor(pixels.rgb(x: 4, y: 4), (255, 0, 0), "右下角")
    }

    @Test("整幅底图作为选区")
    func 整幅选区() {
        let image = solidImage(width: 32, height: 24, color: blueColor)
        let rendered = AnnotationRenderer.render(
            backdrop: image,
            selection: rect(0, 0, 32, 24),
            annotations: []
        )

        let unwrapped = rendered
        #expect(unwrapped?.width == 32)
        #expect(unwrapped?.height == 24)
    }

    @Test("完全在底图之外的选区失败而非崩溃")
    func 完全越界() {
        let image = solidImage(width: 40, height: 40, color: white)
        let rendered = AnnotationRenderer.render(
            backdrop: image,
            selection: rect(100, 100, 10, 10),
            annotations: []
        )
        #expect(rendered == nil)
    }

    // MARK: - 合成契约

    @Test("导出与显示走同一条渲染路径")
    func 导出复用渲染器() {
        let backdrop = solidImage(width: 100, height: 100, color: white)
        let selection = rect(10, 10, 50, 50)
        let annotations = [
            Annotation(kind: .rectangle(
                rect: rect(5, 5, 20, 20),
                stroke: StrokeStyle(color: red, width: 4),
                fill: nil,
                cornerRadius: 0
            ))
        ]

        let exported = Exporter.compose(
            backdrop: backdrop,
            selection: selection,
            annotations: annotations
        )
        let displayed = AnnotationRenderer.render(
            backdrop: backdrop,
            selection: selection,
            annotations: annotations
        )

        let expImage = exported
        let dispImage = displayed
        guard let expImage, let dispImage else { return }

        let expPixels = PixelBuffer(expImage)
        let dispPixels = PixelBuffer(dispImage)

        #expect(expPixels.width == dispPixels.width)
        #expect(expPixels.height == dispPixels.height)

        var mismatch = 0
        for y in 0..<expPixels.height {
            for x in 0..<expPixels.width {
                if expPixels.rgb(x: x, y: y) != dispPixels.rgb(x: x, y: y) {
                    mismatch += 1
                }
            }
        }
        #expect(mismatch == 0, "导出图与显示图不一致，共 \(mismatch) 个像素")
    }

    @Test("标注被烘焙进导出图")
    func 标注进入导出图() {
        let backdrop = solidImage(width: 100, height: 100, color: white)
        // 铺满整个选区的红色矩形填充。
        let annotations = [
            Annotation(kind: .rectangle(
                rect: rect(10, 10, 50, 50),
                stroke: StrokeStyle(color: red, width: 1),
                fill: red,
                cornerRadius: 0
            ))
        ]

        let exported = Exporter.compose(
            backdrop: backdrop,
            selection: rect(10, 10, 50, 50),
            annotations: annotations
        )

        let image = exported
        guard let image else { return }

        let pixels = PixelBuffer(image)
        // 中心必是标注的红色，而不是底图的白。
        expectColor(pixels.rgb(x: pixels.width / 2, y: pixels.height / 2), (255, 0, 0), "标注填充")
    }

    @Test("空选区合成失败")
    func 空选区失败() {
        let backdrop = solidImage(width: 100, height: 100, color: white)
        let exported = Exporter.compose(
            backdrop: backdrop,
            selection: rect(10, 10, 0, 0),
            annotations: []
        )
        #expect(exported == nil)
    }

    // MARK: - 编码与落盘

    @Test("PNG 编码可解码且尺寸一致")
    func png编码往返() throws {
        let backdrop = solidImage(width: 80, height: 60, color: green)

        let data = try Exporter.pngData(
            backdrop: backdrop,
            selection: rect(5, 5, 40, 30),
            annotations: []
        )

        #expect(!data.isEmpty)

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 40)
        #expect(decoded.height == 30)

        let pixels = PixelBuffer(decoded)
        expectColor(pixels.rgb(x: 20, y: 15), (0, 255, 0), "解码后的颜色")
    }

    @Test("写 PNG 文件并读回")
    func 落盘往返() throws {
        let backdrop = solidImage(width: 60, height: 40, color: blueColor)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-exporter-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try Exporter.writePNG(
            backdrop: backdrop,
            selection: rect(0, 0, 30, 20),
            annotations: [],
            to: url
        )

        #expect(FileManager.default.fileExists(atPath: url.path))

        // 读回确认不是空文件、且确实是 PNG。
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let type = try #require(CGImageSourceGetType(source))
        #expect(type as String == "public.png")

        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 30)
        #expect(decoded.height == 20)
    }

    @Test("合成失败时抛 renderFailed")
    func 合成失败抛错() {
        let backdrop = solidImage(width: 50, height: 50, color: white)

        #expect(throws: ExportError.renderFailed) {
            _ = try Exporter.pngData(
                backdrop: backdrop,
                selection: rect(0, 0, 0, 0),
                annotations: []
            )
        }
    }

    // MARK: - 文件名

    @Test("默认文件名含日期且为 png")
    func 默认文件名() {
        // 固定时间，避免依赖当前时刻。
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let name = Exporter.defaultFileName(at: date)

        #expect(name.hasSuffix(".png"))
        #expect(name.contains("截图"))
        // 文件名里不能出现会被 Finder 显示成路径分隔符的冒号。
        #expect(!name.contains(":"))
    }
}
