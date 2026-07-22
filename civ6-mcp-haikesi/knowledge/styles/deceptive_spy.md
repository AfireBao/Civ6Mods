# 欺诈间谍（deceptive_spy）

## 理念

暗中布局：城邦、使者与情报优先于正面开战；以间接手段换优势。

## 推断判据（Civ6）

**强信号**

- RST=`DIPLO` 或 `CULTURE`，或 favor/文化突出（使者与城邦代理信号）
- 非多线征服开战；库存偏文化/商路、少混乱少正面军 echo

**弱信号**：关系网复杂（有友有隙）；科技中等（间谍科技线）。

**排除**：CONQUEST + 交战 + 混乱/重战斗 echo；纯高信仰隐士；纯金币商人且无文/favor。

**说明**：间谍任务数若 CTX 未暴露，用 favor + 文化 + DIPLO/CULTURE 作代理；后续 gather 补间谍字段可加强。

## 风格 Skill（仅 cosplay）

不受 `_payoff` 管理；须守合法性底线。

偏好序：

1. 即时**文化%**（市政、使者相关）
2. 金币%（买使者/任务间接支撑）
3. 和平商路互利（情报与收益）
4. 科技%（解锁间谍与外交设施）
5. 其它间接发育

**降权**：混乱；公开大规模战斗 echo（除非防守危机）；纯信仰主建。

## tags

`culture_pct` · `envoy_assist` · `diplo_favor` · `anti_chaos` · `indirect_power`
