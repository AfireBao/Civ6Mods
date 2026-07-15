# Civ6Mods — 海克斯大乱斗 Dev

基于工坊原版「海克斯大乱斗」的开发分支，叠加 **FireTuner / civ6-mcp**，让外部大模型在人类确认海克斯后，为各 AI 从候选卡中择一并写下决策理由。

本仓库包含：

| 目录 | 内容 |
|------|------|
| [`Haikesi_Dev/`](Haikesi_Dev/) | 海克斯大乱斗 Dev 模组（替换/并行于工坊原版使用） |
| [`civ6-mcp-haikesi/`](civ6-mcp-haikesi/) | 基于 [civ6-mcp](https://github.com/lmwilki/civ6-mcp) 的本地副本，含海克斯 AI 决策扩展（不向 upstream 推送） |

---

## 描述

本项目实现「**人类选海克斯 → 外部大模型读局势 → 经 FireTuner 为 AI 提交海克斯选择与理由**」的单机/开发闭环：

1. **模组侧（`Haikesi_Dev`）**  
   在开启「AI 可选海克斯」与「外部大模型 AI 海克斯」时，人类确认选卡后挂起异步请求；超时则确定性回退。支持联机主机权威发放、AI 专属海克斯池扩展、资源创建型海克斯、南蛮入侵等效果，并在追踪面板展示大模型决策理由。

2. **工具侧（`civ6-mcp-haikesi`）**  
   通过 FireTuner 轮询待决策请求，调用 DeepSeek / OpenAI 兼容 / Anthropic 等后端完成择卡与理由生成，再 `submit_haikesi_ai_choices` 写回游戏。亦可由 Cursor Agent 经 MCP 半自动调试。

密钥仅放在本地 `.env`（已 `.gitignore`），仓库只保留 [`.env.example`](civ6-mcp-haikesi/.env.example)。

---

## 前置

使用本项目前请先准备：

1. **civ6-mcp（上游 MCP 仓库）**  
   https://github.com/lmwilki/civ6-mcp  
   本仓库内 [`civ6-mcp-haikesi/`](civ6-mcp-haikesi/) 为其 vendored 副本（含 Haikesi 扩展）；上游 provenance 见 [`civ6-mcp-haikesi/UPSTREAM.md`](civ6-mcp-haikesi/UPSTREAM.md)。

2. **海克斯大乱斗（原模组 · Steam 创意工坊）**  
   https://steamcommunity.com/sharedfiles/filedetails/?id=3751996207  
   建议先订阅原版了解玩法；本地开发请启用本仓库的 `Haikesi_Dev`（勿与工坊同 ID 模组混用导致数据错乱）。

3. **Real Strategy / RST（Steam 创意工坊）**  
   https://steamcommunity.com/sharedfiles/filedetails/?id=1617282434  
   AI 行为增强依赖；与海克斯 PVE / 外部大模型流程配合使用。

另需：文明 6（含 Gathering Storm）、**Development Tools（FireTuner，AppID 404350）**、`AppOptions.txt` 中 `EnableTuner 1` 与窗口模式。完整步骤见下方「启动配置」文档。

---

## 本项目修改

相较于工坊原版海克斯大乱斗，本仓库 Dev 分支新增/修复的内容如下。**后续每次有意义的更新请在本表顶部追加一行**（含日期与简述）。

| 上传日期 | 描述 |
|----------|------|
| 2026-07-15 | **仓库首发**：联机/非 0 号位 AI 海克斯发放修复（主机权威 + 确定性 `AIChoices` 回退）；新增「外部大模型 AI 海克斯」异步决策（FireTuner / MCP 提交 choices + reasons，超时确定性回退）；追踪面板展示决策理由；AI 海克斯池扩展——南蛮入侵、资源创建类型（棉花/烟草/糖/丝绸/茶等，数据表 `Haikesi_Relic_ResourceSpawns`）；vendored `civ6-mcp-haikesi` 与 DeepSeek/通用 LLM 监听脚本。 |

---

## 大模型选择海克斯 · 启动配置

环境安装、高级设置开关、MCP / DeepSeek 监听脚本、Cursor Agent 调试流程等，见：

**[`Haikesi_Dev/FIRETUNER_MCP_SETUP.md`](Haikesi_Dev/FIRETUNER_MCP_SETUP.md)**

推荐快速路径：配置 `.env` 后，游戏进档并开启相关选项，另开终端常驻：

```powershell
Set-Location "G:\Civ6Mods\civ6-mcp-haikesi"
uv run python scripts/haikesi_deepseek_watch.py
```
