# Display HUD (`agy-hud`)

Antigravity 显示增强插件 + 原生 macOS 右侧悬浮监控窗（`AgyHUD.app`）。

## 功能特性

- **右侧透明悬浮窗**：自动停靠在 Antigravity 窗口右侧；Antigravity 在前台时自动显示，切换到其他应用时自动隐藏（可通过菜单栏钉选为全局置顶或折叠为迷你药丸）。
- **Context 长度**：实时展示当前会话上下文长度（`input_tokens + cache_read_tokens`）、缓存命中率、本轮增量、输出 token，以及双色进度条与压缩阈值刻度。
- **TPS（生成速度）**：展示上一轮 TPS、会话平均 TPS、峰值 TPS、生成中实时计时，以及近期轮次速度 Sparkline。
- **Context 压缩长度**：展示自动压缩触发阈值、距离触发压缩的剩余空间，以及已发生的压缩次数、`压缩前 → 压缩后` token 数与压缩率、摘要长度。
- **配额消息（默认折叠）**：默认折叠为单行摘要（展示当前模型剩余配额百分比与重置倒计时），点击即可展开查看账号档位、AI Credits、分组模型配额条与手动刷新按钮。

## 隐私与性能

- 仅使用被动生命周期 Hook（`SessionStart`、`PreInvocation`、`PostInvocation`、`Stop`），不注册任何 MCP 工具或 `PreToolUse`，**零模型上下文开销**、不改变任何工具审批流程。
- CSRF Token 仅通过 `0600` 权限的本地 Unix Domain Socket 传入悬浮窗内存，**绝不写入磁盘**；`quota.json` 与 `runtime-state.json` 仅保存脱敏后的非敏感统计信息。

## 菜单栏控制

可在 macOS 顶部菜单栏图标中控制：
- 显示/隐藏悬浮窗、切换迷你药丸模式
- 仅 Antigravity 前台显示 / 全局置顶
- 吸附回 Antigravity 右侧
- 展开/折叠配额面板、立即刷新配额
- 切换追踪的对话（默认自动跟随活跃对话）
