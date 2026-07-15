# Haikesi Dev — 问题分析与开发改动

## 背景

PVE「AI 海克斯」流程：人类玩家在 UI 确认海克斯时，由**某一端**为所有 AI 随机挑选 AI 专用海克斯，经 `param.AIChoices` 随 `HaikesiSelectRelic` 下发；Gameplay 端校验并 `ApplyRelicToPlayer`。

原实现假定 **Player 0** 既是主机又是第一个人类，在联机、换座位或非 0 号人类开局时会失效或重复执行。

## 已发现的问题

### 1. UI 侧用 `Game.GetLocalPlayer() == 0` 打包 AIChoices

- **现象**：只有本地玩家 ID 为 0 的客户端会在确认时生成 `AIChoices`。
- **影响**：人类坐在 1、2… 号位时，AI 海克斯永远不会被写入请求；或只有 0 号玩家确认时 AI 才有海克斯。
- **根因**：把「地图槽位 0」误当成「网络主机 / 权威端」。

### 2. Gameplay 侧用 `iPlayer == 0 and pPlayer:IsHuman()`

- **现象**：只有 Player0 的人类确认才会处理 `AIChoices`。
- **影响**：与 UI 条件叠加后，非 0 人类几乎无法驱动 AI 海克斯；联机下各端可能重复或无人处理。
- **根因**：同上，应使用 `Network.IsGameHost()` 且 `iPlayer` 为**发起选择的人类**（任意座位）。

### 3. `HaikesiAIRelics` 带 `Criteria NW_HAIKESI_AI_RELIC`

- **现象**：仅当高级设置勾选 AI 海克斯时才加载 `Haikesi_AI_Relics.sql`。
- **Dev 需求**：开发分支始终加载 AI  relic SQL，避免调试时忘记开选项导致数据表缺失、校验失败。

### 4. 同一选择轮次重复处理 AIChoices（联机风险）

- **现象**：`HaikesiSelectRelic` 可能在主机上被多次触发（或重复事件），导致同一轮 AI 海克斯重复发放尝试。
- **缓解**：在请求者玩家上记录 `PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT`，与即将递增的 `SELECT_COUNT before Trigger increment (countBefore)` 对齐；已处理则跳过并打日志。

## 本次改动（Haikesi_Dev）

| 文件 | 改动 |
|------|------|
| `Haikesi.modinfo` | 名称增加 `Dev`；`HaikesiAIRelics` 移除 `<Criteria>`，SQL 始终加载 |
| `UI/Haikesi_Panel.lua` | AIChoices 条件：`GetLocalPlayer() == 0` → `Network.IsGameHost()` |
| `GamePlay/Haikesi_GamePlay_Script.lua` | AIChoices：`Haikesi_IsGameHost()` + `pPlayer:IsHuman()`；countBefore guard |
| `DEV_NOTES.md` | 本文件 |

## 相关逻辑（未改）

- **`UI/Haikesi_Panel.lua`**：`Open()` / `OnPlayerTurnActivated` 仍按**本地玩家**触发面板；`OnInit` 注册 `Haikesi_TogglePanel` 等。
- **`GamePlay/Haikesi_Trigger.lua`**：监听 `HaikesiSelectRelic`，递增 `PROP_NW_HAIKESI_SELECT_COUNT` 与 PVE 时代记录（与 AI 轮次 guard 的 `+1` 语义一致）。

## 建议测试

1. 单机 PVE：开 AI 海克斯，人类非 0 号位（若可设）或默认 0，确认 AI 获得海克斯。
2. 联机：人类非主机座位确认一次，仅主机日志出现 AI 发放；重复触发不应二次发放（guard 日志）。
3. Dev mod：未勾选 AI 海克斯选项时，`Haikesi_AI_Relics.sql` 仍应加载（Modifier/类型存在）。

## 代码对照（摘要）

### UI — 确认时附加 AIChoices

**Before:** `if Game.GetLocalPlayer() == 0 and (GameConfiguration.GetValue('NW_HAIKESI_AI_RELIC') or false) then`

**After:** `if Network.IsGameHost() and (GameConfiguration.GetValue('NW_HAIKESI_AI_RELIC') or false) then`

### Gameplay — `HaikesiSelectRelic`

**Before:** `if iPlayer == 0 and pPlayer:IsHuman() and ... and param.AIChoices ~= nil then`

**After:** 主机 + 人类请求者 + 配置开启 + `aiAppliedForCount ~= countBefore`；处理前 `SetProperty('PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT', selectionRound)`；已处理则 `elseif ... skip` 日志。

### modinfo

**Before:** `<Criteria>NW_HAIKESI_AI_RELIC</Criteria>` 在 `HaikesiAIRelics` 内。

