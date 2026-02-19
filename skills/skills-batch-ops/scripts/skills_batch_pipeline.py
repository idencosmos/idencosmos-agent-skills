#!/usr/bin/env python3
"""Skills batch discovery/review/install pipeline for skills-batch-ops."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import re
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Iterable
from urllib.error import HTTPError, URLError
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
TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]{2,}")
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


def collect_find(input_path: Path, out: Path, evidence_url: str = "") -> None:
    text = input_path.read_text(encoding="utf-8", errors="ignore")
    best: dict[str, dict[str, object]] = {}

    for line in text.splitlines():
        line = line.strip()
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
            prev = best.get(skill_ref)
            if prev is None or installs > int(prev["installs"]):
                best[skill_ref] = {
                    "source_method": "find",
                    "source_rank": 0,
                    "skill_ref": skill_ref,
                    "repo": repo,
                    "skill": skill,
                    "installs": installs,
                    "evidence_url": evidence_url,
                    "evidence_note": sanitize(line)[:180],
                }

    rows = sorted(best.values(), key=lambda item: (int(item["installs"]), item["skill_ref"]), reverse=True)
    for idx, row in enumerate(rows, start=1):
        row["source_rank"] = idx
    write_tsv(out, CANDIDATE_HEADER, rows)


def collect_popular(input_path: Path, out: Path, evidence_url: str = "") -> None:
    text = input_path.read_text(encoding="utf-8", errors="ignore")
    candidates: dict[str, dict[str, object]] = {}

    for pattern in POPULAR_PATTERNS:
        for match in pattern.finditer(text):
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


def parse_frontmatter(text: str) -> tuple[str, str] | None:
    match = FRONTMATTER_RE.match(text)
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
    return name, description


def candidate_skill_md_urls(repo: str, skill: str) -> list[str]:
    return [
        f"https://raw.githubusercontent.com/{repo}/main/skills/{skill}/SKILL.md",
        f"https://raw.githubusercontent.com/{repo}/master/skills/{skill}/SKILL.md",
        f"https://raw.githubusercontent.com/{repo}/main/{skill}/SKILL.md",
        f"https://raw.githubusercontent.com/{repo}/master/{skill}/SKILL.md",
    ]


def fetch_text(url: str, timeout_sec: int = 10) -> str:
    req = Request(url=url, headers={"User-Agent": "skills-batch-ops/1.0"})
    with urlopen(req, timeout=timeout_sec) as resp:
        return resp.read().decode("utf-8", errors="replace")


def validate_content(candidates: Path, out: Path, strict: bool) -> int:
    rows = read_table(candidates)
    output: list[dict[str, object]] = []
    failed = 0

    seen: set[str] = set()
    for skill_ref, repo, skill in iter_skill_refs(rows):
        if skill_ref in seen:
            continue
        seen.add(skill_ref)
        status = "failed"
        content_checked = "false"
        source_url = ""
        fm_name = ""
        fm_description = ""
        reason = "skill_md_not_found"

        for url in candidate_skill_md_urls(repo, skill):
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

            parsed = parse_frontmatter(text)
            if parsed is None:
                source_url = url
                content_checked = "true"
                reason = "missing_frontmatter"
                continue

            fm_name, fm_description = parsed
            source_url = url
            content_checked = "true"
            if fm_name != skill:
                reason = "frontmatter_name_mismatch"
                continue
            if not fm_description.strip():
                reason = "missing_frontmatter_description"
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


def build_manifest(
    merged: Path,
    content_report: Path,
    out: Path,
    project_profile: Path | None,
    min_methods: int,
    limit: int,
) -> None:
    merged_rows = read_table(merged)
    content_rows = read_table(content_report)
    content_map = {row.get("skill_ref", ""): row for row in content_rows}
    project_keywords = load_project_keywords(project_profile)

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
        keyword_match = "true" if project_keywords.intersection(skill_tokens) else "false"
        score = method_count * 100 + min(installs_max, 500_000) // 5_000 + (20 if keyword_match == "true" else 0)

        if content_status != "passed":
            manifest_status = "rejected"
            decision = "reject"
            rationale = "SKILL.md content verification failed"
        elif method_count >= min_methods:
            manifest_status = "approved"
            decision = "approve"
            rationale = f"content verified and discovered by {method_count} methods"
        else:
            manifest_status = "pending"
            decision = "hold"
            rationale = f"content verified but discovery coverage is below min_methods={min_methods}"

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
                cmd = ["npx", "skills", "add", repo, "--skill", skill]
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
    )

    install_rc = install_manifest(manifest_out, install_out, dry_run=args.dry_run, yes=not args.no_yes)
    print(f"run_dir: {run_dir}")
    print(f"project_profile: {project_profile}")
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
    run_cmd.add_argument("--dry-run", action="store_true")
    run_cmd.add_argument("--no-yes", action="store_true")

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
    raise RuntimeError(f"unknown subcommand: {args.subcommand}")


if __name__ == "__main__":
    raise SystemExit(main())
