# ExtAI 领袖性格对照

> 供对照查阅：风格比例、`LEADER_*` 基线、选卡 Skill。
>
> - 数据源：[`civ6-mcp-haikesi/knowledge/styles/leader_baselines.json`](civ6-mcp-haikesi/knowledge/styles/leader_baselines.json)、[`_index.json`](civ6-mcp-haikesi/knowledge/styles/_index.json)
> - 运行时：[`haikesi_styles.py`](civ6-mcp-haikesi/src/civ_mcp/haikesi_styles.py)（推断分 ≥5 → 风格；否则历史原型兜底；Session 锁定优先）
> - **仅影响 ExtAI 选卡**，不改写局内 AI / RST / RHAI
> - 关 RST 时用 VictoryLean 填主战略标签；开 RST 仍读真战略
> - 再生本页：`uv run python scripts/gen_extai_style_reference_md.py`（在 `civ6-mcp-haikesi` 下）

## 1. 性格比例

基线条目合计：**84**（`LEADER_*`，含部分 Persona / 别名 Type）。

### 按风格

| 风格 | id | 人数 | 占比 |
|------|----|-----:|-----:|
| 好战督军 | `militant_warlord` | 10 | 11.9% |
| 工匠商人 | `artisan_merchant` | 9 | 10.7% |
| 谋略督军 | `strategist_warlord` | 9 | 10.7% |
| 恶魔督军 | `demonic_warlord` | 7 | 8.3% |
| 狂热隐士 | `fanatic_isolationist` | 7 | 8.3% |
| 帝国督军 | `imperial_warlord` | 7 | 8.3% |
| 竞争商人 | `competitive_merchant` | 6 | 7.1% |
| 孤僻隐士 | `solitary_isolationist` | 6 | 7.1% |
| 威权外交官 | `authoritarian_diplomat` | 5 | 6.0% |
| 欺诈间谍 | `deceptive_spy` | 5 | 6.0% |
| 博学贤者 | `erudite_sage` | 5 | 6.0% |
| 侠义外交官 | `chivalrous_diplomat` | 4 | 4.8% |
| 经济督军 | `economic_warlord` | 4 | 4.8% |

### 按族系

| 族系 | 人数 | 占比 |
|------|-----:|-----:|
| 督军 | 37 | 44.0% |
| 商人 | 15 | 17.9% |
| 外交/间谍 | 14 | 16.7% |
| 隐士 | 13 | 15.5% |
| 贤者 | 5 | 6.0% |

### 按基线胜线路 `victory_lean`

| 胜线路 | 人数 | 占比 |
|--------|-----:|-----:|
| 征服 (`CONQUEST`) | 28 | 33.3% |
| 文化 (`CULTURE`) | 23 | 27.4% |
| 科技 (`SCIENCE`) | 17 | 20.2% |
| 宗教 (`RELIGION`) | 10 | 11.9% |
| 外交 (`DIPLO`) | 6 | 7.1% |

说明：v4 已匀摊基线，各风格大约 4–8 人；督军族仍略多（征服向领袖本身更多）。主题优先于硬平均；`victory_lean` 主要作对照；VictoryLean 打分仍以 gather 局势为主。

## 2. 领袖性格对照表

