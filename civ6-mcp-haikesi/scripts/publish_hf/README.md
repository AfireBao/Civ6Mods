# Publishing the civ6-mcp benchmark to Hugging Face

End-to-end pipeline for taking the Azure-hosted telemetry corpus and publishing it as a Hugging Face dataset with a Croissant 1.1 metadata file.

The publisher is staged: every step is idempotent on a local staging directory, so a partial run can resume from any point without redoing earlier work.

## Prereqs

1. **Python deps**:
   ```bash
   uv sync --extra publish
   ```

2. **Credentials in `evals/.env`** (copy from `evals/.env.example`):
   - `AZURE_STORAGE_ACCOUNT_NAME` — defaults to `civbenchstorage`.
   - `AZURE_SAS_TOKEN` — read-only SAS for the `telemetry` container. Either the bare query string or the full container URL (the publisher strips the URL prefix automatically).
   - `HF_TOKEN` — write-scoped token for the target HF namespace. Create at https://huggingface.co/settings/tokens.

3. **Convex (optional but recommended)** — the `games.parquet` table is enriched with admissibility, ELO, dimension scores, and outcome from a Convex snapshot. Without it, `games.parquet` falls back to a minimal summary derived from per-run `manifest.json`.
   ```bash
   cd web/
   npx convex export --table games --format jsonl --path ~/civbench-hf-staging/_convex/
   ```
   This requires Convex CLI auth (`npx convex login`) and access to the prod deployment.

## End-to-end run

```bash
# Stage 1: pull the Azure blob into a local staging dir (~8 GB).
# Resumable; safe to re-run if interrupted. Uses 16 parallel workers.
uv run --extra publish python scripts/publish_hf_dataset.py download

# Stage 2: build curated parquet tables from the raw JSONL.
# Reads the Convex snapshot at <staging>/_convex/games.jsonl if present.
uv run --extra publish python scripts/publish_hf_dataset.py export-tables

# Stage 3: SHA-256 every shippable file (required for Croissant FileObjects).
uv run --extra publish python scripts/publish_hf_dataset.py hash

# Stage 4: emit croissant.json. The --repo arg is baked into the dataset URL
# and citation, so use the final HF repo name.
uv run --extra publish python scripts/publish_hf_dataset.py croissant \
    --repo <hf-namespace>/<dataset-name>

# Stage 5: validate locally — runs `mlcroissant validate` for structural
# checks, then `mlcroissant load` against a relative-path copy of the JSON-LD
# to exercise every extract path against the real bytes. Catches schema bugs
# that pure structural validation misses.
uv run --extra publish python scripts/publish_hf_dataset.py validate

# Stage 6: upload. Creates the dataset repo if it doesn't exist; uses
# huggingface_hub.HfApi.upload_large_folder which is multi-threaded and
# resumable (writes checkpoint state to <staging>/.cache/.huggingface/).
# `--confirm` is required as a safety check.
uv run --extra publish python scripts/publish_hf_dataset.py push \
    --repo <hf-namespace>/<dataset-name> --confirm
```

Or run everything end-to-end:

```bash
uv run --extra publish python scripts/publish_hf_dataset.py all \
    --repo <hf-namespace>/<dataset-name> --confirm
```

## Staging dir layout (default `~/civbench-hf-staging/`)

```
<staging>/
├── croissant.json          # Croissant 1.1 metadata (uploaded)
├── croissant.local.json    # local-validation-only copy with relative URLs (NOT uploaded)
├── README.md               # HF dataset card; copy from publish_hf/README_TEMPLATE.md
├── LICENSE                 # CC BY 4.0 license text (uploaded)
├── _hashes.json            # sha256 + size per file (NOT uploaded)
├── _convex/                # Convex export sink (NOT uploaded)
│   └── games.jsonl
├── tables/                 # curated parquet (uploaded as `tables` config)
│   ├── games.parquet
│   ├── player_rows.parquet
│   ├── city_rows.parquet
│   ├── tool_calls.parquet
│   └── spatial_turns.parquet
├── raw/                    # byte-identical mirror of the blob (uploaded as `raw` config)
│   └── runs/<hex_id>/
│       ├── manifest.json
│       ├── diary.jsonl
│       ├── cities.jsonl
│       ├── log.jsonl
│       ├── spatial.jsonl
│       ├── map_static.json
│       └── map_turns.jsonl
├── inspect_logs/           # Inspect AI sidecar archives (uploaded)
│   └── *.eval
└── .cache/.huggingface/    # upload_large_folder checkpoint state (NOT uploaded)
```

Files matching `_hashes.json`, `_convex/**`, `croissant.local.json`, and `.DS_Store` are excluded from the upload via `IGNORE_PATTERNS` in `push.py`.

## Resume behavior

Every stage is idempotent on the staging dir:

- **`download`** — skips files whose local size matches the blob's. Fine to re-run after a kill.
- **`export-tables`** — overwrites parquet output, but it's deterministic given the same inputs.
- **`hash`** — overwrites `_hashes.json`.
- **`croissant`** — overwrites `croissant.json`.
- **`push`** — `upload_large_folder` reads its own checkpoint cache from `<staging>/.cache/.huggingface/` and skips files already pre-uploaded or committed. Re-running picks up where it left off; if you killed mid-LFS-upload, only the partial in-flight file restarts from byte 0.

## Common issues

- **403 on `create_repo`** — the `HF_TOKEN` doesn't have write rights to that namespace. Either fix the token (fine-grained tokens scope per repo) or change the `--repo` namespace.
- **HF LFS rate-limit (rate drops to <1 MB/s mid-upload)** — `upload_large_folder` will retry transient failures indefinitely. Killing and re-running won't reset the throttle window. Best to wait it out; a fresh push 30+ min later usually lands at full speed.
- **`mlcroissant validate` warning about `@context`** — non-fatal. The publisher emits the canonical context from `mlcommons/croissant/datasets/1.0/titanic/metadata.json`. New unknown keys typically mean Croissant added vocabulary in a newer spec version.
- **No `_convex/games.jsonl`** — `games.parquet` falls back to a minimal summary (see warning in `export-tables` output). Run `npx convex export --table games --format jsonl --path <staging>/_convex/` and re-run `export-tables` + `hash` + `croissant` to upgrade.

## File-by-file pointers

- `scripts/publish_hf_dataset.py` — CLI entrypoint, dispatches to stage modules. Loads `evals/.env` automatically.
- `scripts/publish_hf/download.py` — Azure → local mirror. Reuses `scripts/analyze.py::_get_fs()` for SAS auth.
- `scripts/publish_hf/export_tables.py` — JSONL → parquet via pyarrow. JSON-stringifies nested values for stable schemas.
- `scripts/publish_hf/hashing.py` — SHA-256 of all uploadable files into `_hashes.json`.
- `scripts/publish_hf/croissant.py` — emits Croissant 1.1 JSON-LD. Introspects parquet schemas to declare Fields automatically. Cross-table foreign keys via `references: {field: {@id: ...}}`.
- `scripts/publish_hf/validate.py` — `mlcroissant validate` + local-path `load` smoke test.
- `scripts/publish_hf/push.py` — `HfApi.upload_large_folder(num_workers=8, ignore_patterns=...)`.
- `scripts/publish_hf/README_TEMPLATE.md` — HF dataset card template; the publisher copies it into staging with `<repo>` placeholders substituted.
