import Foundation

/// 局部纹理块只在同一列内匹配，再由有符号位移投票确定滚动量。
/// 固定侧栏不参与投票，局部浮层也不会使整行正文特征失效。
enum ScrollshotFeatureTranslation {
    struct Estimate {
        let delta: Int
        let votes: Int
        let rivalVotes: Int
    }

    private struct Support {
        var cells: Set<Int> = []
        var rows: Set<Int> = []
        var columns: Set<Int> = []
    }

    static func estimate(
        previous: ScrollshotImage, next: ScrollshotImage, options: VerticalOverlap.Options
    ) -> Estimate? {
        guard previous.width == next.width, previous.height == next.height else { return nil }
        let top = max(2, options.ignoreTopRows)
        let left = max(1, options.ignoreLeftColumns)
        let right = previous.width - max(1, options.ignoreRightColumns)
        let bottom = previous.height - 2
        guard right - left >= 24, bottom - top >= 16 else { return nil }
        let columns = Array(stride(from: left, to: right - 23, by: max(16, (right - left) / 48)))
        let maxDelta = Int((Double(previous.height - top) * (1 - options.minOverlapRatio)).rounded())
        let minDelta = max(1, Int((Double(previous.height - top) * (1 - options.maxOverlapRatio)).rounded()))
        var votes: [Int: Support] = [:]

        previous.withPixels { p in
            next.withPixels { n in
                func signatures(
                    _ pixels: UnsafeBufferPointer<UInt8>, _ other: UnsafeBufferPointer<UInt8>, x: Int
                ) -> [UInt64: [Int]] {
                    var result: [UInt64: [Int]] = [:]
                    for y in top..<bottom {
                        var hash: UInt64 = 14695981039346656037
                        var minimum = 255
                        var maximum = 0
                        var changed = 0
                        for row in [y - 2, y, y + 2] {
                            for column in stride(from: x, through: x + 21, by: 3) {
                                let index = (row * previous.width + column) * 4
                                let value = (Int(pixels[index]) + Int(pixels[index + 1])
                                    + Int(pixels[index + 2])) / 3
                                minimum = min(minimum, value)
                                maximum = max(maximum, value)
                                let difference = abs(Int(pixels[index]) - Int(other[index]))
                                    + abs(Int(pixels[index + 1]) - Int(other[index + 1]))
                                    + abs(Int(pixels[index + 2]) - Int(other[index + 2]))
                                if difference > 30 { changed += 1 }
                                hash = (hash ^ UInt64(value / 16)) &* 1099511628211
                            }
                        }
                        guard maximum - minimum >= 32, changed >= 3 else { continue }
                        // 高度重复的字形不具备唯一位置；保留超限标记，不能截断成独特特征。
                        if result[hash, default: []].count <= 4 { result[hash, default: []].append(y) }
                    }
                    return result
                }

                for (column, x) in columns.enumerated() {
                    let from = signatures(p, n, x: x)
                    let to = signatures(n, p, x: x)
                    for (signature, sourceRows) in from where sourceRows.count <= 4 {
                        guard let targetRows = to[signature], targetRows.count <= 4 else { continue }
                        for source in sourceRows {
                            for target in targetRows {
                                let delta = source - target
                                guard abs(delta) >= minDelta, abs(delta) <= maxDelta else { continue }
                                // 同一小块只算一票，避免一个字的多条扫描线淹没其他证据。
                                let row = target / 8
                                votes[delta, default: Support()].cells.insert(row * columns.count + column)
                                votes[delta, default: Support()].rows.insert(row)
                                votes[delta, default: Support()].columns.insert(column)
                            }
                        }
                    }
                }
            }
        }
        let ranked = votes.sorted {
            $0.value.cells.count == $1.value.cells.count
                ? abs($0.key) < abs($1.key) : $0.value.cells.count > $1.value.cells.count
        }
        guard let winner = ranked.first,
              winner.value.cells.count >= 12, winner.value.rows.count >= 4,
              winner.value.columns.count >= 2 else { return nil }
        let rival = ranked.first { abs($0.key - winner.key) > 2 }?.value.cells.count ?? 0
        let count = winner.value.cells.count
        guard count >= rival + 6, count * 2 >= rival * 3 else { return nil }
        return Estimate(delta: winner.key, votes: count, rivalVotes: rival)
    }
}
