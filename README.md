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

- `skills-batch-ops`: 운영형 배치 워크플로우로 프로젝트 요구사항 분석, 다중 채널(Find/Top/GitHub/Web) 후보 수집, 리뷰 매니페스트 승인 게이트, 승인 기반 설치, 감사 로그까지 일괄 수행.

## Development

```bash
# list all skills available from this repo
npx skills add . --list

# test install one local skill
npx skills add . --skill <skill-name> -y
```
