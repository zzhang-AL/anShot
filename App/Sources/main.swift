//
//  main.swift
//  anShot
//
//  应用入口。保持极薄，装配逻辑在 AnShotUI.AppDelegate。
//

import AppKit
import AnShotAutomation
import AnShotUI
import Darwin

// ── 自动化模式分流（必须在创建 NSApplication 之前）────────────────
//
// `--mcp`（MCP stdio 服务端）与 `--capture`/`--list-displays`（命令行截图）
// 都在这里被截住，**不进入 GUI 装配**。
//
// 位置为什么关键：菜单栏图标、全局热键、覆盖层都在
// `applicationDidFinishLaunching` 里安装。自动化运行的进程一旦走到那里，
// 每被 AI 调用一次就会多一个菜单栏图标，并参与热键的进程级竞争。
// 详见 AnShotAutomation/AutomationMode.swift 的说明。
//
// `detect` 会抛错：`--mcp` 与截图类选项混用时意图不明确，必须在**真实入口**
// 拒绝，而不是让其中一半生效。
do {
    if let mode = try AutomationRunner.detect(from: CommandLine.arguments) {
        exit(AutomationRunner.runBlocking(mode))
    }
} catch let error as AutomationError {
    // 走统一的失败出口：stdout 上仍是合法失败 JSON（脚本可无脑 jq .ok）。
    exit(AutomationRunner.emitEntryFailure(error.localizedDescription))
} catch {
    exit(AutomationRunner.emitEntryFailure("参数错误：\(error.localizedDescription)"))
}

// ── 单实例守卫（必须在创建 NSApplication 之前）────────────────────
//
// 两个 GUI 进程同时存活会各自注册同一组 Carbon 热键、各装一整套覆盖层：
// 按一次 Esc 每个进程各关一层。这里用文件锁把「纯 GUI 启动」限制成单实例。
//
// 注意：**不要**改用 LSMultipleInstancesProhibited —— 那会连
// `open -n app --args -diagnose...` 一起禁掉，诊断入口就没了。
// 因此只对「没有额外参数」的启动生效，带诊断参数的启动照旧放行。
if isPlainGUILaunch(CommandLine.arguments) {
    enforceSingleInstance()
}

let app = NSApplication.shared

// .accessory：菜单栏 agent，无 Dock 图标、无主菜单（与 Info.plist 的 LSUIElement 一致）
app.setActivationPolicy(.accessory)

// ⚠️ NSApplication.delegate 是 weak 引用。
// 必须在此持有强引用，否则 AppDelegate 会在 run() 之前被释放，
// 导致 applicationDidFinishLaunching 永不调用、菜单栏图标不出现。
// 切勿写作 app.delegate = AppDelegate()。
let delegate = AppDelegate()
app.delegate = delegate

app.run()

// ── 单实例守卫的实现 ─────────────────────────────────────────────

/// 是否应当施加单实例守卫。
///
/// 只有**不注册热键**的诊断/展示入口才放行第二个进程：
/// `-diagnose*`、`-show*`、`-editImage`、`-checkUpdates`、
/// `-requestMicrophoneAccess`。它们对应 `AppDelegate.isDiagnosticRun`，
/// 不会抢 Carbon 热键，因此 `open -n app --args -diagnose...` 必须继续可用。
///
/// 其余参数（包括 `-recordFrames` / `-recordAllFrames`）仍按普通 GUI 处理：
/// 它们会注册热键、创建覆盖层，允许第二个实例就会重新出现「按两次 Esc」。
private func isPlainGUILaunch(_ arguments: [String]) -> Bool {
    // 这些是 macOS 自己注入的、带值的参数（值形如 `YES`、`(en)`）。
    let injectedWithValue: Set<String> = [
        "-NSDocumentRevisionsDebugMode",
        "-ApplePersistenceIgnoreState",
        "-AppleLanguages",
        "-AppleLocale",
    ]

    var index = 1  // arguments[0] 是可执行文件路径
    while index < arguments.count {
        let argument = arguments[index]
        if argument.hasPrefix("-psn_") {
            index += 1  // 进程序列号，无值
            continue
        }
        if injectedWithValue.contains(argument) {
            index += 2  // 连同它的值一起跳过
            continue
        }
        if argument.hasPrefix("-diagnose")
            || argument.hasPrefix("-show")
            || argument == "-requestMicrophoneAccess"
            || argument == "-checkUpdates"
            || argument == "-editImage" {
            return false
        }
        index += 1
    }
    return true
}

/// 用 `flock` 保证纯 GUI 启动只有一个实例。
///
/// 另一个实例持锁时：激活它（`.activateAllWindows`），写一行 stderr，然后退出。
/// 任何**意外**失败（目录建不出来、文件打不开、锁失败但 errno 不是
/// EWOULDBLOCK）都选择「放行」——锁出问题不该让应用起不来。
private func enforceSingleInstance() {
    let supportDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/anShot", isDirectory: true)
    let lockURL = supportDirectory.appendingPathComponent("instance.lock")

    do {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    } catch {
        writeStderr("anShot: 无法准备单实例目录（\(error.localizedDescription)），跳过单实例检查")
        return
    }

    let descriptor = lockURL.path.withCString {
        open($0, O_CREAT | O_RDWR, 0o644)
    }
    guard descriptor >= 0 else {
        writeStderr("anShot: 无法打开实例锁 \(lockURL.path)，跳过单实例检查")
        return
    }

    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
        // 拿到锁：写入自己的 PID 供后来者激活，然后**不关闭 fd**。
        // fd 是进程级资源，不关闭即可让锁在整个进程生命周期内有效；
        // 进程退出时内核自动释放锁，残留的锁文件不会挡住下次启动。
        let pid = getpid()
        _ = ftruncate(descriptor, 0)
        _ = String(pid).withCString { write(descriptor, $0, strlen($0)) }
        return
    }

    guard errno == EWOULDBLOCK else {
        writeStderr("anShot: 实例锁获取失败（errno \(errno)），跳过单实例检查")
        close(descriptor)
        return
    }

    // 另一个实例持锁：尽量把它的窗口提到前台，然后安静退出（不是错误）。
    if let holder = readHolderPID(from: descriptor) {
        NSRunningApplication(processIdentifier: holder)?.activate(options: [.activateAllWindows])
    }
    writeStderr("anShot: 已有实例在运行，已激活该实例并退出")
    close(descriptor)
    exit(0)
}

/// 持锁进程是「先加锁、后写 PID」，所以这里短暂重试，避免读到空文件。
/// 重试耗尽仍拿不到有效 PID 时返回 nil（调用方直接退出即可）。
private func readHolderPID(from descriptor: Int32) -> pid_t? {
    for _ in 0..<10 {
        var buffer = [CChar](repeating: 0, count: 32)
        let readCount = buffer.withUnsafeMutableBytes { raw in
            pread(descriptor, raw.baseAddress, raw.count - 1, 0)
        }
        let text = buffer.withUnsafeBufferPointer { bytes in
            String(cString: bytes.baseAddress!)
        }
        if readCount > 0,
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0 {
            return pid
        }
        usleep(10_000)  // 10ms
    }
    return nil
}

/// 诊断信息只走 stderr：GUI 进程的 stdout 不属于任何人。
private func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
