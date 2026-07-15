"""Stage 1 — mirror Azure blob into the staging directory.

Layout produced:
    <staging>/raw/runs/{hex_id}/{7 files}
    <staging>/inspect_logs/<filename>.eval

Reuses scripts/analyze.py::_get_fs() so SAS auth comes from the same
AZURE_SAS_TOKEN env var the rest of the codebase uses.

Downloads run through a thread pool — fsspec's per-request overhead
dominates throughput for the small JSONL/manifest files, so 16 parallel
GETs gives ~10× the serial rate.
"""

from __future__ import annotations

import logging
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

log = logging.getLogger("publish_hf.download")

CONTAINER = "telemetry"
NUM_WORKERS = 16
_PROGRESS_LOCK = threading.Lock()


def _get_fs():
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from analyze import _get_fs as analyze_get_fs

    return analyze_get_fs()


def _list(fs, prefix: str) -> list[dict]:
    """fs.ls with detail; tolerates trailing slash inconsistencies."""
    prefix = prefix.rstrip("/") + "/"
    return fs.ls(prefix, detail=True)


def _enumerate_jobs(
    fs, raw_dir: Path, inspect_dir: Path
) -> list[tuple[str, Path, int]]:
    """Walk the container and produce (blob_path, local_path, size) triples
    for every file whose local copy is missing or wrong-sized.
    """
    jobs: list[tuple[str, Path, int]] = []

    runs = [e for e in _list(fs, f"{CONTAINER}/runs") if e["type"] == "directory"]
    log.info("Found %d runs under %s/runs/", len(runs), CONTAINER)
    for run_entry in runs:
        run_prefix = run_entry["name"].rstrip("/")
        hex_id = run_prefix.rsplit("/", 1)[-1]
        local_run = raw_dir / hex_id
        local_run.mkdir(parents=True, exist_ok=True)
        for blob in fs.ls(run_prefix, detail=True):
            if blob["type"] != "file":
                continue
            name = blob["name"].rsplit("/", 1)[-1]
            dst = local_run / name
            if dst.exists() and dst.stat().st_size == blob["size"]:
                continue
            jobs.append((blob["name"], dst, blob["size"]))

    evals = [e for e in _list(fs, f"{CONTAINER}/evals") if e["type"] == "file"]
    log.info("Found %d Inspect .eval files", len(evals))
    for blob in evals:
        name = blob["name"].rsplit("/", 1)[-1]
        dst = inspect_dir / name
        if dst.exists() and dst.stat().st_size == blob["size"]:
            continue
        jobs.append((blob["name"], dst, blob["size"]))

    return jobs


def run(staging: Path, dry_run: bool = False) -> int:
    fs = _get_fs()

    raw_dir = staging / "raw" / "runs"
    inspect_dir = staging / "inspect_logs"
    raw_dir.mkdir(parents=True, exist_ok=True)
    inspect_dir.mkdir(parents=True, exist_ok=True)

    jobs = _enumerate_jobs(fs, raw_dir, inspect_dir)
    if not jobs:
        log.info("Nothing to download — staging is already in sync.")
        return 0

    total_planned = sum(j[2] for j in jobs)
    log.info(
        "Planned: %d files, %.1f MB total (using %d workers)",
        len(jobs),
        total_planned / 1_000_000,
        NUM_WORKERS,
    )
    if dry_run:
        for blob_path, dst, size in jobs[:10]:
            log.info("DRY %s → %s (%d bytes)", blob_path, dst, size)
        log.info("... %d more (dry run, skipping)", max(0, len(jobs) - 10))
        return 0

    transferred = {"bytes": 0, "files": 0}
    started_at = time.monotonic()

    def _download_one(blob_path: str, dst: Path, size: int) -> int:
        fs.get_file(blob_path, str(dst))
        with _PROGRESS_LOCK:
            transferred["bytes"] += size
            transferred["files"] += 1
            if transferred["files"] % 25 == 0 or transferred["files"] == len(jobs):
                elapsed = max(0.001, time.monotonic() - started_at)
                rate = transferred["bytes"] / elapsed / 1_000_000
                pct = transferred["bytes"] * 100 // max(1, total_planned)
                log.info(
                    "[%d/%d] %d%% — %.1f MB @ %.1f MB/s",
                    transferred["files"],
                    len(jobs),
                    pct,
                    transferred["bytes"] / 1_000_000,
                    rate,
                )
        return size

    failures: list[tuple[str, Exception]] = []
    with ThreadPoolExecutor(max_workers=NUM_WORKERS) as ex:
        futures = {
            ex.submit(_download_one, blob_path, dst, size): (blob_path, dst)
            for blob_path, dst, size in jobs
        }
        for fut in as_completed(futures):
            blob_path, dst = futures[fut]
            try:
                fut.result()
            except Exception as e:
                failures.append((blob_path, e))
                log.error("FAILED %s: %s", blob_path, e)

    elapsed = time.monotonic() - started_at
    log.info(
        "Download done. %d files, %.1f MB in %.0fs (%.1f MB/s); %d failures.",
        transferred["files"],
        transferred["bytes"] / 1_000_000,
        elapsed,
        transferred["bytes"] / max(0.001, elapsed) / 1_000_000,
        len(failures),
    )
    return 1 if failures else 0
