//
//  main.swift
//  anShot
//
//  应用入口。保持极薄，装配逻辑在 AnShotUI.AppDelegate。
//

import AppKit
import AnShotAutomation
import AnShotUI

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
