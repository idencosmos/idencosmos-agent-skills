#!/usr/bin/env python3
"""Validate SKILL.md metadata for all skill directories."""

from __future__ import annotations

import re
import sys
from pathlib import Path


FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n?", re.DOTALL)
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
ALLOWED_KEYS = {"name", "description", "license", "allowed-tools", "metadata", "compatibility"}
PRIMARY_SKILL_MD = "SKILL.md"
LEGACY_SKILL_MD = "SKILLS.md"


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


def validate_skill_dir(skill_dir: Path) -> list[str]:
    errors: list[str] = []
    skill_md, resolve_errors = resolve_skill_markdown(skill_dir)
    if resolve_errors:
        return resolve_errors
    if skill_md is None:
        return [f"{skill_dir}: missing {PRIMARY_SKILL_MD}"]

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


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_skill.py <skills-root>", file=sys.stderr)
        return 1

    root = Path(sys.argv[1]).resolve()
    if not root.exists():
        print(f"error: path not found: {root}", file=sys.stderr)
        return 1

    failures: list[str] = []
    skill_dirs = sorted(d for d in root.iterdir() if d.is_dir() and has_skill_markdown(d))
    if not skill_dirs:
        print("error: no skill directories found", file=sys.stderr)
        return 1

    for skill_dir in skill_dirs:
        failures.extend(validate_skill_dir(skill_dir))

    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1

    for skill_dir in skill_dirs:
        print(f"ok: {skill_dir.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
