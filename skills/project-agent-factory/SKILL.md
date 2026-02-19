---
name: project-agent-factory
description: 프로젝트에 필요한 Codex 멀티 에이전트를 설계/생성해야 할 때 사용합니다. 프로젝트 분석 후 공식 문서와 GitHub/인터넷 사례를 근거로 agent_plan.tsv를 작성하고, apply-plan으로 .codex/config.toml 및 .codex/agents/*.toml에 안전 적용하며 apply_report.tsv/scope_validation.tsv 실행 증적을 남깁니다.
---

# Project Agent Factory

`project-agent-factory`로 프로젝트에 필요한 멀티 에이전트를 **분석 → 설계 → 반영** 순서로 처리하세요.

책임 경계를 분리하세요:
- 계획 생성 단계(분석/소스 검증/`agent_plan.tsv` 작성)는 AI 워크플로로 수행합니다.
- 반영 단계(`.codex/config.toml`, `.codex/agents/*.toml` 쓰기/정리/검증)는 `apply-plan` 스크립트로 수행합니다.

고정 파이프라인:
1. 프로젝트 분석 (`project_profile.md`)
2. 공식/사례 검증 (`source_review.tsv`)
3. 멀티 에이전트 계획 생성 (`agent_plan.tsv`)
4. 계획 반영 (`apply-plan`)
5. 결과 감사 (`apply_report.tsv`, `scope_validation.tsv`)

핵심 계약:
- `references/codex-multi-agent-notes.md`로 공식 스펙을 먼저 확인하세요.
- GitHub 사례 + 인터넷 사례를 최소 1개씩 수집해 `source_review.tsv`에 남기세요.
- `agent_plan.tsv` 각 행의 `reason`에는 프로젝트 근거와 소스 ID를 함께 적으세요.
- 반영 단계는 항상 `apply-plan` 단일 커맨드로 실행하세요.
- 생성/갱신 경로를 `<project-root>/.codex/` 하위로 강제하세요.
- 실행 산출물은 `<project-root>/.agents/project-agent-factory/runs/<timestamp>/`에 기록하세요.
- 기존 `.codex/config.toml`은 전체 덮어쓰지 말고 관리 블록만 갱신하세요.
- `config_file` 경로는 `.codex/config.toml` 기준 상대경로(`agents/*.toml`)로 유지하세요.

## Preflight

- 필수 명령이 있는지 먼저 확인하세요: `bash`, `awk`, `cmp`, `find`, `head`, `rg`, `sort`
- 아래처럼 `PAF_SCRIPT`를 먼저 해석하세요.

```bash
PAF_SCRIPT="${PAF_SCRIPT:-$HOME/.agents/skills/project-agent-factory/scripts/agent_factory.sh}"
if [[ ! -x "$PAF_SCRIPT" && -x "$(pwd)/skills/project-agent-factory/scripts/agent_factory.sh" ]]; then
  PAF_SCRIPT="$(pwd)/skills/project-agent-factory/scripts/agent_factory.sh"
fi
if [[ ! -x "$PAF_SCRIPT" && -x "$(pwd)/idencosmos-agent-skills/skills/project-agent-factory/scripts/agent_factory.sh" ]]; then
  PAF_SCRIPT="$(pwd)/idencosmos-agent-skills/skills/project-agent-factory/scripts/agent_factory.sh"
fi
if [[ ! -x "$PAF_SCRIPT" ]]; then
  echo "error: set PAF_SCRIPT to project-agent-factory/scripts/agent_factory.sh" >&2
  exit 1
fi
```

## Step 1) 프로젝트 분석

프로젝트 구조/스택/테스트/운영 신호를 먼저 수집하세요.

```bash
RUN_DIR=".agents/project-agent-factory/runs/$(date -u +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_DIR"

{
  echo "# Project Profile"
  echo "generated_at_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## Stack Signals"
  rg --files -g 'package.json' -g 'pnpm-workspace.yaml' -g 'pyproject.toml' -g 'requirements*.txt' -g 'go.mod' -g 'Cargo.toml' . || true
  echo
  echo "## Runtime and Ops Signals"
  rg --files -g 'Dockerfile*' -g 'docker-compose*.yml' -g '.github/workflows/*.yml' -g 'terraform*.tf' . || true
  echo
  echo "## Test Signals"
  rg --files -g '*test*' -g '*spec*' . || true
} > "$RUN_DIR/project_profile.md"
```

분석 후 `references/agent-role-patterns.md`를 읽고 역할 후보를 추립니다.

## Step 2) 공식 문서 + GitHub/인터넷 사례 검증

먼저 `references/codex-multi-agent-notes.md`와 `references/multi-agent-case-sources.md`를 읽으세요.
그리고 `source_review.tsv`를 생성하세요.

```bash
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$RUN_DIR/source_review.tsv" <<TSV
source_id	source_type	url	checked_at_utc	relevance_note	key_constraints
official-1	official	https://developers.openai.com/codex/multi-agent	$NOW_UTC	multi_agent 활성화와 agent 설정 키 확인	experimental 기능/버전 차이 확인 필요
github-1	github	https://github.com/openai/codex/pull/8783	$NOW_UTC	agent control 명령 기반 오케스트레이션 구현 사례 확인	experimental 플래그와 권한/스코프 관리 필요
web-1	web	https://cookbook.openai.com/examples/agents_sdk/parallel_agents	$NOW_UTC	병렬 에이전트 분해 패턴을 역할 설계에 참고	샘플 코드 참고용(일부 레거시/비프로덕션 경고)이며 Codex 설정 키는 공식 문서로 재검증
TSV
```

`source_type=official|github|web` 3종류를 모두 포함하세요.
`source_type=web`는 GitHub 외 도메인 URL만 사용하세요.
`source_type=github`는 GitHub URL만 사용하세요.
네트워크가 막히면 `relevance_note`에 `blocked`를 명시하고 부분 검증으로 보고하세요.

## Step 3) 멀티 에이전트 계획 생성 (`agent_plan.tsv`)

필수 헤더:

```tsv
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
```

필수 규칙:
- 모든 컬럼 값은 비어 있으면 안 됩니다.
- `agent_id`와 `config_relpath`는 중복되면 안 됩니다.
- `priority`는 정수이며 `1` 이상이어야 합니다.
- `config_relpath`는 `agents/*.toml`만 허용됩니다.
- `config_relpath`는 하위 디렉터리를 허용하지 않습니다(예: `agents/paf_explorer.toml` 허용, `agents/backend/paf_explorer.toml` 금지).
- 공식 Codex 스펙은 `config_file`에 일반 상대경로를 허용하지만, 이 스킬은 경로 안전성과 정리 자동화를 위해 `agents/*.toml` 단일 깊이로 제한합니다.
- `agent_id`는 영문/숫자/`._-`만 허용됩니다.
- `model_reasoning_effort`: `minimal|low|medium|high|xhigh` (`xhigh`는 deprecated이므로 신규 계획은 `high` 우선)
- `sandbox_mode`: `read-only|workspace-write|danger-full-access`
- 헤더 외 추가 컬럼은 허용되지 않습니다.
- `agent_id`에 `.`이 포함돼도 `.codex/config.toml`에는 `[agents."<agent_id>"]`로 안전하게 기록되어 TOML 중첩 테이블 충돌을 피합니다.
- `reason`에는 `project_profile.md` 근거 + `source_review.tsv`의 `source_id`(`official-<n>|github-<n>|web-<n>`)를 포함하세요. `apply-plan`에서 형식을 검증합니다.

반영 전에 `source_review.tsv` 최소 기준을 점검하세요.

```bash
awk -F'\t' '
NR == 1 { next }
{ seen[$2] = 1 }
END {
  if (!seen["official"] || !seen["github"] || !seen["web"]) {
    print "error: source_review.tsv must include official/github/web rows" > "/dev/stderr"
    exit 1
  }
}
' "$RUN_DIR/source_review.tsv"
```

샘플:

```tsv
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
paf_explorer	Project Explorer	10	stack-map(package+tests), source=official-1 web-1	agents/paf_explorer.toml	Explore repo structure and constraints.	Map architecture with evidence-first notes.	gpt-5	medium	workspace-write
paf_implementer	Project Implementer	20	delivery-path(api+ui), source=github-1 official-1	agents/paf_implementer.toml	Implement scoped changes with verification.	Apply requested edits and run available checks.	gpt-5	high	workspace-write
```

레거시 `prompt` 헤더도 하위 호환으로 허용되지만, 신규 계획은 `developer_instructions` 헤더를 사용하세요.

## Step 4) 계획 반영 (`apply-plan`)

```bash
bash "$PAF_SCRIPT" apply-plan \
  --project-root "$(pwd)" \
  --plan "$RUN_DIR/agent_plan.tsv" \
  --out-dir "$RUN_DIR"
```

`<run-dir>`는 프로젝트 루트 하위 경로만 허용됩니다.
내부적으로 스키마 검증 + 파일 반영 + 스코프 검증을 순서대로 자동 실행합니다.

## Step 5) 실행 결과 감사

- `apply_report.tsv`: 실제 파일 생성/갱신/정리 결과(`enable_multi_agent_feature` 포함)
- `scope_validation.tsv`: 프로젝트 경로 제한 검증 결과
- 아래 템플릿으로 결과를 보고하고, 부분 검증 항목을 분리하세요.

```markdown
# Multi-Agent Factory Audit
generated_at_utc: <YYYY-MM-DDTHH:MM:SSZ>
run_dir: <path>

## 1) Project Analysis Summary
- stack/runtime/test 신호 요약

## 2) Source Verification Summary
- official/github/web 각 1개 이상 여부
- blocked 항목 여부

## 3) Planned Agents
- agent_id, priority, reason(source_id 포함) 요약

## 4) Apply Results
- apply_report.tsv 주요 변경
- scope_validation.tsv 실패 여부

## 5) Open Risks
- 네트워크 차단, 미검증 테스트, 버전 호환성 등
```

## Commands

### apply-plan

```bash
bash "$PAF_SCRIPT" apply-plan \
  --project-root "$(pwd)" \
  --plan <agent_plan.tsv> \
  --out-dir <run-dir>
```

## Smoke Test

필요할 때 아래 테스트를 실행해 `apply-plan` 계약(스키마/경로/레거시 커맨드 비노출)이 유지되는지 확인하세요.

```bash
bash "$HOME/.agents/skills/project-agent-factory/tests/test_agent_factory.sh"
```

설치 전 로컬 저장소에서 검증할 때는 아래 경로를 사용할 수 있습니다.

```bash
bash "./idencosmos-agent-skills/skills/project-agent-factory/tests/test_agent_factory.sh"
```

## Migration Note

레거시 `run`, `scan-project`, `plan-agents` 공개 커맨드를 사용하지 마세요.
`validate-plan`, `render-config`, `validate-scope`, `audit` 공개 커맨드를 사용하지 마세요.
반영 단계는 항상 `apply-plan` 단일 진입점을 사용하세요.

## References

- 멀티 에이전트 필드 정의를 확인할 때 `references/codex-multi-agent-notes.md`를 읽으세요.
- AI가 만든 계획의 역할 우선순위/구성 타당성을 점검할 때 `references/agent-role-patterns.md`를 읽으세요.
- GitHub/인터넷 사례 수집 기준과 `source_review.tsv` 계약은 `references/multi-agent-case-sources.md`를 읽으세요.
