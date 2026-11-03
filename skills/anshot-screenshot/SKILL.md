---
name: anshot-screenshot
description: "用 anShot 获取 macOS 桌面截图，让 agent 真正「看到」界面而不是靠推测。当需要「看一眼屏幕」「截图确认布局」「UI 调试需要看到实际渲染」「复现视觉问题时对照截图」「截某个应用/窗口的图」「用户说截个图 / 看看现在的界面」时使用。支持整屏、屏幕区域，以及**被遮挡、不在最顶层**的应用窗口。默认复用 anShot 自身已有的屏幕录制授权，不需要给终端或 AI 客户端授权。"
---

# anShot 桌面截图

用 anShot 截取 macOS 屏幕或某个窗口，让 agent 能真正**看到**界面，而不是靠推测。

**命令入口**：下文一律用 `anshot`，它装在 `~/.local/bin/anshot`。

若提示 `command not found`，用仓库内的等价入口替代（把 `anshot` 换成
`<anShot 仓库>/tools/anshot`），或先安装：

```bash
mkdir -p ~/.local/bin && ln -sfn "<anShot 仓库>/tools/anshot" ~/.local/bin/anshot
```

---

## 一、先选对取景方式（这一步决定成败）

| 你想做的事 | 用什么 | 为什么 |
|---|---|---|
| 看**某个应用**现在长什么样 | `--app <应用名>` | 窗口被遮挡、不在最顶层也能截到完整内容；不需要知道它在哪 |
| 看某个**具体窗口** | `--window <id>`（id 来自 `anshot list-windows`） | 精确到窗口；同一应用有多个窗口时用它 |
| 看屏幕上**某个位置** | `--region x,y,w,h` | 你能说出坐标时用；注意单位是逻辑点 |
| 看**整块屏幕** | 不传参数 | 主屏整屏 |

> **优先用 `--app` / `--window`。** 只要目标是一个应用或窗口，就不要绕道
> 「先找到窗口坐标、再按坐标截区域」——那既容易算错，也无法截到被遮挡的部分。

**截图不要激活窗口。** 不要在截图前通过 AppleScript `activate`、`set frontmost to true`、
`AXRaise`、应用切换快捷键或其他方式把目标应用带到前台。窗口截图失败或内容为空时，
应说明系统限制，不要自行切换桌面或激活应用。截图与点击等界面操作是不同的步骤；
如果界面操作确实需要切到前台，须先取得用户对这种干扰的明确同意。

```bash
anshot list-windows                     # 有哪些窗口可选（应用名 / 标题 / id）
anshot capture --app Safari --out /tmp/safari.png
anshot capture --window 1234  --out /tmp/win.png
```

---

## 二、命令行用法

```bash
anshot capture --out /tmp/shot.png                      # 主屏整屏
anshot capture --app Safari --out /tmp/safari.png       # 某个应用（推荐）
anshot capture --window 1234 --out /tmp/win.png         # 某个窗口
anshot capture --region 0,0,800,600 --out /tmp/shot.png # 屏幕区域
anshot capture --max-size 0 --out /tmp/shot.png         # 原始分辨率
anshot list-displays                                    # 有哪些屏幕
anshot list-desktops                                    # 各屏桌面与当前状态
anshot list-windows                                     # 有哪些窗口
```

成功时 stdout 打印结果 JSON：

```json
{
  "capture": {
    "displayId": 1,
    "pixelWidth": 2560,
    "pixelHeight": 1665,
    "savedPath": "/tmp/shot.png",
    "scaleFactor": 2,
    "sourcePixelWidth": 2940,
    "sourcePixelHeight": 1912,
    "window": {
      "windowId": 1234,
      "applicationName": "Safari",
      "title": "Apple",
      "x": 0, "y": 0, "width": 1470, "height": 900
    }
  },
  "ok": true
}
```

拿到 `savedPath` 后，**用 `read` 工具读取该 PNG** 即可看到画面。
（`window` 字段只在按窗口截图时出现，整屏 / 区域截图时没有它。）

`list-windows` 返回的每一项：