| LeaderType | 风格 | style_id | 胜线路 | 原型短注 |
|------------|------|----------|--------|----------|
| `LEADER_ABRAHAM_LINCOLN` | 谋略督军 | `strategist_warlord` | 科技 | 林肯：工业军工与解放 |
| `LEADER_ALEXANDER` | 好战督军 | `militant_warlord` | 征服 | 亚历山大：连胜不疲征服 |
| `LEADER_AMANITORE` | 帝国督军 | `imperial_warlord` | 征服 | 阿曼尼托尔：金字塔产力扩张 |
| `LEADER_AMBIORIX` | 恶魔督军 | `demonic_warlord` | 征服 | 安比奥里克斯：近战群殴与混乱施压 |
| `LEADER_BARBAROSSA` | 恶魔督军 | `demonic_warlord` | 征服 | 巴巴罗萨：铁冠征城邦、开战施压 |
| `LEADER_BASIL` | 狂热隐士 | `fanatic_isolationist` | 宗教 | 巴西尔二世：宗教战斗碾压 |
| `LEADER_CATHERINE_DE_MEDICI` | 欺诈间谍 | `deceptive_spy` | 文化 | 黑王后：情报与文化施压 |
| `LEADER_CATHERINE_DE_MEDICI_ALT` | 工匠商人 | `artisan_merchant` | 文化 | 荣光卡特琳：宫廷奢华与文旅 |
| `LEADER_CHANDRAGUPTA` | 谋略督军 | `strategist_warlord` | 征服 | 旃陀罗笈多：择机领土扩张 |
| `LEADER_CHARLEMAGNE` | 好战督军 | `militant_warlord` | 征服 | 查理曼（维京剧本专用 Type，非标准选人） |
| `LEADER_CLEOPATRA` | 竞争商人 | `competitive_merchant` | 文化 | 埃及艳后：同盟商路与地中海文旅 |
| `LEADER_CLEOPATRA_ALT` | 工匠商人 | `artisan_merchant` | 文化 | 托勒密克利奥帕特拉：泛滥地与文产 |
| `LEADER_CYRUS` | 谋略督军 | `strategist_warlord` | 征服 | 居鲁士：突袭机动征服 |
| `LEADER_DIDO` | 竞争商人 | `competitive_merchant` | 外交 | 狄多：迁都海权与商路 |
| `LEADER_ELEANOR_ENGLAND` | 欺诈间谍 | `deceptive_spy` | 文化 | 阿基坦埃莉诺：大作忠诚渗透 |
| `LEADER_ELEANOR_FRANCE` | 欺诈间谍 | `deceptive_spy` | 文化 | 阿基坦埃莉诺（法）：剧院忠诚渗透 |
| `LEADER_ELIZABETH` | 经济督军 | `economic_warlord` | 文化 | 伊丽莎白：海商私掠养战 |
| `LEADER_EMPRESS_WU` | 欺诈间谍 | `deceptive_spy` | 文化 | 武则天别名 |
| `LEADER_GANDHI` | 侠义外交官 | `chivalrous_diplomat` | 宗教 | 甘地：和平信仰与外交（亦防核突袭刻板） |
| `LEADER_GENGHIS_KHAN` | 恶魔督军 | `demonic_warlord` | 征服 | 成吉思汗：骑兵横扫 |
| `LEADER_GILGAMESH` | 侠义外交官 | `chivalrous_diplomat` | 科技 | 吉尔伽美什：盟友恩奇都、友谊优先（战则为友而战） |
| `LEADER_GITARJA` | 狂热隐士 | `fanatic_isolationist` | 宗教 | 季塔尔贾：信仰海军与群岛 |
| `LEADER_GORGO` | 好战督军 | `militant_warlord` | 征服 | 戈尔戈：杀戮换文化、尚武斯巴达 |
| `LEADER_HAMMURABI` | 博学贤者 | `erudite_sage` | 科技 | 汉谟拉比：欧卡洪流科技 |
| `LEADER_HARALD_ALT` | 帝国督军 | `imperial_warlord` | 征服 | 哈拉尔德·瓦兰吉：护教与远征 |
| `LEADER_HARDRADA` | 好战督军 | `militant_warlord` | 征服 | 哈拉尔德·哈德拉达（北境王）：维京劫掠与海岸征服 |
| `LEADER_HOJO` | 孤僻隐士 | `solitary_isolationist` | 文化 | 北条：神风冲区、防务内向武士道 |
| `LEADER_JADWIGA` | 狂热隐士 | `fanatic_isolationist` | 宗教 | 雅德维加：信仰与文化庇护 |
| `LEADER_JAYAVARMAN` | 狂热隐士 | `fanatic_isolationist` | 宗教 | 阇耶跋摩：水田圣城 |
| `LEADER_JOAO_III` | 竞争商人 | `competitive_merchant` | 外交 | 若昂三世：探索商路帝国 |
| `LEADER_JOHN_CURTIN` | 谋略督军 | `strategist_warlord` | 科技 | 柯廷：危机产力与防守反击 |
| `LEADER_JULIUS_CAESAR` | 经济督军 | `economic_warlord` | 征服 | 凯撒：劫掠黄金养战 |
| `LEADER_KRISTINA` | 威权外交官 | `authoritarian_diplomat` | 文化 | 克里斯蒂娜：巨作主题与文迪/favor |
| `LEADER_KUBLAI_KHAN_CHINA` | 竞争商人 | `competitive_merchant` | 科技 | 忽必烈（中）：商科双收 |
| `LEADER_KUBLAI_KHAN_MONGOLIA` | 经济督军 | `economic_warlord` | 征服 | 忽必烈（蒙）：商路养战 |
| `LEADER_KUPE` | 孤僻隐士 | `solitary_isolationist` | 文化 | 库佩：远洋开局与自然魅力 |
| `LEADER_LADY_SIX_SKY` | 孤僻隐士 | `solitary_isolationist` | 科技 | 六天夫人：城邦压制与紧凑发展 |
| `LEADER_LADY_TRIEU` | 好战督军 | `militant_warlord` | 征服 | 赵夫人别名（游戏 Type） |
| `LEADER_LAURIER` | 威权外交官 | `authoritarian_diplomat` | 外交 | 劳里埃：极地外交与宜居 |
| `LEADER_LAUTARO` | 好战督军 | `militant_warlord` | 征服 | 劳塔罗：抗击帝国游击 |
| `LEADER_LUDWIG` | 工匠商人 | `artisan_merchant` | 文化 | 路德维希：奇观文旅 |
| `LEADER_MANSA_MUSA` | 竞争商人 | `competitive_merchant` | 外交 | 曼萨·穆萨：黄金商路帝国 |
| `LEADER_MATTHIAS_CORVINUS` | 帝国督军 | `imperial_warlord` | 征服 | 匈雅提·马加什：征召城邦扩军帝国 |
| `LEADER_MENELIK` | 孤僻隐士 | `solitary_isolationist` | 宗教 | 孟尼利克：山地防务与内向科文 |
| `LEADER_MONTEZUMA` | 恶魔督军 | `demonic_warlord` | 征服 | 蒙特祖马：奢侈战争与扩张 |
| `LEADER_MVEMBA` | 侠义外交官 | `chivalrous_diplomat` | 文化 | 姆文巴：受教和平与雨林文旅 |
| `LEADER_NADER_SHAH` | 谋略督军 | `strategist_warlord` | 征服 | 纳迪尔沙阿：奢侈战斗与机动征服 |
| `LEADER_NZINGA_MBANDE` | 帝国督军 | `imperial_warlord` | 征服 | 恩津加：多城扩张 |
| `LEADER_PACHACUTI` | 孤僻隐士 | `solitary_isolationist` | 科技 | 帕查库特克：山地紧凑内政 |
| `LEADER_PEDRO` | 工匠商人 | `artisan_merchant` | 文化 | 佩德罗二世：伟人与雨林奇观向 |
| `LEADER_PERICLES` | 侠义外交官 | `chivalrous_diplomat` | 文化 | 伯里克利：城邦使者与文化同盟 |
| `LEADER_PETER_GREAT` | 博学贤者 | `erudite_sage` | 科技 | 彼得大帝：贸易区科文与西化 |
| `LEADER_PHILIP_II` | 狂热隐士 | `fanatic_isolationist` | 宗教 | 腓力二世：异教审判与舰队 |
| `LEADER_POUNDMAKER` | 威权外交官 | `authoritarian_diplomat` | 外交 | 庞德梅克：同盟共享与外交网 |
| `LEADER_QIN` | 工匠商人 | `artisan_merchant` | 文化 | 秦始皇（天命）：冲刺奇观与文化 |
| `LEADER_QIN_ALT` | 恶魔督军 | `demonic_warlord` | 征服 | 秦始皇·一统：南蛮转化与连战征服 |
| `LEADER_QIN_SHI_HUANG_UNIFIER` | 恶魔督军 | `demonic_warlord` | 征服 | 秦·一统别名 |
| `LEADER_RAMSES` | 帝国督军 | `imperial_warlord` | 文化 | 拉美西斯：建筑奇观文化 |
| `LEADER_ROBERT_THE_BRUCE` | 谋略督军 | `strategist_warlord` | 科技 | 罗伯特·布鲁斯：自由战争与科产 |
| `LEADER_SALADIN` | 狂热隐士 | `fanatic_isolationist` | 宗教 | 萨拉丁：信仰与科学并举 |
| `LEADER_SALADIN_ALT` | 好战督军 | `militant_warlord` | 宗教 | 萨拉丁·苏丹：圣战征服 |
| `LEADER_SEJONG` | 博学贤者 | `erudite_sage` | 科技 | 世宗：科技文化喷泉 |
| `LEADER_SEONDEOK` | 博学贤者 | `erudite_sage` | 科技 | 善德：科学文化双辉煌 |
| `LEADER_SHAKA` | 恶魔督军 | `demonic_warlord` | 征服 | 沙卡：军团碾压 |
| `LEADER_SIMON_BOLIVAR` | 谋略督军 | `strategist_warlord` | 征服 | 玻利瓦尔：解放战争与指挥 |
| `LEADER_SULEIMAN` | 经济督军 | `economic_warlord` | 征服 | 苏莱曼：扩张与黄金时代养战 |
| `LEADER_SULEIMAN_ALT` | 谋略督军 | `strategist_warlord` | 科技 | 苏莱曼·立法者：科文治理 |
| `LEADER_SULEIMAN_KANUNI` | 谋略督军 | `strategist_warlord` | 科技 | 苏莱曼·立法者别名 |
| `LEADER_SUNDIATA_KEITA` | 竞争商人 | `competitive_merchant` | 文化 | 松迪亚塔：市场巨作与金币买伟人 |
| `LEADER_TAMAR` | 狂热隐士 | `fanatic_isolationist` | 宗教 | 塔马尔：信仰护教与城邦 |
| `LEADER_THEODORA` | 工匠商人 | `artisan_merchant` | 文化 | 狄奥多拉：圣区文化建造 |
| `LEADER_TOKUGAWA` | 孤僻隐士 | `solitary_isolationist` | 科技 | 德川：国内商路封闭发展 |
| `LEADER_TOMYRIS` | 好战督军 | `militant_warlord` | 征服 | 托米丽司：轻骑复仇与征伐 |
| `LEADER_TRAJAN` | 帝国督军 | `imperial_warlord` | 文化 | 图拉真：免费建筑扩城、帝国文产 |
| `LEADER_TRIEU` | 好战督军 | `militant_warlord` | 征服 | 赵夫人：文化战斗与林区作战 |
| `LEADER_T_ROOSEVELT` | 工匠商人 | `artisan_merchant` | 文化 | 驼鹿泰迪：高魅力地块与公园文旅 |
| `LEADER_T_ROOSEVELT_ROUGHRIDER` | 好战督军 | `militant_warlord` | 征服 | 莽骑兵泰迪：美洲霸权征伐 |
| `LEADER_VICTORIA` | 帝国督军 | `imperial_warlord` | 征服 | 维多利亚：日不落扩张 |
| `LEADER_VICTORIA_ALT` | 工匠商人 | `artisan_merchant` | 科技 | 维多利亚·蒸汽：工业产力 |
| `LEADER_VICTORIA_STEAM` | 工匠商人 | `artisan_merchant` | 科技 | 维多利亚蒸汽别名 |
| `LEADER_WILFRID_LAURIER` | 威权外交官 | `authoritarian_diplomat` | 外交 | 劳里埃别名（游戏 Type 为 LEADER_LAURIER） |
| `LEADER_WILHELMINA` | 威权外交官 | `authoritarian_diplomat` | 文化 | 威廉明娜：商路忠诚与外交施压 |
| `LEADER_WU_ZETIAN` | 欺诈间谍 | `deceptive_spy` | 文化 | 武则天：间谍与文化 |
| `LEADER_YONGLE` | 博学贤者 | `erudite_sage` | 科技 | 永乐：人口科文金 |

