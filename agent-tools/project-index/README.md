# Project Index (MacTalk)

This folder contains a small, dependency-free indexer that generates a grep-friendly “project map” and per-file metadata for the MacTalk repo.

## What It Generates

Running the indexer produces these files (in this directory):

- `project_index.jsonl` — one JSON object per file (easy to `rg`, easy to stream/parse).
- `project_index.tsv` — tab-separated summary (good for `cut`, `awk`, `sort`).
- `project_map.yaml` — aggregated, machine-readable map (build commands, key paths, stats).
- `PROJECT_MAP.md` — human-friendly overview + grep examples.

## Usage

From the repo root:

```bash
python3 agent-tools/project-index/index_project.py
```

Then open/read:

- `agent-tools/project-index/PROJECT_MAP.md` (overview)
- `agent-tools/project-index/project_map.yaml` (machine-readable summary)
- `agent-tools/project-index/project_index.jsonl` / `agent-tools/project-index/project_index.tsv` (per-file index)

Optional: increase parsing limit for larger files:

```bash
python3 agent-tools/project-index/index_project.py --max-bytes $((2 * 1024 * 1024))
```

## JSONL Schema (Per File)

Each line of `project_index.jsonl` is one JSON object with keys like:

- `path`, `category`, `language`, `size_bytes`, `mtime_iso`, `type`
- Optional: `line_count`, `truncated`, `summary`, `importance`

`summary` is language-specific (e.g. Swift: `imports`, `symbols`, `marks`, `asr_engines`).

## Grep Examples

- Find Swift files importing `ScreenCaptureKit`:
  - `rg '\"imports\": \\[.*ScreenCaptureKit' agent-tools/project-index/project_index.jsonl`
- Find all files in the `Whisper` area:
  - `rg '^MacTalk/MacTalk/Whisper/' agent-tools/project-index/project_index.tsv`
- List detected Swift protocols:
  - `rg '\"kind\": \"protocol\"' agent-tools/project-index/project_index.jsonl`

## Exclusions

The indexer skips:

- Hidden directories/files (any path segment starting with `.`)
- Common build output directories: `build`, `Build`, `DerivedData`, `.build`, `xcuserdata`
- `Vendor/whisper.cpp/build`

If you want additional exclusions, update the constants at the top of `agent-tools/project-index/index_project.py`.
