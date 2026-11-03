//
//  ScrollshotImage.swift
//  AnShotCore
//
//  滚动截图用的像素图像：一块紧凑的 RGBA8 缓冲。
//
//  ── 为什么不用 CGImage 直接算 ──────────────────────────────
//
//  配准要在两帧之间做数百万次像素比较，而 `CGImage` 不保证你能直接拿到
//  某一行某一列的字节：它可能背后是压缩数据、可能有 row padding、
//  位深与通道序也随来源变化。每次都画进上下文再读会慢一个数量级。
//  所以先「一次性摊平」成确定的 RGBA8 缓冲，之后只做整数下标运算。
//
//  ── 布局约定（全流程唯一） ────────────────────────────────
//
//  行优先、左上原点、每像素 4 字节 RGBA、无行填充。
//  「左上原点」只影响人对 y 的直觉，不影响本文件的任何计算——
//  配准只比较 `y` 与 `y + delta`，保持自洽即可。
//

import CoreGraphics
import Foundation

/// 一块紧凑的 RGBA8 像素图像。
public struct ScrollshotImage: Equatable, Sendable {

    /// 像素宽度，必须 > 0。
    public let width: Int

    /// 像素高度，必须 > 0。
    public let height: Int

    /// 长度恒为 `width * height * 4` 的 RGBA8 缓冲。
    public let data: [UInt8]

    /// 每行的字节数（等于 `width * 4`；此处显式暴露，避免调用方各处重算）。
    public var bytesPerRow: Int { width * 4 }

    public init?(width: Int, height: Int, data: [UInt8]) {
        guard width > 0, height > 0, data.count == width * height * 4 else {
            return nil
        }
        self.width = width
        self.height = height
        self.data = data
    }

    /// 从 `CGImage` 摊平。
    ///
    /// 用 `CGContext` 重绘一次而不是读 `CGImage.dataProvider`：后者给出的
    /// 通道序、位深与行填充都取决于图像来源，读之前得先判断一堆条件，
    /// 判错就是静默的错位。重绘成固定格式是唯一稳妥的做法。
    public init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, data: buffer)
    }

    /// 转成 `CGImage`（供 Vision 等系统 API 使用）。
    ///
    /// 布局与本类型完全一致（左上原点、RGBA8、无行填充），所以
    /// `CGImage.cropping(to:)` 的像素坐标与 `worldOffset` 是同一套方向，
    /// 裁剪时不需要翻转 y——这一点是「两帧做相同裁剪」能成立的前提。
    public func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// 在像素缓冲的裸指针上执行一段计算。
    ///
    /// 配准的热点循环每帧要做几十万次像素读取。用下标访问时，每次读写都会
    /// 走一遍边界检查与数组缓冲的引用计数，实测比指针版慢一个数量级；
    /// 所以热点一律在外层取一次指针，内层只做整数下标运算。
    @inline(__always)
    public func withPixels<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        data.withUnsafeBufferPointer(body)
    }

    // MARK: - 转置（轴向复用的技术支点）

    /// 行列互换：`(x, y)` 处的像素搬到 `(y, x)`。
    ///
    /// ── 为什么需要它 ──────────────────────────────────────────
    ///
    /// 横向长截图与竖直长截图在几何上是**同一个问题**，只是增长轴换了：
    /// 竖直是「帧之间求纵向位移、按行贴」，横向是「求横向位移、按列贴」。
    /// 而本项目的配准内核（`VerticalOverlap`）、世界坐标会话
    /// （`ScrollshotSession`）、拼接编排（`ScrollStitcher`）合计两千余行，
    /// 全部围绕**行**写死，并由现有测试逐条钉住。
    ///
    /// 把它们参数化成轴无关，改动面覆盖每一个已固化的常量与判据（行权重、
    /// 吸顶带、不可用带、接缝行…），等于把已验证的算法重写一遍。
    /// 转置只需要**一处**几何变换，就能把横向问题映射成竖直问题：
    ///
    /// ```
    /// 横向帧 --transposed--> 竖直帧 --现有全链路--> 竖直长图 --transposed--> 横向长图
    /// ```
    ///
    /// 代价是每帧一次整块像素搬运：1600×900×4 ≈ 5.5 MB，实测毫秒级，
    /// 相对 8 Hz 的抓帧间隔可忽略；收益是横向模式**零改动复用**全部已验证算法。
    ///
    /// ── 调用方必须注意的语义旋转 ──────────────────────────────
    ///
    /// 转置会交换「行」与「列」，于是竖直模式里的参数在横向模式下含义变了：
    /// * `unusableTopRows`  → 原图的**左侧**不可用带（侧栏、竖向分隔条）
    /// * `unusableBottomRows` → 原图的**右侧**不可用带（滚动条轨道所在侧）
    /// * `stickyHeaderRows` → 原图**左侧**的吸顶列（例如冻结的表格首列）
    /// * `maxOutputHeight`  → 输出**宽**的上限
    ///
    /// 这不是缺陷而是复用带来的必然：转置后的「上」就是原来的「左」。
    /// 调用方按轴换算，内核保持不知道轴的存在。
    ///
    /// ── 为什么返回可选 ───────────────────────────────────────
    ///
    /// 与 `init?` 保持一致：分配失败（内存不足）或尺寸退化时返回 nil，
    /// 让调用方走「抓帧失败」的同一条路径，而不是在长截图里抛出一个
    /// 无法预期的崩溃。转置本身不改变尺寸，正常路径下几乎不可能失败。
    public func transposed() -> ScrollshotImage? {
        let newWidth = height
        let newHeight = width
        var buffer = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        buffer.withUnsafeMutableBufferPointer { output in
            guard let out = output.baseAddress else { return }
            data.withUnsafeBufferPointer { source in
                guard let src = source.baseAddress else { return }
                // 目标行号即原图列号：转置把「一行」变成「一列」。
                for y in 0..<height {
                    let sourceRow = y * width * 4
                    for x in 0..<width {
                        let from = sourceRow + x * 4
                        let to = (x * newWidth + y) * 4
                        out[to] = src[from]
                        out[to + 1] = src[from + 1]
                        out[to + 2] = src[from + 2]
                        out[to + 3] = src[from + 3]
                    }
                }
            }
        }
        return ScrollshotImage(width: newWidth, height: newHeight, data: buffer)
    }

    /// 某个像素的 RGB 三通道之和（用于差异比较）。
    ///
    /// 直接下标访问：调用方在热点循环里，别在这里做边界判断带来的分支——
    /// 越界访问是编程错误，应当由调用方的循环边界保证。
    @inline(__always)
    func rgbSum(x: Int, y: Int) -> Int {
        let offset = (y * width + x) * 4
        return Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])
    }

    /// 某个像素三通道与另一个像素的绝对差之和。
    @inline(__always)
    func rgbDiff(x: Int, y: Int, other: ScrollshotImage, otherX: Int, otherY: Int) -> Int {
        let a = (y * width + x) * 4
        let b = (otherY * other.width + otherX) * 4
        let ad = data
        let bd = other.data
        return abs(Int(ad[a]) - Int(bd[b]))
            + abs(Int(ad[a + 1]) - Int(bd[b + 1]))
            + abs(Int(ad[a + 2]) - Int(bd[b + 2]))
    }
}
