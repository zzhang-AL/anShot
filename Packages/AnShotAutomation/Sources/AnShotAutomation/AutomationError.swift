//
//  AutomationError.swift
//  AnShotAutomation
//
//  自动化入口的错误模型。
//
//  ── 设计约束：错误必须「可操作」─────────────────────────────
//
//  这些错误的读者是 AI 与脚本，不是看着界面的用户。因此每条错误
//  都要回答两件事：
//
//      1. 发生了什么（现象）
//      2. 调用方/用户下一步该做什么（动作）
//
//  「permissionDenied」这种只有现象的措辞会让人（和模型）原地重试，
//  而重试必然失败——权限不会因为重试而出现。所以这里把
//  「为什么失败 + 去系统设置的哪一栏 + 该授权给谁」写进错误本身。
//
//  ── 关于「该授权给谁」：只陈述已知，不猜进程名 ────────────────
//
//  曾有一版实现按 `TERM_PROGRAM`／父进程名推测被授权的进程并写进文案。
//  这是**错的**，已移除。理由：
//
//      本项目 M1 阶段的一手记录（`ScreenCapturePermission.swift` 文件头）明确写着
//      「从终端直接执行 Foo.app/Contents/MacOS/Foo 时，TCC 的 responsible
//        process 是**终端本身**（实测中为 ghostty）」
//
//  也就是说，从 bash 里执行时被记名的是**终端应用**，而不是 `bash`。
//  一个猜出来的、且可能是错的名字，会把用户直接引到错误的方向——
//  他在系统设置里根本找不到那个名字。
//
//  没有公开 API 能查询 TCC 实际的 responsible process，因此文案只说明
//  「可能是哪一类对象」并请用户**以系统设置里实际显示的条目为准**。
//

import Foundation

/// 自动化入口的错误。
public enum AutomationError: Error {

    /// 调用方传入的参数不合法。`detail` 要说清期望值域。
    case invalidArgument(String)

    /// 缺少屏幕录制权限。
    case permissionDenied

    /// 目标显示器不存在（已断开或 ID 传错）。
    case displayUnavailable(UInt32)

    /// 目标窗口不可用（已关闭、已最小化、或应用名下没有任何可截图的窗口）。
    ///
    /// 与 `displayUnavailable` 分开：窗口寻址有两类失败（ID 失效 / 应用名无命中），
    /// 而处理方式不同——前者要重新枚举，后者要改名字。合并成一个 case
    /// 就只能靠解析文案来区分，那是不可靠的。
    case windowUnavailable(String)

    /// 请求区域与该显示器无有效交集。
    case emptyRegion

    /// `--out` 与 `--json-out` 指向同一目标。
    ///
    /// 单独成一个 case（而不是复用 `invalidArgument`）是为了让失败流程能识别它：
    /// 这类失败**不能**把报告写到那个目标上，否则「拒绝覆盖」的初衷
    /// 会被失败处理本身破坏。
    case outputPathConflict(String)

    /// 捕获阶段失败，`detail` 为底层原因。
    case captureFailed(String)

    /// 编码或落盘失败。
    case outputFailed(String)

    /// 由另一个 anShot 实例报告的错误。
    ///
    /// 与 `captureFailed` 分开的原因：跨进程拿到的 `detail` 已经是一条完整、
    /// 可读、带处理建议的中文消息，再套一层「捕获失败：」会变成
    /// 「捕获失败：缺少屏幕录制权限：…」，把真正的标题挤到第二行。
    case remoteFailure(String)
}

extension AutomationError: LocalizedError {

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let detail):
            return detail

        case .permissionDenied:
            // 这条消息在两种情况下都会出现，而且本工具**无法区分**：
            //   1. anShot.app 自己没被授权（默认路径走通但 app 缺权限）
            //   2. 调用方显式要求就地截图（--direct），当前进程没被授权
            // 所以不给单一结论，而是把「怎么判断」和「各自怎么办」都写清楚。
            return """
            缺少屏幕录制权限：执行截图的进程没有获得授权，无法读取屏幕内容。

            为什么会这样：这项权限记在**发起进程**的代码身份上，而不是可执行
            文件上。默认情况下本工具经 LaunchServices 让 anShot.app 自己截图，
            复用它已有的授权；出现这条错误意味着那一层没走通——要么 anShot.app
            自身缺少授权，要么调用方显式要求了就地截图（--direct）。

            处理：「系统设置 → 隐私与安全性 → 屏幕录制」里，以**实际显示的条目**
            为准（本工具无法查询 TCC 的 responsible process，不做猜测）：

            · 列表里有 anShot  → 打开它。这是默认路径需要的授权。
            · 列表里只有你运行命令的终端 / AI 客户端 → 这是 --direct 就地截图
              造成的。去掉 --direct 即可，**不需要**给终端录屏权限。
            · 若开关本就打开却仍报错 → 退出并重启对应应用。更换签名证书或
              改动 bundle id 会让旧授权失效，此时需要重新打开一次开关。

            本工具不会主动弹出授权对话框——那会在无人应答的桌面上挂起，且无助于
            解决问题。权限只能由人授予。
            """

        case .displayUnavailable(let id):
            return "显示器 #\(id) 不存在。请先调用 list_displays 获取当前可用的显示器 ID。"

        case .windowUnavailable(let detail):
            // detail 已经由调用方写成可操作文案（含候选列表），原样透传。
            return detail

        case .emptyRegion:
            return "请求的区域与该显示器没有有效交集（区域超出屏幕边界或宽高小于 1）。"

        case .outputPathConflict(let detail):
            return detail

        case .captureFailed(let detail):
            return "捕获失败：\(detail)"

        case .remoteFailure(let detail):
            // 消息来自另一个进程，已经完整，原样透传。
            return detail

        case .outputFailed(let detail):
            return "写入截图失败：\(detail)"
        }
    }
}
