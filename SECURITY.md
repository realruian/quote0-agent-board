# 安全说明

## 报告安全问题

请不要在公开的 Issue 里描述安全问题。在仓库的 **Security** 标签页点 **Report a vulnerability**，通过 GitHub 的私密报告功能提交。

这是个人项目，我会尽快回复，但无法承诺时限。

## 这个项目接触哪些东西

评估风险时可以参考：

- **Agent 的钩子配置**：第一次打开 App 时在 `~/.claude/settings.json` 和 `~/.codex/hooks.json` 里追加钩子，每次改动前都会备份。
- **钩子收到的事件**：钩子脚本把事件的前 4 KB 通过本机 socket 交给 App，里面有对话编号、工作目录、工具名和提问的开头。socket 所在的目录只有当前用户能访问。
- **MindReset 的 API 密钥**：只存在 `~/.dot_api_key`（权限 600），只发给 `api_base` 配置的地址（默认是 MindReset 的官方地址）。在 App 的窗口里填写时，App 向 MindReset 验证后写入这个文件，之后不会再显示它。
- **Python 版的本地设置页**（App 不监听任何网络端口）：只监听 `127.0.0.1`。请求必须带正确的 Host 和页面自带的一次性口令，修改类请求还要校验 Origin。菜单栏 App 从 `~/.quote0-agent-board/run/console.json` 读端口和口令，这个文件和所在目录只有当前用户能访问。
- **发往云端的内容**：只有渲染好的 296×152 黑白图。

## 支持的版本

只维护最新的发布版本。
