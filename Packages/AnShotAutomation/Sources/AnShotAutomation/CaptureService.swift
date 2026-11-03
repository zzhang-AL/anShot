//
//  CaptureService.swift
//  AnShotAutomation
//
//  截图执行的唯一入口。CLI 与 MCP 都调用这里，不各自实现一遍。
//
//  ── 职责边界 ─────────────────────────────────────────────────
//
//  本类型**不产生任何新的捕获语义**：
//
//      范围解析        → `CaptureParameters.validate()`（复用 DisplayGeometry）
//      抓帧            → `CapturerFactory.makeDefault()`（与 GUI 同一条管线）
//      PNG 编码        → `AnShotCapture.ImageEncoding`
//
//  它只负责「把请求串起来」，以及串的过程中三件确实新增的事：
//  权限预检的**可操作报错**、输出尺寸的**上限裁切**、
//  以及**并发安全的落盘**。
//
//  ── 为什么权限预检在这里而不只依赖捕获层 ─────────────────────
//
//  `CaptureSetup.requirePermission()` 也会查权限，但它抛出的
//  `CaptureError.permissionDenied` 只说「缺权限」，不说「下一步怎么办」。
//  而自动化场景下这个信息是**必需**的：被授权的对象往往不是 anShot.app，
//  调用方不可能自己推断出来。故在进入捕获前先拦一次，给出可操作指引。
//

import AnShotCapture
import AnShotCore
import CoreGraphics
import Foundation
import ImageIO

/// 截图结果。
public struct CaptureOutcome: Sendable {

    /// 图像（可能已按 `maxLongEdge` 缩小）。
    public let image: CGImage

    /// PNG 编码后的数据。
    public let pngData: Data

    /// 来源显示器。
    public let displayID: CGDirectDisplayID

    /// 捕获时该显示器的缩放系数。
    public let scaleFactor: CGFloat

    /// 本次实际生效的采样区域（显示器内逻辑点）。整屏与窗口截图时为 `nil`。
    public let region: CGRect?

    /// 请求指定的桌面 ID；普通截图为 nil。
    public let spaceID: UInt64?

    /// 窗口来源。整屏 / 区域截图时为 `nil`。
    ///
    /// 带着它一路走到 JSON 与 MCP 元数据的理由：调用方（AI）需要知道
    /// 「这张图到底属于哪个窗口」才能把结论与它看到的界面连起来，
    /// 而窗口在截图之后可能已经关闭或改名，事后再查是不可靠的。
    public let window: WindowCaptureInfo?

    /// 落盘路径。未请求落盘时为 `nil`。
    public let savedURL: URL?

    /// 输出像素尺寸（缩放**之后**）。
    public var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    /// 原图像素尺寸（缩放**之前**）。
    public let sourcePixelSize: CGSize

    /// 返回仅替换 `savedURL` 的副本。
    ///
    /// 跨进程路径需要它：截图由子实例完成（所以当时没有落盘），落盘由父进程
    /// 补上，而本类型的字段都是 `let`。
    func withSavedURL(_ url: URL?) -> CaptureOutcome {
        CaptureOutcome(
            image: image,
            pngData: pngData,
            displayID: displayID,
            scaleFactor: scaleFactor,
            region: region,
            spaceID: spaceID,
            window: window,
            savedURL: url,
            sourcePixelSize: sourcePixelSize
        )
    }
}

/// 截图服务。
public enum CaptureService {

    /// 输出像素总数上限。
    ///
    /// 为何需要它：`max_size` 只限制**长边**，而 `max_size: 0` 表示不缩放，
    /// 于是「一张 6K 全屏图」在所有校验下都是合法的——它也确实应当合法。
    /// 但若某天接了更大的屏、或区域被拼得异常宽，后续的 CGContext 与 PNG
    /// 编码就会在不知哪一步变成内存灾难。
    ///
    /// 取值 4000 万像素：略大于 8K（7680×4320 = 3320 万），
    /// 足以覆盖真实使用中的任何单帧截图，又足以拦住无意义的巨图。
    public static let maximumOutputPixels = 40_000_000


