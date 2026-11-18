//
//  MicrophoneCapturer.swift
//  AnShotCapture
//
//  麦克风采集，基于 AVFoundation。
//
//  ── 为何不走 ScreenCaptureKit ────────────────────────────────
//
//  SCK 的麦克风捕获（`captureMicrophone` / `microphoneCaptureDeviceID` /
//  `SCStreamOutputType.microphone`）全部是 **macOS 15.0+**，而部署基线是 13.0。
//  若走双路径，13.0–14.0 的回退分支在开发机（macOS 27）上**永远不会被选中执行**，
//  会成为一段从未运行过的代码。故统一走 AVFoundation（macOS 10.7+），
//  全版本单一代码路径（plan.md §3.1 决策 A）。
//
//  ── 时间基准（M2 的最高风险点）──────────────────────────────
//
//  麦克风与 SCStream 的视频/系统声音**来自不同时钟域**，两者的时间戳不能直接相减。
//  `AVCaptureAudioDataOutput` 给出的 PTS 需要经 `CMClockConvertHostTimeToSystemUnits`
//  或 `CMSyncConvertTime` 换算到与视频相同的参考时钟后才能使用。
//  本类型只负责**如实给出原始时间戳**，换算由录制器统一处理——
//  换算逻辑必须只有一处，否则必然出现「某条路径忘了换算」的隐蔽偏移。
//

import AnShotCore
import AVFoundation
import CoreMedia
import Foundation
import os

private let microphoneLogger = AnShotLog.recording

/// 可用的音频输入设备描述，供设置面板与录制配置选择。
public struct AudioInputDevice: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// 麦克风采集器。
///
/// 样本回调**直接发生在调用方指定的串行队列上**，不做二次派发——
/// `CMSampleBuffer` 不满足 `Sendable`，跨队列传递只能靠 `@unchecked` 包装掩盖问题，
/// 而让回调落在录制器自己的串行队列上则完全没有这个问题。
public final class MicrophoneCapturer: NSObject, @unchecked Sendable {

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()

    /// 会话配置与启停专用队列。
    ///
    /// **必须存在**：`AVCaptureSession.startRunning()` / `stopRunning()` 是**阻塞调用**
    /// （首次启动可能耗时数百毫秒）。若在调用方线程上直接执行，会阻塞该线程——
    /// 实测在 async 上下文中同步调用会让整个会话启动挂起、诊断永远等不到结果。
    private let sessionQueue = DispatchQueue(label: "com.anshot.recording.microphone.session")

    /// 样本回调与运行时状态。
    private var handler: (@Sendable (CMSampleBuffer) -> Void)?
    private var outputQueue: DispatchQueue?
    private var activeDeviceID: String?
    private var disconnectObserver: NSObjectProtocol?
    private var isRunning = false

