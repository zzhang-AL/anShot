import Foundation
import Testing

@testable import AnShotCapture
@testable import AnShotCore

@Suite("录制启动取消")
struct RecordingStartCancellationTests {
    @Test("先收到停止再开始时，不得启动录制或遗留挂起任务")
    func stopBeforeRecord() async {
        let recorder = SCStreamRecorder()
        await recorder.stop()
        await expectCancelled(recorder)
    }

    @Test("调用任务已取消时，不发起权限检查或建立输出文件")
    func alreadyCancelledBeforeRecord() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await expectCancelled(SCStreamRecorder())
        }
        await task.value
    }

    private func expectCancelled(_ recorder: SCStreamRecorder) async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anshot-cancelled-\(UUID()).mp4")
        let configuration = RecordingConfiguration(scope: .display(0),
                                                   audio: AudioSettings(systemAudio: false, microphone: false),
                                                   output: .movie(url, container: .mp4))
        do {
            _ = try await recorder.record(configuration: configuration)
            Issue.record("已经停止的录制不应产出文件")
        } catch {
            #expect(error as? RecordingError == .cancelled)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(recorder.state == .idle)
    }
}
