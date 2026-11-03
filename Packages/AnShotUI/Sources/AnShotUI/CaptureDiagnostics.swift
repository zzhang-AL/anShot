//
//  CaptureDiagnostics.swift
//  AnShotUI
//
//  捕获层诊断。仅在 Debug 构建中存在，P3 接入真实截图功能后可逐步移除。
//
//  存在的理由：菜单项无法脚本化点击（osascript 缺辅助功能权限），
//  若没有命令行入口，捕获层的每次验证都要人工操作，事实上无法回归测试。
//
//  用法：
//      open -n anShot.app --args -diagnoseCapture
//      open -n anShot.app --args -diagnoseCapture -captureImpl stream
//      open -n anShot.app --args -diagnoseRegion
//      open -n anShot.app --args -diagnoseBenchmark
//      open -n anShot.app --args -diagnoseOverlay
//      open -n anShot.app --args -diagnoseSelection
//      open -n anShot.app --args -diagnoseSelectionPhase      （候选 / 已确认两阶段）
//      open -n anShot.app --args -diagnoseRecording          （全屏 3 秒）
//      open -n anShot.app --args -diagnoseRecording -duration 5 -scopeRegion
//      open -n anShot.app --args -diagnoseGIF                 （GIF 全链路 7 个子项）
//      open -n anShot.app --args -diagnoseGIF -autoStop        （只验上限自动停止）
//

#if DEBUG

import AnShotCapture
import AnShotCore
@preconcurrency import AVFoundation
import AppKit
import ImageIO
import Carbon.HIToolbox
@preconcurrency import ScreenCaptureKit
import Foundation

