//
//  WebPEncoder.swift
//  AnShotCapture
//
//  纯 Swift 无损 WebP（VP8L + VP8X + EXIF DPI）编码器，零第三方二进制依赖，严格 MIT 纯净。
//
//  ── 编码策略 ──────────────────────────────────────────────────
//  1. 严格遵守 RFC 9649（VP8L 无损位流 + RIFF Extended WebP 容器）：
//     - 单/双符号通道走 Simple Prefix Code（不透明 Alpha 通道仅占 11 bit）；
//     - 一般通道构建长度受限（≤15 bit）的 Canonical Huffman 树并用 Normal Code Length Code 写出；
//     - 内置轻量快速 LZ77（匹配左邻像素 distance=1 与上邻行像素 distance=width），
//       对桌面 UI 截图大片纯色与水平/垂直重复区域实现高无损压缩率；
//  2. 通过 `VP8X` + `EXIF` chunk 写入精确物理分辨率（XResolution/YResolution/ResolutionUnit=2），
//     确保 Retina 2x 截图导出 WebP 后在预览/浏览器/文档中保持 144 DPI 1:1 清晰度；
//  3. 超过 WebP VP8L 14-bit 尺寸上限（16384×16384）时返回明确错误，由上层安全降级为 PNG。
//

import CoreGraphics
import Foundation

/// 纯 Swift 无损 WebP 编码错误。
public enum WebPEncodingError: Error, LocalizedError, Sendable, Equatable {
    case invalidDimensions(width: Int, height: Int)
    case dimensionsExceedWebPLimit(width: Int, height: Int)
    case pixelExtractionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions(let w, let h):
            return "图像尺寸无效（\(w)×\(h)）"
        case .dimensionsExceedWebPLimit(let w, let h):
            return "图像尺寸（\(w)×\(h)）超出 WebP 16384px 规格上限"
        case .pixelExtractionFailed:
            return "无法提取图像 RGBA 像素缓冲"
        }
    }
}

/// 纯 Swift 无损 WebP（VP8L）编码器。
public enum WebPEncoder {

    /// WebP VP8L 规格允许的最大单边像素长度（14 bit：`0...16383` 对应 `1...16384`）。
    public static let maximumDimension = 16_384

    /// 将 `CGImage` 无损编码为包含 EXIF DPI 元数据的 WebP 二进制数据。
    ///
    /// - Parameters:
    ///   - image: 源位图（支持透明 Alpha 通道）。
    ///   - backingScale: 物理缩放因子（2x Retina 传 `2.0`，写入 144 DPI）。
    public static func encodeLossless(
        _ image: CGImage,
        backingScale: CGFloat = 1.0
    ) throws -> Data {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw WebPEncodingError.invalidDimensions(width: width, height: height)
        }
        guard width <= maximumDimension, height <= maximumDimension else {
            throw WebPEncodingError.dimensionsExceedWebPLimit(width: width, height: height)
        }

