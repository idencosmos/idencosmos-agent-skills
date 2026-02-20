# idencosmos-agent-skills

Public agent skills maintained by `idencosmos`.

## Install

```bash
npx skills add idencosmos/idencosmos-agent-skills --list
npx skills add idencosmos/idencosmos-agent-skills --skill <skill-name> -y
```

## Published Skills

- `skills-batch-ops`: 프로젝트 분석 + 3채널(find-skills/인기/웹) 후보 탐색 + 실제 `SKILL.md` 내용 검증 + 승인 항목 설치를 일괄 수행.
- `project-agent-factory`: 프로젝트 분석 후 공식 문서/사례 근거로 `agent_plan.tsv`를 설계하고, `.codex/config.toml` 및 `.codex/agents/*.toml`에 안전 적용/검증하며 `apply_report.md`, `scope_validation.md` 실행 증적을 남김.

## Maintainer Specs

- `docs/skills-batch-ops-spec.md`: `skills-batch-ops` 유지보수 상세 스펙.
- `docs/project-agent-factory-spec.md`: `project-agent-factory` 유지보수 상세 스펙.
- `docs/publishing-checklist.md`: 공개 배포 전 점검 체크리스트.
- `docs/naming-conventions.md`: 네이밍 규칙.
- `docs/readme-policy.md`: README 역할 분리/중복 방지 운영 규칙.

## Repository Layout

- `skills/<skill-name>/SKILL.md`: Each published skill.
- `skills/README.md`: Skills catalog with purpose/outputs/status.
- `docs/`: Maintainer specs and documentation policy.
- `.github/workflows/`: CI checks for skill docs and structure.

## Development

Run from repository root (`idencosmos-agent-skills`):

```bash
# list all skills available from this repo
npx skills add . --list

# test install one local skill
npx skills add . --skill <skill-name> -y

# validate metadata + markdown-only structure
python3 .github/scripts/validate_skill.py skills/<skill-name>
```
