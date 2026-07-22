#!/usr/bin/env python3
"""Export Civ6 Civilopedia + Haikesi relic dictionary for ExtAI tool lookup.

Reads local game Text (zh_Hans_CN) + Gameplay XML, plus Haikesi_Dev/Text.
Writes knowledge/civilopedia/index.json (committed artifact; re-run after game/mod updates).

Usage (from civ6-mcp-haikesi):
  uv run python scripts/export_civilopedia_index.py
  uv run python scripts/export_civilopedia_index.py --game-root "F:/SteamLibrary/.../Sid Meier's Civilization VI"
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

_REPO = Path(__file__).resolve().parents[1]  # civ6-mcp-haikesi
_CIV6_ROOT = _REPO.parent  # Civ6Mods
_DEFAULT_OUT = _REPO / "knowledge" / "civilopedia" / "index.json"
_DEFAULT_HAIKESI_TEXT = _CIV6_ROOT / "Haikesi_Dev" / "Text" / "Haikesi_Text.xml"

_LANG = "zh_Hans_CN"

# LOC_UNIT_FOO_NAME → kind=unit, id=UNIT_FOO
_KIND_PREFIXES: tuple[tuple[str, str], ...] = (
    ("UNIT_", "unit"),
    ("BUILDING_", "building"),
    ("DISTRICT_", "district"),
    ("TECH_", "tech"),
    ("CIVIC_", "civic"),
    ("RESOURCE_", "resource"),
    ("IMPROVEMENT_", "improvement"),
    ("BELIEF_", "belief"),
    ("POLICY_", "policy"),
    ("PROJECT_", "project"),
    ("FEATURE_", "feature"),
    ("GOVERNMENT_", "government"),
    ("GREATPERSON_", "great_person"),
    ("GREAT_PERSON_INDIVIDUAL_", "great_person"),
)

# Tag / Language attribute order varies across Vanilla vs Expansion files.
_REPLACE_RE = re.compile(
    r"<Replace\b([^>]*)>\s*<Text>(.*?)</Text>\s*</Replace>",
    re.DOTALL | re.IGNORECASE,
)

_ICON_RE = re.compile(r"\s*\[ICON_[^\]]+\]\s*", re.IGNORECASE)
_ROW_ATTR_RE = re.compile(r'(\w+)="([^"]*)"')


def _strip_text(raw: str) -> str:
    text = raw.replace("[NEWLINE]", " ").replace("\n", " ")
    text = _ICON_RE.sub(" ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def _parse_loc_file(path: Path) -> dict[str, str]:
    """Tag -> text for zh_Hans_CN only."""
    if not path.is_file():
        return {}
    # Large files: stream via regex on full read (Exp2 ~19MB OK)
    content = path.read_text(encoding="utf-8", errors="replace")
    out: dict[str, str] = {}
    for m in _REPLACE_RE.finditer(content):
        attrs = dict(_ROW_ATTR_RE.findall(m.group(1)))
        if attrs.get("Language") != _LANG:
            continue
        tag = attrs.get("Tag") or ""
        if not tag.startswith("LOC_"):
            continue
        body = _strip_text(m.group(2))
        if body:
            out[tag] = body
    return out


def _kind_and_id_from_name_tag(tag: str) -> tuple[str, str] | None:
    # LOC_HAIKESI_RELIC_* handled separately
    if not tag.startswith("LOC_") or not tag.endswith("_NAME"):
        return None
    core = tag[len("LOC_") : -len("_NAME")]
    for prefix, kind in _KIND_PREFIXES:
        if core.startswith(prefix):
            return kind, core
    return None


def _parse_units_table(path: Path) -> dict[str, dict]:
    """UnitType -> stats from <Units> Rows (Cost, Maintenance, PrereqTech, ...)."""
    if not path.is_file():
        return {}
    content = path.read_text(encoding="utf-8", errors="replace")
    # Narrow to Units table if possible
    m = re.search(r"<Units>(.*?)</Units>", content, re.DOTALL | re.IGNORECASE)
    block = m.group(1) if m else content
    stats: dict[str, dict] = {}
    for row in re.finditer(r"<Row\b([^>/]*)/?>", block):
        attrs = dict(_ROW_ATTR_RE.findall(row.group(1)))
        ut = attrs.get("UnitType")
        if not ut:
            continue
        # Skip TypeTags-only rows (no Cost)
        if "Cost" not in attrs and "Combat" not in attrs and "RangedCombat" not in attrs:
            continue
        entry: dict = {}
        for key in (
            "Cost",
            "Maintenance",
            "BaseMoves",
            "BaseSightRange",
            "Combat",
            "RangedCombat",
            "Range",
            "PrereqTech",
            "PrereqCivic",
            "PromotionClass",
            "Domain",
            "FormationClass",
        ):
            if key in attrs:
                entry[key] = attrs[key]
        if entry:
            stats[ut] = entry
    return stats


def _parse_simple_prereq_table(
    path: Path, *, type_attr: str, table: str | None = None
) -> dict[str, dict]:
    if not path.is_file():
        return {}
    content = path.read_text(encoding="utf-8", errors="replace")
    if table:
        m = re.search(rf"<{table}>(.*?)</{table}>", content, re.DOTALL | re.IGNORECASE)
        block = m.group(1) if m else content
    else:
        block = content
    stats: dict[str, dict] = {}
    for row in re.finditer(r"<Row\b([^>/]*)/?>", block):
        attrs = dict(_ROW_ATTR_RE.findall(row.group(1)))
        tid = attrs.get(type_attr)
        if not tid:
            continue
        entry = {
            k: v
            for k, v in attrs.items()
            if k
            in {
                "Cost",
                "Maintenance",
                "PrereqTech",
                "PrereqCivic",
                "PrereqDistrict",
                "Housing",
                "Entertainment",
                "CitizenSlots",
            }
        }
        if entry:
            stats[tid] = entry
    return stats


def _merge_loc_maps(maps: list[dict[str, str]]) -> dict[str, str]:
    merged: dict[str, str] = {}
    for m in maps:
        merged.update(m)  # later files override
    return merged


def build_civilopedia_entries(
    loc: dict[str, str],
    *,
    unit_stats: dict[str, dict],
    building_stats: dict[str, dict],
    district_stats: dict[str, dict],
    tech_stats: dict[str, dict],
) -> list[dict]:
    entries: list[dict] = []
    seen: set[str] = set()
    for tag, name in loc.items():
        parsed = _kind_and_id_from_name_tag(tag)
        if not parsed:
            continue
        kind, type_id = parsed
        if type_id in seen:
            continue
        seen.add(type_id)
        desc = loc.get(f"LOC_{type_id}_DESCRIPTION", "")
        # Prefer shorter DESCRIPTION over long PEDIA history
        entry: dict = {
            "id": type_id,
            "kind": kind,
            "chapter": "civilopedia",
            "name": name,
            "description": desc,
        }
        if kind == "unit" and type_id in unit_stats:
            entry["stats"] = unit_stats[type_id]
        elif kind == "building" and type_id in building_stats:
            entry["stats"] = building_stats[type_id]
        elif kind == "district" and type_id in district_stats:
            entry["stats"] = district_stats[type_id]
        elif kind == "tech" and type_id in tech_stats:
            entry["stats"] = tech_stats[type_id]
        entries.append(entry)
    entries.sort(key=lambda e: (e["kind"], e["id"]))
    return entries


def build_haikesi_entries(haikesi_text: Path) -> list[dict]:
    loc = _parse_loc_file(haikesi_text)
    entries: list[dict] = []
    name_re = re.compile(r"^LOC_HAIKESI_RELIC_(.+)_NAME$")
    for tag, name in loc.items():
        m = name_re.match(tag)
        if not m:
            continue
        relic_key = m.group(1)  # ARCANEPUNCHRUNE or NW_AI_ECHO_MELEE
        desc = loc.get(f"LOC_HAIKESI_RELIC_{relic_key}_DESCRIPTION", "")
        flavor = loc.get(f"LOC_HAIKESI_RELIC_{relic_key}_FLAVOR", "")
        # Canonical id: AI cards already NW_AI_*; human often without prefix
        if relic_key.startswith("NW_AI_") or relic_key.startswith("NW_"):
            type_id = relic_key
            audience = "ai" if relic_key.startswith("NW_AI_") else "mixed"
        else:
            type_id = relic_key
            audience = "human"
        entry = {
            "id": type_id,
            "kind": "haikesi_relic",
            "chapter": "haikesi",
            "audience": audience,
            "name": name,
            "description": desc,
        }
        if flavor:
            entry["flavor"] = flavor
        # Alias for lookup_relic compatibility
        if not type_id.startswith("NW_") and f"LOC_HAIKESI_RELIC_{type_id}_NAME" in loc:
            entry["aliases"] = [f"HAIKESI_RELIC_{type_id}"]
        entries.append(entry)
    entries.sort(key=lambda e: e["id"])
    return entries


def _default_game_root() -> Path | None:
    candidates = [
        Path(r"F:\SteamLibrary\steamapps\common\Sid Meier's Civilization VI"),
        Path(r"C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI"),
        Path(r"G:\SteamLibrary\steamapps\common\Sid Meier's Civilization VI"),
    ]
    env_raw = (__import__("os").environ.get("CIV6_GAME_ROOT") or "").strip()
    # Path("") == "." which is always a directory — must require non-empty.
    if env_raw:
        env = Path(env_raw)
        if env.is_dir():
            return env
    for c in candidates:
        if c.is_dir():
            return c
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--game-root", type=Path, default=None)
    ap.add_argument("--haikesi-text", type=Path, default=_DEFAULT_HAIKESI_TEXT)
    ap.add_argument("--out", type=Path, default=_DEFAULT_OUT)
    args = ap.parse_args()

    game = args.game_root or _default_game_root()
    if game is None or not game.is_dir():
        print("ERROR: Civ6 game root not found. Pass --game-root.", file=sys.stderr)
        return 1

    loc_files = [
        game / "Base" / "Assets" / "Text" / "Vanilla_zh_Hans_CN.xml",
        game / "DLC" / "Expansion1" / "Text" / "Expansion1_Translations_Text.xml",
        game / "DLC" / "Expansion1" / "Text" / "Expansion1_Translations_Major_Text.xml",
        game / "DLC" / "Expansion2" / "Text" / "Expansion2_Translations_Text.xml",
    ]
    loc_maps = []
    for p in loc_files:
        if p.is_file():
            print(f"LOC: {p} ...", flush=True)
            loc_maps.append(_parse_loc_file(p))
            print(f"  -> {len(loc_maps[-1])} zh strings", flush=True)
    loc = _merge_loc_maps(loc_maps)

    gp = game / "Base" / "Assets" / "Gameplay" / "Data"
    unit_stats: dict[str, dict] = {}
    for up in [
        gp / "Units.xml",
        game / "DLC" / "Expansion1" / "Data" / "Expansion1_Units.xml",
        game / "DLC" / "Expansion2" / "Data" / "Expansion2_Units.xml",
        game / "DLC" / "Expansion2" / "Data" / "Expansion2_Units_Major.xml",
    ]:
        unit_stats.update(_parse_units_table(up))

    building_stats: dict[str, dict] = {}
    for bp in [
        gp / "Buildings.xml",
        game / "DLC" / "Expansion1" / "Data" / "Expansion1_Buildings.xml",
        game / "DLC" / "Expansion2" / "Data" / "Expansion2_Buildings.xml",
    ]:
        building_stats.update(
            _parse_simple_prereq_table(bp, type_attr="BuildingType", table="Buildings")
        )

    district_stats = _parse_simple_prereq_table(
        gp / "Districts.xml", type_attr="DistrictType", table="Districts"
    )
    for dp in [
        game / "DLC" / "Expansion1" / "Data" / "Expansion1_Districts.xml",
        game / "DLC" / "Expansion2" / "Data" / "Expansion2_Districts.xml",
    ]:
        district_stats.update(
            _parse_simple_prereq_table(dp, type_attr="DistrictType", table="Districts")
        )

    tech_stats = _parse_simple_prereq_table(
        gp / "Technologies.xml", type_attr="TechnologyType", table="Technologies"
    )

    print("Building civilopedia entries...", flush=True)
    civ_entries = build_civilopedia_entries(
        loc,
        unit_stats=unit_stats,
        building_stats=building_stats,
        district_stats=district_stats,
        tech_stats=tech_stats,
    )
    print(f"  civilopedia: {len(civ_entries)}", flush=True)

    print(f"Haikesi: {args.haikesi_text} ...", flush=True)
    haikesi_entries = build_haikesi_entries(args.haikesi_text)
    print(f"  haikesi: {len(haikesi_entries)}", flush=True)

    payload = {
        "version": 1,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "game_root": str(game),
        "language": _LANG,
        "chapters": {
            "civilopedia": {"count": len(civ_entries)},
            "haikesi": {"count": len(haikesi_entries)},
        },
        "entries": civ_entries + haikesi_entries,
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(payload, ensure_ascii=False, indent=1),
        encoding="utf-8",
    )
    size_kb = args.out.stat().st_size / 1024
    print(f"Wrote {args.out} ({size_kb:.0f} KB, {len(payload['entries'])} entries)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
