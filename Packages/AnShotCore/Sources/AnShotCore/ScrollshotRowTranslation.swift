/// 用有纹理的多行签名投票产生位移候选；重复签名与竞争峰不能提供唯一位置。
/// 只适用于截图的整数竖直平移，候选还必须通过独立的移动内容校验。
enum ScrollshotRowTranslation {
    struct Estimate {
        let delta: Int
        let votes: Int
        let rivalVotes: Int
    }

    static func estimate(
        previous: ScrollshotImage, next: ScrollshotImage, options: VerticalOverlap.Options
    ) -> Estimate? {
        guard previous.width == next.width, previous.height == next.height else { return nil }
        let width = previous.width
        let height = previous.height
        let top = max(1, options.ignoreTopRows)
        let left = max(1, options.ignoreLeftColumns)
        // 窗口右侧滚动条不以正文速度移动，不能参与行签名。
        let right = width - max(options.ignoreRightColumns, min(32, width / 20))
        guard right - left >= 16, height - top >= 16 else { return nil }
        let columns = Array(stride(from: left, to: right, by: max(1, (right - left) / 96)))
        func signatures(_ image: ScrollshotImage) -> [UInt64: [Int]] {
            image.withPixels { pixels in
                var result: [UInt64: [Int]] = [:]
                for y in top..<(height - 1) {
                    var hash: UInt64 = 14695981039346656037
                    var minimum = 255
                    var maximum = 0
                    for row in (y - 1)...(y + 1) {
                        for x in columns {
                            let offset = (row * width + x) * 4
                            let value = (Int(pixels[offset]) + Int(pixels[offset + 1])
                                + Int(pixels[offset + 2])) / 3
                            minimum = min(minimum, value)
                            maximum = max(maximum, value)
                            hash = (hash ^ UInt64(value / 16)) &* 1099511628211
                        }
                    }
                    // 背景、空行和纯色固定带不产生特征。
                    guard maximum - minimum >= 32 else { continue }
                    // 保留一个超限标记，不能截断后把高度重复的签名误认为独特。
                    if result[hash, default: []].count <= 8 { result[hash, default: []].append(y) }
                }
                return result
            }
        }
        let previousRows = signatures(previous)
        let nextRows = signatures(next)
        let maxDelta = Int((Double(height - top) * (1 - options.minOverlapRatio)).rounded())
        let minDelta = max(0, Int((Double(height - top) * (1 - options.maxOverlapRatio)).rounded()))
        var votes: [Int: Set<Int>] = [:]
        for (signature, fromRows) in previousRows where fromRows.count <= 8 {
            guard let toRows = nextRows[signature], toRows.count <= 8 else { continue }
            for from in fromRows {
                for to in toRows {
                    let delta = from - to
                    guard abs(delta) >= minDelta, abs(delta) <= maxDelta else { continue }
                    votes[delta, default: []].insert(to)
                }
            }
        }
        let ranked = votes.sorted {
            $0.value.count == $1.value.count ? abs($0.key) < abs($1.key) : $0.value.count > $1.value.count
        }
        guard let winner = ranked.first, winner.key != 0, winner.value.count >= 8 else { return nil }
        let rival = ranked.first { abs($0.key - winner.key) > 2 }?.value.count ?? 0
        // 周期文本中票数接近的多个峰代表歧义，保留原有保守求解路径。
        guard winner.value.count >= rival + 4, winner.value.count * 2 >= rival * 3 else { return nil }
        return Estimate(delta: winner.key, votes: winner.value.count, rivalVotes: rival)
    }
}
