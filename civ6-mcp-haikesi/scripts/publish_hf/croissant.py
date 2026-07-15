"""Stage 4 — emit MLCommons Croissant 1.1 metadata at <staging>/croissant.json.

Also renders <staging>/README.md from publish_hf/README_TEMPLATE.md so the
HF dataset card always reflects the current --repo argument.

Strategy:
  * One cr:FileObject per parquet table, with sha256 from _hashes.json.
  * One cr:RecordSet per parquet table whose Fields are introspected from
    the parquet schema (ensures the declaration matches reality).
  * One cr:FileSet per raw JSONL family for forensic access.
  * One cr:FileSet for the Inspect AI .eval sidecar archive.

The HF resolver URL pattern is:
    https://huggingface.co/datasets/{repo}/resolve/main/{path_in_repo}

We emit the JSON-LD by hand rather than via the mlcroissant Python
builder — the doc surface is small enough that direct construction is
clearer than threading mlc.Context everywhere, and the validate stage
(`mlcroissant validate`) will catch any schema drift.
"""

from __future__ import annotations

import datetime
import json
import logging
from pathlib import Path

import pyarrow.parquet as pq

log = logging.getLogger("publish_hf.croissant")

CROISSANT_VERSION = "http://mlcommons.org/croissant/1.1"

# Order matters: the games table is the join root; declare it first so
# foreign-key references resolve top-down for human readers.
TABLES = ("games", "player_rows", "city_rows", "tool_calls", "spatial_turns")

RAW_FAMILIES = (
    ("raw_diary", "raw/runs/*/diary.jsonl", "Per-turn agent reflections + scoreboard."),
    ("raw_cities", "raw/runs/*/cities.jsonl", "Per-turn per-city state."),
    ("raw_log", "raw/runs/*/log.jsonl", "Tool call event log."),
    ("raw_spatial", "raw/runs/*/spatial.jsonl", "Per-tile attention tracking."),
    ("raw_map_turns", "raw/runs/*/map_turns.jsonl", "Per-turn ownership/route deltas."),
    ("raw_map_static", "raw/runs/*/map_static.json", "Initial terrain dump per game."),
    ("raw_manifest", "raw/runs/*/manifest.json", "Per-run identity & metadata."),
)


def _hf_url(repo: str, path: str) -> str:
    return f"https://huggingface.co/datasets/{repo}/resolve/main/{path}"


def _arrow_to_croissant_dtype(arrow_type) -> str:
    import pyarrow as pa

    if pa.types.is_boolean(arrow_type):
        return "sc:Boolean"
    if pa.types.is_integer(arrow_type):
        return "sc:Integer"
    if pa.types.is_floating(arrow_type):
        return "sc:Float"
    if pa.types.is_temporal(arrow_type):
        return "sc:Date"
    return "sc:Text"


def _record_set_for_parquet(
    table_name: str,
    parquet_path: Path,
    file_object_id: str,
) -> dict:
    schema = pq.read_schema(parquet_path)
    fields = []
    for field in schema:
        is_json_blob = field.name in {
            "stockpiles",
            "luxuries",
            "unit_composition",
            "diplo_states",
            "envoys_sent",
            "gp_points",
            "governors",
            "trade_routes",
            "reflections",
            "policies",
            "techs",
            "civics",
            "religion_beliefs",
            "eloPlayers",
            "turnSeries",
            "outcome",
            "dimensionScores",
        }
        description = "JSON-encoded blob; parse client-side." if is_json_blob else None
        f: dict = {
            "@type": "cr:Field",
            "@id": f"{table_name}/{field.name}",
            "name": field.name,
            "dataType": _arrow_to_croissant_dtype(field.type),
            "source": {
                "fileObject": {"@id": file_object_id},
                "extract": {"column": field.name},
            },
        }
        if description:
            f["description"] = description
        fields.append(f)

    rs: dict = {
        "@type": "cr:RecordSet",
        "@id": table_name,
        "name": table_name,
        "field": fields,
    }
    if "gameId" in schema.names:
        # Express composite keys where they apply.
        keys = {
            "games": ["gameId"],
            "player_rows": ["gameId", "turn", "pid"],
            "city_rows": ["gameId", "turn", "city_id"],
            "tool_calls": ["gameId", "turn"],  # log rows lack a strict pk
            "spatial_turns": ["gameId", "turn"],
        }.get(table_name)
        if keys:
            rs["key"] = [{"@id": f"{table_name}/{k}"} for k in keys]
    return rs