        let (rgba, hasAlpha) = try extractStraightRGBA(from: image)
        let vp8l = encodeVP8LPayload(rgba: rgba, width: width, height: height, hasAlpha: hasAlpha)
        let dpi = 72.0 * max(1.0, backingScale)
        let exif = makeEXIFChunkPayload(dpi: dpi)
        return buildExtendedWebPContainer(
            vp8lPayload: vp8l,
            exifPayload: exif,
            width: width,
            height: height,
            hasAlpha: hasAlpha
        )
    }

    // MARK: - 像素提取（直通非预乘 RGBA）

    /// 将任意像素格式的 `CGImage` 转为非预乘 8-bit RGBA 字节数组，保留透明像素真实色彩。
    private static func extractStraightRGBA(from image: CGImage) throws -> ([UInt8], Bool) {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        // macOS CoreGraphics 不支持直接创建 non-premultiplied RGBA 上下文，先渲染为 premultipliedLast，
        // 若检测到半透明像素再做精确反预乘（unpremultiply）以符合 VP8L 直通 Alpha 语义。
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else {
            throw WebPEncodingError.pixelExtractionFailed
        }

        var hasAlpha = false
        let pixelCount = width * height
        for idx in 0..<pixelCount {
            let offset = idx * 4
            let a = buffer[offset + 3]
            if a < 255 {
                hasAlpha = true
                if a == 0 {
                    buffer[offset] = 0
                    buffer[offset + 1] = 0
                    buffer[offset + 2] = 0
                } else {
                    let alphaInt = Int(a)
                    let half = alphaInt / 2
                    buffer[offset] = UInt8(min(255, (Int(buffer[offset]) * 255 + half) / alphaInt))
                    buffer[offset + 1] = UInt8(min(255, (Int(buffer[offset + 1]) * 255 + half) / alphaInt))
                    buffer[offset + 2] = UInt8(min(255, (Int(buffer[offset + 2]) * 255 + half) / alphaInt))
                }
            }
        }
        return (buffer, hasAlpha)
    }

    // MARK: - VP8L 比特流编码

    /// VP8L 编码符号单元：普通 ARGB 字面量，或基于前像素/上一行的反向引用拷贝。
    private enum Token {
        case literal(r: UInt8, g: UInt8, b: UInt8, a: UInt8)
        case copy(length: Int, distanceCode: Int, extraBits: Int, extraValue: Int)
    }

    private static func encodeVP8LPayload(
        rgba: [UInt8],
        width: Int,
        height: Int,
        hasAlpha: Bool
    ) -> Data {
        let tokens = tokenizeWithFastLZ77(rgba: rgba, width: width, height: height)

        // 统计 5 个通道的符号频率
        var greenFreq = [Int](repeating: 0, count: 280)
        var redFreq = [Int](repeating: 0, count: 256)
        var blueFreq = [Int](repeating: 0, count: 256)
        var alphaFreq = [Int](repeating: 0, count: 256)
        var distFreq = [Int](repeating: 0, count: 40)

        for token in tokens {
            switch token {
            case .literal(let r, let g, let b, let a):
                greenFreq[Int(g)] += 1
                redFreq[Int(r)] += 1
                blueFreq[Int(b)] += 1
                alphaFreq[Int(a)] += 1
            case .copy(let length, let distanceCode, _, _):
                let lenCode = prefixCode(forValue: length).code
                greenFreq[256 + lenCode] += 1
                distFreq[distanceCode] += 1
            }
        }

        let greenTree = PrefixCode.build(frequencies: greenFreq)
        let redTree = PrefixCode.build(frequencies: redFreq)
        let blueTree = PrefixCode.build(frequencies: blueFreq)
        let alphaTree = PrefixCode.build(frequencies: alphaFreq)
        let distTree = PrefixCode.build(frequencies: distFreq)

        var writer = LSBBitWriter(reserveCapacity: max(64, rgba.count / 4))

        // 1. VP8L Signature (0x2F) + 32-bit Header
        writer.writeBits(0x2F, count: 8)
        writer.writeBits(UInt64(width - 1), count: 14)
        writer.writeBits(UInt64(height - 1), count: 14)
        writer.writeBits(hasAlpha ? 1 : 0, count: 1)
        writer.writeBits(0, count: 3) // version_number = 0

        // 2. 无变换、无 Color Cache、单 Prefix Code 组（无 meta-prefix）
        writer.writeBits(0, count: 1) // no transforms
        writer.writeBits(0, count: 1) // no color cache
        writer.writeBits(0, count: 1) // no meta-prefix

        // 3. 写出 5 棵 Huffman 树
        greenTree.writeHeader(to: &writer)
        redTree.writeHeader(to: &writer)
        blueTree.writeHeader(to: &writer)
        alphaTree.writeHeader(to: &writer)
        distTree.writeHeader(to: &writer)

        // 4. 逐 Token 写入数据流
        for token in tokens {
            switch token {
            case .literal(let r, let g, let b, let a):
                greenTree.writeSymbol(Int(g), to: &writer)
                redTree.writeSymbol(Int(r), to: &writer)
                blueTree.writeSymbol(Int(b), to: &writer)
                alphaTree.writeSymbol(Int(a), to: &writer)
            case .copy(let length, let distanceCode, let distExtraBits, let distExtraValue):
                let lenEncoded = prefixCode(forValue: length)
                greenTree.writeSymbol(256 + lenEncoded.code, to: &writer)
                if lenEncoded.extraBits > 0 {
                    writer.writeBits(UInt64(lenEncoded.extraValue), count: lenEncoded.extraBits)
                }
                distTree.writeSymbol(distanceCode, to: &writer)
                if distExtraBits > 0 {
                    writer.writeBits(UInt64(distExtraValue), count: distExtraBits)
                }
            }
        }

        return writer.finalize()
    }

    /// 轻量快速 LZ77：检查紧邻左像素（scanline distance=1）与紧邻上像素（distance=width），
    /// 对 UI 纯色块与垂直重复列压缩极快且不引入高内存哈希表开销。
    private static func tokenizeWithFastLZ77(rgba: [UInt8], width: Int, height: Int) -> [Token] {
        let totalPixels = width * height
        var tokens: [Token] = []
        tokens.reserveCapacity(totalPixels / 2 + 16)

        // 预计算 scanline distance=1 与 distance=width 对应的 VP8L 2D 距离码：
        // 在 VP8L 中，1...120 保留给 2D 邻域表：
        //   - (dx=1, dy=0) 左邻像素在 2D 邻域表中的平面码为 2（对应 distance_plane = 2）；
        //   - (dx=0, dy=1) 上邻像素在 2D 邻域表中的平面码为 1（对应 distance_plane = 1）；
        // 因此无需转换复杂大距离，左邻=2、上邻=1 就是最短 0-extra-bit 编码！
        let leftDist = prefixCode(forValue: 2)   // 2D plane code 2 -> (dx=1, dy=0)
        let aboveDist = prefixCode(forValue: 1)  // 2D plane code 1 -> (dx=0, dy=1)
        let maxMatchLen = 4096

        var i = 0
        while i < totalPixels {
            let curOffset = i * 4
            var bestLen = 0
            var bestIsAbove = false

            // 1. 测试左邻像素重复（水平游程）
            if i > 0 {
                var len = 0
                let limit = min(maxMatchLen, totalPixels - i)
                while len < limit {
                    let a = (i + len) * 4
                    let b = (i + len - 1) * 4
                    if rgba[a] == rgba[b] && rgba[a + 1] == rgba[b + 1]
                        && rgba[a + 2] == rgba[b + 2] && rgba[a + 3] == rgba[b + 3] {
                        len += 1
                    } else {
                        break
                    }
                }
                if len >= 2 {
                    bestLen = len
                    bestIsAbove = false
                }
            }

            // 2. 测试正上方像素重复（垂直拷贝）
            if i >= width {
                var len = 0
                let limit = min(maxMatchLen, totalPixels - i)
                while len < limit {
                    let a = (i + len) * 4
                    let b = (i + len - width) * 4
                    if rgba[a] == rgba[b] && rgba[a + 1] == rgba[b + 1]
                        && rgba[a + 2] == rgba[b + 2] && rgba[a + 3] == rgba[b + 3] {
                        len += 1
                    } else {
                        break
                    }
                }
                if len > bestLen && len >= 2 {
                    bestLen = len
                    bestIsAbove = true
                }
            }

            if bestLen >= 2 {
                let d = bestIsAbove ? aboveDist : leftDist
                tokens.append(.copy(
                    length: bestLen,
                    distanceCode: d.code,
                    extraBits: d.extraBits,
                    extraValue: d.extraValue
                ))
                i += bestLen
            } else {
                tokens.append(.literal(
                    r: rgba[curOffset],
                    g: rgba[curOffset + 1],
                    b: rgba[curOffset + 2],
                    a: rgba[curOffset + 3]
                ))
                i += 1
            }
        }
        return tokens
    }

    /// RFC 9649 Section 3.5.2.2：长度与距离的 Prefix Code 编码规则（1-based 值）。
    private static func prefixCode(forValue value: Int) -> (code: Int, extraBits: Int, extraValue: Int) {
        if value <= 4 {
            return (value - 1, 0, 0)
        }
        let v = value - 1
        let msb = (Int.bitWidth - 1) - v.leadingZeroBitCount
        let extraBits = msb - 1
        let secondBit = (v >> extraBits) & 1
        let code = 2 * msb + secondBit
        let extraValue = v & ((1 << extraBits) - 1)
        return (code, extraBits, extraValue)
    }

    // MARK: - RIFF Extended WebP 容器与 EXIF DPI

    /// 构造标准 Little-Endian TIFF IFD0 EXIF 载荷，写入 `XResolution`、`YResolution` 与 `ResolutionUnit = 2 (inches)`。
    private static func makeEXIFChunkPayload(dpi: CGFloat) -> Data {
        let numerator = UInt32(max(1, Int((dpi * 100.0).rounded())))
        let denominator: UInt32 = 100

        var data = Data()
        data.reserveCapacity(66)

        // TIFF Header: "II" (Little-Endian) + 0x002A + Offset to IFD0 (8)
        data.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])
        appendLE32(8, to: &data)

        // IFD0: 3 个目录项（按 Tag 升序：0x011A, 0x011B, 0x0128）
        appendLE16(3, to: &data)
        // Value data offset = 8 (header) + 2 (count) + 3*12 (entries) + 4 (next IFD) = 50
        // Entry 1: XResolution (0x011A), RATIONAL (5), count 1, offset 50
        appendLE16(0x011A, to: &data)
        appendLE16(5, to: &data)
        appendLE32(1, to: &data)
        appendLE32(50, to: &data)

        // Entry 2: YResolution (0x011B), RATIONAL (5), count 1, offset 58
        appendLE16(0x011B, to: &data)
        appendLE16(5, to: &data)
        appendLE32(1, to: &data)
        appendLE32(58, to: &data)

        // Entry 3: ResolutionUnit (0x0128), SHORT (3), count 1, inline value 2 (inches)
        appendLE16(0x0128, to: &data)
        appendLE16(3, to: &data)
        appendLE32(1, to: &data)
        appendLE16(2, to: &data)
        appendLE16(0, to: &data)

        // Next IFD offset = 0
        appendLE32(0, to: &data)

        // Offset 50: XResolution rational
        appendLE32(numerator, to: &data)
        appendLE32(denominator, to: &data)

        // Offset 58: YResolution rational
        appendLE32(numerator, to: &data)
        appendLE32(denominator, to: &data)

        return data
    }

    private static func buildExtendedWebPContainer(
        vp8lPayload: Data,
        exifPayload: Data,
        width: Int,
        height: Int,
        hasAlpha: Bool
    ) -> Data {
        let vp8lPadded = vp8lPayload.count + (vp8lPayload.count & 1)
        let exifPadded = exifPayload.count + (exifPayload.count & 1)
        // RIFF payload = "WEBP"(4) + VP8X(8+10) + VP8L(8+vp8lPadded) + EXIF(8+exifPadded)
        let riffPayloadSize = 4 + 18 + (8 + vp8lPadded) + (8 + exifPadded)

        var out = Data()
        out.reserveCapacity(8 + riffPayloadSize)

        // RIFF Header
        out.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendLE32(UInt32(riffPayloadSize), to: &out)
        out.append(contentsOf: [0x57, 0x45, 0x42, 0x50]) // "WEBP"

        // VP8X Chunk
        out.append(contentsOf: [0x56, 0x50, 0x38, 0x58]) // "VP8X"
        appendLE32(10, to: &out)
        var flags: UInt8 = 0x08 // bit 3: EXIF chunk present
        if hasAlpha { flags |= 0x10 } // bit 4: Alpha present
        out.append(flags)
        out.append(contentsOf: [0x00, 0x00, 0x00]) // reserved 24 bits
        appendLE24(UInt32(width - 1), to: &out)
        appendLE24(UInt32(height - 1), to: &out)

        // VP8L Chunk
        out.append(contentsOf: [0x56, 0x50, 0x38, 0x4C]) // "VP8L"
        appendLE32(UInt32(vp8lPayload.count), to: &out)
        out.append(vp8lPayload)
        if vp8lPayload.count & 1 != 0 { out.append(0) }

        // EXIF Chunk
        out.append(contentsOf: [0x45, 0x58, 0x49, 0x46]) // "EXIF"
        appendLE32(UInt32(exifPayload.count), to: &out)
        out.append(exifPayload)
        if exifPayload.count & 1 != 0 { out.append(0) }

        return out
    }

    private static func appendLE16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendLE24(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
    }

    private static func appendLE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

