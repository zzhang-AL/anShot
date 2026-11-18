//
//  MouseClickMonitor.swift
//  AnShotCapture
//
//  录屏可选鼠标点击事件采集与高亮波纹叠加辅助（P2-5）。
//

import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os

/// 一次鼠标点击事件记录。
public struct RecordedMouseClick: Equatable, Sendable {
    /// 全局左上原点屏幕坐标（与 `SCWindow.frame` / `DisplayGeometry` 同坐标系）。
    public let globalPoint: CGPoint
    /// 事件发生的系统单调运行时间（`ProcessInfo.processInfo.systemUptime`）。
    public let uptime: TimeInterval
    /// 鼠标按键编号（0 = 左键，1 = 右键，2 = 中键）。
    public let buttonNumber: Int

    public init(globalPoint: CGPoint, uptime: TimeInterval, buttonNumber: Int) {
        self.globalPoint = globalPoint
        self.uptime = uptime
        self.buttonNumber = buttonNumber
    }
}

/// 鼠标点击事件采集器。
///
/// 使用全局事件监听器捕获系统内点击坐标，并按动画生命周期维护近期点击队列，
/// 平时无活跃点击波纹时对视频帧零拷贝、零开销。
public final class MouseClickMonitor: Sendable {

    private struct State {
        var clicks: [RecordedMouseClick] = []
        var globalToken: Any?
        var localToken: Any?
        var isRunning = false
    }

    /// 由于 `NSEvent` monitor token 非 `Sendable`，状态封装在受锁保护的盒子里。
    private final class TokenBox: @unchecked Sendable {
        var globalToken: Any?
        var localToken: Any?
    }

    private let clicksLock = OSAllocatedUnfairLock<[RecordedMouseClick]>(initialState: [])
    private let tokenBox = TokenBox()
    private let lifecycleLock = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// 单次点击高亮动画持续时长（秒）。
    public let highlightDuration: TimeInterval

    public init(highlightDuration: TimeInterval = 0.45) {
        self.highlightDuration = max(0.1, highlightDuration)
    }

    deinit {
        stop()
    }

    /// 开始监听全局鼠标点击（确保在主线程注册 AppKit 事件监听）。
    public func start() {
        let shouldStart = lifecycleLock.withLock { running -> Bool in
            guard !running else { return false }
            running = true
            return true
        }
        guard shouldStart else { return }

        let register: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let stillRunning = self.lifecycleLock.withLock { $0 }
            guard stillRunning else { return }

            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            self.tokenBox.globalToken = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.recordAppKitClick(buttonNumber: event.buttonNumber)
            }
            self.tokenBox.localToken = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.recordAppKitClick(buttonNumber: event.buttonNumber)
                return event
            }
        }

        if Thread.isMainThread {
            register()
        } else {
            DispatchQueue.main.async(execute: register)
        }
    }

    /// 停止监听并清空缓存事件。
    public func stop() {
        let wasRunning = lifecycleLock.withLock { running -> Bool in
            guard running else { return false }
            running = false
            return true
        }
        guard wasRunning else { return }

        let unregister: @Sendable () -> Void = { [tokenBox = self.tokenBox] in
            if let token = tokenBox.globalToken {
                NSEvent.removeMonitor(token)
                tokenBox.globalToken = nil
            }
            if let token = tokenBox.localToken {
                NSEvent.removeMonitor(token)
                tokenBox.localToken = nil
            }
        }

        if Thread.isMainThread {
            unregister()
        } else {
            DispatchQueue.main.async(execute: unregister)
        }

        clicksLock.withLock { $0.removeAll() }
    }

    /// 手动记录一次点击事件（供测试与内部桥接调用）。
    public func record(_ click: RecordedMouseClick) {
        clicksLock.withLock { clicks in
            clicks.append(click)
            let cutoff = click.uptime - highlightDuration
            clicks.removeAll { $0.uptime < cutoff }
        }
    }

    /// 读取指定时刻仍处于动画周期内的全部点击及归一化进度 `0...1`。
    public func activeHighlights(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [(click: RecordedMouseClick, progress: Double)] {
        let duration = highlightDuration
        return clicksLock.withLock { clicks in
            clicks.removeAll { uptime - $0.uptime > duration }
            return clicks.compactMap { click in
                let elapsed = uptime - click.uptime
                guard elapsed >= 0, elapsed <= duration else { return nil }
                return (click, min(1.0, max(0.0, elapsed / duration)))
            }
        }
    }

    /// 将 AppKit 鼠标位置（主屏左下原点）转换为全局左上原点坐标后写入队列。
    private func recordAppKitClick(buttonNumber: Int) {
        let location = NSEvent.mouseLocation
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let globalTopLeft = CGPoint(x: location.x, y: mainBounds.height - location.y)
        record(
            RecordedMouseClick(
                globalPoint: globalTopLeft,
                uptime: ProcessInfo.processInfo.systemUptime,
                buttonNumber: buttonNumber
            )
        )
    }
}

