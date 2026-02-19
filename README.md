# idencosmos-agent-skills

Public agent skills maintained by `idencosmos`.

## Install

```bash
npx skills add idencosmos/idencosmos-agent-skills --list
npx skills add idencosmos/idencosmos-agent-skills --skill <skill-name> -y
```

## Repository Layout

- `skills/<skill-name>/SKILL.md`: Each published skill.
- `.github/workflows/`: CI checks for skill docs and structure.

## Published Skills

- `skills-batch-ops`: 프로젝트 분석 + 3채널(find-skills/인기/웹) 후보 탐색 + 실제 `SKILL.md` 내용 검증 + 승인 항목 설치를 일괄 수행.
- `project-agent-factory`: 프로젝트 분석 후 공식 문서/사례 근거로 `agent_plan.tsv`를 설계하고, `.codex/config.toml` 및 `.codex/agents/*.toml`에 안전 적용/검증하며 `apply_report.tsv`, `scope_validation.tsv` 실행 증적을 남김.

## Development

```bash
# list all skills available from this repo
npx skills add . --list

# test install one local skill
npx skills add . --skill <skill-name> -y
```
