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

- `skills-batch-ops`: 외부 AI 오케스트레이터가 만든 후보/리뷰 결과에 대해 병렬 실행 증거와 설치 안전 게이트를 강제 검증하고, `approved + gate_pass` 항목만 설치.
- `project-agent-factory`: AI가 생성한 `agent_plan.tsv`를 검증하고, 프로젝트 내부 `.codex/config.toml` 및 `.codex/agents/*.toml`에 안전 적용/검증하며 `apply_report.tsv`, `scope_validation.tsv` 실행 증적을 남김.

## Development

```bash
# list all skills available from this repo
npx skills add . --list

# test install one local skill
npx skills add . --skill <skill-name> -y
```
