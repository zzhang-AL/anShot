import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

setbuf(stdout, nil)

// 配色取自 advisor 的建议，并与设置界面的无色体系保持一致：
// 强调色只出现一处（标注线），多了就会在 Dock 里显得吵。
let plateTop = CGColor(red: 0.16, green: 0.17, blue: 0.19, alpha: 1)
let plateBottom = CGColor(red: 0.09, green: 0.10, blue: 0.11, alpha: 1)
let frameColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let accentColor = CGColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)   // #FF9F0A

/// 画一版图标。
///
/// 网格按 macOS Big Sur 起的规范：1024 画布上主体圆角矩形取 824x824、
/// 圆角 185.4，四周各留 100。系统按这个网格摆放图标，不留白会让它看起来
/// 比 Dock 里的邻居大一圈。
func drawIcon(side: CGFloat) -> CGImage {
    let scale = side / 1024.0
    let ctx = CGContext(
        data: nil,
        width: Int(side),
        height: Int(side),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // ── ① 底板 ──
    let inset = 100.0 * scale
    let plate = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let plateRadius = 185.4 * scale
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil))
    ctx.clip()
    // 轻微渐变而不是纯色：纯平色在大尺寸下显得像没画完。
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [plateTop, plateBottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )
    ctx.restoreGState()

    // ── ② 取景框：四个角标，而不是一个完整矩形 ──
    //
    // 完整矩形会读成「相框」；四角开口是截图工具的通用符号，
    // 也在小尺寸下更透气。
    let frameInset = 202.0 * scale
    let frame = plate.insetBy(dx: frameInset, dy: frameInset)
    let armLength = frame.width * 0.30
    let lineWidth = plate.width * 0.052
    let cornerRadius = lineWidth * 0.5

    ctx.setStrokeColor(frameColor)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)

    // 四个角，每个画两条臂。
    let corners: [(CGPoint, CGPoint, CGPoint)] = [
        // (角点, x 方向臂终点, y 方向臂终点)
        (CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.minX + armLength, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY - armLength)),
        (CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.maxX - armLength, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY - armLength)),
        (CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.minX + armLength, y: frame.minY), CGPoint(x: frame.minX, y: frame.minY + armLength)),
        (CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX - armLength, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY + armLength)),
    ]
    for (corner, horizontalEnd, verticalEnd) in corners {
        ctx.move(to: horizontalEnd)
        ctx.addLine(to: corner)
        ctx.addLine(to: verticalEnd)
        ctx.strokePath()
    }

    // ── ③ 标注笔划 ──
    //
    // 不画完整画笔：小尺寸下会糊成一团。两条不同长度、带角度的圆头线
    // 就足以暗示「标注」，而且缩到 16pt 仍然读得出来。
    ctx.setStrokeColor(accentColor)
    ctx.setLineWidth(plate.width * 0.048)
    ctx.setLineCap(.round)

    // 一条斜线，而不是两段：两段在交接处会露出一个台阶，
    // 在小尺寸下看起来像画坏了，而不是「两笔标注」。
    let center = CGPoint(x: plate.midX, y: plate.midY)
    let span = plate.width * 0.27

    ctx.move(to: CGPoint(x: center.x - span * 0.5, y: center.y - span * 0.40))
    ctx.addLine(to: CGPoint(x: center.x + span * 0.5, y: center.y + span * 0.40))
    ctx.strokePath()

    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        print("❌ 无法创建 \(path)")
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    if CGImageDestinationFinalize(dest) {
        print("✅ \(path)")
    } else {
        print("❌ 写入失败 \(path)")
    }
}

// ── 输出 ──
//
// macOS 的 AppIcon 需要 1x/2x 两档共 10 张。全部从同一个 1024 母图缩放，
// 不分别手工绘制：分别画必然出现「16pt 那张的取景框比 32pt 的粗」这类不一致。
let args = CommandLine.arguments
let assetsDir = args.count > 1 ? args[1] : "/tmp/anshot-icon/icon"

let variants: [(name: String, side: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

// 母图画一次即可：派生尺寸都从它缩，保证线宽比例完全一致。
let master = drawIcon(side: 1024)
for variant in variants {
    if variant.side == 1024 {
        write(master, to: "\(assetsDir)/\(variant.name).png")
        continue
    }
    // 用 CGContext 高质量缩放：直接让 AppKit 缩会得到软边。
    let scale = CGFloat(variant.side) / 1024.0
    let ctx = CGContext(
        data: nil,
        width: variant.side,
        height: variant.side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: CGFloat(variant.side), height: CGFloat(variant.side)))
    _ = scale
    write(ctx.makeImage()!, to: "\(assetsDir)/\(variant.name).png")
}