    /// 枚举当前可用的全部音频输入设备（默认设备排在首位）。
    public static func availableInputDevices() -> [AudioInputDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let mapped = discovery.devices.map { device in
            AudioInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultID
            )
        }
        return mapped.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 开始采集。
    ///
    /// - Parameters:
    ///   - queue: 样本回调的串行队列。应由调用方传入录制器的输出队列，
    ///     使麦克风样本与其他样本在同一线程上被消费。
    ///   - deviceID: 指定设备；nil 表示系统默认输入设备。
    ///   - handler: 样本回调，在 `queue` 上同步调用。
    ///     必须是 `@Sendable`：它跨线程传递到 `queue` 执行。
    func start(
        on queue: DispatchQueue,
        deviceID: String? = nil,
        handler: @escaping @Sendable (CMSampleBuffer) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RecordingError.writerFailed("麦克风采集器已释放"))
                    return
                }
                do {
                    try self.performStart(on: queue, deviceID: deviceID, handler: handler)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 停止采集并释放回调。
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                self?.performStop()
                continuation.resume()
            }
        }
    }

    // MARK: - 仅在 sessionQueue 上调用

    /// 配置会话：解析设备、添加输入与输出。
    ///
    /// ⚠️ **本函数必须独立于启动**。`defer { commitConfiguration() }` 只在函数返回时执行，
    /// 若把 `startRunning()` 写在同一个函数体内，它就会发生在**配置事务尚未提交时**——
    /// 而 `AVCaptureSession` 不允许在 `beginConfiguration()` 与 `commitConfiguration()`
    /// 之间调用 `startRunning()`。实测后果是**无限挂起**：不报错、不返回，
    /// 前面的设备解析与输入输出添加全部正常，只有启动这一步静默卡死。
    private func configure(
        on queue: DispatchQueue,
        deviceID: String?
    ) throws {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            microphoneLogger.notice("麦克风配置：已提交")
        }

        let device = try resolveDevice(preferredID: deviceID)
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw RecordingError.writerFailed("无法添加麦克风输入：\(device.localizedName)")
        }
        session.addInput(input)
        activeDeviceID = device.uniqueID

        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw RecordingError.writerFailed("无法添加麦克风输出")
        }
        session.addOutput(output)
        microphoneLogger.notice("麦克风配置完成：\(device.localizedName, privacy: .public)")
    }

    /// 启动采集。进入此函数时配置事务**已提交**。
    private func performStart(
        on queue: DispatchQueue,
        deviceID: String?,
        handler: @escaping @Sendable (CMSampleBuffer) -> Void
    ) throws {
        guard !isRunning else { return }

        self.handler = handler
        self.outputQueue = queue
        try configure(on: queue, deviceID: deviceID)
        installDisconnectObserverIfNeeded()

        microphoneLogger.notice("麦克风启动：调用 startRunning")
        session.startRunning()
        isRunning = session.isRunning
        microphoneLogger.notice("麦克风启动结束：isRunning=\(self.session.isRunning, privacy: .public)")
    }

    private func performStop() {
        removeDisconnectObserver()
        outputQueue = nil
        activeDeviceID = nil
        guard isRunning else {
            handler = nil
            return
        }
        session.stopRunning()
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        handler = nil
        isRunning = false
        microphoneLogger.notice("麦克风已停止")
    }

    /// 监听麦克风设备断开通知，蓝牙或外接麦拔出时平滑回退到默认设备。
    private func installDisconnectObserverIfNeeded() {
        guard disconnectObserver == nil else { return }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let disconnectedID = (notification.object as? AVCaptureDevice)?.uniqueID
            self.sessionQueue.async {
                self.handleDeviceDisconnected(deviceID: disconnectedID)
            }
        }
    }

    private func removeDisconnectObserver() {
        if let observer = disconnectObserver {
            NotificationCenter.default.removeObserver(observer)
            disconnectObserver = nil
        }
    }

    private func handleDeviceDisconnected(deviceID disconnectedID: String?) {
        guard isRunning else { return }
        if let disconnectedID, let current = activeDeviceID, disconnectedID != current {
            return
        }

        microphoneLogger.notice("检测到当前麦克风断开，尝试平滑回退到系统默认输入设备")
        guard let fallback = AVCaptureDevice.default(for: .audio),
              fallback.uniqueID != activeDeviceID,
              let fallbackInput = try? AVCaptureDeviceInput(device: fallback) else {
            microphoneLogger.notice("无可用回退麦克风，停止麦克风采集（不影响画面与系统音频录制）")
            performStop()
            return
        }

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if session.canAddInput(fallbackInput) {
            session.addInput(fallbackInput)
            activeDeviceID = fallback.uniqueID
            session.commitConfiguration()
            microphoneLogger.notice("麦克风已平滑切换到：\(fallback.localizedName, privacy: .public)")
        } else {
            session.commitConfiguration()
            performStop()
        }
    }

    private func resolveDevice(preferredID: String?) throws -> AVCaptureDevice {
        if let preferredID, !preferredID.isEmpty, let device = AVCaptureDevice(uniqueID: preferredID) {
            return device
        }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw RecordingError.writerFailed("找不到可用的麦克风设备")
        }
        return device
    }
}

extension MicrophoneCapturer: AVCaptureAudioDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        handler?(sampleBuffer)
    }
}
