#!/usr/bin/env python3
"""
MacTalk Project Indexer

Creates:
  - project_index.jsonl: one JSON object per file (grep-friendly)
  - project_index.tsv:   tab-separated summary for quick grep/awk
  - project_map.yaml:    aggregated, machine-readable architecture map
  - PROJECT_MAP.md:      human-friendly overview (still grep-friendly)

No third-party dependencies.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as _dt
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable, Optional


SKIP_DIR_NAMES = {
    "build",
    "Build",
    "DerivedData",
    ".build",
    "xcuserdata",
    ".swiftpm",
    "node_modules",
    "__pycache__",
}

SKIP_FILE_NAMES = {
    ".DS_Store",
}


LANG_BY_EXT: dict[str, str] = {
    ".swift": "Swift",
    ".m": "Objective-C",
    ".mm": "Objective-C++",
    ".h": "C/C++ Header",
    ".c": "C",
    ".cc": "C++",
    ".cpp": "C++",
    ".cxx": "C++",
    ".hpp": "C++ Header",
    ".hh": "C++ Header",
    ".md": "Markdown",
    ".yml": "YAML",
    ".yaml": "YAML",
    ".sh": "Shell",
    ".plist": "PropertyList",
    ".json": "JSON",
    ".txt": "Text",
    ".pbxproj": "XcodeProject",
}


SWIFT_IMPORT_RE = re.compile(r"^\s*import\s+([A-Za-z0-9_\\.]+)\s*$")
SWIFT_TYPE_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s*)*"
    r"(?:(?:public|internal|private|fileprivate|open)\s+)?"
    r"(?:(?:final|indirect)\s+)?"
    r"(class|struct|enum|protocol|actor|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
SWIFT_FUNC_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s*)*"
    r"(?:(?:public|internal|private|fileprivate|open)\s+)?"
    r"(?:(?:static|class)\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)\b"
)
SWIFT_MARK_RE = re.compile(r"^\s*//\s*MARK:\s*(.*)\s*$")
SWIFT_ASR_ENGINE_RE = re.compile(r"^\s*(?:final\s+)?class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^{]+)\{?")

MD_HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)\s*$")

YAML_TOP_KEY_RE = re.compile(r"^([A-Za-z0-9_-]+):\s*(?:#.*)?$")
SHELL_FUNC_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{\s*(?:#.*)?$")

OBJC_IMPORT_RE = re.compile(r"^\s*#\s*(?:import|include)\s+[<\"]([^>\"]+)[>\"]")
OBJC_INTERFACE_RE = re.compile(r"^\s*@interface\s+([A-Za-z_][A-Za-z0-9_]*)\b")
OBJC_PROTOCOL_RE = re.compile(r"^\s*@protocol\s+([A-Za-z_][A-Za-z0-9_]*)\b")
OBJC_IMPLEMENTATION_RE = re.compile(r"^\s*@implementation\s+([A-Za-z_][A-Za-z0-9_]*)\b")

CPP_CLASS_RE = re.compile(r"^\s*(?:template\s*<[^>]+>\s*)?(class|struct)\s+([A-Za-z_][A-Za-z0-9_]*)\b")
CPP_NAMESPACE_RE = re.compile(r"^\s*namespace\s+([A-Za-z_][A-Za-z0-9_:]*)\s*\{")


@dataclasses.dataclass(frozen=True)
class Symbol:
    kind: str
    name: str
    line: int
    detail: Optional[str] = None


def _run(cmd: list[str], cwd: Path) -> tuple[int, str]:
    try:
        p = subprocess.run(
            cmd,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        return p.returncode, (p.stdout or "").strip()
    except Exception as e:
        return 1, str(e)


def _git_info(root: Path) -> dict[str, Any]:
    if not (root / ".git").exists():
        return {}

    info: dict[str, Any] = {}
    rc, branch = _run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=root)
    if rc == 0 and branch:
        info["branch"] = branch

    rc, commit = _run(["git", "rev-parse", "HEAD"], cwd=root)
    if rc == 0 and commit:
        info["commit"] = commit

    rc, status = _run(["git", "status", "--porcelain"], cwd=root)
    if rc == 0:
        info["dirty"] = bool(status.strip())

    rc, remotes = _run(["git", "remote", "-v"], cwd=root)
    if rc == 0 and remotes:
        info["remotes"] = remotes.splitlines()

    return info


def _is_hidden_path(rel_parts: tuple[str, ...]) -> bool:
    return any(part.startswith(".") for part in rel_parts)


def _should_skip_dir(dir_name: str) -> bool:
    if dir_name in SKIP_DIR_NAMES:
        return True
    if dir_name.startswith("."):
        return True
    return False


def _infer_language(path: Path) -> str:
    if path.name == "build.sh":
        return "Shell"
    return LANG_BY_EXT.get(path.suffix.lower(), "Unknown")


def _read_text_lines(path: Path, max_bytes: int) -> tuple[list[str], bool]:
    data = path.read_bytes()
    truncated = False
    if max_bytes > 0 and len(data) > max_bytes:
        data = data[:max_bytes]
        truncated = True
    text = data.decode("utf-8", errors="replace")
    return text.splitlines(), truncated


def _summarize_swift(lines: list[str]) -> dict[str, Any]:
    imports: list[str] = []
    marks: list[str] = []
    symbols: list[Symbol] = []
    asr_engines: list[str] = []

    for i, line in enumerate(lines, start=1):
        m = SWIFT_IMPORT_RE.match(line)
        if m:
            imports.append(m.group(1))
            continue

        m = SWIFT_MARK_RE.match(line)
        if m:
            marks.append(m.group(1))
            continue

        m = SWIFT_TYPE_RE.match(line)
        if m:
            symbols.append(Symbol(kind=m.group(1), name=m.group(2), line=i))
            continue

        m = SWIFT_FUNC_RE.match(line)
        if m:
            symbols.append(Symbol(kind="func", name=m.group(1), line=i))
            continue

        m = SWIFT_ASR_ENGINE_RE.match(line)
        if m:
            class_name = m.group(1)
            bases = m.group(2)
            if "ASREngine" in bases:
                asr_engines.append(class_name)

    return {
        "imports": sorted(set(imports)),
        "marks": marks,
        "symbols": [dataclasses.asdict(s) for s in symbols],
        "asr_engines": sorted(set(asr_engines)),
    }


def _summarize_markdown(lines: list[str]) -> dict[str, Any]:
    headings: list[dict[str, Any]] = []
    for i, line in enumerate(lines, start=1):
        m = MD_HEADING_RE.match(line)
        if m:
            headings.append({"level": len(m.group(1)), "text": m.group(2), "line": i})
    return {"headings": headings}


def _summarize_yaml(lines: list[str], path: Path) -> dict[str, Any]:
    top_keys: list[str] = []
    targets: list[str] = []
    in_targets = False
    targets_indent: Optional[int] = None

    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue

        if not line.startswith((" ", "\t")):
            m = YAML_TOP_KEY_RE.match(line)
            if m:
                key = m.group(1)
                top_keys.append(key)
                in_targets = (path.name == "project.yml" and key == "targets")
                targets_indent = None
            continue

        if in_targets:
            indent = len(line) - len(line.lstrip(" "))
            if targets_indent is None:
                targets_indent = indent
            if indent == targets_indent:
                child_key = line.strip()
                if child_key.endswith(":"):
                    targets.append(child_key[:-1])
            elif indent < (targets_indent or 0):
                in_targets = False

    out: dict[str, Any] = {"top_keys": top_keys}
    if targets:
        out["xcodegen_targets"] = sorted(set(targets))
    return out


def _summarize_shell(lines: list[str]) -> dict[str, Any]:
    functions: list[str] = []
    for line in lines:
        m = SHELL_FUNC_RE.match(line)
        if m:
            functions.append(m.group(1))
    return {"functions": sorted(set(functions))}


def _summarize_objc(lines: list[str]) -> dict[str, Any]:
    imports: list[str] = []
    symbols: list[Symbol] = []

    for i, line in enumerate(lines, start=1):
        m = OBJC_IMPORT_RE.match(line)
        if m:
            imports.append(m.group(1))
            continue

        m = OBJC_INTERFACE_RE.match(line)
        if m:
            symbols.append(Symbol(kind="@interface", name=m.group(1), line=i))
            continue

        m = OBJC_PROTOCOL_RE.match(line)
        if m:
            symbols.append(Symbol(kind="@protocol", name=m.group(1), line=i))
            continue

        m = OBJC_IMPLEMENTATION_RE.match(line)
        if m:
            symbols.append(Symbol(kind="@implementation", name=m.group(1), line=i))
            continue

    return {
        "imports": sorted(set(imports)),
        "symbols": [dataclasses.asdict(s) for s in symbols],
    }


def _summarize_cpp(lines: list[str]) -> dict[str, Any]:
    includes: list[str] = []
    namespaces: list[str] = []
    symbols: list[Symbol] = []

    for i, line in enumerate(lines, start=1):
        m = OBJC_IMPORT_RE.match(line)
        if m:
            includes.append(m.group(1))
            continue

        m = CPP_NAMESPACE_RE.match(line)
        if m:
            namespaces.append(m.group(1))
            continue

        m = CPP_CLASS_RE.match(line)
        if m:
            symbols.append(Symbol(kind=m.group(1), name=m.group(2), line=i))
            continue

    return {
        "includes": sorted(set(includes)),
        "namespaces": sorted(set(namespaces)),
        "symbols": [dataclasses.asdict(s) for s in symbols],
    }


def _category_for_path(rel: Path) -> str:
    parts = rel.parts
    if not parts:
        return "Root"
    if parts[0] == "MacTalk":
        if len(parts) >= 2 and parts[1] == "MacTalk":
            return "AppSource"
        if len(parts) >= 2 and parts[1] == "MacTalkTests":
            return "Tests"
        return "Xcode"
    if parts[0] == "Vendor":
        return "Vendor"
    if parts[0] == "docs":
        return "Docs"
    if parts[0] == "scripts":
        return "Scripts"
    if parts[0] == "agent-tools":
        return "AgentTools"
    return "Other"


def _important_file_hint(rel: Path) -> Optional[str]:
    p = str(rel).replace("\\", "/")
    if p == "build.sh":
        return "Primary dev loop helper (build/run/clean)."
    if p == "project.yml":
        return "XcodeGen config (source of truth for Xcode project)."
    if p.endswith("MacTalk.xcodeproj/project.pbxproj"):
        return "Generated Xcode project; prefer editing project.yml."
    if p == "AGENTS.md":
        return "Contributor/agent workflow and architecture context."
    if p.endswith("MacTalk/MacTalk/main.swift"):
        return "Swift entry point (explicit main)."
    if p.endswith("Whisper/WhisperBridge.mm") or p.endswith("Whisper/WhisperBridge.h"):
        return "Objective-C++ bridge to whisper.cpp."
    if p.endswith("Whisper/WhisperEngine.swift"):
        return "ASR protocol + Whisper engine implementation."
    if p.endswith("TranscriptionController.swift"):
        return "Central state machine (recording/processing)."
    return None


def iter_files(root: Path, exclude_dirs: set[str]) -> Iterable[Path]:
    for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        dir_path = Path(dirpath)
        rel_dir = dir_path.relative_to(root)

        if rel_dir.parts and _is_hidden_path(rel_dir.parts):
            dirnames[:] = []
            continue

        pruned: list[str] = []
        for d in dirnames:
            if _should_skip_dir(d):
                continue
            if d in exclude_dirs:
                continue

            # Skip Vendor/whisper.cpp/build regardless of name casing (common).
            if (rel_dir / d).as_posix() in {"Vendor/whisper.cpp/build"}:
                continue

            pruned.append(d)
        dirnames[:] = pruned

        for f in filenames:
            if f in SKIP_FILE_NAMES or f.startswith("."):
                continue
            yield dir_path / f


def _safe_relpath(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def build_index(root: Path, out_dir: Path, max_bytes: int) -> dict[str, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)

    jsonl_path = out_dir / "project_index.jsonl"
    tsv_path = out_dir / "project_index.tsv"

    exclude_dirs = {out_dir.relative_to(root).parts[0]} if out_dir.is_relative_to(root) else set()

    language_stats = Counter()
    category_stats = Counter()
    swift_asr_engines = set()
    swift_protocols = set()
    key_files: list[dict[str, Any]] = []
    largest_by_loc: list[tuple[int, str]] = []

    file_count = 0
    truncated_count = 0

    with jsonl_path.open("w", encoding="utf-8") as jf, tsv_path.open("w", encoding="utf-8") as tf:
        tf.write("path\tcategory\tlanguage\tsize_bytes\tline_count\timports\tsymbols\n")

        for abs_path in iter_files(root, exclude_dirs=exclude_dirs):
            try:
                st = abs_path.lstat()
            except FileNotFoundError:
                continue

            rel = abs_path.relative_to(root)
            rel_str = rel.as_posix()

            category = _category_for_path(rel)
            language = _infer_language(abs_path)

            record: dict[str, Any] = {
                "path": rel_str,
                "category": category,
                "language": language,
                "size_bytes": st.st_size,
                "mtime_iso": _dt.datetime.fromtimestamp(st.st_mtime).isoformat(timespec="seconds"),
                "type": "symlink" if abs_path.is_symlink() else "file",
            }

            summary: dict[str, Any] = {}
            line_count: Optional[int] = None
            truncated = False

            if record["type"] == "symlink":
                try:
                    record["symlink_target"] = os.readlink(abs_path)
                except OSError:
                    record["symlink_target"] = None
            else:
                try:
                    lines, truncated = _read_text_lines(abs_path, max_bytes=max_bytes)
                    line_count = len(lines)
                    record["truncated"] = truncated
                    if truncated:
                        truncated_count += 1

                    if language == "Swift":
                        summary = _summarize_swift(lines)
                        for engine in summary.get("asr_engines", []):
                            swift_asr_engines.add(engine)
                        for s in summary.get("symbols", []):
                            if s.get("kind") == "protocol":
                                swift_protocols.add(s.get("name"))
                    elif language == "Markdown":
                        summary = _summarize_markdown(lines)
                    elif language == "YAML":
                        summary = _summarize_yaml(lines, path=abs_path)
                    elif language == "Shell":
                        summary = _summarize_shell(lines)
                    elif language in {"Objective-C", "Objective-C++"}:
                        summary = _summarize_objc(lines)
                    elif language in {"C", "C++", "C++ Header", "C/C++ Header"}:
                        summary = _summarize_cpp(lines)

                    if line_count is not None:
                        record["line_count"] = line_count

                except Exception as e:
                    record["read_error"] = f"{type(e).__name__}: {e}"

            if summary:
                record["summary"] = summary

            hint = _important_file_hint(rel)
            if hint:
                record["importance"] = hint
                key_files.append({"path": rel_str, "hint": hint})

            jf.write(json.dumps(record, sort_keys=True) + "\n")

            imports_str = ""
            symbols_str = ""
            if "summary" in record:
                s = record["summary"]
                if isinstance(s, dict):
                    if "imports" in s and isinstance(s["imports"], list):
                        imports_str = ",".join(s["imports"])
                    if "symbols" in s and isinstance(s["symbols"], list):
                        names = []
                        for sym in s["symbols"]:
                            if isinstance(sym, dict) and sym.get("name") and sym.get("kind"):
                                names.append(f"{sym['kind']}:{sym['name']}")
                        symbols_str = ",".join(names)

            tf.write(
                f"{rel_str}\t{category}\t{language}\t{st.st_size}\t{line_count or ''}\t{imports_str}\t{symbols_str}\n"
            )

            file_count += 1
            language_stats[language] += 1
            category_stats[category] += 1

            if language == "Swift" and line_count is not None and not truncated:
                largest_by_loc.append((line_count, rel_str))

    largest_by_loc.sort(reverse=True)

    return {
        "file_count": file_count,
        "truncated_file_count": truncated_count,
        "language_stats": dict(language_stats),
        "category_stats": dict(category_stats),
        "swift_asr_engines": sorted(swift_asr_engines),
        "swift_protocols": sorted(swift_protocols),
        "key_files": sorted(key_files, key=lambda x: x["path"]),
        "top_swift_files_by_loc": [
            {"path": p, "line_count": lc} for (lc, p) in largest_by_loc[:25]
        ],
    }


def write_project_map(root: Path, out_dir: Path, stats: dict[str, Any], max_bytes: int) -> None:
    now = _dt.datetime.now().astimezone().isoformat(timespec="seconds")
    git = _git_info(root)

    exclusions = {
        "skip_hidden": True,
        "skip_dir_names": sorted(SKIP_DIR_NAMES),
        "skip_file_names": sorted(SKIP_FILE_NAMES),
        "max_bytes_per_file": max_bytes,
        "also_skipped": ["Vendor/whisper.cpp/build"],
    }

    key_paths = [
        "AGENTS.md",
        "README.md",
        "build.sh",
        "project.yml",
        "MacTalk/MacTalk/main.swift",
        "MacTalk/MacTalk/TranscriptionController.swift",
        "MacTalk/MacTalk/Audio/AudioCapture.swift",
        "MacTalk/MacTalk/Audio/ScreenAudioCapture.swift",
        "MacTalk/MacTalk/Audio/AudioMixer.swift",
        "MacTalk/MacTalk/Audio/RingBuffer.swift",
        "MacTalk/MacTalk/Whisper/WhisperEngine.swift",
        "MacTalk/MacTalk/Whisper/ModelManager.swift",
        "MacTalk/MacTalk/Whisper/WhisperBridge.h",
        "MacTalk/MacTalk/Whisper/WhisperBridge.mm",
        "MacTalk/MacTalk/UI/StatusBarController.swift",
        "MacTalk/MacTalk/UI/HUDWindowController.swift",
        "MacTalk/MacTalk/UI/SettingsWindowController.swift",
        "docs/development/ARCHITECTURE.md",
        "docs/development/SETUP.md",
        "docs/testing/TESTING.md",
        "scripts/post-build-sign.sh",
    ]
    key_paths = [p for p in key_paths if (root / p).exists()]

    project_map: dict[str, Any] = {
        "generated_at": now,
        "repo_root": str(root),
        "git": git,
        "exclusions": exclusions,
        "high_level_structure": [
            {"path": "MacTalk/MacTalk", "role": "Main macOS app source (Swift/AppKit)"},
            {"path": "MacTalk/MacTalkTests", "role": "XCTest test target"},
            {"path": "Vendor/whisper.cpp", "role": "C++ inference engine submodule"},
            {"path": "scripts", "role": "Build/sign helpers"},
            {"path": "docs", "role": "Architecture + planning docs"},
        ],
        "key_paths": key_paths,
        "stats": stats,
        "architecture_hints": {
            "asr_engines_detected": stats.get("swift_asr_engines", []),
            "swift_protocols_detected": stats.get("swift_protocols", []),
            "notes": [
                "Xcode project is generated via XcodeGen (project.yml).",
                "Skip build/DerivedData and hidden directories for indexing; regenerate index after refactors.",
            ],
        },
        "commands": {
            "dev_loop": "./build.sh run",
            "build_only": "./build.sh",
            "clean": "./build.sh clean",
            "tests": "xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk",
            "xcodegen": "xcodegen generate",
        },
    }

    yaml_path = out_dir / "project_map.yaml"
    yaml_path.write_text(_to_yaml(project_map), encoding="utf-8")

    md_path = out_dir / "PROJECT_MAP.md"
    md_path.write_text(_to_project_map_md(project_map), encoding="utf-8")


def _yaml_quote(s: str) -> str:
    if s == "":
        return "''"
    if re.search(r"[:#\n\r\t]", s) or s.strip() != s or s.startswith(("-", "?", "@", "&", "*", "!", "%")):
        return json.dumps(s)
    return s


def _to_yaml(obj: Any, indent: int = 0) -> str:
    sp = "  " * indent
    if obj is None:
        return "null"
    if isinstance(obj, (bool, int, float)):
        return str(obj).lower() if isinstance(obj, bool) else str(obj)
    if isinstance(obj, str):
        return _yaml_quote(obj)
    if isinstance(obj, list):
        if not obj:
            return "[]"
        lines = []
        for item in obj:
            rendered = _to_yaml(item, indent=indent + 1)
            if "\n" in rendered:
                lines.append(f"{sp}- {rendered.splitlines()[0]}")
                lines.extend([f"{'  ' * (indent + 1)}{l}" for l in rendered.splitlines()[1:]])
            else:
                lines.append(f"{sp}- {rendered}")
        return "\n".join(lines)
    if isinstance(obj, dict):
        if not obj:
            return "{}"
        lines = []
        for k in sorted(obj.keys()):
            v = obj[k]
            key = str(k)
            rendered = _to_yaml(v, indent=indent + 1)
            if isinstance(v, (dict, list)) and v:
                lines.append(f"{sp}{key}:")
                lines.append(rendered)
            else:
                lines.append(f"{sp}{key}: {rendered}")
        return "\n".join(lines)
    return _yaml_quote(str(obj))


def _to_project_map_md(project_map: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append("# MacTalk Project Map")
    lines.append("")
    lines.append(f"- generated_at: `{project_map.get('generated_at')}`")
    lines.append(f"- repo_root: `{project_map.get('repo_root')}`")

    git = project_map.get("git") or {}
    if git:
        lines.append(f"- git.branch: `{git.get('branch', '')}`")
        lines.append(f"- git.commit: `{git.get('commit', '')}`")
        lines.append(f"- git.dirty: `{git.get('dirty', '')}`")

    lines.append("")
    lines.append("## Structure")
    for item in project_map.get("high_level_structure", []):
        lines.append(f"- {item['path']}: {item['role']}")

    lines.append("")
    lines.append("## Key Paths")
    for p in project_map.get("key_paths", []):
        lines.append(f"- {p}")

    lines.append("")
    lines.append("## Stats")
    stats = project_map.get("stats", {})
    lines.append(f"- file_count: `{stats.get('file_count')}`")
    lines.append(f"- truncated_file_count: `{stats.get('truncated_file_count')}`")
    lines.append(f"- languages: `{json.dumps(stats.get('language_stats', {}), sort_keys=True)}`")
    lines.append(f"- categories: `{json.dumps(stats.get('category_stats', {}), sort_keys=True)}`")

    engines = (project_map.get("architecture_hints") or {}).get("asr_engines_detected") or []
    if engines:
        lines.append(f"- asr_engines_detected: `{', '.join(engines)}`")

    lines.append("")
    lines.append("## Hotspots (Top Swift Files by LOC)")
    for item in stats.get("top_swift_files_by_loc", []):
        lines.append(f"- {item['path']}: {item['line_count']}")

    lines.append("")
    lines.append("## Commands")
    cmds = project_map.get("commands", {})
    for k in ["dev_loop", "build_only", "clean", "tests", "xcodegen"]:
        if k in cmds:
            lines.append(f"- {k}: `{cmds[k]}`")

    lines.append("")
    lines.append("## Outputs (This Directory)")
    lines.append("- `project_index.jsonl` (grep-friendly, one JSON per file)")
    lines.append("- `project_index.tsv` (path/category/language/size/line_count/imports/symbols)")
    lines.append("- `project_map.yaml` (machine-readable summary)")

    lines.append("")
    lines.append("## Grep Examples")
    lines.append("- Find all Swift files importing ScreenCaptureKit:")
    lines.append("  - `rg '\"imports\": \\[.*ScreenCaptureKit' agent-tools/project-index/project_index.jsonl`")
    lines.append("- Find TranscriptionController-related symbols:")
    lines.append("  - `rg 'TranscriptionController' agent-tools/project-index/project_index.tsv`")
    lines.append("")

    return "\n".join(lines) + "\n"


def _find_repo_root(start: Path) -> Path:
    # Prefer git root if available; otherwise walk up to find .git.
    rc, out = _run(["git", "rev-parse", "--show-toplevel"], cwd=start)
    if rc == 0 and out:
        return Path(out).resolve()

    p = start.resolve()
    for _ in range(50):
        if (p / ".git").exists():
            return p
        if p.parent == p:
            break
        p = p.parent
    return start.resolve()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Index the MacTalk repo into grep-friendly artifacts.")
    parser.add_argument(
        "--root",
        type=Path,
        default=None,
        help="Repo root (defaults to git root or current directory ascent).",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("agent-tools/project-index"),
        help="Output directory relative to root (default: agent-tools/project-index).",
    )
    parser.add_argument(
        "--max-bytes",
        type=int,
        default=512 * 1024,
        help="Max bytes to read per file for parsing (default: 524288).",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    start = Path.cwd()
    root = _find_repo_root(args.root or start)
    out_dir = (root / args.out_dir).resolve()

    stats = build_index(root=root, out_dir=out_dir, max_bytes=args.max_bytes)
    write_project_map(root=root, out_dir=out_dir, stats=stats, max_bytes=args.max_bytes)

    print(f"Wrote: {out_dir / 'project_index.jsonl'}")
    print(f"Wrote: {out_dir / 'project_index.tsv'}")
    print(f"Wrote: {out_dir / 'project_map.yaml'}")
    print(f"Wrote: {out_dir / 'PROJECT_MAP.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

