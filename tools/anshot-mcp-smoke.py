#!/usr/bin/env python3
"""anShot MCP stdio 服务端冒烟测试。

━━ 为什么需要它 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

MCP 服务端的行为无法用单元测试覆盖：它由**客户端 spawn 子进程**、
经 stdin/stdout 交换 JSON-RPC 消息，其生命周期也由客户端决定
（比如关闭 stdin 后进程该不该退出）。只有真的起一个进程、按协议
走一遍，才能验证这些。

━━ 为什么必须用真实子进程而不是管道灌入 ━━━━━━━━━━━━━━━━━━━━━━

内容一次性灌入并立刻关闭 stdin 时，服务端可能在某些响应发完之前就退出
（详见 docs/automation/task.md §4.2）。那是真实客户端不会触发的边界，
所以本脚本**始终等待每个响应**，最后一个请求完成后再关闭 stdin——
与真实 MCP 客户端一致。

用法：
    tools/anshot-mcp-smoke.py [--binary <anShot 可执行文件路径>]

退出码：0 全部断言通过；1 有断言失败。
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import subprocess
import sys
import threading
import time

PROTOCOL_VERSION = "2025-06-18"
EXPECTED_TOOLS = {"list_displays", "list_desktops", "list_windows", "capture_screenshot"}


class Failure(Exception):
    """断言失败。"""


def check(condition: bool, label: str, detail: str = "") -> None:
    if condition:
        print(f"  ✔ {label}")
        return
    suffix = f" — {detail}" if detail else ""
    raise Failure(f"{label}{suffix}")


class Server:
    """一个真实的 MCP stdio 服务端子进程。"""

    def __init__(self, binary: str) -> None:
        self.next_id = 0
        self.responses: dict[object, dict] = {}
        self.stderr_chunks: list[str] = []

        self.process = subprocess.Popen(
            [binary, "--mcp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )

        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        assert self.process.stdout is not None
        for raw in iter(self.process.stdout.readline, b""):
            text = raw.decode("utf-8", errors="replace").strip()
            if not text:
                continue
            try:
                message = json.loads(text)
            except json.JSONDecodeError:
                # stdout 上出现非协议内容即是故障（协议通道被污染）
                self.responses[("parse-error", text[:80])] = {"__raw__": text}
                continue
            self.responses[message.get("id")] = message

    def _read_stderr(self) -> None:
        assert self.process.stderr is not None
        for raw in iter(self.process.stderr.readline, b""):
            self.stderr_chunks.append(raw.decode("utf-8", errors="replace"))

    def send(self, method: str, params: dict | None = None, *, notify: bool = False):
        payload: dict = {"jsonrpc": "2.0", "method": method}
        if not notify:
            self.next_id += 1
            payload["id"] = self.next_id
        if params is not None:
            payload["params"] = params

        assert self.process.stdin is not None
        self.process.stdin.write((json.dumps(payload) + "\n").encode("utf-8"))
        self.process.stdin.flush()

        return None if notify else payload["id"]

    def wait_for(self, request_id: object, timeout: float = 20.0) -> dict:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if request_id in self.responses:
                return self.responses[request_id]
            time.sleep(0.02)
        raise Failure(f"等待 id={request_id} 的响应超时（{timeout}s）")

    def call(self, method: str, params: dict | None = None) -> dict:
        return self.wait_for(self.send(method, params))

    def call_tool(self, name: str, arguments: dict | None = None) -> dict:
        return self.call(
            "tools/call",
            {"name": name, "arguments": arguments or {}},
        )

    def close_and_wait(self, timeout: float = 15.0) -> int | None:
        if self.process.stdin is not None:
            self.process.stdin.close()
        try:
            return self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.process.kill()
            raise Failure(f"关闭 stdin 后进程未在 {timeout}s 内退出")

    def kill(self) -> None:
        try:
            self.process.kill()
        except Exception:
            pass


def find_binary() -> str:
    """定位一个支持自动化接口的 anShot 可执行文件。"""
    repo = pathlib.Path(__file__).resolve().parent.parent
    for candidate in (
        repo / "build/Build/Products/Debug/anShot.app",
        repo / "build/Build/Products/Release/anShot.app",
        repo / "build-release/Build/Products/Release/anShot.app",
        pathlib.Path("/Applications/anShot.app"),
    ):
        executable = candidate / "Contents/MacOS/anShot"
        if executable.is_file():
            return str(executable)
    raise Failure("找不到 anShot.app，请先构建或用 --binary 指定")


def tool_text(tool_result: dict) -> str:
    """取工具结果里的第一个**文本**块。

    参数是 `tools/call` 响应里的 **result 对象**（不是整个响应），
    调用方负责先取出 `response["result"]`。

    ── 为什么不直接取 content[0] ──────────────────────────────────

    `capture_screenshot` 成功时返回的是 **[image, text]**：首个块是图像，
    文本块在后面。只读 content[0] 会拿到空串，于是「元数据里写了什么」
    这类断言全部假失败——而那条元数据恰恰是模型判断
    「这张图是哪块屏/哪个窗口、有没有被缩放」的唯一依据。
    """
    for block in tool_result.get("content", []):
        if block.get("type") == "text":
            return block.get("text", "")
    return ""


def run(
    binary: str,
    offscreen_window_id: int | None = None,
    offscreen_repetitions: int = 1,
    desktop_id: int | None = None,
) -> None:
    print(f"服务端：{binary}")
    server = Server(binary)

    try:
        print("\n[1/7] initialize")
        response = server.call(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "anshot-mcp-smoke", "version": "1.0"},
            },
        )
        result = response.get("result", {})
        check("result" in response, "收到 initialize 结果", json.dumps(response)[:200])
        check(
            result.get("protocolVersion") == PROTOCOL_VERSION,
            f"协商协议版本为 {PROTOCOL_VERSION}",
            str(result.get("protocolVersion")),
        )
        check(
            result.get("serverInfo", {}).get("name") == "anshot",
            "serverInfo.name 为 anshot",
            str(result.get("serverInfo")),
        )

        print("\n[2/7] notifications/initialized")
        server.send("notifications/initialized", notify=True)
        check(True, "已发送通知（无响应，符合 JSON-RPC 通知语义）")

        print("\n[3/7] tools/list")
        listed = server.call("tools/list").get("result", {}).get("tools", [])
        names = {tool.get("name") for tool in listed}
        check(names == EXPECTED_TOOLS, f"工具集为 {sorted(EXPECTED_TOOLS)}", str(sorted(names)))

        annotations = {tool["name"]: tool.get("annotations", {}) for tool in listed}
        check(
            annotations.get("list_displays", {}).get("readOnlyHint") is True,
            "list_displays 声明为只读",
            str(annotations.get("list_displays")),
        )
        # list_windows 同样是纯查询：它不写盘、不改变任何状态，
        # 声明只读能让客户端在只读会话里放行它。
        check(
            annotations.get("list_windows", {}).get("readOnlyHint") is True,
            "list_windows 声明为只读",
            str(annotations.get("list_windows")),
        )
        check(
            annotations.get("list_desktops", {}).get("readOnlyHint") is True,
            "list_desktops 声明为只读",
            str(annotations.get("list_desktops")),
        )
        # capture_screenshot 能经 save_path 写盘，不能声明只读
        check(
            annotations.get("capture_screenshot", {}).get("readOnlyHint") is False,
            "capture_screenshot 未谎报只读",
            str(annotations.get("capture_screenshot")),
        )

        print("\n[4/7] tools/call list_displays")
        displays_result = server.call_tool("list_displays").get("result", {})
        check(displays_result.get("isError") is False, "list_displays 未报错")
        payload = json.loads(tool_text(displays_result))
        check(len(payload.get("displays", [])) >= 1, "至少返回一块显示器")
        check(
            sum(1 for d in payload["displays"] if d.get("isMain")) == 1,
            "恰好一块被标记为主显示器",
        )

        print("\n[额外] tools/call list_desktops")
        desktops_result = server.call_tool("list_desktops").get("result", {})
        check(desktops_result.get("isError") is False, "list_desktops 未报错", tool_text(desktops_result)[:150])
        desktops = json.loads(tool_text(desktops_result)).get("desktops", [])
        check(bool(desktops), "至少返回一个桌面")

        print("\n[5/7] tools/call list_windows")
        windows_result = server.call_tool("list_windows").get("result", {})
        check(windows_result.get("isError") is False, "list_windows 未报错")
        windows_payload = json.loads(tool_text(windows_result))
        windows = windows_payload.get("windows", [])
        print(f"    · 当前可截图窗口 {len(windows)} 个")

        # 窗口列表可以为空（干净的桌面 / 无 GUI 会话），但只要有窗口，
        # 就必须带上「能据此寻址」的字段——少了 id 或 appName，
        # 调用方拿到列表也用不了。
        if windows:
            first = windows[0]
            check(isinstance(first.get("id"), int), "窗口带 id", str(first)[:90])
            check(bool(first.get("appName")), "窗口带 appName", str(first)[:90])
            check("frame" in first, "窗口带 frame", str(first)[:90])
            # 窗口标题受屏幕录制权限管控：它为空说明枚举发生在无权限进程里，
            # 而那正是 list_windows 默认要走 app 内执行的理由。
            if not first.get("title"):
                print(
                    "    · 注：窗口标题为空。若本条由 CLI 触发，"
                    "说明它没有走 anShot.app 枚举（--direct？）。"
                )

        print("\n[6/7] 参数与错误路径")
        cases = [
            ({"unknown_param": 1}, "未知参数被拒绝"),
            ({"maxsize": 100}, "拼错的参数名被拒绝"),
            ({"region": [1, 2]}, "region 分量不足被拒绝"),
            ({"max_size": -1}, "max_size 为负被拒绝"),
            ({"display_id": 999_999}, "不存在的显示器被拒绝"),
            # 窗口寻址与显示器/区域寻址互斥：同时给出必须报错，
            # 静默取其一会让调用方拿到一张「看起来正常但不是它要的」图。
            ({"window_id": 1, "region": [0, 0, 10, 10]}, "window_id 与 region 混用被拒绝"),
            ({"app": "X", "display_id": 1}, "app 与 display_id 混用被拒绝"),
            ({"window_id": 1, "app": "X"}, "window_id 与 app 混用被拒绝"),
            ({"window_id": 1, "space_id": 1}, "window_id 与 space_id 混用被拒绝"),
            ({"space_id": 0}, "无效桌面 ID 被拒绝"),
            ({"allow_switch": True}, "未指定桌面时不能启用切换"),
            ({"window_id": 999_999_999}, "不存在的窗口被拒绝"),
            ({"app": "NoSuchApplication-anshot-smoke"}, "不存在的应用名被拒绝"),
        ]
        for arguments, label in cases:
            tool_result = server.call_tool("capture_screenshot", arguments).get("result", {})
            check(tool_result.get("isError") is True, label, tool_text(tool_result)[:90])

        # 成功路径：截图由 anShot.app 自己完成，复用它的屏幕录制授权，
        # 因此**与调用它的宿主有没有权限无关**。MCP 服务器总是被宿主 spawn 的，
        # 永远没有自己的 TCC 身份——就地截图会把授权要求推给宿主，那是错的设计。
        #
        # 所以这里要求的就是「返回图像」：拿不到图像说明这条链路断了。
        # 若某个环境确实没有可启动的 anShot.app，会退回就地截图并给出
        # 可操作的权限指引——那属于可解释的降级，脚本据此区分并如实标注。
        plain = server.call_tool("capture_screenshot").get("result", {})
        kinds = [block.get("type") for block in plain.get("content", [])]
        if plain.get("isError"):
            text = tool_text(plain)
            is_permission = "屏幕录制权限" in text
            check(is_permission, "失败时必须是可操作的权限指引", text[:90])
            print("    · 注：本次未能启动可用的 anShot.app，降级为就地截图且当前进程无授权。")
            print("      这是可解释的降级，但**不是**预期路径，请检查 anShot.app 是否完整。")
        else:
            check("image" in kinds, "capture_screenshot 返回 image content")
            check("text" in kinds, "同时返回尺寸与区域文本")
            images = [b for b in plain.get("content", []) if b.get("type") == "image"]
            decoded = len(base64.b64decode(images[0]["data"])) if images else 0
            check(decoded > 0, "图像数据可解码且非空", f"{decoded} 字节")
            check(images[0].get("mimeType") == "image/png", "mimeType 为 image/png")
            print(f"    · 注：成功返回 {decoded} 字节 PNG（由 anShot.app 以自己的授权截取）。")

        # ── 按窗口截图 ──────────────────────────────────────────────
        #
        # 这条路径的全部意义是**能截到被遮挡、不在最顶层的窗口**——
        # 它无法用「整屏截图 + 裁剪」替代，因为被遮挡的部分在屏幕上根本不存在。
        #
        # 这里断言的是协议与产物链路（选了窗口就真的返回一张图，
        # 且元数据说明来源窗口）。「截出来的内容是否是该窗口」
        # 属于需要人眼判断的事，不在这里断言。
        if windows:
            first_window = windows[0]
            window_id = first_window["id"]
            app_name = first_window["appName"]

            print(f"\n[7/7] 按窗口截图（window_id={window_id}, app={app_name}）")

            windowed = server.call_tool(
                "capture_screenshot", {"window_id": window_id}
            ).get("result", {})
            if windowed.get("isError"):
                check(False, "按 window_id 截图成功", tool_text(windowed)[:150])
            else:
                window_kinds = [b.get("type") for b in windowed.get("content", [])]
                check("image" in window_kinds, "窗口截图返回 image content")
                check(
                    "已捕获窗口" in tool_text(windowed),
                    "窗口截图的元数据标明来源窗口",
                    tool_text(windowed)[:120],
                )

            by_app = server.call_tool(
                "capture_screenshot", {"app": app_name}
            ).get("result", {})
            check(
                by_app.get("isError") is False,
                f"按 app={app_name} 截图成功",
                tool_text(by_app)[:120],
            )
            if not by_app.get("isError"):
                check(
                    "已捕获窗口" in tool_text(by_app),
                    "按应用名截图同样标明了来源窗口",
                    tool_text(by_app)[:120],
                )
        else:
            print("\n[7/7] 按窗口截图 —— 跳过（当前没有可截图的窗口）")

        if offscreen_window_id is not None:
            print(f"\n[额外] 按窗口 ID 截取非在屏窗口（{offscreen_window_id}）")
            target = next((item for item in windows if item.get("id") == offscreen_window_id), None)
            check(target is not None, "窗口列表包含指定窗口")
            check(target.get("isOnScreen") is False, "目标窗口当前不在屏")
            if desktop_id is not None:
                check(desktop_id in target.get("spaceIDs", []), "窗口关联到指定桌面")
            for attempt in range(offscreen_repetitions):
                offscreen = server.call_tool(
                    "capture_screenshot", {"window_id": offscreen_window_id, "max_size": 1000}
                ).get("result", {})
                check(
                    offscreen.get("isError") is False,
                    f"非在屏窗口第 {attempt + 1} 次截图成功",
                    tool_text(offscreen)[:150],
                )
                check(any(block.get("type") == "image" for block in offscreen.get("content", [])), "返回图像")
                check("窗口不在当前可见桌面" in tool_text(offscreen), "元数据提示非在屏内容可能过期")

        if desktop_id is not None:
            print(f"\n[额外] 切换到桌面 {desktop_id} 截图并恢复")
            target = next((item for item in desktops if item.get("id") == desktop_id), None)
            check(target is not None, "目标桌面存在")
            display_id = target["displayID"]
            original = next(
                (item for item in desktops if item.get("displayID") == display_id and item.get("isCurrent")),
                None,
            )
            check(original is not None and original.get("id") != desktop_id, "目标桌面与当前桌面不同")
            blocked = server.call_tool(
                "capture_screenshot", {"space_id": desktop_id, "display_id": display_id}
            ).get("result", {})
            check(blocked.get("isError") is True, "默认不切换桌面", tool_text(blocked)[:200])
            check("默认不会切换" in tool_text(blocked), "失败提示后台窗口与显式切换选项")
            capture = server.call_tool(
                "capture_screenshot", {
                    "space_id": desktop_id, "display_id": display_id, "allow_switch": True, "max_size": 1000
                }
            ).get("result", {})
            check(capture.get("isError") is False, "跨桌面整屏截图成功", tool_text(capture)[:200])
            check(any(block.get("type") == "image" for block in capture.get("content", [])), "返回整屏图像")
            updated = json.loads(tool_text(server.call_tool("list_desktops")["result"]))["desktops"]
            check(
                any(item.get("id") == original["id"] and item.get("displayID") == display_id
                    and item.get("isCurrent") for item in updated),
                "截图后恢复原桌面",
            )

        print("\n[收尾] 关闭 stdin 后退出")
        exit_code = server.close_and_wait()
        check(exit_code == 0, "退出码为 0", str(exit_code))

        # stdout 不得被日志污染：到这一步 responses 里不应有解析失败项
        polluted = [k for k in server.responses if isinstance(k, tuple)]
        check(not polluted, "stdout 上只有协议消息（无日志污染）", str(polluted[:2]))
        check(
            any("anshot MCP server" in chunk for chunk in server.stderr_chunks),
            "日志出现在 stderr",
        )

    except Failure:
        server.kill()
        raise
    finally:
        server.kill()

    print("\n全部断言通过。")


def main() -> int:
    parser = argparse.ArgumentParser(description="anShot MCP stdio 冒烟测试")
    parser.add_argument("--binary", help="anShot 可执行文件路径（默认自动查找）")
    parser.add_argument("--offscreen-window-id", type=int, help="额外验证指定的非在屏窗口")
    parser.add_argument("--offscreen-repetitions", type=int, default=1, help="非在屏窗口截图次数")
    parser.add_argument("--desktop-id", type=int, help="额外验证切换到指定桌面截图并恢复")
    options = parser.parse_args()
    if options.offscreen_repetitions < 1:
        parser.error("--offscreen-repetitions 必须大于 0")

    # 日志级别调到 debug，便于 stderr 断言
    os.environ.setdefault("ANSHOT_MCP_LOG", "notice")

    try:
        run(options.binary or find_binary(), options.offscreen_window_id, options.offscreen_repetitions, options.desktop_id)
    except Failure as failure:
        print(f"\n✘ 失败：{failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
