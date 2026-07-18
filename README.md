# Civ6Mods — 海克斯大乱斗 Dev

基于工坊原版「海克斯大乱斗」的开发分支，拓展新的海克斯因子，叠加 **FireTuner / civ6-mcp**，让外部大模型在人类确认海克斯后，为各 AI 从候选卡中择一并写下决策理由。
本项目纯AI生成。

本仓库包含：

| 目录 | 内容 |
|------|------|
| [`Haikesi_Dev/`](Haikesi_Dev/) | 海克斯大乱斗 Dev 模组（不与工坊原版同时启用）。将本目录整体复制到：`%USERPROFILE%\Documents\My Games\Sid Meier's Civilization VI\Mods\Haikesi_Dev\` |
| [`civ6-mcp-haikesi/`](civ6-mcp-haikesi/) | 基于 [civ6-mcp](https://github.com/lmwilki/civ6-mcp) 的本地副本，含海克斯 AI 决策扩展（不向 upstream 推送） |

---

## 描述

本项目实现「**人类选海克斯 → 外部大模型决策 → 写回 AI 海克斯与理由**」闭环：

1. **模组侧（`Haikesi_Dev`）**  
   在开启「AI 可选海克斯」与「外部大模型 AI 海克斯」时，人类确认选卡后挂起异步请求；超时则确定性回退。支持联机主机权威发放、AI 专属海克斯池扩展、资源创建型海克斯、南蛮入侵等效果，并在追踪面板展示大模型决策理由。

2. **工具侧（`civ6-mcp-haikesi`）**  
   - **单机**：FireTuner 轮询 → 调模型 → Stage → UI 广播 `ExtAIApply`。  
   - **联机**（引擎禁 FireTuner）：尾 `Lua.log` 结构化 dump（含与单机对齐的领袖局势 CTX）→ 调模型 → 主机在 ExtAI 输入框 Ctrl+V 落地（选卡/`LuaEvents` 事件驱动，非每帧轮询；`HAIKESI_WATCH_MODE=auto|log`）。  
   亦可由 Cursor Agent 经 MCP 半自动调试（单机 Tuner）。

密钥仅放在本地 `.env`（已 `.gitignore`），仓库只保留 [`.env.example`](civ6-mcp-haikesi/.env.example)。

---

## 前置

另需：文明 6（含 Gathering Storm）；**单机**另需 Development Tools（FireTuner，AppID 404350）与 `EnableTuner 1`；**联机**用 watch LOG 通道时建议窗口模式。完整步骤见下方「启动配置」文档。

### 继承与借鉴（仓库内独立实现，不依赖）

下列项目为本仓库的继承基线或思路来源；相关能力已在本仓库内自行落地，**运行时不要求启用对应工坊模组 / 上游仓库**。

1. **civ6-mcp（上游 MCP 仓库）**  
   https://github.com/lmwilki/civ6-mcp  
   本仓库内 [`civ6-mcp-haikesi/`](civ6-mcp-haikesi/) 为其 vendored 副本（含 Haikesi 扩展）；上游 provenance 见 [`civ6-mcp-haikesi/UPSTREAM.md`](civ6-mcp-haikesi/UPSTREAM.md)。

2. **海克斯大乱斗（原模组 · Steam 创意工坊）**  
   https://steamcommunity.com/sharedfiles/filedetails/?id=3751996207  
   建议先订阅原版了解玩法；本地开发请启用本仓库的 `Haikesi_Dev`（勿与工坊同 ID 模组混用导致数据错乱）。

3. **Builder Plants Resources（建造者可建造资源）**  
   https://steamcommunity.com/sharedfiles/filedetails/?id=3758337710  
   「种地仙人」的种植入口与扣充能思路借鉴自该模组；本仓库已独立实现，不依赖、也不要求启用该工坊模组。

### 拓展依赖（软依赖）

下列模组增强体验，**非硬性必需**；建议与海克斯 PVE / 外部大模型流程一并启用。

1. **Real Strategy / RST（Steam 创意工坊）**  
   https://steamcommunity.com/sharedfiles/filedetails/?id=1617282434  
   AI 行为增强；与海克斯及外部大模型选卡流程配合使用。

---

## 更新日志

相较于工坊原版海克斯大乱斗，本仓库 Dev 分支新增/修复的内容如下。**有意义的功能更新在本表顶部追加一行**（含日期与简述）；同一功能未提交前的迭代修补不要另起多行，合并进该功能条目即可。

| 上传日期 | 描述 |
|----------|------|
| 2026-07-18 | **联机 ExtAI 事件驱动**：去掉每帧 `GameCoreEventPublishComplete` 轮询，改为选卡/`LuaEvents`/EditBox 粘贴驱动；减轻后期卡顿与横幅丢失。 |
| 2026-07-18 | **联机 CTX 补全**：Gameplay dump 用 `HasTech`/`HasCivic` 计数与 UI 军力缓存；关系/不满经 UI 外交缓存 + Script 侧 `GetDiplomaticState` 回退，避免交战仍显示中立、不满全 0。 |
| 2026-07-18 | **南蛮入侵补兵**：缺营时仅在该城 5 环内已有蛮寨均分补兵；环内无可用寨则在该城 4 环生成 6 单位（不再扫全图老寨叠兵）。 |
| 2026-07-18 | **种地仙人**：解锁回合 `MinTurn` 改为 0（开局即可进入棱彩池）。 |
| 2026-07-16 | **玩家海克斯「高翔导航」**：首都获赠特殊单位「翔」；3 环内与己方交战的非友军单位 -1 移动力；可捕获；模型复用补给车队。 |
| 2026-07-16 | **联机外部大模型 AI 海克斯**：人类选卡后主机 watch 调模型；决策写入剪贴板与 exchange.json；手动 Ctrl+V 落地；局势上下文与单机对齐。 |
| 2026-07-15 | **玩家海克斯「憨豆特工」**：首都获得特殊间谍「憨豆」；进攻任务成功时间谍等级 -4；该间谍在己方领土且最近城市有反间谍时，该城 +3 宜居。 |
| 2026-07-15 | **玩家海克斯「世外桃源」**：所有城市地块 +1 魅力；惊艳（魅力≥4）地块 +1 生产力。 |
| 2026-07-15 | **移除**：玩家海克斯「联合作战」（预期效果无法在引擎内稳定实现）。 |
| 2026-07-15 | **修复**：部分海克斯选卡后效果不生效（如赠单位未出现）；种地相关逻辑独立加载以避免冲突。 |
| 2026-07-15 | **玩家海克斯整理**：「种地仙人」「德古拉」「永生乐队」改为独立卡面；部分未实装占位卡恢复为待填充状态。 |
| 2026-07-15 | **玩家海克斯「掌上明猪」**：首都获赠特殊单位「娟」；娟周围 3 格内己方单位 +1 移动力。 |
| 2026-07-15 | **玩家海克斯「种地仙人」**：首都获赠特殊建造者，可在合法地块种植加成/奢侈资源（普通工人无此能力）。 |
| 2026-07-15 | **玩家海克斯「德古拉」**：立即在首都获得 3 个吸血鬼（仅秘密结社模式进入选卡池）。 |
| 2026-07-15 | **AI 海克斯扩展**：「混乱干扰」类（含南蛮入侵）；「和平互利」类（如天朝上国——国际商路对方 +1 科 +1 文、本方 +4 金 +2 信仰）。 |
| 2026-07-15 | **外部大模型选卡**：修复联机落地偶发崩溃与 pending 卡住；模型决策时可参考逐领袖迷雾视角、双向外交不满、世界会议决议等更完整局势。 |
| 2026-07-15 | **仓库首发**：联机 AI 海克斯发放修复；外部大模型为 AI 选卡并展示理由（超时自动规则回退）；人类新海克斯三角贸易、永生乐队；AI 池扩展南蛮入侵与多种资源创建类海克斯；附 civ6-mcp 与 DeepSeek 监听脚本。 |

---

## 大模型选择海克斯 · 启动配置

环境安装、高级设置开关、MCP / DeepSeek 监听脚本、Cursor Agent 调试流程等，见：

**[`Haikesi_Dev/FIRETUNER_MCP_SETUP.md`](Haikesi_Dev/FIRETUNER_MCP_SETUP.md)**

推荐快速路径：配置 `.env` 后，游戏进档并开启相关选项，另开终端常驻：

```powershell
Set-Location "G:\Civ6Mods\civ6-mcp-haikesi"
uv run python scripts/haikesi_deepseek_watch.py
```