// MARK: - LSB-First 比特写入器

private struct LSBBitWriter {
    private var bytes: [UInt8] = []
    private var bitBuffer: UInt64 = 0
    private var bitCount: Int = 0

    init(reserveCapacity: Int) {
        bytes.reserveCapacity(reserveCapacity)
    }

    mutating func writeBits(_ value: UInt64, count: Int) {
        guard count > 0 else { return }
        let mask: UInt64 = count == 64 ? ~0 : ((1 &<< UInt64(count)) &- 1)
        bitBuffer |= (value & mask) &<< UInt64(bitCount)
        bitCount += count
        while bitCount >= 8 {
            bytes.append(UInt8(bitBuffer & 0xFF))
            bitBuffer &>>= 8
            bitCount -= 8
        }
    }

    mutating func finalize() -> Data {
        if bitCount > 0 {
            bytes.append(UInt8(bitBuffer & 0xFF))
            bitBuffer = 0
            bitCount = 0
        }
        return Data(bytes)
    }
}

// MARK: - VP8L 规范前缀码（支持 Simple 与 Normal Code Length Code）

private struct PrefixCode {
    private enum Kind {
        case simpleOne(Int)
        case simpleTwo(Int, Int)
        case normal(lengths: [Int], reversedCodes: [UInt32])
    }

