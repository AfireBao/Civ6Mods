"""Stage 6 — push the staging directory to a Hugging Face dataset repo.

Uses huggingface_hub.HfApi.upload_large_folder which:
  * is resilient (resumable, retries on transient failures),
  * is multi-threaded, and
  * handles git-lfs tracking automatically for files > 10 MB.

Auth: HF_TOKEN env var picked up by huggingface_hub. The caller is
responsible for `huggingface-cli login` or exporting HF_TOKEN.

Excluded from upload (sidecar files we keep locally only):
  * _hashes.json
  * _convex/  (Convex snapshot input, not part of the dataset)
"""

from __future__ import annotations

import logging
from pathlib import Path

from huggingface_hub import HfApi

log = logging.getLogger("publish_hf.push")

IGNORE_PATTERNS = [
    "_hashes.json",
    "_convex/**",
    "croissant.local.json",
    ".DS_Store",
]


def run(staging: Path, repo: str, private: bool = False) -> int:
    api = HfApi()
    log.info("Ensuring dataset repo %s exists (private=%s)", repo, private)
    api.create_repo(repo_id=repo, repo_type="dataset", private=private, exist_ok=True)

    log.info("Uploading %s → %s (this is destructive on conflicts)", staging, repo)
    api.upload_large_folder(
        repo_id=repo,
        repo_type="dataset",
        folder_path=str(staging),
        ignore_patterns=IGNORE_PATTERNS,
        num_workers=8,
    )
    url = f"https://huggingface.co/datasets/{repo}"
    log.info("Done. View at %s", url)
    return 0
