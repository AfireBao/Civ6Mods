"""Stage 5 — validate croissant.json locally before pushing.

1. `mlcroissant validate` — structural check.
2. Rewrite a *copy* of croissant.json with file:// URLs pointing into
   the staging dir, then run `mlcroissant load` against it. This
   exercises every extract path against the real bytes without needing
   the data uploaded to HF yet.
"""

from __future__ import annotations

import json
import logging
import subprocess
from pathlib import Path

log = logging.getLogger("publish_hf.validate")

SAMPLE_RECORD_SETS = ("games", "player_rows")


def _run(cmd: list[str]) -> int:
    log.info("$ %s", " ".join(cmd))
    return subprocess.call(cmd)


def _rewrite_for_local_load(croissant_path: Path, staging: Path) -> Path:
    """Emit a sibling croissant.local.json with relative-path contentUrls.

    mlcroissant resolves bare relative paths against the staging dir
    when the JSON-LD lives there; HTTPS-style URLs are rewritten to the
    file's path within the staging dir.
    """
    data = json.loads(croissant_path.read_text())
    for entry in data.get("distribution", []):
        if entry.get("@type") == "cr:FileObject" and "contentUrl" in entry:
            entry["contentUrl"] = entry["name"]
    out = croissant_path.with_name("croissant.local.json")
    out.write_text(json.dumps(data, indent=2))
    return out


def run(staging: Path) -> int:
    croissant = staging / "croissant.json"
    if not croissant.exists():
        log.error("Missing %s — run the croissant stage first.", croissant)
        return 1

    rc = _run(["mlcroissant", "validate", "--jsonld", str(croissant)])
    if rc != 0:
        log.error("Croissant validation failed (exit %d)", rc)
        return rc

    local = _rewrite_for_local_load(croissant, staging)
    log.info("Wrote %s for local load test", local)

    for rs in SAMPLE_RECORD_SETS:
        rc = _run(
            [
                "mlcroissant",
                "load",
                "--jsonld",
                str(local),
                "--record_set",
                rs,
                "--num_records",
                "3",
            ]
        )
        if rc != 0:
            log.error("Sample load of record_set=%s failed", rs)
            return rc
    log.info("Croissant validates and loads cleanly.")
    return 0
