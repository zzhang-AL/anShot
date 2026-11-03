import Foundation
import Testing

@testable import AnShotAutomation

@Suite("自动化子进程观察者", .serialized)
struct ChildProcessLifetimeTests {
    @Test("取消真实的报告等待路径后，观察进程随之退出")
    func cancelledReportWaitStopsObserver() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let child = OutOfProcessCapture.LaunchedChild(process: process)
        try process.run()
        defer { child.stopWaiting() }
        let missingReport = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-no-report-\(UUID()).json")
        let task = Task {
            try await OutOfProcessCapture.waitForReport(at: missingReport, child: child, timeout: 20)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("取消后不应返回截图报告")
        } catch {
            #expect(error is CancellationError)
        }
        try await waitUntil { child.exitStatus != nil }
        #expect(!process.isRunning)
    }

    @Test("退出码能够送达，完成后观察者可释放")
    func completedObserverDoesNotRetainItself() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        var child: OutOfProcessCapture.LaunchedChild? = .init(process: process)
        let reference = WeakChildReference(child)
        try process.run()
        try await waitUntil { child?.exitStatus != nil }
        #expect(child?.exitStatus == 0)
        child = nil
        try await waitUntil { reference.value == nil }
        #expect(reference.value == nil)
    }

    @Test("结束等待会停止观察进程")
    func stoppedObserverExits() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let child = OutOfProcessCapture.LaunchedChild(process: process)
        try process.run()
        defer { child.stopWaiting() }
        child.stopWaiting()
        try await waitUntil { child.exitStatus != nil }
        #expect(!process.isRunning)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WaitError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum WaitError: Error { case timedOut }
}

private final class WeakChildReference {
    weak var value: OutOfProcessCapture.LaunchedChild?

    init(_ value: OutOfProcessCapture.LaunchedChild?) {
        self.value = value
    }
}
