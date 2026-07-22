# ExtAI 领袖风格（knowledge/styles）

推断标签 + **选卡偏置**；**不**改写文明 6 / RST 局内 AI 行为。

设计流程见仓库 Skill：`.cursor/skills/haikesi-leader-style/SKILL.md`（Civ6Mods 根目录）。

## 三层注入（勿混用）

| 层 | 文件 | 何时注入 |
|----|------|----------|
| 合法性 | `_legality.md` | **始终** |
| 收益优先 | `_payoff.md` | 掷骰 **payoff**，或无风格 |
| 风格 cosplay | `<style_id>.md` | 掷骰 **cosplay** 时按风格注入 |

索引：`_index.json`（`version` / id / 显示名 / tags / signal_hints）。

兼容：`_universal.md` 仍存在；运行时收益策略以 `_payoff.md` 为准。

## 环境变量

需同时 `HAIKESI_LLM_TOOLS=1`（薄板 ToolLoop）。

| 变量 | 默认 | 含义 |
|------|------|------|
| `HAIKESI_LLM_STYLES` | `1` | 开关 |
| `HAIKESI_LLM_STYLE_COSPLAY_P` | `0.5` | 每人独立掷骰：&lt;p → cosplay，否则 payoff |
| `HAIKESI_LLM_STYLE_DICE_SEED` | （空） | 与 `request_id` 混合，复现审计 |
| `HAIKESI_STYLES_DIR` | （本目录） | 可选覆盖知识路径 |

见仓库根 `.env.example`。

## 运行时

- 分类 / 掷骰 / 注入：`src/civ_mcp/haikesi_styles.py`
- 接线：`haikesi_llm.py`（薄板）+ Session `styles` 锁定（`llm_chat_session`）
- 审计：决策 Meta `styles:`、`## Style Dice（审计）` JSON
- 单测：`tests/test_haikesi_styles.py`

## 风格一览（13）

推断：Civ6 可观测信号打分竞优（≥3 入选；同分看优先级）。仅影响 LLM 选 `NW_AI_*`。

### Warlord

| id | 名 | 要旨 |
|----|----|------|
| `demonic_warlord` | 恶魔督军 | 混乱 + 开战 |
| `militant_warlord` | 好战督军 | 战斗 echo、无混乱 |
| `imperial_warlord` | 帝国督军 | 多城 + 产/工人扩张 |
| `economic_warlord` | 经济督军 | 高金养战 |
| `strategist_warlord` | 谋略督军 | 交战 + 科技武装 |

### Merchant

| id | 名 | 要旨 |
|----|----|------|
| `artisan_merchant` | 工匠商人 | 产/金/商路/奇观向；科或文 |
| `competitive_merchant` | 竞争商人 | 金权优先，奇观靠后 |

### Diplomat

| id | 名 | 要旨 |
|----|----|------|
| `authoritarian_diplomat` | 威权外交官 | 高 favor / 使者·外交向 |
| `chivalrous_diplomat` | 侠义外交官 | 友好网、favor 不高、反混乱 |

### Isolationist

| id | 名 | 要旨 |
|----|----|------|
| `fanatic_isolationist` | 狂热隐士 | 高信仰；宗教或征服 |
| `solitary_isolationist` | 孤僻隐士 | 少商路、防务、低信仰 |

### Sage / Spy

| id | 名 | 要旨 |
|----|----|------|
| `erudite_sage` | 博学贤者 | 科技；默认不选战斗 echo（仅被宣战危机） |
| `deceptive_spy` | 欺诈间谍 | 文化/favor 代理；间接手段 |

灵感来自 AoW4 人格，但映射为 **Civ6 信号 → 选卡 Skill**，不是局内人格注入。

## 新增风格清单

1. 选定稳定 `style_id`（snake_case）
2. 写 `styles/<id>.md`：理念 / 推断判据 / cosplay 偏好序 / tags
3. 更新 `_index.json`
4. 在 `haikesi_styles.py` 增加 `classify_*` 并挂入 `_STYLE_CLASSIFIERS` / `_STYLE_PRIORITY`
5. 补单测；可选同步 `.cursor/skills/haikesi-leader-style/examples/`

## 相关

- 词典：[`../civilopedia/README.md`](../civilopedia/README.md)
- 策略短文：`../civ6/*.md`（`civ6_kb` 回退）