    private let kind: Kind

    private static let codeLengthOrder: [Int] = [
        17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    ]

    /// 根据符号频率表构建合法 VP8L 前缀码（单/双符号走 Simple，三符号以上走长度≤15的规范 Huffman）。
    static func build(frequencies: [Int]) -> PrefixCode {
        var activeSymbols: [Int] = []
        for (sym, freq) in frequencies.enumerated() where freq > 0 {
            activeSymbols.append(sym)
        }
        if activeSymbols.isEmpty {
            return PrefixCode(kind: .simpleOne(0))
        }
        if activeSymbols.count == 1, activeSymbols[0] < 256 {
            return PrefixCode(kind: .simpleOne(activeSymbols[0]))
        }
        if activeSymbols.count == 2, activeSymbols[0] < 256, activeSymbols[1] < 256 {
            return PrefixCode(kind: .simpleTwo(activeSymbols[0], activeSymbols[1]))
        }

        let lengths = buildLengthLimitedCodeLengths(frequencies: frequencies, maxBits: 15)
        let reversed = canonicalReversedCodes(from: lengths)
        return PrefixCode(kind: .normal(lengths: lengths, reversedCodes: reversed))
    }

    func writeHeader(to writer: inout LSBBitWriter) {
        switch kind {
        case .simpleOne(let s0):
            writer.writeBits(1, count: 1) // simple code
            writer.writeBits(0, count: 1) // 1 symbol
            if s0 < 2 {
                writer.writeBits(0, count: 1)
                writer.writeBits(UInt64(s0), count: 1)
            } else {
                writer.writeBits(1, count: 1)
                writer.writeBits(UInt64(s0), count: 8)
            }

        case .simpleTwo(let s0, let s1):
            writer.writeBits(1, count: 1) // simple code
            writer.writeBits(1, count: 1) // 2 symbols
            if s0 < 2 {
                writer.writeBits(0, count: 1)
                writer.writeBits(UInt64(s0), count: 1)
            } else {
                writer.writeBits(1, count: 1)
                writer.writeBits(UInt64(s0), count: 8)
            }
            writer.writeBits(UInt64(s1), count: 8)

        case .normal(let lengths, _):
            writer.writeBits(0, count: 1) // normal code length code
            writeNormalCodeLengths(lengths, to: &writer)
        }
    }

