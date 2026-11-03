//
//  VisionRegistrar.swift
//  AnShotCore
//
//  用 Apple Vision 的平移配准，为相邻两帧求一个**二维信号级**的位移候选。
//
//  ── 它解决什么问题 ────────────────────────────────────────
//
//  `VerticalOverlap` 是「抽若干列 × 若干行、加权逐点比差」的评分器。这在
//  照片、图标、多列排版这类内容上又快又准，但在**相邻行看起来几乎一样**的
//  内容上有一个结构性弱点：终端、代码、聊天记录、规则表格里，一屏文字的行
//  与上一行本就相似，于是若干相差一个行距的候选会同时拿到很低的误差——
//  评分器可能选中「局部合理、整体错误」的那一个，而位移方向反了就会让拼接
//  把已覆盖的内容再贴一遍。
//
//  Vision 把整帧当作**二维信号**处理，不逐行独立打分，因此不会 snap 到这种
//  错误候选。这正是用它处理终端/代码类内容的理由。
//
//  ── 为什么只当「候选」而不是「真相」 ──────────────────────
//
//  两个理由：
//
//  1. **它没有置信度**。`VNImageTranslationAlignmentObservation` 只给出一个
//     transform，成功与失败长得一样。而「这块内容到底配准得可信吗」正是
//     `VerticalOverlap` 唯一比它强的地方（分离度 / 证据量 / 匹配率）。
//  2. **它慢一个数量级**：实测内核 1.3ms、Vision 17–40ms。会话按 8Hz 采样，
//     不可能每帧都跑。
//
//  所以分工是：**Vision 出候选，`VerticalOverlap` 的评分函数判优劣**。
//  仲裁逻辑在 `VerticalOverlap.estimate` 里。
//
//  ── 为什么输入要先裁 ──────────────────────────────────────
//
//  两类区域会污染二维配准，且都是实测过的：
//
//  | 区域 | 行为 | 后果 |
//  |---|---|---|
//  | 滚动条 | 随滚动移动，但速度与内容不同 | 配准「取两者折中」，报出偏小的位移 |
//  | 吸顶栏 / 固定底栏 | 完全不动 | 同样被当成证据，把位移往 0 拉 |
//
//  裁掉顶部与底部若干行、右侧若干列即可。**两帧必须用同一份裁剪矩形**，
//  这样 Vision 报出的 ty 就是内容自身的位移，可以直接用。
//

import CoreGraphics
import Foundation
import Vision

/// Vision 平移配准的封装。
public enum VisionRegistrar {

    /// 一次配准的结果。
    public struct Estimate: Sendable {
        /// 有符号位移（像素）。
        ///
        /// 与 `VerticalOverlap` 的约定一致：**正 = 内容上移 = 用户向下滚**，
        /// 负 = 内容下移 = 用户向上回滚。
        public let deltaY: Int

        /// Vision 报出的原始位移（未取整），用于诊断与亚像素判断。
        public let rawShift: Double
    }

    /// 求解 `previous → next` 的竖直位移。
    ///
    /// - Parameters:
    ///   - topCrop: 从顶部裁掉的行数（吸顶栏）。会被限制在帧高的 1/5 以内。
    ///   - bottomCrop: 从底部裁掉的行数（固定底栏）。
    ///   - rightCrop: 从右侧裁掉的列数（滚动条）。
    /// - Returns: 求解失败（裁剪后过小、Vision 无结果、图像无法导出）时返回 nil。
    public static func estimate(
        previous: ScrollshotImage,
        next: ScrollshotImage,
        topCrop: Int = 0,
        bottomCrop: Int = 0,
        rightCrop: Int = 0
    ) -> Estimate? {
        let width = min(previous.width, next.width)
        let height = min(previous.height, next.height)
        guard width > 0, height > 0 else { return nil }

        // 裁剪量各自限制在 1/5 以内：裁太多会把「还有位移可解」的区域也切掉。
        let cropTop = min(max(0, topCrop), height / 5)
        let cropBottom = min(max(0, bottomCrop), height / 5)
        let cropHeight = height - cropTop - cropBottom
        let cropWidth = max(0, width - max(0, rightCrop))

        // Vision 对太小的输入会直接失败；50×50 是保险下限。
        guard cropWidth >= 50, cropHeight >= 50 else { return nil }

        guard let previousImage = previous.makeCGImage(),
              let nextImage = next.makeCGImage() else { return nil }

        // 两帧共用同一矩形，所以 ty 是内容位移本身。
        let rect = CGRect(x: 0, y: cropTop, width: cropWidth, height: cropHeight)
        let visionPrevious = previousImage.cropping(to: rect) ?? previousImage
        let visionNext = nextImage.cropping(to: rect) ?? nextImage

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: visionPrevious)
        let handler = VNImageRequestHandler(cgImage: visionNext, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }

        // 约定核对：`ty` 是把 next 对齐到 previous 所需的上移量。页面向下滚动
        // 时 next 顶部露出的新内容在下方，`ty` 为正——与 `deltaY` 同号。
        let shift = Double(observation.alignmentTransform.ty)
        return Estimate(deltaY: Int(shift.rounded()), rawShift: shift)
    }
}