/// 鼠标点击高亮渲染辅助：当存在活跃点击波纹时，在视频帧缓冲上绘制扩散圆环。
enum MouseClickHighlightRenderer {

    /// 若有活跃点击波纹，复制一份像素缓冲并绘制高亮圆环；无波纹时原样返回以保持零开销。
    static func overlayHighlights(
        _ highlights: [(click: RecordedMouseClick, progress: Double)],
        onto sampleBuffer: CMSampleBuffer,
        captureOrigin: CGPoint,
        scaleFactor: CGFloat
    ) -> CMSampleBuffer {
        guard !highlights.isEmpty,
              let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return sampleBuffer
        }

        let width = CVPixelBufferGetWidth(sourceBuffer)
        let height = CVPixelBufferGetHeight(sourceBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(sourceBuffer)
        guard width > 0, height > 0,
              pixelFormat == kCVPixelFormatType_32BGRA,
              scaleFactor > 0 else {
            return sampleBuffer
        }

        let localPoints: [(point: CGPoint, progress: Double, buttonNumber: Int)] = highlights.compactMap {
            item -> (point: CGPoint, progress: Double, buttonNumber: Int)? in
            let px = (item.click.globalPoint.x - captureOrigin.x) * scaleFactor
            let py = (item.click.globalPoint.y - captureOrigin.y) * scaleFactor
            // CoreGraphics 上下文左下原点，将左上原点 y 翻转。
            let cgY = CGFloat(height) - py
            let margin = 48.0 * scaleFactor
            guard px >= -margin, px <= CGFloat(width) + margin,
                  cgY >= -margin, cgY <= CGFloat(height) + margin else {
                return nil
            }
            return (CGPoint(x: px, y: cgY), item.progress, item.click.buttonNumber)
        }
        guard !localPoints.isEmpty else {
            return sampleBuffer
        }

        var copiedBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &copiedBuffer
        ) == kCVReturnSuccess, let dstBuffer = copiedBuffer else {
            return sampleBuffer
        }

        CVPixelBufferLockBaseAddress(sourceBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(dstBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dstBuffer, [])
            CVPixelBufferUnlockBaseAddress(sourceBuffer, .readOnly)
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(sourceBuffer),
              let dstBase = CVPixelBufferGetBaseAddress(dstBuffer) else {
            return sampleBuffer
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(sourceBuffer)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dstBuffer)
        let copyBytesPerRow = min(srcBytesPerRow, dstBytesPerRow)
        for row in 0 ..< height {
            memcpy(
                dstBase.advanced(by: row * dstBytesPerRow),
                srcBase.advanced(by: row * srcBytesPerRow),
                copyBytesPerRow
            )
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: dstBase,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: dstBytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return sampleBuffer
        }

        drawHighlights(localPoints, in: context, scaleFactor: scaleFactor)

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        )
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: dstBuffer,
            formatDescriptionOut: &formatDesc
        ) == noErr, let formatDesc else {
            return sampleBuffer
        }

        var outputBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: dstBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &outputBuffer
        ) == noErr, let outputBuffer else {
            return sampleBuffer
        }

        // 复制原有附件状态（含 SCStreamFrameInfo.status = .complete）
        if let srcAttachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let dstAttachments = CMSampleBufferGetSampleAttachmentsArray(outputBuffer, createIfNecessary: true) as? [NSMutableDictionary],
           let firstSrc = srcAttachments.first,
           let firstDst = dstAttachments.first {
            for (k, v) in firstSrc {
                firstDst[k] = v
            }
        }
        return outputBuffer
    }

    /// 在指定图形上下文中绘制脉冲扩散圆环（抽取独立函数供单元测试直接验证）。
    static func drawHighlights(
        _ items: [(point: CGPoint, progress: Double, buttonNumber: Int)],
        in context: CGContext,
        scaleFactor: CGFloat
    ) {
        for item in items {
            let alpha = CGFloat(max(0, 1.0 - item.progress)) * 0.85
            let radius = CGFloat(10.0 + item.progress * 26.0) * scaleFactor
            let lineWidth = CGFloat(3.0) * scaleFactor
            let color: CGColor = item.buttonNumber == 1
                ? CGColor(red: 1.0, green: 0.36, blue: 0.25, alpha: alpha)
                : CGColor(red: 0.20, green: 0.58, blue: 1.0, alpha: alpha)
            let fillColor: CGColor = item.buttonNumber == 1
                ? CGColor(red: 1.0, green: 0.36, blue: 0.25, alpha: alpha * 0.22)
                : CGColor(red: 0.20, green: 0.58, blue: 1.0, alpha: alpha * 0.22)

            let rect = CGRect(
                x: item.point.x - radius,
                y: item.point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.setFillColor(fillColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            context.strokeEllipse(in: rect)
        }
    }
}