    /// 执行一次截图。
    ///
    /// - Parameter parameters: 请求参数。内部会先校验。
    /// - Throws: `AutomationError` / `ImageScalingError`
    /// - Parameters:
    ///   - parameters: 请求参数。内部会先校验。
    ///   - reservedOutputPaths: **不得**被本次截图占用的路径（已规范化）。
    ///     CLI 用它把 `--json-out` 的目标排除在 PNG 的候选名之外，否则会出现：
    ///     `--out shot.png --json-out shot-2.png`，而 `shot.png` 已存在
    ///     → PNG 排他到 `shot-2.png` → 报告再覆盖掉它。
    public static func capture(
        _ parameters: CaptureParameters,
        reservedOutputPaths: Set<String> = []
    ) async throws -> CaptureOutcome {
        let target = try parameters.resolveTarget()

        // 权限预检。放在构造 scope 之前：无权限时后续每一步都会失败，
        // 早失败可以省掉一次 `SCShareableContent` 查询。
        try requirePermission()

        let captured: CaptureOutcome
        do {
            captured = try await DesktopCaptureCoordinator.capture(
                spaceID: parameters.spaceID,
                displayID: target.displayID,
                allowSwitch: parameters.allowDesktopSwitch
            ) {
                let frame = try await CapturerFactory.makeDefault().captureFrame(scope: target.scope)
                // ScreenCaptureKit 图像可能引用系统复用的表面；恢复桌面前先编码快照，
                // 避免切回时读取到过渡画面。
                return try prepareOutcome(frame: frame, parameters: parameters, target: target)
            }
        } catch let error as AutomationError {
            throw error
        } catch let error as CaptureError {
            throw mapCaptureError(error, displayID: target.displayID)
        } catch {
            throw AutomationError.captureFailed(String(describing: error))
        }

        // 文件写入在恢复完成后执行，避免恢复失败时留下看似成功的产物。
        guard let path = parameters.savePath, !path.isEmpty else { return captured }
        return captured.withSavedURL(try save(captured.pngData, to: path, reservedPaths: reservedOutputPaths))
    }

    /// 在目标桌面仍处于活动状态时完成像素快照和编码。
    private static func prepareOutcome(
        frame: CapturedFrame,
        parameters: CaptureParameters,
        target: ResolvedCaptureTarget
    ) throws -> CaptureOutcome {
        let sourcePixelSize = frame.pixelSize

        // 缩放失败会抛出，不回退到超限原图（理由见 ImageScaling 的文件头）。
        let outputImage: CGImage
        do {
            outputImage = try ImageScaling.downscale(
                frame.image,
                maxLongEdge: parameters.resolvedMaxLongEdge
            )
        } catch let error as ImageScalingError {
            throw AutomationError.outputFailed(error.localizedDescription)
        }

        // 缩放之后才检查像素总数：这才是真正要被编码与传输的尺寸。
        let outputPixels = outputImage.width * outputImage.height
        guard outputPixels <= Self.maximumOutputPixels else {
            throw AutomationError.invalidArgument(
                "输出图像过大：\(outputImage.width)×\(outputImage.height) = "
                + "\(outputPixels) 像素，超过上限 \(Self.maximumOutputPixels)。"
                + "请缩小 region，或设置 max_size（如 2560）限制长边。"
            )
        }

        let pngData: Data
        do {
            pngData = try ImageEncoding.data(from: outputImage, format: .png)
        } catch {
            throw AutomationError.outputFailed(
                "PNG 编码失败：\(error.localizedDescription)"
            )
        }

        let stableImage: CGImage
        if parameters.spaceID != nil {
            guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw AutomationError.outputFailed("无法读取已编码的桌面截图。")
            }
            stableImage = decoded
        } else {
            stableImage = outputImage
        }

