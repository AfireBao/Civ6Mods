"""Stage 3 — SHA-256 every shippable file into <staging>/_hashes.json.

Croissant 1.1 requires sha256 on each FileObject. We hash everything we
plan to upload so the croissant builder can look values up by relative
path without re-hashing.
"""

from __future__ import annotations

import hashlib
import json
import logging
from pathlib import Path

log = logging.getLogger("publish_hf.hashing")

INCLUDE_DIRS = ("tables", "raw", "inspect_logs")
INCLUDE_ROOT_FILES = ("README.md", "LICENSE", "croissant.json")


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(staging: Path) -> int:
    hashes: dict[str, dict] = {}
    for sub in INCLUDE_DIRS:
        root = staging / sub
        if not root.exists():
            log.warning("Skipping missing dir %s", root)
            continue
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(staging).as_posix()
            hashes[rel] = {"sha256": _sha256(path), "size": path.stat().st_size}
            log.info("hashed %s", rel)

    # Note: croissant.json is hashed separately *after* it's written, by
    # the validate stage if needed; we skip it here since it doesn't yet
    # exist on first run.
    for name in INCLUDE_ROOT_FILES:
        path = staging / name
        if path.exists() and name != "croissant.json":
            hashes[name] = {"sha256": _sha256(path), "size": path.stat().st_size}

    out = staging / "_hashes.json"
    out.write_text(json.dumps(hashes, indent=2, sort_keys=True))
    log.info("Wrote %s (%d entries)", out, len(hashes))
    return 0
