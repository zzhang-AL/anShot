//
//  TextRecognizer.swift
//  AnShotCapture
//
//  文字识别：把图像交给 Vision，返回**模型坐标系**的结果。
//
//  ── 为什么封装在 Capture 而不是 Core ───────────────────────
//
//  `AnShotCore` 是不依赖平台框架的模型与算法层；Vision 属于平台能力，
//  与截屏、录屏同层。结果的模型与坐标转换都在 Core（`OCRText.swift`），
//  这里只负责「调一次 Vision 并按契约转换」。
//
//  ── 语言不硬编码 ──────────────────────────────────────────
//
//  各 macOS 版本支持的语言集不同（本机运行时查到 33 种，含 `zh-Hans`/`zh-Hant`，
//  但那是**本机的请求配置结果**，不代表其它机器）。因此语言在运行时查询后过滤：
//  优先中文简繁与英文，取不到就退回系统给出的全集。
//

import AnShotCore
import CoreGraphics
import CoreText
import Foundation
import Vision

/// 文字识别。
public enum TextRecognizer {

    /// 识别不可用的原因。
    public enum Failure: Error, LocalizedError {
        /// 请求执行失败。
        case requestFailed(String)
        /// 结果转换失败（图像尺寸非法等）。
        case invalidImage

        public var errorDescription: String? {
            switch self {
            case let .requestFailed(reason): return "文字识别失败：\(reason)"
            case .invalidImage: return "图像尺寸非法"
            }
        }
    }

    /// 本机识别能力（运行时查询）。
    public struct Availability: Sendable {
        /// 当前识别级别支持的语言标识。
        public let supportedLanguages: [String]
        /// 实际请求会使用的语言（按优先级从支持列表里挑出来的）。
        public let preferredLanguages: [String]

        /// 是否支持中文（简或繁）。
        public var supportsChinese: Bool {
            supportedLanguages.contains { $0.hasPrefix("zh") }
        }
    }

    /// 我们希望优先使用的语言。**只是偏好**，会和运行时支持列表取交集。
    private static let preferredLanguageIdentifiers = ["zh-Hans", "zh-Hant", "en-US"]

    /// 缓存的识别能力查询结果。
    ///
    /// `supportedRecognitionLanguages` 首次要 6.7ms、之后 0.1ms，单看并不慢；
    /// 但它**每次 `recognize` 都会被问一遍**，而调用方在 MainActor 上——
    /// 也就是说这几毫秒以及任何版本相关的抖动，都是结结实实卡在主线程上的。
    /// 语言集在运行期不会变，所以缓存的代价是零。
    /// （`static let` 自带一次性、线程安全的懒惰初始化。）
    private static let cachedAvailability: Availability = {
        // 用实例方法而不是已弃用的类方法。
        //
        // `VNRecognizeTextRequest.supportedRecognitionLanguages(for:revision:)`
        // 自 macOS 12 起被弃用；SDK 头文件中的 `API_DEPRECATED_WITH_REPLACEMENT`
        // 指向 `-supportedRecognitionLanguagesAndReturnError:`（Swift 侧即实例方法
        // `supportedRecognitionLanguages()`，**同步 throws**，非 async）。
        //
        // 与旧调用的等价条件：新 API 读的是 **request 自身的配置**
        //（“based on its current state of configuration”），
        // 所以必须先把 recognitionLevel 与 revision 设成与旧调用相同的值。
        // 实测等价：本机两者均返回 33 项，顺序与内容完全一致，均含 zh。
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = VNRecognizeTextRequestRevision3
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let preferred = preferredLanguageIdentifiers.filter { supported.contains($0) }
        return Availability(
            supportedLanguages: supported,
            preferredLanguages: preferred.isEmpty ? supported : preferred
        )
    }()

    /// 查询本机识别能力。UI 用它决定是否显示中文相关提示、以及语言数量。
    public static func availability() -> Availability {
        cachedAvailability
    }

    /// 预热：把 Vision 的一次性加载成本从「用户第一次点识别」挪到后台。
    ///
    /// 本机实测（Apple Silicon）：
    ///
    /// | 场景 | 耗时 |
    /// | --- | --- |
    /// | 进程内第一次识别（小图 240x60 也一样） | **约 13.7 秒** |
    /// | 同一进程第二次 | 约 140ms |
    /// | 进程内第一次处理 3840x2160 | 约 13.3 秒 |
    /// | 之后的 3840x2160 | 约 550ms |
    ///
    /// 十几秒里绝大部分是**模型与计算图的加载/编译**，与图像大小基本无关：
    /// 喂一张 240x60 的小图同样要 13.7 秒。这笔成本只需付一次，
    /// 但在此之前没人先付，于是它一直由用户的第一次点击承担——
    /// 而那时界面上毫无动静，看起来就是「按了没反应」。
    ///
    /// 这里刻意用一张很小的图：既然成本与尺寸无关，喂大图只会更慢。
    /// 预热失败不影响任何主流程（结果被丢弃）。
    public static func prewarm() async {
        guard let image = sampleImage() else { return }
        _ = try? await recognize(in: image)
    }

    /// 一张带文字的小图（白底 + 一行英文）。
    ///
    /// 两个用途，共同点是「需要一张确定的、确实有文字的图」：
    /// - `prewarm()` 预热识别能力；
    /// - 设置界面的「测试连接」按钮拿它做一次真实识别。
    ///
    /// 不画文字而留白的话，Vision 有可能走「图里没有文本」的捷径，
    /// 预热会变成空转——模型根本没加载。
    public static func sampleImage() -> CGImage? {
        let width = 240
        let height = 60
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let attributed = NSAttributedString(
            string: "prewarm",
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
        )
        context.textPosition = CGPoint(x: 12, y: 18)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        return context.makeImage()
    }

    /// 识别图中的文字。
    ///
    /// - Parameters:
    ///   - image: 待识别的图像（像素尺寸即结果包围盒的参照系）。
    ///   - languages: 指定语言；nil 表示用 `availability()` 挑出的偏好集。
    /// - Returns: 按阅读顺序排好的结果，包围盒为**模型坐标系（像素、原点左上）**。
    public static func recognize(
        in image: CGImage,
        languages: [String]? = nil
    ) async throws -> OCRResult {
        let pixelSize = PixelSize(width: Double(image.width), height: Double(image.height))
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            throw Failure.invalidImage
        }
        let chosen = languages ?? availability().preferredLanguages

        // Vision 的请求执行是同步阻塞的，放到后台执行，避免卡住主线程
        //（整屏识别是几百毫秒量级）。
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if !chosen.isEmpty {
                request.recognitionLanguages = chosen
            }
            // 自动语言检测是 macOS 13.0+，恰在基线内；它能让中英混排不必手动切换。
            request.automaticallyDetectsLanguage = true

            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                throw Failure.requestFailed(String(describing: error))
            }

            let observations = request.results ?? []
            let lines: [OCRTextLine] = observations.compactMap { observation in
                let candidates = observation.topCandidates(3)
                guard let best = candidates.first else { return nil }
                return OCRTextLine(
                    text: best.string,
                    candidates: candidates.map(\.string),
                    confidence: Double(best.confidence),
                    // 坐标转换只在模型边界做一次（契约 §4.2）。
                    boundingBox: OCRCoordinateConversion.pixelRect(
                        normalized: observation.boundingBox,
                        imagePixelSize: pixelSize
                    )
                )
            }
            return OCRResult(
                lines: OCRResult.readingOrder(lines),
                imagePixelSize: pixelSize
            )
        }.value
    }
}
