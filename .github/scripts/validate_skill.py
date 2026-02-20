#!/usr/bin/env python3
"""Validate skill metadata and markdown-only structure rules."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n?", re.DOTALL)
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
ALLOWED_KEYS = {"name", "description", "license", "allowed-tools", "metadata", "compatibility"}
PRIMARY_SKILL_MD = "SKILL.md"
LEGACY_SKILL_MD = "SKILLS.md"
ALLOWED_TOP_LEVEL_DIRS = {"references"}
ALLOWED_TOP_LEVEL_FILES = {PRIMARY_SKILL_MD, LEGACY_SKILL_MD}
IGNORED_NAMES = {".DS_Store", "__pycache__", ".pytest_cache"}


def has_skill_markdown(skill_dir: Path) -> bool:
    return (skill_dir / PRIMARY_SKILL_MD).exists() or (skill_dir / LEGACY_SKILL_MD).exists()


def resolve_skill_markdown(skill_dir: Path) -> tuple[Path | None, list[str]]:
    primary = skill_dir / PRIMARY_SKILL_MD
    legacy = skill_dir / LEGACY_SKILL_MD

    if primary.exists() and legacy.exists():
        return None, [f"{skill_dir}: both {PRIMARY_SKILL_MD} and {LEGACY_SKILL_MD} exist; keep only {PRIMARY_SKILL_MD}"]
    if primary.exists():
        return primary, []
    if legacy.exists():
        return legacy, []
    return None, [f"{skill_dir}: missing {PRIMARY_SKILL_MD}"]


def parse_frontmatter(text: str) -> dict[str, str]:
    match = FRONTMATTER_RE.match(text)
    if not match:
        raise ValueError("No valid frontmatter block found at top of skill markdown")

    data: dict[str, str] = {}
    for raw_line in match.group(1).splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if ":" not in line:
            raise ValueError(f"Invalid frontmatter line: {raw_line}")
        key, value = line.split(":", 1)
        data[key.strip()] = value.strip().strip("'\"")
    return data


def validate_references_dir(references_dir: Path, skill_dir: Path) -> list[str]:
    errors: list[str] = []
    for entry in sorted(references_dir.rglob("*")):
        rel = entry.relative_to(skill_dir)
        if entry.name in IGNORED_NAMES:
            continue
        if entry.is_dir():
            errors.append(f"{skill_dir}: nested directory not allowed in references/: {rel}")
            continue
        if entry.suffix.lower() != ".md":
            errors.append(f"{skill_dir}: non-markdown reference file is not allowed: {rel}")
    return errors


def validate_skill_structure(skill_dir: Path) -> list[str]:
    errors: list[str] = []

    for child in sorted(skill_dir.iterdir()):
        if child.name in IGNORED_NAMES:
            continue
        rel = child.relative_to(skill_dir)

        if child.is_file():
            if child.name not in ALLOWED_TOP_LEVEL_FILES:
                errors.append(
                    f"{skill_dir}: unexpected top-level file {rel} "
                    f"(allowed: {', '.join(sorted(ALLOWED_TOP_LEVEL_FILES))})"
                )
            continue

        if child.is_dir():
            if child.name not in ALLOWED_TOP_LEVEL_DIRS:
                errors.append(
                    f"{skill_dir}: unexpected top-level directory {rel} "
                    f"(allowed: {', '.join(sorted(ALLOWED_TOP_LEVEL_DIRS))})"
                )
                continue
            if child.name == "references":
                errors.extend(validate_references_dir(child, skill_dir))
            continue

        errors.append(f"{skill_dir}: unsupported path type at {rel}")

    return errors


def validate_skill_dir(skill_dir: Path) -> list[str]:
    errors: list[str] = []
    skill_md, resolve_errors = resolve_skill_markdown(skill_dir)
    if resolve_errors:
        return resolve_errors
    if skill_md is None:
        return [f"{skill_dir}: missing {PRIMARY_SKILL_MD}"]

    errors.extend(validate_skill_structure(skill_dir))

    text = skill_md.read_text(encoding="utf-8")
    try:
        frontmatter = parse_frontmatter(text)
    except ValueError as exc:
        return [f"{skill_md}: {exc}"]

    unknown = sorted(set(frontmatter) - ALLOWED_KEYS)
    if unknown:
        errors.append(f"{skill_md}: unexpected frontmatter key(s): {', '.join(unknown)}")

    name = frontmatter.get("name", "").strip()
    description = frontmatter.get("description", "").strip()
    if not name:
        errors.append(f"{skill_md}: missing 'name' field")
    elif not NAME_RE.fullmatch(name):
        errors.append(f"{skill_md}: name '{name}' must be kebab-case")
    elif name != skill_dir.name:
        errors.append(f"{skill_md}: name '{name}' must match directory '{skill_dir.name}'")

    if not description:
        errors.append(f"{skill_md}: missing 'description' field")
    elif "TODO" in description.upper():
        errors.append(f"{skill_md}: description still contains TODO placeholder")
    elif len(description) > 1024:
        errors.append(f"{skill_md}: description too long ({len(description)} > 1024)")

    body = FRONTMATTER_RE.sub("", text, count=1).strip()
    if not body:
        errors.append(f"{skill_md}: body is empty")

    return errors


def expand_targets(paths: list[Path]) -> list[Path]:
    targets: list[Path] = []
    seen: set[Path] = set()

    for path in paths:
        resolved = path.expanduser().resolve()
        if not resolved.exists():
            if resolved not in seen:
                targets.append(resolved)
                seen.add(resolved)
            continue

        if resolved.is_dir() and has_skill_markdown(resolved):
            if resolved not in seen:
                targets.append(resolved)
                seen.add(resolved)
            continue

        if resolved.is_dir():
            for child in sorted(resolved.iterdir()):
                if child.is_dir() and has_skill_markdown(child) and child not in seen:
                    targets.append(child)
                    seen.add(child)
            continue

        if resolved.is_file() and resolved.name in {PRIMARY_SKILL_MD, LEGACY_SKILL_MD}:
            parent = resolved.parent
            if parent not in seen:
                targets.append(parent)
                seen.add(parent)
            continue

        if resolved not in seen:
            targets.append(resolved)
            seen.add(resolved)

    return targets


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate one or more skill directories (metadata + markdown-only structure)."
    )
    parser.add_argument(
        "paths",
        nargs="+",
        help="Skill directory path(s), SKILL.md path(s), or a parent directory containing skill directories",
    )
    args = parser.parse_args()

    targets = expand_targets([Path(p) for p in args.paths])
    if not targets:
        print("error: no skill directories found", file=sys.stderr)
        return 1

    failures: list[str] = []
    valid_targets: list[Path] = []
    for target in targets:
        if not target.exists():
            failures.append(f"{target}: path does not exist")
            continue
        if not target.is_dir():
            failures.append(f"{target}: path is not a directory")
            continue
        if not has_skill_markdown(target):
            failures.append(f"{target}: missing {PRIMARY_SKILL_MD}")
            continue

        valid_targets.append(target)
        failures.extend(validate_skill_dir(target))

    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1

    for target in valid_targets:
        print(f"ok: {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
