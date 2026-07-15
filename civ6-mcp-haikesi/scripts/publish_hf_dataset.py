#!/usr/bin/env python3
"""Publish the civ6-mcp benchmark to Hugging Face Datasets.

Stages run independently and are idempotent on a staging directory so
a partial run can be resumed without re-doing earlier stages.

    uv run --extra publish python scripts/publish_hf_dataset.py download
    uv run --extra publish python scripts/publish_hf_dataset.py export-tables
    uv run --extra publish python scripts/publish_hf_dataset.py hash
    uv run --extra publish python scripts/publish_hf_dataset.py croissant
    uv run --extra publish python scripts/publish_hf_dataset.py validate
    uv run --extra publish python scripts/publish_hf_dataset.py push --repo {org}/civ6-mcp-bench
    uv run --extra publish python scripts/publish_hf_dataset.py all --repo {org}/civ6-mcp-bench

Staging dir (default: ~/civbench-hf-staging) layout matches the target HF repo:
    raw/runs/{hex_id}/{7 files}
    inspect_logs/*.eval
    tables/{games,player_rows,city_rows,tool_calls,spatial_turns}.parquet
    croissant.json
    README.md
    LICENSE
    _hashes.json   (sidecar, not uploaded)
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("publish_hf")

DEFAULT_STAGING = Path.home() / "civbench-hf-staging"
AZURE_CONTAINER = "telemetry"
ENV_FILE = Path(__file__).resolve().parent.parent / "evals" / ".env"


def _load_env_file() -> None:
    """Populate os.environ from evals/.env without overriding existing values.

    Normalizes AZURE_SAS_TOKEN to the bare query-string form whether the
    user pasted just the SAS or the full container URL.
    """
    if not ENV_FILE.exists():
        return
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if not key or not value:
            continue
        if key == "AZURE_SAS_TOKEN" and "?" in value:
            value = value.split("?", 1)[1]
        os.environ.setdefault(key, value)


def cmd_download(args: argparse.Namespace) -> int:
    """Stage 1 — mirror Azure blob into <staging>/raw and <staging>/inspect_logs."""
    from publish_hf import download as _download

    return _download.run(staging=args.staging, dry_run=args.dry_run)


def cmd_export_tables(args: argparse.Namespace) -> int:
    """Stage 2 — pull Convex tables and write parquet to <staging>/tables."""
    from publish_hf import export_tables as _export

    return _export.run(staging=args.staging, prod=args.prod)


def cmd_hash(args: argparse.Namespace) -> int:
    """Stage 3 — SHA-256 every shippable file into _hashes.json."""
    from publish_hf import hashing as _hashing

    return _hashing.run(staging=args.staging)


def cmd_croissant(args: argparse.Namespace) -> int:
    """Stage 4 — write croissant.json from staging contents + hashes."""
    from publish_hf import croissant as _croissant

    return _croissant.run(staging=args.staging, repo=args.repo, version=args.version)


def cmd_validate(args: argparse.Namespace) -> int:
    """Stage 5 — run mlcroissant validate + load locally."""
    from publish_hf import validate as _validate

    return _validate.run(staging=args.staging)


def cmd_push(args: argparse.Namespace) -> int:
    """Stage 6 — create HF repo + upload_folder."""
    if not args.confirm:
        log.error(
            "push is destructive and requires --confirm. "
            "Run validate first; review the staging dir; then re-run with --confirm."
        )
        return 2
    from publish_hf import push as _push

    return _push.run(staging=args.staging, repo=args.repo, private=args.private)


def cmd_all(args: argparse.Namespace) -> int:
    for fn in (cmd_download, cmd_export_tables, cmd_hash, cmd_croissant, cmd_validate):
        rc = fn(args)
        if rc != 0:
            return rc
    return cmd_push(args)


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument(
        "--staging",
        type=Path,
        default=DEFAULT_STAGING,
        help=f"Staging directory (default: {DEFAULT_STAGING})",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("download", help="Stage 1: pull from Azure").set_defaults(
        func=cmd_download
    )
    sub.choices["download"].add_argument(
        "--dry-run", action="store_true", help="List blobs without downloading"
    )

    p_export = sub.add_parser("export-tables", help="Stage 2: Convex → parquet")
    p_export.add_argument("--prod", action="store_true", default=True)
    p_export.set_defaults(func=cmd_export_tables)

    sub.add_parser("hash", help="Stage 3: SHA-256 everything").set_defaults(
        func=cmd_hash
    )

    p_cr = sub.add_parser("croissant", help="Stage 4: write croissant.json")
    p_cr.add_argument(
        "--repo", required=True, help="HF repo id, e.g. civbench/civbench-v1"
    )
    p_cr.add_argument("--version", default="1.0.0")
    p_cr.set_defaults(func=cmd_croissant)

    sub.add_parser(
        "validate", help="Stage 5: mlcroissant validate + load"
    ).set_defaults(func=cmd_validate)

    p_push = sub.add_parser("push", help="Stage 6: upload to HF (destructive)")
    p_push.add_argument("--repo", required=True)
    p_push.add_argument("--private", action="store_true")
    p_push.add_argument(
        "--confirm", action="store_true", help="Required to actually push"
    )
    p_push.set_defaults(func=cmd_push)

    p_all = sub.add_parser("all", help="Run every stage in order")
    p_all.add_argument("--repo", required=True)
    p_all.add_argument("--version", default="1.0.0")
    p_all.add_argument("--prod", action="store_true", default=True)
    p_all.add_argument("--private", action="store_true")
    p_all.add_argument("--confirm", action="store_true")
    p_all.add_argument("--dry-run", action="store_true")
    p_all.set_defaults(func=cmd_all)

    args = p.parse_args()
    _load_env_file()
    args.staging.mkdir(parents=True, exist_ok=True)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
