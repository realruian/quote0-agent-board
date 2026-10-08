# 参与贡献

欢迎提 Issue 和 Pull Request。这是一个个人项目，回复可能不及时，请见谅。

## 提 Issue 之前

- 先打开 App 窗口的「诊断」页点一次"一键自检"，把结果贴上来，大部分问题能直接定位。
- 日志在 `~/.quote0-agent-board/logs/daemon.log`。贴日志前请看一眼，里面会有你的项目文件夹名。
- 不要贴 API 密钥和设备序列号。

## 本地开发

正式版本是 `app/` 里的 Swift App，新功能只加在这里。需要 macOS 14 或更新版本和 Xcode 命令行工具：

```bash
swift test --package-path app
```

调试时另开一个实例，它用单独的目录，只渲染不推送，不会碰你的设备，也不会改动钩子和开机自启：

```bash
AGENT_BOARD_HOME="$PWD/.dev-home" AGENT_BOARD_DRY_RUN=1 AGENT_BOARD_RESOURCES="$PWD/agent_board" swift run --package-path app
```

两点注意：

- `AGENT_BOARD_HOME` 的路径不能太长，本机 socket 的路径上限是 104 个字符。
- 这个实例的「Agent」「刷新」和「设备」页操作的仍然是真实的钩子配置和设备，调试时不要点里面的开关。

改动要生效到正式运行的版本，重新构建，再用 `dist/` 里的 App 替换「应用程序」里的：

```bash
python3 scripts/build_app.py
```

### Python 版

`agent_board/`、`menubar/` 和 `install.py` 是项目最早的实现，不再加新功能，只修会影响使用的问题。App 仍然用到其中两样：`agent_board/fonts/` 里的字体，和 `agent_board/__init__.py` 里的版本号。

```bash
python3 -m pip install -r requirements.txt
python3 -m unittest discover -s tests
AGENT_BOARD_HOME="$PWD/.dev-home" AGENT_BOARD_DRY_RUN=1 AGENT_BOARD_PORT=8766 python3 -m agent_board.daemon
```

## 代码结构

| 文件 | 职责 |
|---|---|
| `bin/agent-board-hook` | 钩子脚本，把事件转发给 App |
| `app/Sources/BoardCore/Engine.swift` | 接收事件、决定何时刷屏 |
| `app/Sources/BoardCore/State.swift` | 对话的状态机 |
| `app/Sources/BoardCore/View.swift`、`Render.swift` | 决定一帧画面说什么，再画成 296×152 的黑白图 |
| `app/Sources/BoardCore/Names.swift`、`Interrupted.swift`、`Reviewer.swift` | 从 Agent 自己的对话记录里读对话名称、按 Esc 的中断、Codex 是否自动审查 |
| `app/Sources/BoardCore/Usage.swift` | 读取剩余额度 |
| `app/Sources/BoardCore/DotAPI.swift` | MindReset 开放 API 的客户端 |
| `app/Sources/BoardCore/Hooks.swift`、`HookSocket.swift` | 在 Agent 的配置文件里增删钩子；接收钩子脚本送来的事件 |
| `app/Sources/BoardCore/Console.swift` | 窗口各个页面读写数据的接口 |
| `app/Sources/AgentBoard/` | 窗口里的各个页面（`UI/`，SwiftUI）、菜单栏图标、首次启动时的安装和卸载 |
| `app/Tests/BoardCoreTests/` | `BoardCore` 的测试；它不依赖界面 |
| `scripts/build_app.py` | 打包成 App 和 DMG |
| `scripts/make_icons.py` | 把窗口用到的 Hugeicons 图标写进 `app/Sources/AgentBoard/UI/Icons.swift` |
| `agent_board/`、`menubar/main.swift`、`install.py`、`tests/` | Python 版：后台进程、本地设置页、菜单栏 App、安装脚本和测试 |

## 提交改动

- App 只用系统自带的框架，Python 版运行时只依赖标准库和 Pillow，请不要引入新的依赖。
- 改了行为就补测试。测试不访问网络，也不读写真实的用户目录。
- 改了画面就重新生成 README 里的示例图：`python3 scripts/render_samples.py`。
- 不引入 Xcode 工程，用 Swift Package 构建。App 的图标由 `python3 scripts/make_app_icon.py` 生成。
- 示例图和测试数据里不要出现真实的对话名称、路径或设备序列号。
- 屏幕是纯黑白的，文字和图标不做抗锯齿；新增的画面元素请对齐 `Render.swift` 开头定义的网格。
