---
name: project-agent-factory
description: AI가 생성한 agent_plan.tsv를 엄격 검증한 뒤 프로젝트 내부 .codex/config.toml 및 .codex/agents/*.toml에 안전 적용하고 실행 증적(apply_report.tsv, scope_validation.tsv)을 남깁니다. 멀티 에이전트 계획이 이미 있거나 LLM이 역할/지침/모델 설계를 마친 뒤 반영 단계가 필요할 때 사용하고, 계획 생성/자동 탐색 용도로는 사용하지 않습니다.
---

# Project Agent Factory

`project-agent-factory`를 사용해 **AI가 만든 계획을 안전하게 적용하세요**.
역할 선정, 설명문 작성, 지시문 생성은 다른 단계에서 처리하고, 이 스킬은 적용/검증 단계에만 사용하세요.

핵심 가드레일을 유지하세요:
- 생성/갱신 경로를 `<project-root>/.codex/` 하위로 강제
- 실행 산출물을 `<project-root>/.agents/project-agent-factory/runs/<timestamp>/`에 기록
- 기존 `.codex/config.toml` 전체를 덮어쓰지 않고 관리 블록만 갱신
- `agent_plan.tsv` 스키마를 엄격 검증(필수 컬럼/빈 값/중복/허용값)
- 공개 CLI 표면을 최소화(`apply-plan` 단일 진입점)하여 우회 실행 경로를 축소

실행 위생 규칙을 지키세요:
- `--project-root`는 적용 대상 프로젝트 루트로 지정하고, 스킬 디렉토리 자체를 대상으로 사용하지 마세요.
- 실행으로 생성된 `.codex/` 및 `.agents/project-agent-factory/runs/` 산출물은 대상 프로젝트 산출물로 취급하고 스킬 원본에 포함하지 마세요.
- 계획 생성/자동 탐색이 필요하면 다른 스킬이나 별도 AI 단계를 먼저 실행한 뒤, 최종 `agent_plan.tsv`가 준비된 상태에서만 이 스킬을 실행하세요.

## Preflight

- 필수 명령이 있는지 먼저 확인하세요: `bash`, `awk`, `find`, `head`, `rg`, `sort`
- 아래처럼 `PAF_SCRIPT`를 먼저 해석한 뒤 실행하세요.

## Quick Start

```bash
PAF_SCRIPT="${PAF_SCRIPT:-$HOME/.agents/skills/project-agent-factory/scripts/agent_factory.sh}"
if [[ ! -x "$PAF_SCRIPT" && -x "$(pwd)/skills/project-agent-factory/scripts/agent_factory.sh" ]]; then
  PAF_SCRIPT="$(pwd)/skills/project-agent-factory/scripts/agent_factory.sh"
fi
if [[ ! -x "$PAF_SCRIPT" ]]; then
  echo "error: set PAF_SCRIPT to project-agent-factory/scripts/agent_factory.sh" >&2
  exit 1
fi

RUN_DIR=".agents/project-agent-factory/runs/$(date -u +%Y%m%d_%H%M%S)"

mkdir -p "$RUN_DIR"

# 1) AI가 작성한 계획 저장
cat > "$RUN_DIR/agent_plan.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
paf_explorer	Project Explorer	10	context mapping	agents/paf_explorer.toml	Explore repo structure and constraints.	Map architecture with evidence-first notes.	gpt-5	medium	workspace-write
paf_implementer	Project Implementer	20	delivery	agents/paf_implementer.toml	Implement scoped changes with verification.	Apply requested edits and run available checks.	gpt-5	medium	workspace-write
TSV

# 2) 계획 적용 + 스코프 검증(+스키마 자동 검증)
bash "$PAF_SCRIPT" apply-plan \
  --project-root "$(pwd)" \
  --plan "$RUN_DIR/agent_plan.tsv" \
  --out-dir "$RUN_DIR"

# 3) AI가 실행 결과를 요약/감사하도록 위 산출물(`apply_report.tsv`, `scope_validation.tsv`)을 읽어 해석
```

## Commands

### apply-plan

```bash
bash "$PAF_SCRIPT" apply-plan \
  --project-root "$(pwd)" \
  --plan <agent_plan.tsv> \
  --out-dir <run-dir>
```

`<run-dir>`는 프로젝트 루트 하위 경로만 허용됩니다.
내부적으로 스키마 검증 + 파일 반영 + 스코프 검증을 순서대로 자동 실행합니다.

## Plan Contract (Required Header)

```tsv
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
```

필수 규칙:
- 모든 컬럼 값은 비어 있으면 안 됩니다.
- `agent_id`와 `config_relpath`는 중복되면 안 됩니다.
- `priority`는 정수이며 `1` 이상이어야 합니다.
- `config_relpath`는 `agents/*.toml`만 허용됩니다.
- `config_relpath`는 하위 디렉터리를 허용하지 않습니다(예: `agents/paf_explorer.toml` 허용, `agents/backend/paf_explorer.toml` 금지).
- `agent_id`는 영문/숫자/`._-`만 허용됩니다.
- `model_reasoning_effort`: `low|medium|high`
- `sandbox_mode`: `read-only|workspace-write|danger-full-access`
- 헤더 외 추가 컬럼은 허용되지 않습니다.

## Outputs

- `apply_report.tsv`: 실제 파일 생성/갱신/정리 결과
- `scope_validation.tsv`: 프로젝트 경로 제한 검증 결과
- 위 두 파일을 근거로 AI 요약/감사 텍스트를 생성하세요.

## Smoke Test

필요할 때 아래 테스트를 실행해 `apply-plan` 계약(스키마/경로/레거시 커맨드 비노출)이 유지되는지 확인하세요.

```bash
bash "$HOME/.agents/skills/project-agent-factory/tests/test_agent_factory.sh"
```

## Migration Note

레거시 `run`, `scan-project`, `plan-agents`를 사용하지 마세요.
`validate-plan`, `render-config`, `validate-scope`, `audit` 공개 커맨드를 사용하지 마세요.
항상 `apply-plan` 단일 진입점만 사용해 AI 계획 적용 단계에 집중하세요.

## References

- 멀티 에이전트 필드 정의를 확인할 때 `references/codex-multi-agent-notes.md`를 읽으세요.
- AI가 만든 계획의 역할 우선순위/구성 타당성을 점검할 때 `references/agent-role-patterns.md`를 읽으세요.
