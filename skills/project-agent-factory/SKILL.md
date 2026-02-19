---
name: project-agent-factory
description: AI가 생성한 agent_plan.tsv를 검증하고, 프로젝트 내부 .codex/config.toml 및 .codex/agents/*.toml에 안전하게 적용/검증/감사합니다. 멀티 에이전트 계획을 이미 갖고 있거나 LLM이 역할/지침/모델을 설계한 뒤 파일 반영 단계가 필요할 때 사용합니다.
---

# Project Agent Factory

`project-agent-factory`는 **AI가 만든 계획을 안전하게 적용하는 엔진**입니다.
역할 선정, 설명문 작성, 지시문 생성은 스크립트가 아니라 AI가 담당합니다.

핵심 가드레일:
- 생성/갱신 경로를 `<project-root>/.codex/` 하위로 강제
- 실행 산출물을 `<project-root>/.agents/project-agent-factory/runs/<timestamp>/`에 기록
- 기존 `.codex/config.toml` 전체를 덮어쓰지 않고 관리 블록만 갱신
- `agent_plan.tsv` 스키마를 엄격 검증(필수 컬럼/빈 값/중복/허용값)

## Quick Start

```bash
PAF_SCRIPT="$HOME/.agents/skills/project-agent-factory/scripts/agent_factory.sh"
RUN_DIR=".agents/project-agent-factory/runs/$(date -u +%Y%m%d_%H%M%S)"

mkdir -p "$RUN_DIR"

# 1) AI가 작성한 계획 저장
cat > "$RUN_DIR/agent_plan.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
paf_explorer	Project Explorer	10	context mapping	agents/paf_explorer.toml	Explore repo structure and constraints.	Map architecture with evidence-first notes.	gpt-5	medium	workspace-write
paf_implementer	Project Implementer	20	delivery	agents/paf_implementer.toml	Implement scoped changes with verification.	Apply requested edits and run available checks.	gpt-5	medium	workspace-write
TSV

# 2) 계획 검증(선택 권장)
bash "$PAF_SCRIPT" validate-plan --plan "$RUN_DIR/agent_plan.tsv"

# 3) 계획 적용 + 스코프 검증 + 감사
bash "$PAF_SCRIPT" apply-plan \
  --project-root "$(pwd)" \
  --plan "$RUN_DIR/agent_plan.tsv" \
  --out-dir "$RUN_DIR"
```

## Commands

### apply-plan

```bash
bash "$PAF_SCRIPT" apply-plan \
  --project-root "$(pwd)" \
  --plan <agent_plan.tsv> \
  --out-dir <run-dir>
```

내부적으로 `render-config` + `validate-scope` + `audit`를 순서대로 실행합니다.

### render-config

```bash
bash "$PAF_SCRIPT" render-config \
  --project-root "$(pwd)" \
  --plan <agent_plan.tsv> \
  --report <apply_report.tsv>
```

### validate-plan

```bash
bash "$PAF_SCRIPT" validate-plan --plan <agent_plan.tsv>
```

### validate-scope

```bash
bash "$PAF_SCRIPT" validate-scope \
  --project-root "$(pwd)" \
  --report <apply_report.tsv> \
  --out <scope_validation.tsv>
```

### audit

```bash
bash "$PAF_SCRIPT" audit \
  --profile <project_profile.tsv> \
  --plan <agent_plan.tsv> \
  --report <apply_report.tsv> \
  --out <audit.tsv>
```

## Plan Contract (Required Header)

```tsv
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
```

필수 규칙:
- 모든 컬럼 값은 비어 있으면 안 됩니다.
- `agent_id`와 `config_relpath`는 중복되면 안 됩니다.
- `config_relpath`는 `agents/*.toml`만 허용됩니다.
- `model_reasoning_effort`: `low|medium|high`
- `sandbox_mode`: `read-only|workspace-write|danger-full-access`

## Outputs

- `apply_report.tsv`: 실제 파일 생성/갱신/정리 결과
- `scope_validation.tsv`: 프로젝트 경로 제한 검증 결과
- `audit.tsv`: 실행 요약
- `project_profile.tsv`: `apply-plan`에서 `--profile` 미지정 시 `unknown` 값 기반 스텁 생성

## Migration Note

레거시 `run`, `scan-project`, `plan-agents`는 제거되었습니다.
이 스킬은 이제 AI 계획을 받아 안전 적용하는 단계만 담당합니다.

## References

- 멀티 에이전트 설정 근거 및 필드 요약: `references/codex-multi-agent-notes.md`
- 역할 설계 참고 패턴: `references/agent-role-patterns.md`
