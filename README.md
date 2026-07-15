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

本项目实现「**人类选海克斯 → 外部大模型读局势 → 经 FireTuner 为 AI 提交海克斯选择与理由**」的单机/开发闭环：

1. **模组侧（`Haikesi_Dev`）**  
   在开启「AI 可选海克斯」与「外部大模型 AI 海克斯」时，人类确认选卡后挂起异步请求；超时则确定性回退。支持联机主机权威发放、AI 专属海克斯池扩展、资源创建型海克斯、南蛮入侵等效果，并在追踪面板展示大模型决策理由。

2. **工具侧（`civ6-mcp-haikesi`）**  
   通过 FireTuner 轮询待决策请求，调用 DeepSeek / OpenAI 兼容 / Anthropic 等后端完成择卡与理由生成，再 `submit_haikesi_ai_choices` 写回游戏。亦可由 Cursor Agent 经 MCP 半自动调试。

密钥仅放在本地 `.env`（已 `.gitignore`），仓库只保留 [`.env.example`](civ6-mcp-haikesi/.env.example)。

---

## 前置

另需：文明 6（含 Gathering Storm）、**Development Tools（FireTuner，AppID 404350）**、`AppOptions.txt` 中 `EnableTuner 1` 与窗口模式。完整步骤见下方「启动配置」文档。

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
| 2026-07-15 | **玩家海克斯「憨豆特工」**：新增 `BEANAGENTRUNE`（暂借未实装「踢踏舞」图标）；首都获赠特殊间谍「特工」（`UNIT_NW_BEAN`，`InitialLevel=2`）；类型名「特工」/实例显示名「憨豆」（面板兜底；间谍引擎侧 `NAME_UNIT` 通常不可用）；进攻任务成功等级 -4；该单位在己方领土且最近城市有反间谍时该城 +3 宜居（宜居挂 `ABILITY_NW_BEAN`，普通间谍不触发）。 |
| 2026-07-15 | **玩家海克斯「世外桃源」**：新增 `SHANGRILARUNE`（暂借未实装「不动如山」图标）；所有城市地块 +1 魅力；惊艳（魅力≥4）地块 +1 生产力（大地女神 GS 式城内地块产量 + 埃菲尔式全城魅力）。 |
| 2026-07-15 | **移除**：玩家海克斯「联合作战」（`JOINTOPSRUNE`）。引擎无「二环同盟/宗主城邦」计数 Effect，光环 GRANT 方案易崩溃，故删除卡面与全部 Modifier/文案/图标别名。 |
| 2026-07-15 | **修复**：`Haikesi_GamePlay_Script.lua` 文件级 local 触顶（Lua 5.1 寄存器上限）导致整文件加载失败、选卡不落地（娟等赠单位不出现）；种地逻辑拆至 `Haikesi_Planter_GamePlay.lua`。 |
| 2026-07-15 | **重构**：种地仙人 / 德古拉 / 永生乐队改为「新增 RelicType + 只借图标」；恢复原占位「当心葡萄柚」「不祥契约」「战争交响乐」（`IsActive=0`、效果待填充）。新键：`FARMIMMORTALRUNE` / `DRACULARUNE` / `ETERNALBANDRUNE`。（联合作战已移除） |
| 2026-07-15 | **玩家海克斯「掌上明猪」**：新增 `PEARLPIGRUNE`（卡面暂借未实装「群獭献礼」图标，占位不动）；首都获赠特殊单位「娟」（单位用猪鼻图标，3D 复用古典大将军）。娟周围 3 格内己方单位 +1 移动力（大将军 AOE 范式）。 |
| 2026-07-15 | **玩家海克斯「种地仙人」**：新增 `FARMIMMORTALRUNE`（暂借「当心葡萄柚」图标）；首都获赠特殊建造者，可在合法地形种植加成/奢侈资源（白名单 + `CanHaveResource`）；挂 `CLASS_BUILDER` 以吃金字塔等建造次数修正；普通工人无此能力。种植 UI 借鉴 BP_ResourcePlanter，不依赖该模组。白名单在 LoadOrder 16798 时从 `Resources` 表扫入（BONUS/LUXURY 且 Frequency 或 SeaFrequency > 0）；第三方资源模组若更晚写入 `Resources`，需自行补入 `Haikesi_PlanterResources` 或调高本模组加载顺序才会被捕获。 |
| 2026-07-15 | **玩家海克斯「德古拉」**：新增 `DRACULARUNE`（暂借「不祥契约」图标）；立即在首都获得 3 个吸血鬼。前置表新增 `CAPABILITY` 种类，仅秘密结社模式进入选卡池。 |
| 2026-07-15 | **AI 海克斯系列扩展**：新增「混乱干扰」系列（南蛮入侵归入）；新增「和平互利」系列与「天朝上国」——通往该文明城市的国际商路为对方 +1 科 +1 文、为本方 +4 金 +2 信仰（埃及同款 Incoming Trade Modifier）。 |
| 2026-07-15 | **外部大模型选卡加固与局势情报**：修复 ExtAI 落地时 `Haikesi_GetPlayerRelicCount` 前置声明错误（Apply 崩溃导致 pending 不清、下次选卡才随机补齐）；Apply/超时路径加 `pcall`；LLM Prompt 改为逐位领袖迷雾视角（本国城市、已遇文明、视野威胁、RST/宗教/胜利进度），并补齐**双向外交不满**、对方观感修饰语与**世界会议决议**；DeepSeek V4 默认关 thinking / JSON Mode、非法 JSON 自动重试；`.env.example` 补充模型与 token 说明。 |
| 2026-07-15 | **仓库首发**：联机/非 0 号位 AI 海克斯发放修复（主机权威 + 确定性 `AIChoices` 回退）；新增「外部大模型 AI 海克斯」异步决策（FireTuner / MCP 提交 choices + reasons，超时确定性回退）；追踪面板展示决策理由；**人类侧新海克斯**——三角贸易（`TRIANGULARTRADERUNE`，暂借三折光图标）、永生乐队（后迁为 `ETERNALBANDRUNE`，暂借战争交响乐图标；首都赠送高场地等级「终身乐队」）；AI 海克斯池扩展——南蛮入侵、资源创建类型（棉花/烟草/糖/丝绸/茶等，数据表 `Haikesi_Relic_ResourceSpawns`）；vendored `civ6-mcp-haikesi` 与 DeepSeek/通用 LLM 监听脚本。 |

---

## 大模型选择海克斯 · 启动配置

环境安装、高级设置开关、MCP / DeepSeek 监听脚本、Cursor Agent 调试流程等，见：

**[`Haikesi_Dev/FIRETUNER_MCP_SETUP.md`](Haikesi_Dev/FIRETUNER_MCP_SETUP.md)**

推荐快速路径：配置 `.env` 后，游戏进档并开启相关选项，另开终端常驻：

```powershell
Set-Location "G:\Civ6Mods\civ6-mcp-haikesi"
uv run python scripts/haikesi_deepseek_watch.py
```
