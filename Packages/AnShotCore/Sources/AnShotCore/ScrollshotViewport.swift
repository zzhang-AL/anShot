import Foundation

/// 从两帧的运动范围与固定分隔线识别正文视口，不把固定栏带进拼接坐标。
public struct ScrollshotViewport: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 只有出现足够广泛的运动才确定视口；鼠标、光标和悬浮按钮不能触发裁剪。
    /// 没有可信的固定分隔线时保留原边界，不根据正文文字的包围框裁剪。
    public static func detect(previous: ScrollshotImage, next: ScrollshotImage) -> Self? {
        guard previous.width == next.width, previous.height == next.height else { return nil }
        let width = previous.width
        let height = previous.height
        let stepX = max(1, width / 96)
        let stepY = max(1, height / 128)
        let xs = Array(stride(from: 1, to: width - 1, by: stepX))
        let ys = Array(stride(from: 1, to: height - 1, by: stepY))
        guard xs.count >= 8, ys.count >= 8 else { return nil }
        var rowChanges = [Int](repeating: 0, count: ys.count)
        var columnChanges = [Int](repeating: 0, count: xs.count)
        previous.withPixels { p in
            next.withPixels { n in
                for (row, y) in ys.enumerated() {
                    for (column, x) in xs.enumerated() {
                        let offset = (y * width + x) * 4
                        if difference(p, offset, n, offset) > 30 {
                            rowChanges[row] += 1
                            columnChanges[column] += 1
                        }
                    }
                }
            }
        }
        let movingRows = ys.indices.filter { rowChanges[$0] >= 2 }
        let movingColumns = xs.indices.filter { columnChanges[$0] >= 3 }
        guard let firstRow = movingRows.first, let lastRow = movingRows.last,
              let firstColumn = movingColumns.first, let lastColumn = movingColumns.last,
              movingRows.count >= max(3, ys.count / 32),
              ys[lastRow] - ys[firstRow] >= height / 8,
              movingColumns.count >= xs.count / 8 else { return nil }
        let motionTop = ys[firstRow]
        let motionBottom = ys[lastRow]
        let motionLeft = xs[firstColumn]
        let motionRight = xs[lastColumn]

        return previous.withPixels { p in
            next.withPixels { n in
                // 分隔线必须横跨运动区域，且在两帧同一屏幕位置保持不变。
                // 文字前后的纯色留白不是分隔线，不能据此切掉尚未出现的宽正文。
                func verticalBoundary(_ x: Int) -> Bool {
                    let samples = ys.filter { $0 >= motionTop && $0 <= motionBottom }
                    let stableEdges = samples.filter { y in
                        let right = (y * width + x) * 4
                        let left = right - 4
                        return difference(p, left, p, right) >= 24
                            && difference(n, left, n, right) >= 24
                            && (difference(p, left, n, left) <= 9
                                || difference(p, right, n, right) <= 9)
                    }.count
                    return stableEdges * 4 >= samples.count * 3
                }
                func horizontalBoundary(_ y: Int) -> Bool {
                    let samples = xs.filter { $0 >= motionLeft && $0 <= motionRight }
                    let stableEdges = samples.filter { x in
                        let bottom = (y * width + x) * 4
                        let top = bottom - width * 4
                        return difference(p, top, p, bottom) >= 24
                            && difference(n, top, n, bottom) >= 24
                            && (difference(p, top, n, top) <= 9
                                || difference(p, bottom, n, bottom) <= 9)
                    }.count
                    return stableEdges * 4 >= samples.count * 3
                }
                func hasFixedTexture(xRange: Range<Int>, yRange: Range<Int>) -> Bool {
                    var features = 0
                    for y in stride(from: yRange.lowerBound + stepY, to: yRange.upperBound, by: stepY) {
                        for x in stride(from: xRange.lowerBound + stepX, to: xRange.upperBound, by: stepX) {
                            let pixel = (y * width + x) * 4
                            let contrast = max(
                                difference(p, pixel, p, pixel - stepX * 4),
                                difference(p, pixel, p, pixel - stepY * width * 4)
                            )
                            if contrast >= 30, difference(p, pixel, n, pixel) <= 9 {
                                features += 1
                                if features >= 6 { return true }
                            }
                        }
                    }
                    return false
                }
                // 图像或卡片也可能有直边；只有边外存在固定文字/按钮时才视为界面栏。
                let left = (1...motionLeft).last { x in
                    verticalBoundary(x)
                        && hasFixedTexture(xRange: 0..<x, yRange: motionTop..<(motionBottom + 1))
                } ?? 0
                var right = ((motionRight + 1)..<width).first { x in
                    verticalBoundary(x)
                        && hasFixedTexture(xRange: x..<width, yRange: motionTop..<(motionBottom + 1))
                } ?? width
                let top = (1...motionTop).last { y in
                    horizontalBoundary(y) && hasFixedTexture(xRange: 0..<width, yRange: 0..<y)
                } ?? 0
                let bottom = ((motionBottom + 1)..<height).first { y in
                    horizontalBoundary(y) && hasFixedTexture(xRange: 0..<width, yRange: y..<height)
                } ?? height
                // 叠加式滚动条没有贯穿整屏的分隔线；单独识别右缘窄、实心、
                // 灰度且只小幅上下移动的滑块，避免把它逐段贴进正文。
                if right == width, let edge = scrollbarEdge(
                    previous: p, next: n, width: width, height: height, top: top, bottom: bottom
                ) {
                    right = edge
                }
                // 视口必须仍能容纳运动范围；极小分隔区域不能成为正文。
                guard right - left >= width / 4, bottom - top >= height / 3 else {
                    return Self(x: 0, y: 0, width: width, height: height)
                }
                return Self(x: left, y: top, width: right - left, height: bottom - top)
            }
        }
    }

    /// 所有帧使用同一裁剪矩形，避免视口尺寸或坐标在采集中途漂移。
    public func crop(_ image: ScrollshotImage) -> ScrollshotImage? {
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= image.width, y + height <= image.height else { return nil }
        if x == 0, y == 0, width == image.width, height == image.height { return image }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let start = ((y + row) * image.width + x) * 4
            let destination = row * width * 4
            data.replaceSubrange(destination..<(destination + width * 4),
                                 with: image.data[start..<(start + width * 4)])
        }
        return ScrollshotImage(width: width, height: height, data: data)
    }

    private static func difference(
        _ a: UnsafeBufferPointer<UInt8>, _ ai: Int,
        _ b: UnsafeBufferPointer<UInt8>, _ bi: Int
    ) -> Int {
        abs(Int(a[ai]) - Int(b[bi])) + abs(Int(a[ai + 1]) - Int(b[bi + 1]))
            + abs(Int(a[ai + 2]) - Int(b[bi + 2]))
    }

    private static func scrollbarEdge(
        previous: UnsafeBufferPointer<UInt8>, next: UnsafeBufferPointer<UInt8>,
        width: Int, height: Int, top: Int, bottom: Int
    ) -> Int? {
        let margin = min(32, width / 20)
        guard margin >= 8, bottom > top else { return nil }
        func thumb(_ pixels: UnsafeBufferPointer<UInt8>) -> (x: Int, y: Int, endY: Int)? {
            var minX = width
            var maxX = 0
            var minY = bottom
            var maxY = top
            var count = 0
            for y in top..<bottom {
                let reference = (y * width + width - margin - 1) * 4
                for x in (width - margin)..<width {
                    let pixel = (y * width + x) * 4
                    guard abs(Int(pixels[pixel]) - Int(pixels[pixel + 1])) <= 8,
                          abs(Int(pixels[pixel]) - Int(pixels[pixel + 2])) <= 8,
                          difference(pixels, pixel, pixels, reference) > 60 else { continue }
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                    count += 1
                }
            }
            let thumbWidth = maxX - minX + 1
            let thumbHeight = maxY - minY + 1
            guard thumbWidth >= 4, thumbWidth <= margin - 2,
                  thumbHeight >= 8, thumbHeight <= height / 3,
                  count * 10 >= thumbWidth * thumbHeight * 7 else { return nil }
            return (minX, minY, maxY)
        }
        guard let a = thumb(previous), let b = thumb(next), abs(a.x - b.x) <= 2,
              max(a.endY - a.y, b.endY - b.y) >= max(24, height / 40) else { return nil }
        let movement = max(abs(a.y - b.y), abs(a.endY - b.endY))
        guard movement > 0, movement <= height / 12 else { return nil }
        return min(a.x, b.x)
    }

    /// 探测窗口底部左右圆角（及窗底阴影圆弧）所占的像素高度。
    ///
    /// macOS 窗口底部有 10~12pt（20~24px @2x）圆角，直接按满帧高拼接会把圆角底色/桌布黑角
    /// 带入长图中段接缝。本方法对比滚动前后两帧底部左右 `4...24px` 角区：
    /// 若角点在两帧间保持静止（不随内容滚动）且与紧邻上方正文内侧存在显著色彩突变（或透明 Alpha），
    /// 则返回探测到的圆角行高（上限 `24px`），供会话自动归入底帽安全区。
    public static func detectBottomCornerHeight(
        previous: ScrollshotImage,
        next: ScrollshotImage,
        maxRadius: Int = 24
    ) -> Int {
        guard previous.width == next.width,
              previous.height == next.height,
              previous.width >= 80,
              previous.height >= 80 else {
            return 0
        }
        let width = previous.width
        let height = previous.height
        let scan = min(maxRadius, min(width / 6, height / 6))
        guard scan >= 4 else { return 0 }

        return previous.withPixels { p in
            next.withPixels { n in
                // 检查左下与右下两个最外角点是否透明或相对内部正文静止突变。
                let refY = max(0, height - scan - 6)
                let leftRef = (refY * width + min(width - 1, scan + 4)) * 4
                let rightRef = (refY * width + max(0, width - scan - 5)) * 4

                func cornerBandRows(isRight: Bool) -> Int {
                    var rows = 0
                    for dy in 0..<scan {
                        let y = height - 1 - dy
                        let x = isRight ? (width - 1) : 0
                        let edgeIndex = (y * width + x) * 4
                        let innerX = isRight ? max(0, width - 1 - scan) : min(width - 1, scan)
                        let innerIndex = (y * width + innerX) * 4
                        let refIndex = isRight ? rightRef : leftRef

                        // 透明圆角（含 Alpha < 245）直接归入底角。
                        let isTransparentCorner = p[edgeIndex + 3] < 245 && n[edgeIndex + 3] < 245
                        // 不透明截屏下的桌面底角：边缘在两帧间完全静止且与窗口内部/参考背景色差显著。
                        let staticEdge = difference(p, edgeIndex, n, edgeIndex) <= 6
                        let contrastsInner = difference(p, edgeIndex, p, innerIndex) >= 24
                            && difference(p, edgeIndex, p, refIndex) >= 24
                        if isTransparentCorner || (staticEdge && contrastsInner) {
                            rows = dy + 1
                        } else if rows > 0 {
                            break
                        }
                    }
                    return rows
                }

                let leftRows = cornerBandRows(isRight: false)
                let rightRows = cornerBandRows(isRight: true)
                // 左右两侧均检测到圆角特征才采信，防止单侧恰好有深色按钮或滚动条误触发。
                guard leftRows >= 4, rightRows >= 4 else { return 0 }
                return min(scan, max(leftRows, rightRows))
            }
        }
    }
}
