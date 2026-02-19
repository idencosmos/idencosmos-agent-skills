# Changelog

All notable changes to this repository will be documented in this file.

## [Unreleased]

- Add first public skill: `skills-batch-ops`.
- Initial repository scaffold.
- Harden `skills-batch-ops` proof logic with `expected_stage` mismatch detection.
- Prevent `run` from re-ingesting `.agents/skills-batch-ops/runs` artifacts.
- Update `skills-batch-ops` docs for install-path and repo-path compatible execution.
- Add CI frontmatter/name validation and `npx skills` install smoke tests.
- Rebuild `skills-batch-ops` as a multi-source discovery/review/install pipeline (`skills_batch_pipeline.py`) with mandatory `SKILL.md` content verification before approval/install.
- Add offline regression tests for `skills_batch_pipeline.py` (`tests/test_skills_batch_pipeline.sh`).
- Convert `skills-batch-ops` to a markdown-only playbook (`SKILL.md` + `references/*.md`) and remove bundled `scripts/` and `tests/` from the skill package.