    func writeSymbol(_ symbol: Int, to writer: inout LSBBitWriter) {
        switch kind {
        case .simpleOne:
            return
        case .simpleTwo(let s0, _):
            writer.writeBits(symbol == s0 ? 0 : 1, count: 1)
        case .normal(let lengths, let reversedCodes):
            let len = lengths[symbol]
            writer.writeBits(UInt64(reversedCodes[symbol]), count: len)
        }
    }

    /// 按 RFC 9649 Section 3.5.2.3 用二级前缀码（RLE + 7-bit 限制码长）写出 Normal Code Length Code。
    private func writeNormalCodeLengths(_ lengths: [Int], to writer: inout LSBBitWriter) {
        // 1. 将码长序列做 RLE 压缩为 0...18 的符号流
        var rleSymbols: [(sym: Int, extraBits: Int, extraVal: Int)] = []
        rleSymbols.reserveCapacity(lengths.count)
        var i = 0
        var prevNonZero = 8
        while i < lengths.count {
            let len = lengths[i]
            if len == 0 {
                var run = 1
                while i + run < lengths.count && lengths[i + run] == 0 {
                    run += 1
                }
                var rem = run
                while rem > 0 {
                    if rem >= 11 {
                        let take = min(rem, 138)
                        rleSymbols.append((18, 7, take - 11))
                        rem -= take
                    } else if rem >= 3 {
                        let take = min(rem, 10)
                        rleSymbols.append((17, 3, take - 3))
                        rem -= take
                    } else {
                        rleSymbols.append((0, 0, 0))
                        rem -= 1
                    }
                }
                i += run
            } else {
                rleSymbols.append((len, 0, 0))
                prevNonZero = len
                i += 1
                var run = 0
                while i + run < lengths.count && lengths[i + run] == prevNonZero {
                    run += 1
                }
                var rem = run
                while rem >= 3 {
                    let take = min(rem, 6)
                    rleSymbols.append((16, 2, take - 3))
                    rem -= take
                }
                while rem > 0 {
                    rleSymbols.append((prevNonZero, 0, 0))
                    rem -= 1
                }
                i += run
            }
        }

        // 2. 统计 19 个二级码长符号频率并构建 ≤7 bit 的规范码长
        var clFreq = [Int](repeating: 0, count: 19)
        for item in rleSymbols {
            clFreq[item.sym] += 1
        }
        var clLengths = Self.buildLengthLimitedCodeLengths(frequencies: clFreq, maxBits: 7)
        // 如果只有 1 个二级码长符号（所有通道码长都相等，例如全 8-bit），规范要求至少给它 1 bit 码长。
        let nonZeroCL = clLengths.indices.filter { clLengths[$0] > 0 }
        if nonZeroCL.count == 1 {
            clLengths[nonZeroCL[0]] = 1
        }
        let clReversed = Self.canonicalReversedCodes(from: clLengths)

        // 3. 写出二级码长表的长度头（至少 4 个，尾部 0 可裁剪）
        var numCL = 19
        while numCL > 4 && clLengths[Self.codeLengthOrder[numCL - 1]] == 0 {
            numCL -= 1
        }
        writer.writeBits(UInt64(numCL - 4), count: 4)
        for k in 0..<numCL {
            writer.writeBits(UInt64(clLengths[Self.codeLengthOrder[k]]), count: 3)
        }

        // 4. use_max_symbol = 0（读取整个 alphabetSize），随后写出全部 RLE 符号
        writer.writeBits(0, count: 1)
        for item in rleSymbols {
            let bitLen = clLengths[item.sym]
            writer.writeBits(UInt64(clReversed[item.sym]), count: bitLen)
            if item.extraBits > 0 {
                writer.writeBits(UInt64(item.extraVal), count: item.extraBits)
            }
        }
    }