@MainActor
enum CaptureDiagnostics {
    static let logger = AnShotLog.diagnostics
    /// 是否由命令行请求了诊断（用于决定是否在启动时执行）。
    static func hasDiagnosticRequest() -> Bool {
        let args = CommandLine.arguments
        return args.contains("-diagnoseCapture")
            || args.contains("-diagnoseRegion")
            || args.contains("-diagnoseBoth")
            || args.contains("-diagnoseBenchmark")
            || args.contains("-diagnoseOverlay")
            || args.contains("-diagnoseSelection")
            || args.contains("-diagnoseSelectionPhase")
            || args.contains("-diagnoseAnnotation")
            || args.contains("-diagnoseAnnotationInput")
            || args.contains("-diagnoseColorPanel")
            || args.contains("-diagnoseExport")
            || args.contains("-diagnoseMemory")
            || args.contains("-diagnoseWindows")
            || args.contains("-diagnoseDetection")
            || args.contains("-diagnoseSettings")
            || args.contains("-diagnoseSettingsWindow")
            || args.contains("-diagnoseRecording")
            || args.contains("-diagnoseGIF")
            || args.contains("-requestMicrophoneAccess")
            || args.contains("-diagnoseRecordingUI")
            || args.contains("-diagnoseRecordingFrame")
            || args.contains("-diagnoseRecordFlow")
            || args.contains("-diagnoseWindowFollow")
            || args.contains("-diagnoseScrollshot")
            || args.contains("-diagnoseScrollshotLive")
            || args.contains("-diagnoseScrollshotEntry")
            || args.contains("-diagnoseScrollshotOverlay")
            || args.contains("-diagnoseScrollshotPanel")
            || args.contains("-diagnoseOCR")
            || args.contains("-diagnoseOCRProvider")
            || args.contains("-diagnoseM3Annotation")
            || args.contains("-diagnosePin")
            || args.contains("-diagnoseHistory")
            || args.contains("-diagnoseTranslation")
            || args.contains("-diagnoseLaunchAtLogin")
    }
    /// 是否正在跑「录制入口流程」诊断。
    ///
    /// 那个诊断只验证「通知被正确发出」，若装配层同时真的去录制，它会写文件、
    /// 开麦克风，并与诊断抢捕获资源——一个声称只测通知的诊断不该有这些副作用。
    static func shouldSkipRecordingRequests() -> Bool {
        CommandLine.arguments.contains("-diagnoseRecordFlow")
    }
    /// 解析并分发命令行诊断请求。
    static func handleCommandLineArguments() {
        let args = CommandLine.arguments
        let implementation = parseImplementation(args)

        if args.contains("-diagnoseBenchmark") {
            // 纯基准测试。故意不做任何捕获，避免污染计时。
            Task { await runBenchmark() }
            return
        }

        if args.contains("-diagnoseOverlay") {
            Task { await runOverlayDiagnostic() }
            return
        }

        if args.contains("-diagnoseSettings") {
            Task { await runSettingsDiagnostic() }
            return
        }

        if args.contains("-diagnoseLaunchAtLogin") {
            Task { await runLaunchAtLoginDiagnostic() }
            return
        }

        if args.contains("-diagnoseSettingsWindow") {
            Task { await runSettingsWindowDiagnostic() }
            return
        }

        if args.contains("-diagnoseSelection") {
            Task { await runSelectionDiagnostic() }
            return
        }

        if args.contains("-diagnoseSelectionPhase") {
            Task { await runSelectionPhaseDiagnostic() }
            return
        }

        if args.contains("-diagnoseColorPanel") {
            Task { await runColorPanelDiagnostic() }
            return
        }

        if args.contains("-diagnoseAnnotationInput") {
            Task { await runAnnotationInputDiagnostic() }
            return
        }

        if args.contains("-diagnoseExport") {
            Task { await runExportDiagnostic() }
            return
        }

        if args.contains("-diagnoseMemory") {
            Task { await runMemoryDiagnostic() }
            return
        }

        if args.contains("-diagnoseWindows") {
            Task { await runWindowProbe() }
            return
        }

        if args.contains("-diagnoseRecordFlow") {
            Task { await runRecordFlowDiagnostic() }
            return
        }

        if args.contains("-diagnoseWindowFollow") {
            Task { await runWindowFollowDiagnostic() }
            return
        }

        if args.contains("-diagnoseScrollshot") {
            Task { await runScrollshotDiagnostic() }
            return
        }

        if args.contains("-diagnoseScrollshotLive") {
            Task { await runScrollshotLiveDiagnostic() }
            return
        }

        if args.contains("-diagnoseScrollshotEntry") {
            Task { await runScrollshotEntryDiagnostic() }
            return
        }

        if args.contains("-diagnoseScrollshotOverlay") {
            Task { await runScrollshotOverlayDiagnostic() }
            return
        }

        if args.contains("-diagnoseScrollshotPanel") {
            Task { await runScrollshotPanelDiagnostic() }
            return
        }

        if args.contains("-diagnoseOCR") {
            Task { await runOCRDiagnostic() }
            return
        }

        if args.contains("-diagnoseOCRProvider") {
            Task { await runOCRProviderDiagnostic() }
            return
        }

        if args.contains("-diagnoseM3Annotation") {
            Task { await runM3AnnotationDiagnostic() }
            return
        }

        if args.contains("-diagnosePin") {
            Task { await runPinDiagnostic() }
            return
        }

        if args.contains("-diagnoseHistory") {
            Task { await runHistoryDiagnostic() }
            return
        }

        if args.contains("-diagnoseTranslation") {
            Task { await runTranslationDiagnostic() }
            return
        }

        if args.contains("-diagnoseRecordingFrame") {
            Task { await runRecordingFrameDiagnostic() }
            return
        }

        if args.contains("-diagnoseRecordingUI") {
            Task { await runRecordingUIDiagnostic() }
            return
        }

        if args.contains("-requestMicrophoneAccess") {
            Task { await requestMicrophoneAccessDiagnostic() }
            return
        }

        if args.contains("-diagnoseRecording") {
            Task { await runRecordingDiagnostic() }
            return
        }

        if args.contains("-diagnoseGIF") {
            Task { await runGIFDiagnostic() }
            return
        }

        if args.contains("-diagnoseDetection") {
            Task { await runDetectionDiagnostic() }
            return
        }

        if args.contains("-diagnoseAnnotation") {
            Task { await runAnnotationDiagnostic() }
            return
        }

        let displayID = DisplayGeometry.mainDisplay()

        if args.contains("-diagnoseCapture") {
            Task { await runCapture(scope: .display(displayID), implementation: implementation, label: "full") }
        } else if args.contains("-diagnoseRegion") {
            let region = CGRect(x: 200, y: 150, width: 600, height: 400)
            Task { await runCapture(scope: .region(displayID, rect: region), implementation: implementation, label: "region") }
        } else if args.contains("-diagnoseBoth") {
            Task { await runBoth(implementation: implementation) }
        }
    }
    /// 从菜单触发的诊断，等同 `-diagnoseCapture`。
    static func runFromMenu() {
        Task { await runCapture(scope: .display(DisplayGeometry.mainDisplay()), implementation: nil, label: "full") }
    }
    /// `-captureImpl stream|screenshotManager`。缺省用系统版本选择。
    private static func parseImplementation(_ args: [String]) -> CapturerFactory.Implementation? {
        guard let index = args.firstIndex(of: "-captureImpl"), index + 1 < args.count else {
            return nil
        }
        return CapturerFactory.Implementation(rawValue: args[index + 1])
    }
    static func parseIntArgument(_ args: [String], _ name: String) -> Int? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else {
            return nil
        }
        return Int(args[index + 1])
    }
    static func parseNamedDoubleArgument(_ args: [String], _ name: String) -> Double? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else {
            return nil
        }
        return Double(args[index + 1])
    }
    static func makeCapturer(_ implementation: CapturerFactory.Implementation?) -> any ScreenCapturing {
        guard let implementation else { return CapturerFactory.makeDefault() }
        return CapturerFactory.make(implementation)
    }

    // MARK: - 基准测试
}

#endif
