#!/usr/bin/env python3
"""Skills batch discovery/review/install pipeline for skills-batch-ops."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import re
import shlex
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path
from types import SimpleNamespace
from typing import Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import quote_plus
from urllib.request import Request, urlopen


CANDIDATE_HEADER = [
    "source_method",
    "source_rank",
    "skill_ref",
    "repo",
    "skill",
    "installs",
    "evidence_url",
    "evidence_note",
]

MERGED_HEADER = [
    "skill_ref",
    "repo",
    "skill",
    "methods",
    "method_count",
    "installs_max",
    "evidence_count",
    "source_files",
]

CONTENT_HEADER = [
    "skill_ref",
    "repo",
    "skill",
    "content_status",
    "content_checked",
    "source_url",
    "frontmatter_name",
    "frontmatter_description",
    "body_line_count",
    "body_char_count",
    "content_keywords",
    "reason",
]

MANIFEST_HEADER = [
    "skill_ref",
    "repo",
    "skill",
    "methods",
    "method_count",
    "installs_max",
    "content_status",
    "project_keyword_match",
    "project_keyword_hits",
    "score",
    "manifest_status",
    "status",
    "ai_decision",
    "ai_rationale",
]

INSTALL_REPORT_HEADER = [
    "timestamp",
    "repo",
    "skill",
    "manifest_status",
    "install_status",
    "command",
    "reason",
]

SKILL_REF_RE = re.compile(r"^(?P<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@(?P<skill>[A-Za-z0-9_.-]+)$")
FRONTMATTER_RE = re.compile(r"^---\n(?P<body>.*?)\n---\n?", re.DOTALL)
# Support both English-like tokens and Korean tokens so project/content
# keyword matching works for multilingual repositories.
TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]{2,}|[가-힣][가-힣0-9_-]{1,}")
BODY_PLACEHOLDER_RE = re.compile(r"\b(TODO|TBD|PLACEHOLDER)\b", re.IGNORECASE)
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*m")
FIND_LINE_RE = re.compile(
    r"(?P<skill_ref>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+)"
    r"(?:\s+(?P<installs>[0-9][0-9,._KkMm]*)\s+installs?)?"
)
POPULAR_PATTERNS = [
    re.compile(
        r'\\"source\\":\\"(?P<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\\"'
        r'.*?\\"skillId\\":\\"(?P<skill>[A-Za-z0-9_.-]+)\\"'
        r'.*?\\"installs\\":(?P<installs>[0-9]+)'
    ),
    re.compile(
        r'"source":"(?P<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)"'
        r'.*?"skillId":"(?P<skill>[A-Za-z0-9_.-]+)"'
        r'.*?"installs":(?P<installs>[0-9]+)'
    ),
]

STOPWORDS = {
    "the",
    "this",
    "that",
    "with",
    "from",
    "into",
    "for",
    "and",
    "are",
    "was",
    "were",
    "will",
    "you",
    "your",
    "our",
    "not",
    "have",
    "has",
    "had",
    "use",
    "using",
    "project",
    "skills",
    "skill",
    "readme",
}


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def sanitize(value: str) -> str:
    return " ".join(value.replace("\t", " ").replace("\r", " ").replace("\n", " ").split())


def strip_ansi(value: str) -> str:
    return ANSI_ESCAPE_RE.sub("", value)


def normalize_newlines(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def extract_keywords(text: str, limit: int = 40) -> list[str]:
    counter: Counter[str] = Counter()
    for token in TOKEN_RE.findall(text.lower()):
        if token in STOPWORDS:
            continue
        counter[token] += 1
    return [token for token, _count in counter.most_common(limit)]


def parse_install_count(raw: str | None) -> int:
    if not raw:
        return 0
    token = raw.strip().replace(",", "")
    if not token:
        return 0
    multiplier = 1
    if token[-1] in {"k", "K"}:
        multiplier = 1_000
        token = token[:-1]
    elif token[-1] in {"m", "M"}:
        multiplier = 1_000_000
        token = token[:-1]
    token = token.replace("_", "")
    try:
        return int(float(token) * multiplier)
    except ValueError:
        return 0


def split_skill_ref(value: str) -> tuple[str, str]:
    match = SKILL_REF_RE.match(value.strip())
    if not match:
        raise ValueError(f"invalid skill_ref: {value}")
    return match.group("repo"), match.group("skill")


def read_table(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        raise FileNotFoundError(str(path))
    text = path.read_text(encoding="utf-8")
    lines = [line for line in text.splitlines() if line.strip() != ""]
    if not lines:
        return []
    first = lines[0]
    delimiter = "\t" if first.count("\t") >= first.count(",") else ","
    reader = csv.DictReader(lines, delimiter=delimiter)
    rows: list[dict[str, str]] = []
    for row in reader:
        normalized = {str(k or "").strip().lower(): str(v or "").strip() for k, v in row.items()}
        rows.append(normalized)
    return rows


def write_tsv(path: Path, header: list[str], rows: Iterable[dict[str, object]]) -> None:
    ensure_parent(path)
    with path.open("w", encoding="utf-8", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=header, delimiter="\t", extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in header})


def iter_skill_refs(rows: Iterable[dict[str, str]]) -> Iterable[tuple[str, str, str]]:
    for row in rows:
        skill_ref = row.get("skill_ref", "").strip()
        repo = row.get("repo", "").strip()
        skill = row.get("skill", "").strip()
        if skill_ref:
            try:
                parsed_repo, parsed_skill = split_skill_ref(skill_ref)
            except ValueError:
                continue
            yield skill_ref, parsed_repo, parsed_skill
            continue
        if repo and skill:
            merged = f"{repo}@{skill}"
            if SKILL_REF_RE.match(merged):
                yield merged, repo, skill


def analyze_project(project_root: Path, out: Path) -> None:
    root = project_root.resolve()
    if not root.exists():
        raise FileNotFoundError(f"project root not found: {root}")

    detectors: list[tuple[str, list[str]]] = [
        ("nodejs", ["package.json"]),
        ("pnpm", ["pnpm-lock.yaml"]),
        ("yarn", ["yarn.lock"]),
        ("python", ["pyproject.toml", "requirements.txt", "requirements-dev.txt"]),
        ("go", ["go.mod"]),
        ("rust", ["Cargo.toml"]),
        ("java", ["pom.xml", "build.gradle", "build.gradle.kts"]),
        ("ruby", ["Gemfile"]),
        ("docker", ["Dockerfile", "docker-compose.yml", "docker-compose.yaml"]),
        ("terraform", ["*.tf"]),
        ("kubernetes", ["k8s/*.yaml", "k8s/*.yml", "manifests/*.yaml", "manifests/*.yml"]),
    ]

    technologies: list[str] = []
    for tech, patterns in detectors:
        for pattern in patterns:
            if any(root.glob(pattern)):
                technologies.append(tech)
                break

    token_counter: Counter[str] = Counter()
    readmes = sorted(root.glob("README*"))[:5]
    for readme in readmes:
        content = readme.read_text(encoding="utf-8", errors="ignore")[:120_000]
        for token in TOKEN_RE.findall(content.lower()):
            if token in STOPWORDS:
                continue
            token_counter[token] += 1

    for path in root.rglob("*"):
        if len(token_counter) >= 500:
            break
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix().lower()
        for token in TOKEN_RE.findall(rel):
            if token in STOPWORDS:
                continue
            token_counter[token] += 1

    top_keywords = [token for token, _count in token_counter.most_common(30)]
    rows = [
        {"key": "generated_at", "value": utc_now()},
        {"key": "project_root", "value": str(root)},
        {"key": "technologies", "value": ",".join(sorted(set(technologies)))},
        {"key": "top_keywords", "value": ",".join(top_keywords)},
    ]
    write_tsv(out, ["key", "value"], rows)


def parse_find_output_text(
    text: str,
    evidence_url: str = "",
    source_method: str = "find",
    note_prefix: str = "",
) -> list[dict[str, object]]:
    best: dict[str, dict[str, object]] = {}

    for raw_line in text.splitlines():
        line = strip_ansi(raw_line).strip()
        if not line:
            continue
        for match in FIND_LINE_RE.finditer(line):
            start, end = match.span("skill_ref")
            if start > 0 and end < len(line) and line[start - 1] == "<" and line[end] == ">":
                # Ignore documentation placeholders like <owner/repo@skill>.
                continue
            skill_ref = match.group("skill_ref")
            installs = parse_install_count(match.group("installs"))
            repo, skill = split_skill_ref(skill_ref)
            evidence_note = sanitize(line)[:180]
            if note_prefix:
                evidence_note = sanitize(f"{note_prefix} | {line}")[:180]
            prev = best.get(skill_ref)
            if prev is None or installs > int(prev["installs"]):
                best[skill_ref] = {
                    "source_method": source_method,
                    "source_rank": 0,
                    "skill_ref": skill_ref,
                    "repo": repo,
                    "skill": skill,
                    "installs": installs,
                    "evidence_url": evidence_url,
                    "evidence_note": evidence_note,
                }

    rows = sorted(best.values(), key=lambda item: (int(item["installs"]), item["skill_ref"]), reverse=True)
    for idx, row in enumerate(rows, start=1):
        row["source_rank"] = idx
    return rows


def collect_find(input_path: Path, out: Path, evidence_url: str = "") -> None:
    text = input_path.read_text(encoding="utf-8", errors="ignore")
    rows = parse_find_output_text(text, evidence_url=evidence_url, source_method="find")
    write_tsv(out, CANDIDATE_HEADER, rows)


def collect_popular(input_path: Path, out: Path, evidence_url: str = "") -> None:
    text = input_path.read_text(encoding="utf-8", errors="ignore")
    candidates: dict[str, dict[str, object]] = {}
    search_spaces = [text]
    if "\\\"" in text:
        # Some feeds escape inner JSON with variable slash depth (e.g. \\\", \\\\").
        normalized_escaped = re.sub(r'\\+"', r'\\"', text)
        normalized_plain = normalized_escaped.replace('\\"', '"')
        search_spaces.extend([normalized_escaped, normalized_plain])

    for search_text in search_spaces:
        for pattern in POPULAR_PATTERNS:
            for match in pattern.finditer(search_text):
                repo = match.group("repo")
                skill = match.group("skill")
                installs = parse_install_count(match.group("installs"))
                skill_ref = f"{repo}@{skill}"
                prev = candidates.get(skill_ref)
                if prev is None or installs > int(prev["installs"]):
                    candidates[skill_ref] = {
                        "source_method": "popular",
                        "source_rank": 0,
                        "skill_ref": skill_ref,
                        "repo": repo,
                        "skill": skill,
                        "installs": installs,
                        "evidence_url": evidence_url,
                        "evidence_note": "skills popular feed",
                    }

    rows = sorted(candidates.values(), key=lambda item: (int(item["installs"]), item["skill_ref"]), reverse=True)
    for idx, row in enumerate(rows, start=1):
        row["source_rank"] = idx
    write_tsv(out, CANDIDATE_HEADER, rows)


def collect_web(input_path: Path, out: Path) -> None:
    rows = read_table(input_path)
    normalized_rows: list[dict[str, object]] = []
    seen: set[str] = set()
    for row in rows:
        skill_ref = row.get("skill_ref", "")
        repo = row.get("repo", "")
        skill = row.get("skill", "")
        if not skill_ref and repo and skill:
            skill_ref = f"{repo}@{skill}"
        if not skill_ref:
            continue
        try:
            repo, skill = split_skill_ref(skill_ref)
        except ValueError:
            continue
        installs = parse_install_count(row.get("installs", ""))
        dedupe_key = f"{skill_ref}|{row.get('evidence_url', '')}|{row.get('evidence_note', '')}"
        if dedupe_key in seen:
            continue
        seen.add(dedupe_key)
        normalized_rows.append(
            {
                "source_method": "web",
                "source_rank": 0,
                "skill_ref": skill_ref,
                "repo": repo,
                "skill": skill,
                "installs": installs,
                "evidence_url": row.get("evidence_url", ""),
                "evidence_note": sanitize(row.get("evidence_note", row.get("notes", "")))[:180],
            }
        )
    for idx, row in enumerate(normalized_rows, start=1):
        row["source_rank"] = idx
    write_tsv(out, CANDIDATE_HEADER, normalized_rows)


def merge_candidates(inputs: list[Path], out: Path) -> None:
    merged: dict[str, dict[str, object]] = {}
    for candidate_path in inputs:
        rows = read_table(candidate_path)
        for row in rows:
            skill_ref = row.get("skill_ref", "")
            repo = row.get("repo", "")
            skill = row.get("skill", "")
            if not skill_ref:
                if repo and skill:
                    skill_ref = f"{repo}@{skill}"
                else:
                    continue
            try:
                repo, skill = split_skill_ref(skill_ref)
            except ValueError:
                continue
            current = merged.setdefault(
                skill_ref,
                {
                    "skill_ref": skill_ref,
                    "repo": repo,
                    "skill": skill,
                    "methods": set(),
                    "method_count": 0,
                    "installs_max": 0,
                    "evidence_count": 0,
                    "source_files": set(),
                },
            )
            source_method = row.get("source_method", "").strip()
            if source_method:
                current["methods"].add(source_method)
            installs = parse_install_count(row.get("installs", ""))
            if installs > int(current["installs_max"]):
                current["installs_max"] = installs
            current["evidence_count"] = int(current["evidence_count"]) + 1
            current["source_files"].add(candidate_path.name)

    output_rows: list[dict[str, object]] = []
    for skill_ref, row in merged.items():
        methods_sorted = sorted(str(v) for v in row["methods"])
        output_rows.append(
            {
                "skill_ref": skill_ref,
                "repo": row["repo"],
                "skill": row["skill"],
                "methods": ",".join(methods_sorted),
                "method_count": len(methods_sorted),
                "installs_max": int(row["installs_max"]),
                "evidence_count": int(row["evidence_count"]),
                "source_files": ",".join(sorted(str(v) for v in row["source_files"])),
            }
        )

    output_rows.sort(
        key=lambda item: (
            int(item["method_count"]),
            int(item["installs_max"]),
            item["skill_ref"],
        ),
        reverse=True,
    )
    write_tsv(out, MERGED_HEADER, output_rows)


def parse_skill_markdown(text: str) -> tuple[str, str, str] | None:
    normalized = normalize_newlines(text).lstrip("\ufeff")
    match = FRONTMATTER_RE.match(normalized)
    if not match:
        return None
    name = ""
    description = ""
    for raw_line in match.group("body").splitlines():
        if ":" not in raw_line:
            continue
        key, value = raw_line.split(":", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key == "name":
            name = value
        elif key == "description":
            description = value
    body = normalized[match.end() :].strip()
    return name, description, body


def candidate_skill_md_urls(repo: str, skill: str, branches: list[str] | None = None) -> list[str]:
    urls: list[str] = []
    for branch in dedupe_keep_order((branches or []) + ["main", "master"]):
        urls.extend(
            [
                f"https://raw.githubusercontent.com/{repo}/{branch}/SKILL.md",
                f"https://raw.githubusercontent.com/{repo}/{branch}/skills/{skill}/SKILL.md",
                f"https://raw.githubusercontent.com/{repo}/{branch}/{skill}/SKILL.md",
            ]
        )
    return urls


def fetch_text(url: str, timeout_sec: int = 10) -> str:
    req = Request(url=url, headers={"User-Agent": "skills-batch-ops/1.0"})
    with urlopen(req, timeout=timeout_sec) as resp:
        return resp.read().decode("utf-8", errors="replace")


def validate_content(candidates: Path, out: Path, strict: bool) -> int:
    rows = read_table(candidates)
    output: list[dict[str, object]] = []
    failed = 0

    seen: set[str] = set()
    default_branch_cache: dict[str, str] = {}
    for skill_ref, repo, skill in iter_skill_refs(rows):
        if skill_ref in seen:
            continue
        seen.add(skill_ref)
        status = "failed"
        content_checked = "false"
        source_url = ""
        fm_name = ""
        fm_description = ""
        body_line_count = 0
        body_char_count = 0
        content_keywords = ""
        reason = "skill_md_not_found"

        default_branch = default_branch_cache.get(repo)
        if default_branch is None:
            default_branch = fetch_repo_default_branch(repo)
            default_branch_cache[repo] = default_branch
        branch_candidates = ["main", "master"]
        if default_branch:
            branch_candidates = dedupe_keep_order([default_branch] + branch_candidates)

        for url in candidate_skill_md_urls(repo, skill, branches=branch_candidates):
            try:
                text = fetch_text(url)
            except HTTPError as exc:
                reason = f"http_{exc.code}"
                continue
            except URLError:
                reason = "network_error"
                continue
            except TimeoutError:
                reason = "timeout"
                continue

            parsed = parse_skill_markdown(text)
            if parsed is None:
                source_url = url
                content_checked = "true"
                reason = "missing_frontmatter"
                continue

            fm_name, fm_description, body = parsed
            source_url = url
            content_checked = "true"
            body_char_count = len(body)
            body_line_count = len([line for line in body.splitlines() if line.strip()])
            content_keywords = ",".join(extract_keywords(f"{fm_description}\n{body}", limit=40))

            if fm_name != skill:
                reason = "frontmatter_name_mismatch"
                continue
            if not fm_description.strip():
                reason = "missing_frontmatter_description"
                continue
            if body_char_count < 80 and body_line_count < 3:
                reason = "skill_body_too_short"
                continue
            if BODY_PLACEHOLDER_RE.search(body):
                reason = "skill_body_has_placeholder"
                continue

            status = "passed"
            reason = "ok"
            break

        if status != "passed":
            failed += 1

        output.append(
            {
                "skill_ref": skill_ref,
                "repo": repo,
                "skill": skill,
                "content_status": status,
                "content_checked": content_checked,
                "source_url": source_url,
                "frontmatter_name": fm_name,
                "frontmatter_description": fm_description,
                "body_line_count": body_line_count,
                "body_char_count": body_char_count,
                "content_keywords": content_keywords,
                "reason": reason,
            }
        )

    write_tsv(out, CONTENT_HEADER, output)
    if strict and failed > 0:
        return 2
    return 0


def load_project_keywords(profile_path: Path | None) -> set[str]:
    if profile_path is None:
        return set()
    rows = read_table(profile_path)
    keywords: set[str] = set()
    for row in rows:
        if row.get("key") != "top_keywords":
            continue
        for token in row.get("value", "").split(","):
            token = token.strip().lower()
            if token:
                keywords.add(token)
    return keywords


def load_project_profile_map(profile_path: Path) -> dict[str, str]:
    profile: dict[str, str] = {}
    for row in read_table(profile_path):
        key = row.get("key", "").strip()
        if not key:
            continue
        profile[key] = row.get("value", "").strip()
    return profile


def split_csv_tokens(raw: str) -> list[str]:
    tokens: list[str] = []
    for token in raw.split(","):
        token = token.strip().lower()
        if not token:
            continue
        tokens.append(token)
    return tokens


def dedupe_keep_order(values: Iterable[str]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for value in values:
        normalized = value.strip()
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        out.append(normalized)
    return out


def derive_live_queries(
    profile: dict[str, str],
    explicit_find_query: str | None,
    explicit_web_queries: list[str] | None,
) -> tuple[str, list[str]]:
    keywords = [
        token
        for token in split_csv_tokens(profile.get("top_keywords", ""))
        if len(token) >= 3 and token not in STOPWORDS
    ]
    technologies = split_csv_tokens(profile.get("technologies", ""))

    base_terms = dedupe_keep_order(keywords + technologies)
    if not base_terms:
        base_terms = ["software", "engineering", "automation", "testing"]

    find_query = (explicit_find_query or " ".join(base_terms[:4])).strip()
    if not find_query:
        find_query = "software engineering automation"

    if explicit_web_queries:
        web_queries = dedupe_keep_order(explicit_web_queries)
    else:
        generated = [find_query]
        generated.extend(f"{term} agent skills" for term in base_terms[:3])
        web_queries = dedupe_keep_order(generated)
    if not web_queries:
        web_queries = [find_query]
    return find_query, web_queries


def run_find_query(find_command: str, query: str, out: Path, timeout_sec: int) -> None:
    cmd = shlex.split(find_command)
    if not cmd:
        raise RuntimeError("find-command is empty")
    cmd.append(query)

    safe_timeout = max(int(timeout_sec), 1)
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            timeout=safe_timeout,
        )
    except subprocess.TimeoutExpired as exc:
        partial_out = (exc.stdout or "").strip() if isinstance(exc.stdout, str) else ""
        partial_err = (exc.stderr or "").strip() if isinstance(exc.stderr, str) else ""
        merged_partial = partial_out
        if partial_err:
            merged_partial = f"{merged_partial}\n{partial_err}" if merged_partial else partial_err
        ensure_parent(out)
        out.write_text((merged_partial + "\n") if merged_partial else "", encoding="utf-8")
        raise RuntimeError(f"find command timed out after {safe_timeout}s: {' '.join(cmd)}") from exc

    text_out = (proc.stdout or "").strip()
    text_err = (proc.stderr or "").strip()
    merged_output = text_out
    if text_err:
        merged_output = f"{merged_output}\n{text_err}" if merged_output else text_err

    ensure_parent(out)
    out.write_text((merged_output + "\n") if merged_output else "", encoding="utf-8")
    if proc.returncode != 0:
        snippet = sanitize((merged_output or "find command failed")[:240])
        raise RuntimeError(f"find command failed (exit={proc.returncode}): {snippet}")


def fetch_json(url: str, timeout_sec: int = 15) -> object:
    req = Request(
        url=url,
        headers={
            "User-Agent": "skills-batch-ops/1.0",
            "Accept": "application/vnd.github+json",
        },
    )
    with urlopen(req, timeout=timeout_sec) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
    return json.loads(raw)


def fetch_repo_default_branch(repo: str, api_base: str = "https://api.github.com", timeout_sec: int = 10) -> str:
    url = f"{api_base.rstrip('/')}/repos/{repo}"
    try:
        payload = fetch_json(url, timeout_sec=max(int(timeout_sec), 1))
    except (HTTPError, URLError, TimeoutError, json.JSONDecodeError):
        return ""
    if not isinstance(payload, dict):
        return ""
    return str(payload.get("default_branch", "")).strip()


def discover_repo_skills_from_github(
    api_base: str,
    repo: str,
    timeout_sec: int,
    max_skills_per_repo: int,
    branches: list[str] | None = None,
) -> list[str]:
    api_base = api_base.rstrip("/")
    skills: list[str] = []
    seen: set[str] = set()
    branch_candidates = dedupe_keep_order((branches or []) + ["main", "master"])

    for branch in branch_candidates:
        url = f"{api_base}/repos/{repo}/contents/skills?ref={quote_plus(branch)}"
        try:
            payload = fetch_json(url, timeout_sec=timeout_sec)
        except HTTPError as exc:
            if exc.code == 404:
                continue
            raise

        if not isinstance(payload, list):
            continue
        for entry in payload:
            if not isinstance(entry, dict):
                continue
            if entry.get("type") != "dir":
                continue
            name = str(entry.get("name", "")).strip()
            if not name:
                continue
            if name in seen:
                continue
            seen.add(name)
            skills.append(name)
            if len(skills) >= max_skills_per_repo:
                return skills

    if skills:
        return skills

    # Fallback: inspect git tree for any path ending with SKILL.md.
    for branch in branch_candidates:
        tree_url = f"{api_base}/repos/{repo}/git/trees/{quote_plus(branch)}?recursive=1"
        try:
            payload = fetch_json(tree_url, timeout_sec=timeout_sec)
        except HTTPError as exc:
            if exc.code == 404:
                continue
            raise
        if not isinstance(payload, dict):
            continue
        tree = payload.get("tree")
        if not isinstance(tree, list):
            continue

        for entry in tree:
            if not isinstance(entry, dict):
                continue
            if entry.get("type") != "blob":
                continue
            path = str(entry.get("path", "")).strip()
            if not path.endswith("SKILL.md"):
                continue

            parts = path.split("/")
            skill_name = ""
            if path == "SKILL.md":
                # Root-level SKILL.md: fetch name from frontmatter.
                raw_url = f"https://raw.githubusercontent.com/{repo}/{branch}/SKILL.md"
                try:
                    text = fetch_text(raw_url, timeout_sec=timeout_sec)
                except HTTPError:
                    continue
                except URLError:
                    continue
                parsed = parse_skill_markdown(text)
                if parsed is None:
                    continue
                skill_name = parsed[0].strip()
            elif len(parts) >= 3 and parts[0] == "skills":
                skill_name = parts[1].strip()
            elif len(parts) >= 2:
                skill_name = parts[-2].strip()

            if not skill_name:
                continue
            if skill_name in seen:
                continue
            seen.add(skill_name)
            skills.append(skill_name)
            if len(skills) >= max_skills_per_repo:
                return skills
        if skills:
            return skills

    # Fallback for repositories that expose a single root-level SKILL.md.
    for branch in branch_candidates:
        raw_url = f"https://raw.githubusercontent.com/{repo}/{branch}/SKILL.md"
        try:
            text = fetch_text(raw_url, timeout_sec=timeout_sec)
        except HTTPError as exc:
            if exc.code == 404:
                continue
            raise
        except URLError:
            continue
        parsed = parse_skill_markdown(text)
        if parsed is None:
            continue
        name = parsed[0].strip()
        if not name:
            continue
        if name not in seen:
            skills.append(name)
        break

    return skills[:max_skills_per_repo]


def collect_web_candidates_from_github(
    web_queries: list[str],
    out: Path,
    api_base: str,
    repo_limit: int,
    skill_limit_per_repo: int,
    timeout_sec: int,
) -> None:
    api_base = api_base.rstrip("/")
    per_page = max(1, min(repo_limit, 100))
    rows_by_skill_ref: dict[str, dict[str, object]] = {}
    seen_repos: set[str] = set()

    for query in web_queries:
        search_query = f"{query} skills in:name,description,readme archived:false"
        url = (
            f"{api_base}/search/repositories"
            f"?q={quote_plus(search_query)}&sort=stars&order=desc&per_page={per_page}"
        )
        payload = fetch_json(url, timeout_sec=timeout_sec)
        if not isinstance(payload, dict):
            continue
        items = payload.get("items")
        if not isinstance(items, list):
            continue

        for item in items:
            if not isinstance(item, dict):
                continue
            repo = str(item.get("full_name", "")).strip()
            if not repo or repo in seen_repos:
                continue
            seen_repos.add(repo)

            stars = int(item.get("stargazers_count") or 0)
            default_branch = str(item.get("default_branch", "")).strip()
            repo_url = str(item.get("html_url", f"https://github.com/{repo}")).strip()
            try:
                skills = discover_repo_skills_from_github(
                    api_base=api_base,
                    repo=repo,
                    timeout_sec=timeout_sec,
                    max_skills_per_repo=max(1, skill_limit_per_repo),
                    branches=[default_branch] if default_branch else None,
                )
            except HTTPError:
                continue
            except URLError:
                continue

            for skill in skills:
                skill_ref = f"{repo}@{skill}"
                if not SKILL_REF_RE.match(skill_ref):
                    continue
                note = sanitize(f"github_search query={query} stars={stars}")[:180]
                row = rows_by_skill_ref.get(skill_ref)
                if row is None or stars > int(row["installs"]):
                    rows_by_skill_ref[skill_ref] = {
                        "skill_ref": skill_ref,
                        "repo": repo,
                        "skill": skill,
                        "installs": stars,
                        "evidence_url": repo_url,
                        "evidence_note": note,
                    }

            if len(seen_repos) >= repo_limit:
                break
        if len(seen_repos) >= repo_limit:
            break

    output_rows = sorted(
        rows_by_skill_ref.values(),
        key=lambda item: (int(item["installs"]), item["skill_ref"]),
        reverse=True,
    )
    write_tsv(
        out,
        ["skill_ref", "repo", "skill", "installs", "evidence_url", "evidence_note"],
        output_rows,
    )


def collect_web_candidates_via_find(
    web_queries: list[str],
    out: Path,
    find_command: str,
    timeout_sec: int,
) -> None:
    rows_by_skill_ref: dict[str, dict[str, object]] = {}

    for query in web_queries:
        cmd = shlex.split(find_command)
        if not cmd:
            raise RuntimeError("find-command is empty")
        cmd.append(query)

        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=False,
                timeout=max(int(timeout_sec), 1),
            )
        except subprocess.TimeoutExpired:
            continue
        if proc.returncode != 0:
            continue
        evidence_url = f"https://skills.sh/?q={quote_plus(query)}"
        parsed_rows = parse_find_output_text(
            proc.stdout or "",
            evidence_url=evidence_url,
            source_method="web",
            note_prefix=f"web_query={query}",
        )
        for row in parsed_rows:
            skill_ref = str(row.get("skill_ref", ""))
            if not skill_ref:
                continue
            current = rows_by_skill_ref.get(skill_ref)
            installs = int(row.get("installs", 0) or 0)
            if current is None or installs > int(current["installs"]):
                rows_by_skill_ref[skill_ref] = {
                    "skill_ref": skill_ref,
                    "repo": row.get("repo", ""),
                    "skill": row.get("skill", ""),
                    "installs": installs,
                    "evidence_url": row.get("evidence_url", evidence_url),
                    "evidence_note": row.get("evidence_note", ""),
                }

    output_rows = sorted(
        rows_by_skill_ref.values(),
        key=lambda item: (int(item["installs"]), item["skill_ref"]),
        reverse=True,
    )
    write_tsv(
        out,
        ["skill_ref", "repo", "skill", "installs", "evidence_url", "evidence_note"],
        output_rows,
    )


def collect_sources_live(args: argparse.Namespace) -> int:
    project_root = Path(args.project_root).resolve()
    run_dir = Path(args.run_dir).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)

    project_profile = run_dir / "project_profile.tsv"
    find_output = Path(args.find_output).resolve() if args.find_output else run_dir / "find_output.txt"
    popular_output = Path(args.popular_output).resolve() if args.popular_output else run_dir / "popular_output.html"
    web_output = Path(args.web_output).resolve() if args.web_output else run_dir / "web_candidates.tsv"

    candidates_find = run_dir / "candidates.find.tsv"
    candidates_popular = run_dir / "candidates.popular.tsv"
    candidates_web = run_dir / "candidates.web.tsv"
    web_fallback_reason = ""

    analyze_project(project_root, project_profile)
    profile = load_project_profile_map(project_profile)
    find_query, web_queries = derive_live_queries(profile, args.find_query, args.web_query)

    find_evidence_url = args.find_evidence_url.strip() or f"https://skills.sh/?q={quote_plus(find_query)}"
    run_find_query(
        args.find_command,
        find_query,
        find_output,
        timeout_sec=max(args.find_timeout_sec, 1),
    )
    collect_find(find_output, candidates_find, evidence_url=find_evidence_url)

    popular_html = fetch_text(args.popular_url, timeout_sec=max(args.timeout_sec, 5))
    ensure_parent(popular_output)
    popular_output.write_text(popular_html, encoding="utf-8")
    collect_popular(popular_output, candidates_popular, evidence_url=args.popular_url)

    if args.web_mode == "seed":
        if not args.web_seed_input:
            raise RuntimeError("--web-seed-input is required when --web-mode seed")
        seed_path = Path(args.web_seed_input).resolve()
        if not seed_path.exists():
            raise FileNotFoundError(f"web seed input not found: {seed_path}")
        ensure_parent(web_output)
        shutil.copyfile(seed_path, web_output)
    else:
        github_failure_reason = ""
        try:
            collect_web_candidates_from_github(
                web_queries=web_queries,
                out=web_output,
                api_base=args.github_api_base,
                repo_limit=max(args.web_repo_limit, 1),
                skill_limit_per_repo=max(args.web_skill_limit_per_repo, 1),
                timeout_sec=max(args.timeout_sec, 5),
            )
        except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as exc:
            github_failure_reason = f"github-api-unavailable ({type(exc).__name__})"
        else:
            if len(read_table(web_output)) == 0:
                github_failure_reason = "github-api-empty"

        if github_failure_reason:
            if args.web_fallback_mode == "find":
                web_fallback_reason = github_failure_reason
                collect_web_candidates_via_find(
                    web_queries=web_queries,
                    out=web_output,
                    find_command=args.find_command,
                    timeout_sec=max(args.find_timeout_sec, 1),
                )
            else:
                raise RuntimeError(
                    f"internet web source collection failed: {github_failure_reason}. "
                    "Set --web-fallback-mode find to allow find-based fallback."
                )

    collect_web(web_output, candidates_web)
    source_counts = {
        "find": len(read_table(candidates_find)),
        "popular": len(read_table(candidates_popular)),
        "web": len(read_table(candidates_web)),
    }
    if not args.allow_empty_sources:
        empty_sources = [name for name, count in source_counts.items() if count == 0]
        if empty_sources:
            joined = ", ".join(empty_sources)
            raise RuntimeError(
                f"empty source(s) after live collection: {joined}. "
                "Use better queries or pass --allow-empty-sources."
            )

    print(f"run_dir: {run_dir}")
    print(f"project_profile: {project_profile}")
    print(f"find_query: {find_query}")
    print(f"web_queries: {', '.join(web_queries)}")
    print(
        "source_counts: "
        f"find={source_counts['find']},popular={source_counts['popular']},web={source_counts['web']}"
    )
    print(f"find_output: {find_output}")
    print(f"popular_output: {popular_output}")
    print(f"web_output: {web_output}")
    if web_fallback_reason:
        print(f"web_fallback: {web_fallback_reason}")
    print(f"candidates_find: {candidates_find}")
    print(f"candidates_popular: {candidates_popular}")
    print(f"candidates_web: {candidates_web}")

    if not args.run_after_collect:
        return 0

    run_args = SimpleNamespace(
        project_root=str(project_root),
        run_dir=str(run_dir),
        find_input=str(find_output),
        popular_input=str(popular_output),
        web_input=str(web_output),
        find_evidence_url=find_evidence_url,
        popular_evidence_url=args.popular_url,
        min_methods=max(args.min_methods, 1),
        limit=max(args.limit, 1),
        min_project_keyword_hits=max(args.min_project_keyword_hits, 0),
        dry_run=bool(args.dry_run),
        no_yes=bool(args.no_yes),
        allow_empty_sources=bool(args.allow_empty_sources),
    )
    return run_pipeline(run_args)


def build_manifest(
    merged: Path,
    content_report: Path,
    out: Path,
    project_profile: Path | None,
    min_methods: int,
    limit: int,
    min_project_keyword_hits: int,
) -> None:
    merged_rows = read_table(merged)
    content_rows = read_table(content_report)
    content_map = {row.get("skill_ref", ""): row for row in content_rows}
    project_keywords = load_project_keywords(project_profile)

    keyword_gate_active = bool(project_keywords) and min_project_keyword_hits > 0
    drafted: list[dict[str, object]] = []
    for row in merged_rows:
        skill_ref = row.get("skill_ref", "")
        repo = row.get("repo", "")
        skill = row.get("skill", "")
        methods = row.get("methods", "")
        method_count = int(row.get("method_count", "0") or 0)
        installs_max = int(row.get("installs_max", "0") or 0)
        content = content_map.get(skill_ref, {})
        content_status = content.get("content_status", "failed")

        skill_tokens = {token.lower() for token in re.split(r"[-_.]", skill) if token}
        content_tokens = {
            token.strip().lower()
            for token in content.get("content_keywords", "").split(",")
            if token.strip()
        }
        keyword_hits = sorted(project_keywords.intersection(skill_tokens.union(content_tokens)))
        keyword_match = "true" if keyword_hits else "false"
        keyword_hits_value = ",".join(keyword_hits[:20])
        keyword_hit_count = len(keyword_hits)
        relevance_bonus = min(len(keyword_hits), 5) * 12
        score = method_count * 100 + min(installs_max, 500_000) // 5_000 + relevance_bonus

        if content_status != "passed":
            manifest_status = "rejected"
            decision = "reject"
            rationale = "SKILL.md content verification failed"
        elif method_count < min_methods:
            manifest_status = "pending"
            decision = "hold"
            rationale = f"content verified but discovery coverage is below min_methods={min_methods}"
        elif keyword_gate_active and keyword_hit_count < min_project_keyword_hits:
            manifest_status = "pending"
            decision = "hold"
            rationale = (
                "content verified and discovery coverage passed, "
                f"but project keyword hits are below min_project_keyword_hits={min_project_keyword_hits}"
            )
        else:
            manifest_status = "approved"
            decision = "approve"
            if keyword_hits:
                rationale = (
                    f"content verified, discovered by {method_count} methods, "
                    f"project keyword hits: {', '.join(keyword_hits[:5])}"
                )
            elif project_keywords:
                rationale = (
                    f"content verified and discovered by {method_count} methods "
                    "(no direct project keyword overlap)"
                )
            else:
                rationale = f"content verified and discovered by {method_count} methods"

        drafted.append(
            {
                "skill_ref": skill_ref,
                "repo": repo,
                "skill": skill,
                "methods": methods,
                "method_count": method_count,
                "installs_max": installs_max,
                "content_status": content_status,
                "project_keyword_match": keyword_match,
                "project_keyword_hits": keyword_hits_value,
                "score": score,
                "manifest_status": manifest_status,
                "status": manifest_status,
                "ai_decision": decision,
                "ai_rationale": rationale,
            }
        )

    approved = [row for row in drafted if row["manifest_status"] == "approved"]
    approved.sort(key=lambda item: (int(item["score"]), int(item["installs_max"]), item["skill_ref"]), reverse=True)
    if limit > 0 and len(approved) > limit:
        keep_refs = {row["skill_ref"] for row in approved[:limit]}
        for row in drafted:
            if row["manifest_status"] != "approved":
                continue
            if row["skill_ref"] in keep_refs:
                continue
            row["manifest_status"] = "pending"
            row["status"] = "pending"
            row["ai_decision"] = "hold"
            row["ai_rationale"] = f"content verified but approval limit exceeded (limit={limit})"

    drafted.sort(key=lambda item: (int(item["score"]), int(item["installs_max"]), item["skill_ref"]), reverse=True)
    write_tsv(out, MANIFEST_HEADER, drafted)


def install_manifest(manifest: Path, report: Path, dry_run: bool, yes: bool) -> int:
    rows = read_table(manifest)
    ensure_parent(report)
    timestamp = utc_now()
    failures = 0
    written_rows: list[dict[str, object]] = []
    approved_count = 0

    if not dry_run and shutil.which("npx") is None:
        raise RuntimeError("npx is required for install-manifest")

    for row in rows:
        manifest_status = (row.get("manifest_status") or row.get("status") or "").lower()
        if manifest_status != "approved":
            continue
        approved_count += 1

        skill_ref = row.get("skill_ref", "").strip()
        repo = row.get("repo", "").strip()
        skill = row.get("skill", "").strip()
        content_status = row.get("content_status", "").strip().lower()

        install_status = "skipped"
        reason = ""
        command = ""

        try:
            parsed_repo, parsed_skill = split_skill_ref(skill_ref)
            if repo != parsed_repo or skill != parsed_skill:
                raise ValueError("skill_ref/repo/skill mismatch")
        except ValueError as exc:
            install_status = "failed"
            reason = str(exc)
            failures += 1
        else:
            if content_status and content_status != "passed":
                install_status = "failed"
                reason = "content_status is not passed"
                failures += 1
            else:
                cmd = ["npx", "--yes", "skills", "add", repo, "--skill", skill]
                if yes:
                    cmd.append("-y")
                command = " ".join(cmd)
                if dry_run:
                    install_status = "dry-run"
                    reason = "dry-run"
                else:
                    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
                    if proc.returncode == 0:
                        install_status = "installed"
                        reason = "ok"
                    else:
                        install_status = "failed"
                        reason = sanitize((proc.stderr or proc.stdout or "npx skills add failed")[:240])
                        failures += 1

        written_rows.append(
            {
                "timestamp": timestamp,
                "repo": repo,
                "skill": skill,
                "manifest_status": manifest_status,
                "install_status": install_status,
                "command": command,
                "reason": reason,
            }
        )

    write_tsv(report, INSTALL_REPORT_HEADER, written_rows)
    if approved_count == 0:
        return 0
    if failures > 0:
        return 3
    return 0


def run_pipeline(args: argparse.Namespace) -> int:
    project_root = Path(args.project_root).resolve()
    run_dir = Path(args.run_dir).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)

    find_input = Path(args.find_input).resolve()
    popular_input = Path(args.popular_input).resolve()
    web_input = Path(args.web_input).resolve()

    for label, path in [
        ("find_input", find_input),
        ("popular_input", popular_input),
        ("web_input", web_input),
    ]:
        if not path.exists():
            raise FileNotFoundError(f"{label} not found: {path}")

    project_profile = run_dir / "project_profile.tsv"
    find_out = run_dir / "candidates.find.tsv"
    popular_out = run_dir / "candidates.popular.tsv"
    web_out = run_dir / "candidates.web.tsv"
    merged_out = run_dir / "candidates.merged.tsv"
    content_out = run_dir / "review_content.tsv"
    manifest_out = run_dir / "review_manifest.ai.tsv"
    install_out = run_dir / "install.report.tsv"

    analyze_project(project_root, project_profile)
    collect_find(find_input, find_out, args.find_evidence_url)
    collect_popular(popular_input, popular_out, args.popular_evidence_url)
    collect_web(web_input, web_out)
    source_counts = {
        "find": len(read_table(find_out)),
        "popular": len(read_table(popular_out)),
        "web": len(read_table(web_out)),
    }
    if not args.allow_empty_sources:
        empty_sources = [name for name, count in source_counts.items() if count == 0]
        if empty_sources:
            joined = ", ".join(empty_sources)
            raise RuntimeError(
                f"empty candidate source(s): {joined}. "
                "Provide data for all three methods or pass --allow-empty-sources."
            )
    merge_candidates([find_out, popular_out, web_out], merged_out)

    validate_rc = validate_content(merged_out, content_out, strict=False)
    if validate_rc not in {0, 2}:
        return validate_rc

    build_manifest(
        merged=merged_out,
        content_report=content_out,
        out=manifest_out,
        project_profile=project_profile,
        min_methods=args.min_methods,
        limit=args.limit,
        min_project_keyword_hits=max(args.min_project_keyword_hits, 0),
    )

    install_rc = install_manifest(manifest_out, install_out, dry_run=args.dry_run, yes=not args.no_yes)
    print(f"run_dir: {run_dir}")
    print(f"project_profile: {project_profile}")
    print(
        "source_counts: "
        f"find={source_counts['find']},popular={source_counts['popular']},web={source_counts['web']}"
    )
    print(f"merged_candidates: {merged_out}")
    print(f"content_report: {content_out}")
    print(f"manifest: {manifest_out}")
    print(f"install_report: {install_out}")
    return install_rc


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="skills_batch_pipeline.py",
        description="Project-aware multi-source skills discovery, content review, and install pipeline.",
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    analyze = sub.add_parser("analyze-project", help="analyze project profile")
    analyze.add_argument("--project-root", required=True)
    analyze.add_argument("--out", required=True)

    collect_find_cmd = sub.add_parser("collect-find", help="collect candidates from find-skills output text")
    collect_find_cmd.add_argument("--input", required=True)
    collect_find_cmd.add_argument("--out", required=True)
    collect_find_cmd.add_argument("--evidence-url", default="")

    collect_popular_cmd = sub.add_parser("collect-popular", help="collect candidates from popular skills HTML/text")
    collect_popular_cmd.add_argument("--input", required=True)
    collect_popular_cmd.add_argument("--out", required=True)
    collect_popular_cmd.add_argument("--evidence-url", default="")

    collect_web_cmd = sub.add_parser("collect-web", help="import internet-search candidate table (tsv/csv)")
    collect_web_cmd.add_argument("--input", required=True)
    collect_web_cmd.add_argument("--out", required=True)

    merge_cmd = sub.add_parser("merge-candidates", help="merge candidate TSVs")
    merge_cmd.add_argument("--out", required=True)
    merge_cmd.add_argument("inputs", nargs="+")

    validate_cmd = sub.add_parser("validate-content", help="verify candidate SKILL.md content from source repos")
    validate_cmd.add_argument("--candidates", required=True)
    validate_cmd.add_argument("--out", required=True)
    validate_cmd.add_argument("--strict", action="store_true")

    manifest_cmd = sub.add_parser("build-manifest", help="build review_manifest.ai.tsv")
    manifest_cmd.add_argument("--merged", required=True)
    manifest_cmd.add_argument("--content-report", required=True)
    manifest_cmd.add_argument("--out", required=True)
    manifest_cmd.add_argument("--project-profile")
    manifest_cmd.add_argument("--min-methods", type=int, default=2)
    manifest_cmd.add_argument("--limit", type=int, default=8)
    manifest_cmd.add_argument("--min-project-keyword-hits", type=int, default=1)

    install_cmd = sub.add_parser("install-manifest", help="install approved skills from manifest")
    install_cmd.add_argument("--manifest", required=True)
    install_cmd.add_argument("--report", required=True)
    install_cmd.add_argument("--dry-run", action="store_true")
    install_cmd.add_argument("--no-yes", action="store_true")

    run_cmd = sub.add_parser("run", help="run 1~6 pipeline end-to-end")
    run_cmd.add_argument("--project-root", required=True)
    run_cmd.add_argument("--run-dir", required=True)
    run_cmd.add_argument("--find-input", required=True)
    run_cmd.add_argument("--popular-input", required=True)
    run_cmd.add_argument("--web-input", required=True)
    run_cmd.add_argument("--find-evidence-url", default="")
    run_cmd.add_argument("--popular-evidence-url", default="")
    run_cmd.add_argument("--min-methods", type=int, default=2)
    run_cmd.add_argument("--limit", type=int, default=8)
    run_cmd.add_argument("--min-project-keyword-hits", type=int, default=1)
    run_cmd.add_argument("--dry-run", action="store_true")
    run_cmd.add_argument("--no-yes", action="store_true")
    run_cmd.add_argument(
        "--allow-empty-sources",
        action="store_true",
        help="allow run completion when one or more source candidate lists are empty",
    )

    live_cmd = sub.add_parser(
        "collect-sources-live",
        help="collect find/popular/web source files automatically",
    )
    live_cmd.add_argument("--project-root", required=True)
    live_cmd.add_argument("--run-dir", required=True)
    live_cmd.add_argument("--find-query")
    live_cmd.add_argument("--web-query", action="append", default=[])
    live_cmd.add_argument("--find-command", default="npx --yes skills find")
    live_cmd.add_argument("--find-timeout-sec", type=int, default=45)
    live_cmd.add_argument("--find-evidence-url", default="")
    live_cmd.add_argument("--popular-url", default="https://skills.sh/")
    live_cmd.add_argument("--github-api-base", default="https://api.github.com")
    live_cmd.add_argument("--web-mode", choices=["github", "seed"], default="github")
    live_cmd.add_argument(
        "--web-fallback-mode",
        choices=["none", "find"],
        default="none",
        help="fallback mode when github web collection fails (default: none)",
    )
    live_cmd.add_argument("--web-seed-input")
    live_cmd.add_argument("--web-repo-limit", type=int, default=18)
    live_cmd.add_argument("--web-skill-limit-per-repo", type=int, default=6)
    live_cmd.add_argument("--timeout-sec", type=int, default=15)
    live_cmd.add_argument("--find-output")
    live_cmd.add_argument("--popular-output")
    live_cmd.add_argument("--web-output")
    live_cmd.add_argument("--allow-empty-sources", action="store_true")
    live_cmd.add_argument("--run-after-collect", action="store_true")
    live_cmd.add_argument("--min-methods", type=int, default=2)
    live_cmd.add_argument("--limit", type=int, default=8)
    live_cmd.add_argument("--min-project-keyword-hits", type=int, default=1)
    live_cmd.add_argument("--dry-run", action="store_true")
    live_cmd.add_argument("--no-yes", action="store_true")

    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])

    if args.subcommand == "analyze-project":
        analyze_project(Path(args.project_root), Path(args.out))
        return 0
    if args.subcommand == "collect-find":
        collect_find(Path(args.input), Path(args.out), args.evidence_url)
        return 0
    if args.subcommand == "collect-popular":
        collect_popular(Path(args.input), Path(args.out), args.evidence_url)
        return 0
    if args.subcommand == "collect-web":
        collect_web(Path(args.input), Path(args.out))
        return 0
    if args.subcommand == "merge-candidates":
        merge_candidates([Path(p) for p in args.inputs], Path(args.out))
        return 0
    if args.subcommand == "validate-content":
        return validate_content(Path(args.candidates), Path(args.out), strict=args.strict)
    if args.subcommand == "build-manifest":
        build_manifest(
            merged=Path(args.merged),
            content_report=Path(args.content_report),
            out=Path(args.out),
            project_profile=Path(args.project_profile) if args.project_profile else None,
            min_methods=max(args.min_methods, 1),
            limit=max(args.limit, 1),
            min_project_keyword_hits=max(args.min_project_keyword_hits, 0),
        )
        return 0
    if args.subcommand == "install-manifest":
        return install_manifest(
            manifest=Path(args.manifest),
            report=Path(args.report),
            dry_run=bool(args.dry_run),
            yes=not args.no_yes,
        )
    if args.subcommand == "run":
        return run_pipeline(args)
    if args.subcommand == "collect-sources-live":
        return collect_sources_live(args)
    raise RuntimeError(f"unknown subcommand: {args.subcommand}")


if __name__ == "__main__":
    raise SystemExit(main())