    /// 构建满足 Kraft 不等式且最大码长 `<= maxBits` 的规范 Huffman 码长数组。
    private static func buildLengthLimitedCodeLengths(frequencies: [Int], maxBits: Int) -> [Int] {
        let n = frequencies.count
        var lengths = [Int](repeating: 0, count: n)

        let active = frequencies.indices.filter { frequencies[$0] > 0 }
        if active.isEmpty { return lengths }
        if active.count == 1 {
            lengths[active[0]] = 1
            return lengths
        }

        // 构建经典最小堆 Huffman 树求初始深度
        struct Node {
            var weight: Int
            var symbol: Int // >=0 为叶节点，-1 为内部节点
            var left: Int
            var right: Int
        }
        var nodes: [Node] = []
        nodes.reserveCapacity(active.count * 2)
        var heap: [Int] = []
        heap.reserveCapacity(active.count)

        for sym in active {
            let idx = nodes.count
            nodes.append(Node(weight: frequencies[sym], symbol: sym, left: -1, right: -1))
            heap.append(idx)
        }

        func popMin() -> Int {
            var bestPos = 0
            for pos in 1..<heap.count {
                if nodes[heap[pos]].weight < nodes[heap[bestPos]].weight {
                    bestPos = pos
                }
            }
            return heap.remove(at: bestPos)
        }

        while heap.count > 1 {
            let a = popMin()
            let b = popMin()
            let parent = nodes.count
            nodes.append(Node(weight: nodes[a].weight + nodes[b].weight, symbol: -1, left: a, right: b))
            heap.append(parent)
        }

        // 递归计算每个叶节点深度
        var stack: [(idx: Int, depth: Int)] = [(heap[0], 0)]
        while let (idx, depth) = stack.popLast() {
            let node = nodes[idx]
            if node.symbol >= 0 {
                lengths[node.symbol] = max(1, depth)
            } else {
                stack.append((node.left, depth + 1))
                stack.append((node.right, depth + 1))
            }
        }

        // 若存在超过 maxBits 的深度，先钳制到 maxBits，再按 Kraft 和精确平衡回 `1 << maxBits`
        var overflow = false
        for sym in active where lengths[sym] > maxBits {
            lengths[sym] = maxBits
            overflow = true
        }
        if overflow {
            let targetKraft = 1 << maxBits
            func currentKraft() -> Int {
                active.reduce(0) { $0 + (1 << (maxBits - lengths[$1])) }
            }
            // 超支时拉长较短码（从低频的较短码开始）
            let sortedByFreqAsc = active.sorted { frequencies[$0] < frequencies[$1] }
            while currentKraft() > targetKraft {
                var adjusted = false
                for sym in sortedByFreqAsc where lengths[sym] < maxBits {
                    lengths[sym] += 1
                    adjusted = true
                    if currentKraft() <= targetKraft { break }
                }
                if !adjusted { break }
            }
            // 若有结余，缩短最高频的长码以填满 Kraft 树（避免未完全树报错）
            let sortedByFreqDesc = active.sorted { frequencies[$0] > frequencies[$1] }
            while currentKraft() < targetKraft {
                let gap = targetKraft - currentKraft()
                var shrunk = false
                for sym in sortedByFreqDesc where lengths[sym] > 1 {
                    let delta = 1 << (maxBits - lengths[sym])
                    if delta <= gap {
                        lengths[sym] -= 1
                        shrunk = true
                        break
                    }
                }
                if !shrunk { break }
            }
        }

        return lengths
    }

    /// 由规范码长数组生成每个符号用于 LSB-first 写入的位反转码字。
    private static func canonicalReversedCodes(from lengths: [Int]) -> [UInt32] {
        let maxLen = lengths.max() ?? 0
        var reversed = [UInt32](repeating: 0, count: lengths.count)
        guard maxLen > 0 else { return reversed }

        var blCount = [Int](repeating: 0, count: maxLen + 1)
        for len in lengths where len > 0 {
            blCount[len] += 1
        }

        var nextCode = [UInt32](repeating: 0, count: maxLen + 1)
        var code: UInt32 = 0
        for bits in 1...maxLen {
            code = (code + UInt32(blCount[bits - 1])) << 1
            nextCode[bits] = code
        }

        for (sym, len) in lengths.enumerated() where len > 0 {
            let canonical = nextCode[len]
            nextCode[len] += 1
            reversed[sym] = reverseBits(canonical, count: len)
        }
        return reversed
    }

    private static func reverseBits(_ value: UInt32, count: Int) -> UInt32 {
        var v = value
        var out: UInt32 = 0
        for _ in 0..<count {
            out = (out << 1) | (v & 1)
            v >>= 1
        }
        return out
    }
}
