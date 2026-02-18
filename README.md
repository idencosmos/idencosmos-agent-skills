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
- `project-agent-factory`: 프로젝트를 자동 탐색해 Codex 멀티 에이전트 구성을 제안하고, 프로젝트 내부 `.codex/config.toml` 및 `.codex/agents/*.toml`을 안전하게 생성/갱신.

## Development

```bash
# list all skills available from this repo
npx skills add . --list

# test install one local skill
npx skills add . --skill <skill-name> -y
```
