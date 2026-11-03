//
//  AnnotationRendererTests.swift
//  AnShotCoreTests
//
//  渲染管线的像素级验证。
//
//  这些测试不只断言「函数返回了图」，而是逐个像素核对结果，
//  因为渲染缺陷（坐标方向、z 序、块边界）在返回值层面完全看不出来。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotCore

// MARK: - 矢量标注

@Suite("渲染管线 · 矢量标注")
struct RenderVectorTests {
    @Test("矩形填充与描边落在模型坐标指定的位置")
    func rectanglePlacement() throws {
        let backdrop = solidImage(width: 200, height: 200, color: white)
        let annotation = Annotation(kind: .rectangle(
            rect: rect(50, 50, 100, 100),
            stroke: StrokeStyle(color: black, width: 10),
            fill: red,
            cornerRadius: 0
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 200, 200),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        expectColor(pixels.rgb(x: 100, y: 100), (255, 0, 0), "矩形内部应为红色填充")
        expectColor(pixels.rgb(x: 5, y: 5), (255, 255, 255), "矩形之外应保持底图白色")
        // 上边界：y=50 处是描边中心。
        expectColor(pixels.rgb(x: 100, y: 50), (0, 0, 0), "上边界应为黑色描边")
        expectColor(pixels.rgb(x: 100, y: 150), (0, 0, 0), "下边界应为黑色描边")
    }

    @Test("矩形圆角处不填充，直角处填充")
    func rectangleCornerRadius() throws {
        let backdrop = solidImage(width: 100, height: 100, color: white)
        let annotation = Annotation(kind: .rectangle(
            rect: rect(10, 10, 80, 80),
            stroke: StrokeStyle(color: red, width: 0.0001),
            fill: red,
            cornerRadius: 24
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 100, 100),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        expectColor(pixels.rgb(x: 50, y: 50), (255, 0, 0), "中心应填充")
        expectColor(pixels.rgb(x: 12, y: 12), (255, 255, 255), "圆角处应未被填充")
    }

    @Test("直线起点与终点方向与模型一致")
    func lineEndpoints() throws {
        let backdrop = solidImage(width: 100, height: 100, color: white)
        let annotation = Annotation(kind: .line(
            start: PixelPoint(x: 10, y: 10),
            end: PixelPoint(x: 90, y: 10),
            stroke: StrokeStyle(color: black, width: 6)
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 100, 100),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        expectColor(pixels.rgb(x: 50, y: 10), (0, 0, 0), "线上应为黑色")
        expectColor(pixels.rgb(x: 50, y: 50), (255, 255, 255), "线外应保持白色")
    }

    @Test("箭头尖端朝向 end 且头部被填充")
    func arrowHeadIsFilled() throws {
        let backdrop = solidImage(width: 100, height: 100, color: white)
        // 从 (10,50) 指向 (90,50)：头在右侧。
        let annotation = Annotation(kind: .arrow(
            start: PixelPoint(x: 10, y: 50),
            end: PixelPoint(x: 90, y: 50),
            stroke: StrokeStyle(color: black, width: 3),
            headLength: 20,
            headWidth: 20
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 100, 100),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        expectColor(pixels.rgb(x: 88, y: 50), (0, 0, 0), "尖端附近应被填充")
        expectColor(pixels.rgb(x: 12, y: 50), (0, 0, 0), "尾部应被填充")
        expectColor(pixels.rgb(x: 50, y: 20), (255, 255, 255), "杆的上方应为空白")
    }

    @Test("文字绘制在基线起点处且方向正确")
    func textIsUprightAtBaseline() throws {
        let backdrop = solidImage(width: 400, height: 200, color: white)
        let annotation = Annotation(kind: .text(
            origin: PixelPoint(x: 40, y: 120),
            text: "Ag",
            font: .system(size: 64),
            color: black,
            background: nil,
            maxWidth: nil
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 400, 200),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        // 统计基线以上与以下的深色像素。
        var above = 0
        var below = 0
        for y in 0 ..< 200 {
            for x in 0 ..< 400 {
                let rgb = pixels.rgb(x: x, y: y)
                guard rgb.r < 128, rgb.g < 128, rgb.b < 128 else {
                    continue
                }
                if y < 120 {
                    above += 1
                } else if y > 120 {
                    below += 1
                }
            }
        }

        #expect(above > 0, "基线以上应有字形像素")
        // 基线之下只应有极少量下伸部（"g" 的下圈），
        // 若文字被上下颠倒，则会退化成「基线以下远比以上多」。
        #expect(below < above, "基线以下不应多过基线以上（above=\(above) below=\(below)）")
    }

    @Test("文字底色跟随该行的排版盒")
    func textBackground() throws {
        let backdrop = solidImage(width: 400, height: 200, color: white)
        let annotation = Annotation(kind: .text(
            origin: PixelPoint(x: 40, y: 120),
            text: "B",
            font: .system(size: 64),
            color: black,
            background: red,
            maxWidth: nil
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 400, 200),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        // 取「基线下方、字形之外」的点：底框覆盖 origin.x 起、
        // 基线上下 ascent/descent 的范围，而文字下伸部极少，
        // 因此基线下方必定是底色。
        expectColor(pixels.rgb(x: 60, y: 130), (255, 0, 0), "文字底色应被填充")
    }
}

// MARK: - 马赛克

@Suite("渲染管线 · 马赛克")
struct RenderMosaicTests {
    @Test("马赛克对纯色区域是幂等的")
    func mosaicOnSolidColorIsIdempotent() throws {
        let backdrop = solidImage(width: 120, height: 120, color: red)
        let annotation = Annotation(kind: .mosaic(
            rect: rect(20, 20, 80, 80),
            mode: .pixelate,
            intensity: 8
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 120, 120),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        expectColor(pixels.rgb(x: 60, y: 60), (255, 0, 0), "纯色区域马赛克后颜色不变")
    }

    @Test("马赛克按块取平均")
    func mosaicAveragesBlocks() throws {
        // 100x100 全白，左半为红；整块马赛克后应得到半红半白的平均值。
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
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))

        let backdrop = context.makeImage()!
        let annotation = Annotation(kind: .mosaic(
            rect: rect(0, 0, 100, 100),
            mode: .pixelate,
            intensity: 100
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 100, 100),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        // 左半 50 个红色像素 + 右半 50 个白色像素 → (255, 128, 128)。
        expectColor(pixels.rgb(x: 10, y: 50), (255, 128, 128), tolerance: 4, "左半应被平均")
        expectColor(pixels.rgb(x: 90, y: 50), (255, 128, 128), tolerance: 4, "右半应被平均")
    }

    @Test("马赛克的行方向与模型左上原点一致")
    func mosaicRowOrientation() throws {
        // 100x100：上半黑、下半白。
        let backdrop = splitImage(width: 100, height: 100, top: black, bottom: white)

        // 马赛克只覆盖模型 y 0...60（上半黑 50 行 + 下部白 10 行）。
        let annotation = Annotation(kind: .mosaic(
            rect: rect(0, 0, 100, 60),
            mode: .pixelate,
            intensity: 100
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 100, 100),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        // 期望 (50*0 + 10*255) / 60 ≈ 42。
        // 若行方向颠倒，结果会变成 (10*0 + 50*255) / 60 ≈ 212。
        let inside = pixels.rgb(x: 50, y: 30).r
        #expect(
            abs(inside - 42) <= 4,
            "马赛克应读取上半（黑）为主的区域，实际灰度 \(inside)（接近 212 说明行方向颠倒）"
        )

        // 未被马赛克覆盖的下半仍应为白色。
        expectColor(pixels.rgb(x: 50, y: 80), (255, 255, 255), "马赛克范围外不应被修改")
    }

    @Test("马赛克读取的是当前画布而不是原始底图（z 序）")
    func mosaicReadsCurrentCanvas() throws {
        // 200x100 白色底图，先画一个覆盖左半的红色矩形，再整块马赛克。
        let backdrop = solidImage(width: 200, height: 100, color: white)
        let rectangle = Annotation(kind: .rectangle(
            rect: rect(0, 0, 100, 100),
            stroke: StrokeStyle(color: red, width: 0.0001),
            fill: red,
            cornerRadius: 0
        ))
        let mosaic = Annotation(kind: .mosaic(
            rect: rect(0, 0, 200, 100),
            mode: .pixelate,
            intensity: 200
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 200, 100),
            annotations: [rectangle, mosaic]
        ))
        let pixels = PixelBuffer(result)

        // 若马赛克读的是「原始底图」（全白），结果会是纯白，矩形被抹掉；
        // 契约要求它读当前画布，因此结果应为半红半白。
        expectColor(pixels.rgb(x: 100, y: 50), (255, 128, 128), tolerance: 4, "马赛克应把已画的矩形一起平均")
    }

    @Test("同一区域先马赛克再画箭头时箭头保持原色")
    func arrowAfterMosaicIsNotBlurred() throws {
        let backdrop = solidImage(width: 200, height: 100, color: white)
        let mosaic = Annotation(kind: .mosaic(
            rect: rect(0, 0, 200, 100),
            mode: .pixelate,
            intensity: 200
        ))
        let rectangle = Annotation(kind: .rectangle(
            rect: rect(0, 0, 100, 100),
            stroke: StrokeStyle(color: red, width: 0.0001),
            fill: red,
            cornerRadius: 0
        ))

        // 顺序反过来：马赛克在前，矩形在后。
        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 200, 100),
            annotations: [mosaic, rectangle]
        ))
        let pixels = PixelBuffer(result)

        // 马赛克先把纯白底图平均（仍是白），随后矩形以原色画上去。
        expectColor(pixels.rgb(x: 50, y: 50), (255, 0, 0), "后画的矩形不应被马赛克处理")
    }

    @Test("未实现的马赛克模式被跳过而不是中断整幅渲染")
    func unsupportedModeIsSkipped() throws {
        let backdrop = solidImage(width: 100, height: 100, color: white)
        let annotation = Annotation(kind: .mosaic(
            rect: rect(0, 0, 100, 100),
            mode: .blur,
            intensity: 10
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 100, 100),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        expectColor(pixels.rgb(x: 50, y: 50), (255, 255, 255), "未实现的模式应只跳过自身")
    }

    @Test("非零选区原点下马赛克仍作用于标注指定的底图区域")
    func mosaicRespectsNonZeroCanvasOrigin() throws {
        // 马赛克直接寻址位图缓冲区，而 CGContext 的 translate/scale 只作用于矢量绘制。
        // 忘减画布原点时，马赛克会整体平移一个 selection.origin——
        // 在非零偏移选区下就会默默盖到错误的区域上。
        //
        // 布局：目标区（红/绿各半）在底图左上，而「错位一个 origin 后」
        // 会落到的右下区域是纯白（马赛克对纯色幂等，不会留下痕迹）。
        // 因此：出现红色分量 ⇒ 打对了地方；纯绿 ⇒ 打到了别处。
        let backdrop = regionedImage(
            width: 400,
            height: 300,
            background: white,
            regions: [
                (100, 100, 100, 50, red),
                (100, 150, 100, 50, green),
            ]
        )

        let selection = rect(100, 100, 200, 200)
        let annotation = Annotation(kind: .mosaic(
            rect: rect(100, 100, 100, 100),
            mode: .pixelate,
            intensity: 8
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: selection,
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        // 块网格锚定底图原点，块边界因此固定在 8 的倍数处：
        // 底图 y 144...152 这一块跨过红/绿边界（150），平均后必带红色分量。
        // 画布 (50,45) 对应底图 (150,145)，正落在该块内。
        let blended = pixels.rgb(x: 50, y: 45)
        #expect(
            blended.r > 30,
            "马赛克未作用于标注指定的底图区域：实际 \(blended)，疑似漏减画布原点"
        )

        // 画布 (150,150) 对应底图 (250,250)，只在马赛克错位时才会被覆盖。
        expectColor(
            pixels.rgb(x: 150, y: 150),
            (255, 255, 255),
            tolerance: 2,
            "错位区域不应被马赛克触碰"
        )
    }
}

// MARK: - 组合

@Suite("渲染管线 · 组合")
struct RenderCompositionTests {
    @Test("多个标注按数组顺序叠加")
    func annotationsStackInOrder() throws {
        let backdrop = solidImage(width: 100, height: 100, color: white)
        // 两个重叠矩形：后一个应盖住前一个。
        let first = Annotation(kind: .rectangle(
            rect: rect(10, 10, 60, 60),
            stroke: StrokeStyle(color: red, width: 0.0001),
            fill: red,
            cornerRadius: 0
        ))
        let second = Annotation(kind: .rectangle(
            rect: rect(30, 30, 60, 60),
            stroke: StrokeStyle(color: black, width: 0.0001),
            fill: black,
            cornerRadius: 0
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 100, 100),
            annotations: [first, second]
        ))
        let pixels = PixelBuffer(result)

        expectColor(pixels.rgb(x: 20, y: 20), (255, 0, 0), "仅第一个矩形覆盖处为红")
        expectColor(pixels.rgb(x: 70, y: 70), (0, 0, 0), "重叠处应由后一个矩形覆盖")
    }

    @Test("带偏移的选区会整体平移标注坐标系")
    func selectionOffsetsAnnotationCoordinates() throws {
        let backdrop = solidImage(width: 200, height: 200, color: white)
        // 裁剪 (100,100)-(200,200)，在其中画一个覆盖全画布的红色矩形。
        let annotation = Annotation(kind: .rectangle(
            rect: rect(100, 100, 100, 100),
            stroke: StrokeStyle(color: red, width: 0.0001),
            fill: red,
            cornerRadius: 0
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(100, 100, 100, 100),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        #expect(result.width == 100)
        expectColor(pixels.rgb(x: 0, y: 0), (255, 0, 0), "左上角应落在标注内")
        expectColor(pixels.rgb(x: 99, y: 99), (255, 0, 0), "右下角应落在标注内")
    }

    @Test("非法参数返回 nil 而不是崩溃")
    func invalidArgumentsReturnNil() {
        let backdrop = solidImage(width: 100, height: 100, color: white)

        #expect(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 0, 0),
            annotations: []
        ) == nil)

        #expect(AnnotationRenderer.crop(
            backdrop: backdrop,
            selection: rect(0, 0, 0, 10)
        ) == nil)
    }

    @Test("马赛克块网格锚定底图坐标，不随拖动框起点漂移")
    func mosaicGridAnchorsToBackdrop() throws {
        // 块网格若按「拖动框左上角」起算，同一区域先后刷两次会得到两套网格，
        // 拼缝处出现半块错位。判据：块边界必须落在底图坐标的 blockSize 倍数处。
        let backdrop = horizontalGradientImage(width: 200, height: 60)
        let blockSize = 8

        // 框起点 99 刻意不是 8 的倍数：
        // 网格若随框起算，边界会落在 99、107、115……而不是 8 的倍数处。
        let annotation = Annotation(kind: .mosaic(
            rect: rect(99, 10, 40, 20),
            mode: .pixelate,
            intensity: Double(blockSize)
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 200, 60),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        let boundaries = blockBoundaries(in: pixels, y: 20, from: 99, to: 139)
        #expect(!boundaries.isEmpty, "渐变底图下应当能看到块边界")
        #expect(
            boundaries.allSatisfy { $0 % blockSize == 0 },
            "块边界未锚定底图原点：\(boundaries)"
        )
    }

    @Test("涂抹马赛克按半径覆盖路径两侧，路径之外不受影响")
    func mosaicStrokeCoversPath() throws {
        // 底图左红右绿，用一条竖直涂抹路径骑在红绿边界上。
        //
        // 边界刻意取 204 而不是 200：200 是 blockSize 8 的倍数，
        // 那样就没有任何一个马赛克块会跨越边界，测不出「块内平均混合两种颜色」。
        let backdrop = regionedImage(
            width: 400,
            height: 300,
            background: white,
            regions: [
                (0, 0, 204, 300, red),
                (204, 0, 196, 300, green),
            ]
        )

        // 路径沿 x=204 自上而下，半径 20：覆盖 x ∈ [184, 224]。
        // 块 200...208 因此跨越边界，平均后红绿分量都明显。
        let annotation = Annotation(kind: .mosaicStroke(
            points: [
                PixelPoint(x: 204, y: 100),
                PixelPoint(x: 204, y: 160),
                PixelPoint(x: 204, y: 220),
            ],
            radius: 20,
            mode: .pixelate,
            intensity: 8
        ))

        let result = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 400, 300),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(result)

        // 路径正下方：块跨越红绿边界，平均后红绿分量都明显。
        let onPath = pixels.rgb(x: 200, y: 160)
        #expect(onPath.r > 30 && onPath.g > 30, "路径下方未被涂抹：\(onPath)")

        // 半径之外必须保持纯色。
        expectColor(pixels.rgb(x: 100, y: 160), (255, 0, 0), tolerance: 2, "路径外不应被涂抹")
        expectColor(pixels.rgb(x: 330, y: 160), (0, 255, 0), tolerance: 2, "路径外不应被涂抹")

        // 路径纵向之外（y < 100 - 20）同样不受影响，仍是该处底图的原色（绿）。
        expectColor(pixels.rgb(x: 204, y: 40), (0, 255, 0), tolerance: 6, "路径上下端之外不应被涂抹")
    }

}