| 字段 | 说明 |
|---|---|
| `id` | 窗口 ID，传给 `--window` |
| `appName` | 应用名，可直接传给 `--app` |
| `title` | 窗口标题。**可能为空**——那表示该窗口本就没有标题（不少应用的主窗口如此），不是错误 |
| `frame` | 窗口矩形（全局逻辑点，原点主屏左上） |
| `displayID` | 所在显示器 |
| `spaceIDs` | 所属桌面 ID 数组，可与 `list-desktops` 的 `id` 关联；系统无法确定时省略 |
| `isOnScreen` | 是否在当前可见桌面（被遮挡仍算在屏）；`false` 可能是在其他桌面、最小化或隐藏 |

列表已按「在屏优先、面积降序」排好，通常**第一项**就是最该看的那个。
列表也包含其他桌面的窗口：同一应用有多个窗口时，优先按标题选择 `id`。
这些窗口可尝试用 `--window` / `window_id` 截图，但系统可能返回空图或旧内容；
最小化或隐藏的窗口也可能无法捕获。

---

## 三、坐标系（最容易搞错的一条）

`--region x,y,w,h` 与 MCP 的 `region` 都是：

> **显示器内逻辑点，原点在该显示器左上角。**

- **不是**像素
- **不是**全局坐标
- **不是**左下原点

`输出像素 = 逻辑点 × scaleFactor`（Retina 屏 scaleFactor = 2）。

例：`--region 0,0,400,300` → 输出 **800×600 像素**。

先跑 `list-displays`，用返回的 `logicalSize` 校验区域是否越界。

> `--window` / `--app` 不需要这些——这也正是它们更可靠的原因。

---

## 四、命令行要点

```bash
anshot path           # 打印实际使用的可执行文件路径
anshot list-displays  # 显示器列表（不需要屏幕权限）
anshot list-windows   # 窗口列表（标题需要屏幕权限；应用名不需要）
anshot mcp            # 以 MCP stdio 服务端运行（前台，会阻塞）
anshot help           # 完整用法
anshot capture --direct ...    # 用当前进程的授权就地截图（一般不需要）
```

- **stdout 始终是结果 JSON**（含 `ok` 字段），失败也是合法 JSON；
  给眼睛看的诊断在 stderr
- 产物**绝不覆盖已有文件**：同名时自动追加 `-2`、`-3`…
  **以返回的 `savedPath` 为准**，不要假定等于你请求的路径
- 父目录不存在会自动创建
- 退出码：0 成功；1 失败；2 参数用法错误（如 `--mcp` 与截图选项混用）

---

## 五、MCP 方式（同样不需要授权）

先运行 `anshot path`，将输出的绝对路径填入下面的 `command`。
不要假定 `/Applications` 中的版本与当前项目构建一致。
配置（Snow App / Claude Code / Cursor / pi 同为 `mcpServers` 结构）：

```json
{
  "mcpServers": {
    "anshot": {
      "command": "<anshot path 的完整输出>",
      "args": ["--mcp"]
    }
  }
}
```

工具：

| 工具 | 说明 |
|---|---|
| `list_displays` | 列出显示器（id / 逻辑尺寸 / 像素尺寸 / scaleFactor / 全局位置）。只读 |
| `list_desktops` | 列出显示器对应的桌面 ID、位置、普通桌面序号和活动状态。只读 |
| `list_windows` | 列出各桌面的窗口（`id` / 应用名 / 标题 / 矩形 / 所在显示器 / `spaceIDs`）。只读；能否截图以实际捕获为准 |
| `capture_screenshot` | 取景三选一：`window_id`、`app`、或 `display_id`+`region`；可选 `space_id` / `allow_switch`、`max_size`、`save_path`。返回 PNG 图像 + 元数据。**可写盘**（传了 `save_path` 时） |

推荐调用顺序：`list_windows` → 选一个 `window_id`（或用 `app`）→ `capture_screenshot`。
`app` 优先选择当前在屏窗口；要精确选择后台窗口请传 `window_id`。
默认不切换桌面。确需其他桌面的**完整画面**时，先取得用户对切换桌面的明确同意，
再用 `list_desktops` 找到其 `id`，传 `space_id` 和 `allow_switch: true`；CLI 对应
`--space <id> --switch-desktop`。不得因工具返回切换选项而自行视为用户已同意。
切换需要辅助功能权限、已启用 Control + 左右方向键，且键盘焦点位于目标显示器。
切换会短暂影响屏幕，截图后恢复；不能满足条件时会报错，不自动更改系统设置。