**After:** 已删除 Criteria；`<Name>... V0.9 Dev</Name>`。

## Event order (verified)

- UI: `UI.RequestPlayerOperation(..., EXECUTE_SCRIPT)` with `OnStart = 'HaikesiSelectRelic'` fires custom `GameEvents.HaikesiSelectRelic`.
- Handlers register on `Events.LoadScreenClose`: **GamePlay** (load 16796) first → `HaikesiSelectRelic`; **Trigger** (load 16797) second → `OnRelicSelected`.
- Dispatch order: **Gameplay applies relic + AIChoices first**, then Trigger **increments** `PROP_NW_HAIKESI_SELECT_COUNT`.
- Round guard uses **`countBefore = SELECT_COUNT` at handler entry** (not +1). Property `PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT` stores the count index already processed; duplicate calls with the same `countBefore` skip.

## Network.IsGameHost in Gameplay

- `Network.IsGameHost()` is the standard MP host check in Civ6 in-game scripts; this repo had no prior usage.
- Gameplay uses `Haikesi_IsGameHost()` with fallback: if `Network` missing, treat non-network multiplayer as host (SP/local).
- UI keeps `Network.IsGameHost()` when attaching `AIChoices` (host-only client packs choices into the operation param).

## MP / 非主机人类确认（补充修复）

### 问题
联机中非主机人类确认海克斯时，`param.AIChoices` 为空（仅主机 UI 会打包 AI 选择），导致该轮 AI 未获得海克斯。

### 修复
- 抽取 `Haikesi_ApplyAIChoicesForRound(requesterPlayerID, aiChoicesTable, countBefore)`。
- 主机 GameCore 在 `NW_HAIKESI_AI_RELIC` 开启且**任意人类**完成 `HaikesiSelectRelic` 时：
  - 若 `param.AIChoices` 存在 → 使用主机 UI 下发的表（含 math.random）。
  - 若缺失 → `Haikesi_BuildDeterministicAIChoices` + `PickAIRelicDeterministic`（salt = `countBefore * 1000 + aiID + requesterPlayerID`）。
- 防重复仍为 `PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT == countBefore`（`countBefore` 为 Trigger 递增前的 `SELECT_COUNT`）。

### 建议测试
1. **单机 + AI 海克斯**：人类选一次，确认所有 AI 获得 AI 池海克斯。
2. **联机，主机人类确认**：日志含「主机下发 AI 海克斯」或 GamePlay 使用 UI 表；AI 获得与主机 UI 一致（随机）。
3. **联机，非主机人类确认**：非主机客户端无 `AIChoices`；**主机** Lua.log 应出现 `Host generated deterministic AIChoices`；各 AI 获得海克斯且各客户端一致。
4. **同轮重复事件**：第二次应打印 `AIChoices already applied for select count … skip`。
5. **读档/LoadScreenClose 后**：重复步骤 2–3，确认 AI 仍正常、无重复发放。

### modinfo
- `<Authors>` 应为 **千川白浪**。

## 资源创建类型（Haikesi_Relic_ResourceSpawns）

数据驱动：Lua 通用流程读表生成资源（含改良避坑）。扩展同类型只需：

1. `Haikesi_Relics` + 文本/图标（AI 则再进 `AI_RELIC_TYPES`）
2. `Haikesi_Relic_ResourceSpawns` 加一行
3. 可选占位 Modifier

| 字段 | 含义 | 默认 |
|------|------|------|
| ResourceType | 资源 Type | 必填 |
| Amount | 生成地块数 | 1 |
| Radius / MinDistance | 距城环数 | 3 / 1 |
| CityTarget | `NEWEST` 或 `CAPITAL` | NEWEST |
| PreferOwned / AllowUnowned / AllowForeign | 领土优先级 | 1 / 1 / 0 |
| ResourceCount | SetResourceType 数量 | 1 |

**例：勇敢的木** `NW_AI_BRAVE_WOOD` → 最新城市 3 环 4 棉花。

## NW_AI_BARBARIAN_INVASION（南蛮入侵，Dev 新增）

### 实测注意（14 个后不再出新的）

1. **必须开新档**：修改 `Haikesi_AI_Relics.sql` 后需重新开局，旧存档的数据库仍是 14 种 AI 海克斯。
2. **只启用 Dev 版**：工坊原版 `AI_RELIC_TYPES` 只有 14 项，且与 Dev 同 Mod ID 易混用。
3. **15 个选满后仍会停**：`IsRepeatable=0`，每个 AI 终身最多 15 种不同 AI 海克斯；第 15 个即为「南蛮入侵」。
4. **互斥逻辑已修**：仅剩「南蛮入侵」可选的 AI 会优先占用本轮唯一名额，避免被其他 AI 抢互斥后空过。