        return CaptureOutcome(
            image: stableImage,
            pngData: pngData,
            displayID: frame.displayID,
            scaleFactor: frame.scaleFactor,
            // 区域取自已校验的范围：窗口与整屏都为 nil，只有「显示器 + 区域」有值。
            region: target.scope.regionRect,
            spaceID: parameters.spaceID,
            window: frame.window,
            savedURL: nil,
            sourcePixelSize: sourcePixelSize
        )
    }

    // MARK: - 落盘

    /// 把已编码的 PNG 落盘，返回实际写入的路径。
    ///
    /// 单独暴露的理由：跨进程截图时，图片由子实例产生、落盘由父进程完成。
    /// 两条路径必须共用**同一套**排他编号与保留路径逻辑，否则
    /// 「PNG 排他到报告路径上、报告再把它覆盖掉」这个已经修过的缺陷
    /// 会在跨进程路径上重新出现，而且同样不报错、退出码还是 0。
    ///
    /// - Parameters:
    ///   - pngData: 已编码的 PNG 字节。
    ///   - savePath: 期望路径，支持 `~`。若已存在则自动追加 `-2`、`-3`…。
    ///   - reservedPaths: 视为已占用的路径（已规范化），用于保护结果 JSON。
    public static func save(
        _ pngData: Data,
        to savePath: String,
        reservedPaths: Set<String> = []
    ) throws -> URL {
        let requested = URL(fileURLWithPath: (savePath as NSString).expandingTildeInPath)
        return try writeExclusively(
            pngData,
            desiredURL: requested,
            reservedPaths: reservedPaths
        )
    }

    // MARK: - 权限

    /// 权限预检，失败时给出可操作指引。
    ///
    /// **不调用** `CGRequestScreenCaptureAccess()`：那会弹系统对话框，
    /// 而自动化场景下这个弹窗出现在**用户的桌面**上，调用方（AI）
    /// 既看不到也无法应答，只会得到一个静默挂起的进程。
    /// 因此这里只做无副作用的 preflight，把动作交给用户。
    private static func requirePermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw AutomationError.permissionDenied
        }
    }

    /// 把捕获层错误翻译成自动化层的可操作错误。
    private static func mapCaptureError(
        _ error: CaptureError,
        displayID: CGDirectDisplayID
    ) -> AutomationError {
        switch error {
        case .permissionDenied:
            return .permissionDenied

        case .displayUnavailable:
            return .displayUnavailable(displayID)

        case .emptyResult:
            return .emptyRegion

        case .unsupportedScope(let detail):
            // 单帧实现只接受「显示器 / 区域 / 单个窗口」。走到这里说明
            // 上层构造的范围与捕获层支持范围不一致（编程错误）。
            return .invalidArgument("请求的范围不受支持：\(detail)")

        case .scopeUnavailable:
            // CoreGraphics 能枚举的窗口不一定能被 ScreenCaptureKit 共享。
            // 窗口可能已关闭、隐藏或最小化，也可能被系统拒绝共享。
            return .windowUnavailable(
                "系统未提供目标窗口的可捕获内容。窗口可能已关闭、最小化或隐藏，"
                + "也可能暂时无法从其他桌面共享。请用 list_windows 重新获取窗口，"
                + "必要时恢复窗口或切换到其所在桌面后重试。"
            )

        case .timedOut, .underlying:
            return .captureFailed(error.localizedDescription)
        }
    }

    // MARK: - 落盘

    /// 以**排他创建**写文件；目标已存在时换名重试。
    ///
    /// ── 为什么不用「先判断存在再写」─────────────────────────
    ///
    /// 那是典型的 TOCTOU：两个并发调用可能都判定「路径空闲」，
    /// 然后其中一个把另一个刚写的文件覆盖掉。
    /// 本工具正是会被**多个 AI 工具/脚本并发调用**的场景，
    /// 所以「绝不覆盖已有产物」这条不变量必须由内核裁决：
    /// `O_CREAT | O_EXCL` 让「打开成功」本身就等于「这个名字归我了」。
    ///
    /// 命名规则与 `AnShotCore.OutputPath` 一致（`a.png` → `a-2.png` → …），
    /// 序号耗尽后退化为 UUID 后缀，保证「绝不覆盖」优先于「命名好看」。
    ///
    /// - Returns: 实际写入的路径。
    ///
    /// 可见度为 internal（而非 private）**仅为可测试**：
    /// 「并发下绝不覆盖」这条不变量无法通过公开 API 验证
    /// （公开路径要先拿到屏幕录制权限），而它恰恰是这里最容易写错的部分。
    static func writeExclusively(
        _ data: Data,
        desiredURL: URL,
        reservedPaths: Set<String> = []
    ) throws -> URL {
        let directory = desiredURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw AutomationError.outputFailed(
                "无法创建目录 \(directory.path)：\(error.localizedDescription)"
            )
        }

        // attempt 0 是原路径；其后依次追加 -2、-3…（命名规则统一由 OutputPath 给出）
        for attempt in 0...OutputPath.maximumAttempts {
            let candidate = OutputPath.candidate(for: desiredURL, attempt: attempt)

            // 保留路径视为「已占用」：不只看它是否真实存在——
            // 报告可能尚未写入，但把它的位置占了就会导致后续报告覆盖截图。
            if reservedPaths.contains(PathIdentity.canonical(candidate)) {
                continue
            }

            switch try createExclusively(at: candidate, contents: data) {
            case .written:
                return candidate

            case .alreadyExists:
                continue

            case .failed(let message):
                throw AutomationError.outputFailed("\(candidate.path)：\(message)")
            }
        }

        // 序号空间用尽：退化为 UUID，仍然保证不覆盖。
        var fallback = OutputPath.fallbackCandidate(for: desiredURL)
        // UUID 撞上保留路径的概率可忽略，但没必要靠概率——显式换一个。
        while reservedPaths.contains(PathIdentity.canonical(fallback)) {
            fallback = OutputPath.fallbackCandidate(for: desiredURL)
        }

        switch try createExclusively(at: fallback, contents: data) {
        case .written:
            return fallback
        case .alreadyExists:
            throw AutomationError.outputFailed(
                "\(fallback.path)：该路径已被占用（UUID 后缀仍冲突，属异常情况）。"
            )
        case .failed(let message):
            throw AutomationError.outputFailed("\(fallback.path)：\(message)")
        }
    }

    private enum ExclusiveWriteResult {
        case written
        case alreadyExists
        case failed(String)
    }

    /// 用 `O_CREAT | O_EXCL` 打开并写入。
    ///
    /// `O_EXCL` 让「已存在」表现为 `EEXIST` 而不是静默覆盖——
    /// 这正是并发安全所依赖的那一个原子动作。
    private static func createExclusively(
        at url: URL,
        contents: Data
    ) throws -> ExclusiveWriteResult {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        }

        if descriptor < 0 {
            if errno == EEXIST {
                return .alreadyExists
            }
            return .failed(String(cString: strerror(errno)))
        }

        // closeOnDealloc：即便中途抛错也不会泄漏描述符
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: contents)
            try handle.close()
            return .written
        } catch {
            // 写入失败时删掉半成品，避免留下一个损坏的 PNG 挡住后续重试
            try? FileManager.default.removeItem(at: url)
            return .failed(error.localizedDescription)
        }
    }
}
