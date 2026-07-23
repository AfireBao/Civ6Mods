#!/usr/bin/env python3
"""Generate Civ6Mods/ExtAI_领袖性格对照.md from styles knowledge files."""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STYLES = ROOT / "civ6-mcp-haikesi" / "knowledge" / "styles"
OUT = ROOT / "ExtAI_领袖性格对照.md"

STYLE_NAMES = {
    "demonic_warlord": "恶魔督军",
    "militant_warlord": "好战督军",
    "imperial_warlord": "帝国督军",
    "economic_warlord": "经济督军",
    "strategist_warlord": "谋略督军",
    "artisan_merchant": "工匠商人",
    "competitive_merchant": "竞争商人",
    "authoritarian_diplomat": "威权外交官",
    "chivalrous_diplomat": "侠义外交官",
    "fanatic_isolationist": "狂热隐士",
    "solitary_isolationist": "孤僻隐士",
    "erudite_sage": "博学贤者",
    "deceptive_spy": "欺诈间谍",
}
VL_NAMES = {
    "CONQUEST": "征服",
    "SCIENCE": "科技",
    "CULTURE": "文化",
    "RELIGION": "宗教",
    "DIPLO": "外交",
}
FAMILY = {
    "demonic_warlord": "督军",
    "militant_warlord": "督军",
    "imperial_warlord": "督军",
    "economic_warlord": "督军",
    "strategist_warlord": "督军",
    "artisan_merchant": "商人",
    "competitive_merchant": "商人",
    "authoritarian_diplomat": "外交/间谍",
    "chivalrous_diplomat": "外交/间谍",
    "deceptive_spy": "外交/间谍",
    "fanatic_isolationist": "隐士",
    "solitary_isolationist": "隐士",
    "erudite_sage": "贤者",
}
BLURB = {
    "demonic_warlord": "混乱干扰 + 开战向；可接受南蛮/仇水等",
    "militant_warlord": "战斗 echo / 军事向；避免混乱",
    "imperial_warlord": "多城扩张 + 产力/工人",
    "economic_warlord": "高金养战",
    "strategist_warlord": "交战 + 科技武装",
    "artisan_merchant": "产/金/商路/奇观；科或文发展",
    "competitive_merchant": "金权与商路优先，奇观靠后",
    "authoritarian_diplomat": "高 favor / 使者与外交向",
    "chivalrous_diplomat": "友好网、反混乱、和平优先",
    "fanatic_isolationist": "高信仰；宗教或征服",
    "solitary_isolationist": "内商偏重、防务内政",
    "erudite_sage": "科技优先；默认不选战斗 echo",
    "deceptive_spy": "文化/favor 代理；间接手段",
}