def run(staging: Path, repo: str, version: str) -> int:
    hashes_path = staging / "_hashes.json"
    if not hashes_path.exists():
        log.error("Missing %s — run the hash stage first.", hashes_path)
        return 1
    hashes: dict[str, dict] = json.loads(hashes_path.read_text())

    distribution: list[dict] = []
    record_sets: list[dict] = []

    # 1. Parquet tables — FileObject + RecordSet
    for table in TABLES:
        rel = f"tables/{table}.parquet"
        path = staging / rel
        if not path.exists():
            log.warning("Skipping missing %s", path)
            continue
        h = hashes.get(rel)
        if not h:
            log.error("No hash for %s — re-run the hash stage", rel)
            return 1
        fo_id = f"file-{table}"
        distribution.append(
            {
                "@type": "cr:FileObject",
                "@id": fo_id,
                "name": rel,
                "contentUrl": _hf_url(repo, rel),
                "encodingFormat": "application/x-parquet",
                "sha256": h["sha256"],
            }
        )
        record_sets.append(_record_set_for_parquet(table, path, fo_id))

    # 2. Cross-table foreign keys via `references`. Apply post-hoc to
    #    the gameId fields we just emitted. Canonical form per the
    #    mlcommons reference datasets is {"field": {"@id": ...}}.
    by_id = {rs["@id"]: rs for rs in record_sets}
    for table in TABLES:
        if table == "games" or table not in by_id:
            continue
        for f in by_id[table]["field"]:
            if f["name"] == "gameId":
                f["references"] = {"field": {"@id": "games/gameId"}}

    # 3. Raw JSONL families — FileSet (glob), no RecordSet (forensic only)
    for fs_id, glob, desc in RAW_FAMILIES:
        encoding = (
            "application/jsonlines" if glob.endswith(".jsonl") else "application/json"
        )
        distribution.append(
            {
                "@type": "cr:FileSet",
                "@id": fs_id,
                "name": fs_id,
                "description": desc,
                "encodingFormat": encoding,
                "includes": glob,
            }
        )

    # 4. Inspect AI .eval sidecar
    distribution.append(
        {
            "@type": "cr:FileSet",
            "@id": "inspect_logs",
            "name": "inspect_logs",
            "description": (
                "Inspect AI evaluation log archives (one per game). Use "
                "`inspect.log.read_eval_log()` from the inspect-ai package "
                "to load message traces, scores, and tool-call sequences."
            ),
            "encodingFormat": "application/octet-stream",
            "includes": "inspect_logs/*.eval",
        }
    )

    # @context lifted verbatim from the official mlcommons reference
    # datasets so mlcroissant validate doesn't warn about non-standard keys.
    metadata = {
        "@context": {
            "@language": "en",
            "@vocab": "https://schema.org/",
            "citeAs": "cr:citeAs",
            "column": "cr:column",
            "conformsTo": "dct:conformsTo",
            "cr": "http://mlcommons.org/croissant/",
            "rai": "http://mlcommons.org/croissant/RAI/",
            "data": {"@id": "cr:data", "@type": "@json"},
            "dataType": {"@id": "cr:dataType", "@type": "@vocab"},
            "dct": "http://purl.org/dc/terms/",
            "equivalentProperty": "cr:equivalentProperty",
            "examples": {"@id": "cr:examples", "@type": "@json"},
            "extract": "cr:extract",
            "field": "cr:field",
            "fileProperty": "cr:fileProperty",
            "fileObject": "cr:fileObject",
            "fileSet": "cr:fileSet",
            "format": "cr:format",
            "includes": "cr:includes",
            "isLiveDataset": "cr:isLiveDataset",
            "jsonPath": "cr:jsonPath",
            "key": "cr:key",
            "md5": "cr:md5",
            "parentField": "cr:parentField",
            "path": "cr:path",
            "recordSet": "cr:recordSet",
            "references": "cr:references",
            "regex": "cr:regex",
            "repeated": "cr:repeated",
            "replace": "cr:replace",
            "samplingRate": "cr:samplingRate",
            "sc": "https://schema.org/",
            "separator": "cr:separator",
            "source": "cr:source",
            "subField": "cr:subField",
            "transform": "cr:transform",
            "prov": "http://www.w3.org/ns/prov#",
            "wd": "https://www.wikidata.org/wiki/",
        },
        "@type": "sc:Dataset",
        "name": "civbench",
        "conformsTo": CROISSANT_VERSION,
        "description": (
            "A benchmark of LLM-played Civilization VI games. Each run "
            "captures the full per-turn game state, every tool call the "
            "agent issued, and the agent's own structured reflections. "
            "Curated parquet tables are derived from the raw JSONL streams; "
            "Inspect AI evaluation archives are included as a sidecar."
        ),
        "version": version,
        "datePublished": datetime.date.today().isoformat(),
        "license": "https://creativecommons.org/licenses/by/4.0/",
        "url": f"https://huggingface.co/datasets/{repo}",
        "citeAs": (
            "@misc{civbench2026, "
            "title={CivBench: A Civilization VI benchmark for LLM agents}, "
            "year={2026}, "
            "url={https://huggingface.co/datasets/" + repo + "}}"
        ),
        # ── Responsible AI metadata (required by NeurIPS E&D track) ──
        "rai:dataLimitations": (
            "CivBench evaluates LLM agents through a single commercial "
            "strategy game (Civilization VI: Gathering Storm). Results may "
            "not generalise to other strategy games, real-world planning, "
            "or domains without turn-based discrete action spaces. The "
            "benchmark measures agent behaviour through MCP tool calls; "
            "internal reasoning is not directly observable. AI opponent "
            "behaviour is deterministic given the same save file and game "
            "version but varies across Civ VI patches. The dataset covers "
            "a limited number of frontier models available during the "
            "collection period (March–May 2026)."
        ),
        "rai:dataBiases": (
            "Model selection is biased toward commercially available "
            "frontier models with tool-use support. Scenarios were designed "
            "by the benchmark authors and encode specific gameplay values "
            "(e.g., penalising gold hoarding, rewarding exploration) that "
            "may not align with all valid strategies. Games where the agent "
            "crashed or ran fewer than 50 turns are excluded, which may "
            "systematically exclude models that struggle with tool reliability."
        ),
        "rai:personalSensitiveInformation": (
            "None. All data is generated by LLM agents playing a commercial "
            "video game against AI opponents. No human subjects, personal "
            "data, or sensitive information is present."
        ),
        "rai:dataUseCases": (
            "Intended for evaluating and comparing LLM agent capabilities "
            "in complex, long-horizon strategic planning. Established use: "
            "comparing frontier models on the 8-dimension scoring rubric "
            "across standardised scenarios. Unestablished use: training "
            "game-playing agents or evaluating non-frontier models."
        ),
        "rai:dataSocialImpact": (
            "CivBench contributes to understanding how LLM agents handle "
            "long-horizon planning, tool use, and strategic reasoning — "
            "capabilities relevant to AI safety research. Negative risks "
            "are minimal: the dataset documents game-playing behaviour "
            "with no real-world consequences."
        ),
        "rai:hasSyntheticData": True,
        "rai:sourceDatasets": [],
        "prov:wasGeneratedBy": (
            "Data was collected by running frontier LLM agents against "
            "Civilization VI: Gathering Storm via a Model Context Protocol "
            "server. Each agent played from an identical Turn 1 save file "
            "for a given scenario. Per-turn state was recorded by querying "
            "the game engine through FireTuner Lua scripting. Tool-call "
            "logs were captured by the MCP server telemetry pipeline. "
            "Admissibility was determined programmatically: games must have "
            "an outcome, 50+ turns, identified agent model, and no exclude "
            "reason. 8-dimension scores were computed from diary and log "
            "data using a deterministic scoring pipeline."
        ),
        "distribution": distribution,
        "recordSet": record_sets,
    }

    out = staging / "croissant.json"
    out.write_text(json.dumps(metadata, indent=2))
    log.info(
        "Wrote %s (%d distribution entries, %d record sets)",
        out,
        len(distribution),
        len(record_sets),
    )

    template = Path(__file__).parent / "README_TEMPLATE.md"
    if template.exists():
        rendered = template.read_text().replace("<repo>", repo)
        readme_path = staging / "README.md"
        readme_path.write_text(rendered)
        log.info("Rendered %s with repo=%s", readme_path, repo)

    license_path = staging / "LICENSE"
    if not license_path.exists():
        import httpx

        log.info("Fetching CC BY 4.0 license text")
        try:
            resp = httpx.get(
                "https://creativecommons.org/licenses/by/4.0/legalcode.txt",
                timeout=30,
                follow_redirects=True,
            )
            resp.raise_for_status()
            license_path.write_bytes(resp.content)
            log.info("Wrote %s", license_path)
        except Exception as e:
            log.warning(
                "Could not fetch license (%s). Drop a LICENSE file in %s manually.",
                e,
                staging,
            )

    return 0
