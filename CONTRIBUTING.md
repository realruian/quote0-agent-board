# 参与贡献

欢迎提 Issue 和 Pull Request。这是一个个人项目，回复可能不及时，请见谅。

## 提 Issue 之前

- 先打开设置页的「诊断」页点一次"一键自检"，把结果贴上来，大部分问题能直接定位。
- 日志在 `~/.quote0-agent-board/logs/daemon.log`。贴日志前请看一眼，里面会有你的项目文件夹名。
- 不要贴 API 密钥和设备序列号。

## 本地开发

需要 macOS、Python 3.9 或更新版本，以及 Pillow：

```bash
python3 -m pip install -r requirements.txt
python3 -m unittest discover -s tests
```

调试时另开一个实例，它用单独的目录和端口，只渲染不推送，不会碰你的设备：

```bash
AGENT_BOARD_HOME="$PWD/.dev-home" AGENT_BOARD_DRY_RUN=1 AGENT_BOARD_PORT=8766 python3 -m agent_board.daemon
```

然后打开 <http://127.0.0.1:8766>。两点注意：

- `AGENT_BOARD_HOME` 的路径不能太长，本机 socket 的路径上限是 104 个字符。
- 这个实例的「集成」和「设备」页操作的仍然是真实的钩子配置和设备，调试时不要点里面的开关。

改动要生效到正式运行的版本，重新运行一次安装脚本：

```bash
python3 install.py
```

## 代码结构

| 文件 | 职责 |
|---|---|
| `bin/agent-board-hook` | 钩子脚本，把事件转发给后台进程 |
| `agent_board/daemon.py` | 后台进程：接收事件、决定何时刷屏 |
| `agent_board/state.py` | 对话的状态机 |
| `agent_board/render.py` | 把状态渲染成 296×152 的黑白图 |
| `agent_board/names.py` | 读取对话名称 |
| `agent_board/usage.py` | 读取剩余额度 |
| `agent_board/dot_api.py` | MindReset 开放 API 的客户端 |
| `agent_board/hooks.py` | 在 Agent 的配置文件里增删钩子 |
| `agent_board/web.py`、`agent_board/web/` | 本地设置页 |
| `install.py` | 安装和卸载 |

## 提交改动

- 运行时只依赖 Python 标准库和 Pillow，请不要引入新的依赖。
- 改了行为就补测试。测试不访问网络，也不读写真实的用户目录。
- 改了画面就重新生成 README 里的示例图：`python3 scripts/render_samples.py`。
- 示例图和测试数据里不要出现真实的对话名称、路径或设备序列号。
- 屏幕是纯黑白的，文字和图标不做抗锯齿；新增的画面元素请对齐 `render.py` 开头定义的网格。
