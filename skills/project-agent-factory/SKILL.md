---
name: project-agent-factory
description: 프로젝트를 자동 탐색해 Codex 멀티 에이전트 구성을 제안하고, 현재 프로젝트 내부 .codex/config.toml 및 .codex/agents/*.toml을 안전하게 생성/갱신합니다. 프로젝트 맞춤 에이전트를 빠르게 초기 구성하거나 재생성해야 할 때 사용합니다.
---

# Project Agent Factory

프로젝트별 에이전트를 "추측"이 아니라 실제 파일 신호를 기반으로 구성합니다.
현재 권장 방식은 **AI가 계획(roles/instructions/model)을 만들고**, 스크립트는 **적용/검증/감사**만 수행하는 것입니다.

핵심 가드레일:
- 생성/갱신 경로를 `<project-root>/.codex/` 하위로 강제
- 실행 로그/산출물을 `<project-root>/.agents/project-agent-factory/runs/<timestamp>/`에 기록
- 기존 `.codex/config.toml` 전체를 덮어쓰지 않고 관리 블록만 갱신

## Quick Start

```bash
PAF_SCRIPT="$HOME/.agents/skills/project-agent-factory/scripts/agent_factory.sh"
bash "$PAF_SCRIPT" run \
  --project-root "$(pwd)"
```

소스 저장소에서 직접 테스트할 때는 아래 경로를 사용합니다.

```bash
bash idencosmos-agent-skills/skills/project-agent-factory/scripts/agent_factory.sh run \
  --project-root "$(pwd)"
```

권장 파이프라인:
1. AI가 프로젝트를 탐색해 `agent_plan.tsv` 작성
2. `apply-plan`: 계획 적용 (`render-config` + `validate-scope` + `audit`)

레거시 파이프라인(호환용):
1. `scan-project`: 언어/프레임워크/테스트/운영 신호 수집
2. `plan-agents`: 기본 규칙 기반 계획 생성
3. `render-config`
4. `validate-scope`
5. `audit`

## Commands

### AI-First Run (Recommended)

```bash
PAF_SCRIPT="$HOME/.agents/skills/project-agent-factory/scripts/agent_factory.sh"
bash "$PAF_SCRIPT" apply-plan \
  --project-root "$(pwd)" \
  --plan .agents/project-agent-factory/runs/<ts>/agent_plan.tsv \
  --out-dir .agents/project-agent-factory/runs/<ts>
```

`agent_plan.tsv` 권장 헤더:

```tsv
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
```

- 최소 필수 컬럼: `agent_id`, `role_name`, `priority`, `reason`, `config_relpath`
- AI 품질 향상을 위해 권장 컬럼: `description`, `developer_instructions`, `model`, `model_reasoning_effort`, `sandbox_mode`

### Legacy Stage Run

```bash
# 1) Scan
bash "$PAF_SCRIPT" scan-project \
  --project-root "$(pwd)" \
  --out .agents/project-agent-factory/runs/<ts>/project_profile.tsv

# 2) Plan
bash "$PAF_SCRIPT" plan-agents \
  --profile .agents/project-agent-factory/runs/<ts>/project_profile.tsv \
  --out .agents/project-agent-factory/runs/<ts>/agent_plan.tsv \
  --max-agents 6

# 3) Render
bash "$PAF_SCRIPT" render-config \
  --project-root "$(pwd)" \
  --plan .agents/project-agent-factory/runs/<ts>/agent_plan.tsv \
  --report .agents/project-agent-factory/runs/<ts>/apply_report.tsv

# 4) Scope validation
bash "$PAF_SCRIPT" validate-scope \
  --project-root "$(pwd)" \
  --report .agents/project-agent-factory/runs/<ts>/apply_report.tsv \
  --out .agents/project-agent-factory/runs/<ts>/scope_validation.tsv
```

## Outputs

- `project_profile.tsv`: (선택) 프로젝트 탐색 결과(언어/프레임워크/신호)
- `agent_plan.tsv`: AI 또는 레거시 규칙으로 생성한 계획
- `apply_report.tsv`: 실제 파일 생성/갱신 결과
- `scope_validation.tsv`: 프로젝트 경로 제한 검증 결과
- `audit.tsv`: 실행 요약

## Role Selection Rules

- 항상 포함: `paf_explorer`, `paf_implementer`
- 조건부 포함:
  - 백엔드 신호가 있으면 `paf_backend`
  - 프론트엔드 신호가 있으면 `paf_frontend`
  - 테스트 신호 또는 코드량이 많으면 `paf_qa`
  - Docker/K8s/Terraform 신호가 있으면 `paf_ops`
- `--max-agents` 상한을 넘으면 우선순위 높은 순서로 절단

위 규칙은 레거시 `plan-agents` 커맨드의 기본 동작입니다. AI-first 모드에서는 프로젝트 맥락에 따라 더 세밀한 계획을 생성할 수 있습니다.

## References

- 멀티 에이전트 설정 근거 및 필드 요약: `references/codex-multi-agent-notes.md`
- 역할별 지침 패턴: `references/agent-role-patterns.md`