## 3. 性格决策 Skill 表

注入规则：合法性 [`_legality.md`](civ6-mcp-haikesi/knowledge/styles/_legality.md) **始终**；掷骰 **cosplay** → 风格 md；掷骰 **payoff** / 无风格 → [`_payoff.md`](civ6-mcp-haikesi/knowledge/styles/_payoff.md)。

| 风格 | id | Skill 文件 | tags | signal_hints（推断提示） |
|------|----|------------|------|--------------------------|
| 恶魔督军 | `demonic_warlord` | [`demonic_warlord.md`](civ6-mcp-haikesi/knowledge/styles/demonic_warlord.md) | chaos, combat_echo, gold_military, tech_for_units, anti_peaceful_trade | RST=CONQUEST, at_war, high_grievance, chaos_inventory |
| 好战督军 | `militant_warlord` | [`militant_warlord.md`](civ6-mcp-haikesi/knowledge/styles/militant_warlord.md) | combat_echo, gold_military, tech_for_units, anti_chaos | RST=CONQUEST, at_war, combat_echo, no_chaos, mil_advantage |
| 帝国督军 | `imperial_warlord` | [`imperial_warlord.md`](civ6-mcp-haikesi/knowledge/styles/imperial_warlord.md) | prod_pct, builder_echo, combat_echo, expansion, anti_chaos | RST=CONQUEST, many_cities, prod_or_builder |
| 经济督军 | `economic_warlord` | [`economic_warlord.md`](civ6-mcp-haikesi/knowledge/styles/economic_warlord.md) | gold_pct, combat_echo, gold_military, anti_chaos | high_gold, CONQUEST_or_war |
| 谋略督军 | `strategist_warlord` | [`strategist_warlord.md`](civ6-mcp-haikesi/knowledge/styles/strategist_warlord.md) | science_pct, combat_echo, tech_for_units, anti_chaos | at_war, SCIENCE_or_high_sci, combat_or_tech_inv |
| 工匠商人 | `artisan_merchant` | [`artisan_merchant.md`](civ6-mcp-haikesi/knowledge/styles/artisan_merchant.md) | prod_pct, gold_pct, trade_mutual, builder_echo, sci_or_culture | RST=SCIENCE|CULTURE, trade_routes, prod_or_gold_inventory |
| 竞争商人 | `competitive_merchant` | [`competitive_merchant.md`](civ6-mcp-haikesi/knowledge/styles/competitive_merchant.md) | gold_pct, trade_mutual, prod_pct, anti_war | trade_busy, high_gold, gold_over_wonder |
| 威权外交官 | `authoritarian_diplomat` | [`authoritarian_diplomat.md`](civ6-mcp-haikesi/knowledge/styles/authoritarian_diplomat.md) | culture_pct, trade_mutual, diplo_favor, envoy_assist, anti_chaos | RST=DIPLO|CULTURE, high_favor, peaceful_relations |
| 侠义外交官 | `chivalrous_diplomat` | [`chivalrous_diplomat.md`](civ6-mcp-haikesi/knowledge/styles/chivalrous_diplomat.md) | culture_pct, trade_mutual, anti_chaos, anti_war, peace_first | RST=DIPLO|CULTURE, friendly_net, favor_not_high |
| 狂热隐士 | `fanatic_isolationist` | [`fanatic_isolationist.md`](civ6-mcp-haikesi/knowledge/styles/fanatic_isolationist.md) | faith_pct, religion_or_conquest, anti_trade, isolation | RST=RELIGION|CONQUEST, high_faith, domestic_trade |
| 孤僻隐士 | `solitary_isolationist` | [`solitary_isolationist.md`](civ6-mcp-haikesi/knowledge/styles/solitary_isolationist.md) | defense_echo, prod_pct, anti_trade, isolation, low_faith | domestic_trade, border_pressure, faith_not_high |
| 博学贤者 | `erudite_sage` | [`erudite_sage.md`](civ6-mcp-haikesi/knowledge/styles/erudite_sage.md) | science_pct, anti_war, combat_echo_only_under_dow, builder_echo | RST=SCIENCE, high_sci, peace_or_defensive |
| 欺诈间谍 | `deceptive_spy` | [`deceptive_spy.md`](civ6-mcp-haikesi/knowledge/styles/deceptive_spy.md) | culture_pct, envoy_assist, diplo_favor, anti_chaos, indirect_power | DIPLO|CULTURE, favor_or_culture, indirect_not_open_war |

### Skill 要旨（一句话）

| 风格 | 选卡要旨 |
|------|----------|
| 恶魔督军 | 混乱干扰 + 开战向；可接受南蛮/仇水等 |
| 好战督军 | 战斗 echo / 军事向；避免混乱 |
| 帝国督军 | 多城扩张 + 产力/工人 |
| 经济督军 | 高金养战 |
| 谋略督军 | 交战 + 科技武装 |
| 工匠商人 | 产/金/商路/奇观；科或文发展 |
| 竞争商人 | 金权与商路优先，奇观靠后 |
| 威权外交官 | 高 favor / 使者与外交向 |
| 侠义外交官 | 友好网、反混乱、和平优先 |
| 狂热隐士 | 高信仰；宗教或征服 |
| 孤僻隐士 | 内商偏重、防务内政 |
| 博学贤者 | 科技优先；默认不选战斗 echo |
| 欺诈间谍 | 文化/favor 代理；间接手段 |

## 相关

- 风格目录说明：[`civ6-mcp-haikesi/knowledge/styles/README.md`](civ6-mcp-haikesi/knowledge/styles/README.md)
- 仓库首页：[`README.md`](README.md)