def main() -> None:
    baselines = json.loads((STYLES / "leader_baselines.json").read_text(encoding="utf-8"))
    index = json.loads((STYLES / "_index.json").read_text(encoding="utf-8"))
    leaders: dict = baselines["leaders"]
    n = len(leaders)
    style_counts = Counter(v["style_id"] for v in leaders.values())
    lean_counts = Counter(v["victory_lean"] for v in leaders.values())
    family_counts = Counter(FAMILY[v["style_id"]] for v in leaders.values())

    lines: list[str] = [
        "# ExtAI 领袖性格对照",
        "",
        "> 供对照查阅：风格比例、`LEADER_*` 基线、选卡 Skill。",
        ">",
        "> - 数据源：[`civ6-mcp-haikesi/knowledge/styles/leader_baselines.json`](civ6-mcp-haikesi/knowledge/styles/leader_baselines.json)、[`_index.json`](civ6-mcp-haikesi/knowledge/styles/_index.json)",
        "> - 运行时：[`haikesi_styles.py`](civ6-mcp-haikesi/src/civ_mcp/haikesi_styles.py)（推断分 ≥5 → 风格；否则历史原型兜底；Session 锁定优先）",
        "> - **仅影响 ExtAI 选卡**，不改写局内 AI / RST / RHAI",
        "> - 关 RST 时用 VictoryLean 填主战略标签；开 RST 仍读真战略",
        "> - 再生本页：`uv run python scripts/gen_extai_style_reference_md.py`（在 `civ6-mcp-haikesi` 下）",
        "",
        "## 1. 性格比例",
        "",
        f"基线条目合计：**{n}**（`LEADER_*`，含部分 Persona / 别名 Type）。",
        "",
        "### 按风格",
        "",
        "| 风格 | id | 人数 | 占比 |",
        "|------|----|-----:|-----:|",
    ]
    for sid, cnt in sorted(style_counts.items(), key=lambda x: (-x[1], x[0])):
        lines.append(
            f"| {STYLE_NAMES[sid]} | `{sid}` | {cnt} | {100 * cnt / n:.1f}% |"
        )

    lines += [
        "",
        "### 按族系",
        "",
        "| 族系 | 人数 | 占比 |",
        "|------|-----:|-----:|",
    ]
    for fam, cnt in sorted(family_counts.items(), key=lambda x: (-x[1], x[0])):
        lines.append(f"| {fam} | {cnt} | {100 * cnt / n:.1f}% |")

    lines += [
        "",
        "### 按基线胜线路 `victory_lean`",
        "",
        "| 胜线路 | 人数 | 占比 |",
        "|--------|-----:|-----:|",
    ]
    for lean, cnt in sorted(lean_counts.items(), key=lambda x: (-x[1], x[0])):
        lines.append(
            f"| {VL_NAMES.get(lean, lean)} (`{lean}`) | {cnt} | {100 * cnt / n:.1f}% |"
        )

    lines += [
        "",
        "说明：v4 已匀摊基线，各风格大约 4–8 人；督军族仍略多（征服向领袖本身更多）。"
        "主题优先于硬平均；`victory_lean` 主要作对照；VictoryLean 打分仍以 gather 局势为主。",
        "",
        "## 2. 领袖性格对照表",
        "",
        "| LeaderType | 风格 | style_id | 胜线路 | 原型短注 |",
        "|------------|------|----------|--------|----------|",
    ]
    for key in sorted(leaders):
        row = leaders[key]
        sid = row["style_id"]
        lean = row["victory_lean"]
        note = str(row.get("archetype_note") or "").replace("|", "/")
        lines.append(
            f"| `{key}` | {STYLE_NAMES[sid]} | `{sid}` | "
            f"{VL_NAMES.get(lean, lean)} | {note} |"
        )

    lines += [
        "",
        "## 3. 性格决策 Skill 表",
        "",
        "注入规则：合法性 [`_legality.md`](civ6-mcp-haikesi/knowledge/styles/_legality.md) **始终**；"
        "掷骰 **cosplay** → 风格 md；掷骰 **payoff** / 无风格 → [`_payoff.md`](civ6-mcp-haikesi/knowledge/styles/_payoff.md)。",
        "",
        "| 风格 | id | Skill 文件 | tags | signal_hints（推断提示） |",
        "|------|----|------------|------|--------------------------|",
    ]
    for style in index.get("styles") or []:
        sid = style["id"]
        tags = ", ".join(style.get("tags") or [])
        hints = ", ".join(style.get("signal_hints") or [])
        fname = style["file"]
        lines.append(
            f"| {style['name']} | `{sid}` | "
            f"[`{fname}`](civ6-mcp-haikesi/knowledge/styles/{fname}) | "
            f"{tags} | {hints} |"
        )

    lines += [
        "",
        "### Skill 要旨（一句话）",
        "",
        "| 风格 | 选卡要旨 |",
        "|------|----------|",
    ]
    for style in index.get("styles") or []:
        sid = style["id"]
        lines.append(f"| {style['name']} | {BLURB[sid]} |")

    lines += [
        "",
        "## 相关",
        "",
        "- 风格目录说明：[`civ6-mcp-haikesi/knowledge/styles/README.md`](civ6-mcp-haikesi/knowledge/styles/README.md)",
        "- 仓库首页：[`README.md`](README.md)",
        "",
    ]

    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {OUT} ({OUT.stat().st_size} bytes, {n} leaders)")


if __name__ == "__main__":
    main()