传入未知参数名会被**显式拒绝**（不会被静默忽略）。
`window_id`/`app` 与 `display_id`/`space_id`/`region` 混用同样会被拒绝并说明原因。

MCP 服务器虽然是被宿主 spawn 的、自己没有 TCC 身份，但它内部会让 anShot.app
去截图与枚举窗口，所以**宿主无需任何授权**。若返回权限错误，那是 anShot 自身的问题。

---

## 六、失败排查

| 现象 | 原因与处理 |
|---|---|
| `缺少屏幕录制权限…` | 默认路径下基本不会出现。它只意味着两件事之一：① 你用了 `--direct`（去掉即可）；② **anShot.app 自身**没被授权。去「系统设置 → 隐私与安全性 → 屏幕录制」，**以列表里实际显示的条目为准**：有 anShot 就打开它；只有终端则说明是 `--direct` 造成的。开关本就打开却仍报错时，重启对应应用。本工具**不会**主动弹授权框 |
| `没有找到应用「X」的可截图窗口` | 应用名拼错，或系统未列出该应用的窗口。错误信息里会列出**当前可用的应用名**，照它改；或用 `list-windows` 看全量列表 |
| `系统未提供目标窗口的可捕获内容` | 窗口可能关闭、隐藏、最小化或无法由系统共享；恢复窗口或切到其所在桌面后重试 |
| `窗口 #N 不存在或已关闭` | 窗口列表与截图之间窗口被关了。重新 `list-windows` 取新 ID |
| 窗口列表里没有标题（title 为空） | 该窗口确实没有标题，或用 `--direct` 在无权限进程里枚举。改用 `appName` 判断即可；按窗口截图本身不受影响 |
| 命令长时间无输出，或提示找不到支持自动化的 app | 可能选到了不支持自动化接口的旧版本。跑 `anshot path` 确认；旧版本会把参数当未知参数、以 GUI 模式常驻。可用 `ANSHOT_APP=/path/to/anShot.app` 显式指定 |
| 提示等待 anShot 实例超时 | 自启动的子实例没能正常结束。按错误里的命令手动执行一次即可看到原因：`open -n "<anShot.app>" --args --capture --direct --out /tmp/a.png` |
| `显示器 #N 不存在` | 先跑 `list-displays`，用返回的 `id` |
| `region 与该显示器没有有效交集` | 检查单位是逻辑点、原点在左上；对照 `list-displays` 的 `logicalSize` |
| `--out 与 --json-out 指向同一个文件` | 给两者不同路径，否则 JSON 会覆盖刚写好的 PNG |
| 截出来的区域不对 | 十有八九是把像素当成了逻辑点，或用了全局坐标 |
| 图偏大/偏糊 | 默认长边 2560 会缩放。要原始分辨率传 `--max-size 0`；要更省 token 传更小的值 |
| 窗口截图里有黑色/旧内容区域 | 其他桌面的窗口或少数应用（游戏、视频渲染）可能不再更新不可见内容；切换到窗口所在桌面后重试 |

---

## 七、使用边界

- 截图内容是**用户真实桌面**：可能包含密码管理器、私人聊天、银行页面等。
  **优先用 `--app` / `--window` 只截需要的那个窗口**；用区域时只截需要的区域，
  不要无谓地整屏截图
- 用完的临时截图建议删除
- 分辨率上限的意义是省 token，但**像素计数类的判断**
  （如「这个按钮宽 400 像素吗」）必须用 `--max-size 0` 拿原始分辨率，
  或先看返回元数据里的 `sourcePixelWidth`
- 每次截图会启动一个 app 子实例（已有的实例收不到新的 `--args`），
  完成后自行退出，实测端到端约 0.2 秒；它的界面副作用已刻意关闭
  （不装菜单栏图标、不注册热键、`-g` 后台启动不抢焦点）
