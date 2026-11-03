//
//  RecordingOutputContractTests.swift
//  AnShotCoreTests
//
//  M2 GIF 界面接通后的契约测试：档位集合、输出选择、错误契约。
//
//  这些断言盯的是「界面能选到的值」与「契约允许的值」必须一致——
//  两者一旦漂移，表现是界面给了一个后台会拒绝的档位（用户点开始才报错）。
//

import Foundation
import Testing

@testable import AnShotCore

@Suite("GIF 档位与输出选择契约")
struct RecordingOutputContractTests {

    @Test("默认值必须落在界面档位集合内")
    func defaultsAreInsideOptionSets() {
        #expect(GIFSettings.durationOptions.contains(GIFSettings.defaultDuration))
        #expect(GIFSettings.pixelDimensionOptions.contains(GIFSettings.defaultPixelDimension))
    }

    @Test("档位集合是本方案定稿的三档")
    func optionSetsMatchDecision() {
        #expect(GIFSettings.durationOptions == [15, 30, 60])
        #expect(GIFSettings.pixelDimensionOptions == [800, 1200, 1600])
    }

    @Test("帧率与循环次数是固定的默认值，不下沉到界面")
    func frameRateAndLoopCountAreFixed() {
        let settings = GIFSettings()
        #expect(settings.frameRate == 12)
        #expect(settings.loopCount == 0)
    }

    @Test("自定义档位只经由初始化参数进入，且不影响其它字段")
    func customTiers() {
        let settings = GIFSettings(maximumDuration: 60, maximumPixelDimension: 1600)
        #expect(settings.maximumDuration == 60)
        #expect(settings.maximumPixelDimension == 1600)
        #expect(settings.frameRate == GIFSettings.defaultFrameRate)
        #expect(settings.loopCount == GIFSettings.defaultLoopCount)
    }

    @Test("输出选择的扩展名与输出目标一致")
    func choiceExtensionMatchesOutput() {
        let url = URL(fileURLWithPath: "/tmp/a.gif")

        let movie = RecordingOutputChoice.movie
        #expect(movie.fileExtension == "mp4")
        #expect(!movie.isGIF)
        if case .movie(let url, let container) = movie.output(at: URL(fileURLWithPath: "/tmp/a.mp4")) {
            #expect(container == .mp4)
            #expect(url.lastPathComponent == "a.mp4")
        } else {
            Issue.record("movie 选择未构造出 movie 输出")
        }

        let gif = RecordingOutputChoice.gif(GIFSettings(maximumDuration: 30))
        #expect(gif.fileExtension == "gif")
        #expect(gif.isGIF)
        if case .gif(let producedURL, let settings) = gif.output(at: url) {
            #expect(producedURL == url)
            // 档位必须原样透传：丢了它用户选的 30 秒就会变回 15 秒
            #expect(settings.maximumDuration == 30)
        } else {
            Issue.record("gif 选择未构造出 gif 输出")
        }
    }

    @Test("GIF 转码失败属于保留已录内容的一类")
    func gifExportFailureKeepsPartialOutput() {
        #expect(RecordingError.gifExportFailed("无法创建 GIF 输出").shouldKeepPartialOutput)
        #expect(RecordingError.writerFailed("磁盘满").shouldKeepPartialOutput)
        #expect(RecordingError.streamFailed("中断").shouldKeepPartialOutput)
        #expect(!RecordingError.cancelled.shouldKeepPartialOutput)
        #expect(!RecordingError.timedOut.shouldKeepPartialOutput)
    }

    @Test("GIF 转码失败的文案不复用 IO 失败的措辞")
    func gifExportFailureHasItsOwnWording() {
        let message = RecordingError.gifExportFailed("无法创建输出").errorDescription ?? ""
        #expect(message.contains("GIF"))
        #expect(!message.contains("写入文件失败"))
    }

    @Test("麦克风权限失败必须有独立文案，不能指向屏幕录制")
    func microphonePermissionFailureIsDistinguishable() {
        // 两者共用一句「缺少屏幕录制权限」时，用户在系统设置里会发现那一项
        // 明明是开着的，于是永远找不对地方——文案本身就是排查线索。
        let mic = RecordingError.microphonePermissionDenied.errorDescription ?? ""
        let screen = RecordingError.permissionDenied.errorDescription ?? ""
        #expect(mic.contains("麦克风"))
        #expect(!mic.contains("屏幕录制"))
        #expect(mic != screen)
        // 权限类失败都没有可保留的产物。
        #expect(!RecordingError.microphonePermissionDenied.shouldKeepPartialOutput)
    }
}
