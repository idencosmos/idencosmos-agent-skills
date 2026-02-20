---
name: project-agent-factory
description: 프로젝트에 필요한 Codex 멀티 에이전트를 설계/생성할 때 사용하는 순수 Markdown 지시형 스킬입니다. 프로젝트 분석 → 공식/사례 검증 → agent_plan.tsv 설계 → .codex 수동 반영 → 검증 보고까지를 SKILL.md와 references만으로 수행합니다.
---

# Project Agent Factory (Markdown-Only)

`project-agent-factory`는 프로젝트에 필요한 멀티 에이전트를 **분석 → 설계 → 반영 → 검증** 순서로 수행하는 순수 Markdown 지시형 스킬입니다.

핵심 원칙:
- 자동 적용 스크립트(`apply-plan` 등)를 사용하지 않습니다.
- 반영은 AI가 직접 `.codex/config.toml`, `.codex/agents/*.toml`을 편집해서 수행합니다.
- 모든 판단 근거는 실행 산출물(`project_profile.md`, `source_review.tsv`, `agent_plan.tsv`, `apply_report.md`)에 남깁니다.

고정 파이프라인:
1. 프로젝트 분석 (`project_profile.md`)
2. 공식/사례 검증 (`source_review.tsv`)
3. 멀티 에이전트 계획 생성 (`agent_plan.tsv`)
4. 계획 반영 (직접 파일 편집)
5. 결과 감사 (`apply_report.md`, `scope_validation.md`)

## Step 0) 프로젝트 루트 고정 + Run 디렉터리 준비

```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_ROOT"

RUN_DIR="$PROJECT_ROOT/.agents/project-agent-factory/runs/$(date -u +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_DIR" "$PROJECT_ROOT/.codex/agents"
echo "project_root=$PROJECT_ROOT"
```

이후 단계의 모든 상대경로는 `PROJECT_ROOT` 기준으로 해석합니다.

## Step 1) 프로젝트 분석 (`project_profile.md`)

프로젝트 구조/스택/테스트/운영 신호를 먼저 수집합니다.

```bash
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

## Step 2) 공식 문서 + GitHub/인터넷 사례 검증 (`source_review.tsv`)

먼저 아래 레퍼런스를 읽습니다.
- `references/codex-multi-agent-notes.md`
- `references/multi-agent-case-sources.md`

그 다음 실제 원문 링크를 열람하고 `source_review.tsv`를 작성합니다.

헤더:

```tsv
source_id	source_type	url	checked_at_utc	relevance_note	key_constraints
```

필수 규칙:
- `source_type=official|github|web` 3종류를 모두 포함합니다.
- `source_type=official`은 OpenAI 공식 도메인(`developers.openai.com`, `openai.com`)만 사용합니다.
- `source_type=github`는 GitHub URL만 사용합니다.
- `source_type=web`는 GitHub/OpenAI 공식 도메인을 제외한 공개 웹 URL만 사용합니다.
- `checked_at_utc`는 실제 확인 시각(`YYYY-MM-DDTHH:MM:SSZ`)을 기록합니다.
- 템플릿 복사만 하지 말고 프로젝트 맥락 `relevance_note`를 직접 작성합니다.
- 네트워크가 막히면 `relevance_note`에 `blocked`를 명시하고 부분 검증으로 보고합니다.

샘플:

```bash
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$RUN_DIR/source_review.tsv" <<TSV
source_id	source_type	url	checked_at_utc	relevance_note	key_constraints
official-1	official	https://developers.openai.com/codex/multi-agent	$NOW_UTC	multi_agent 기능 플래그 및 에이전트 등록 키 검증	experimental 기능/버전 차이 확인 필요
github-1	github	https://github.com/openai/codex/pull/11917	$NOW_UTC	config_file 분리형 role 구성 사례 검증	PR 기준이므로 현재 CLI 버전과 교차 확인 필요
web-1	web	https://platform.claude.com/docs/en/build-with-claude/agentic-workflows	$NOW_UTC	역할 분해/오케스트레이션 패턴 참고	Codex 설정 키의 1차 근거로 사용하지 않음
TSV
```

## Step 3) 멀티 에이전트 계획 생성 (`agent_plan.tsv`)

필수 헤더:

```tsv
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
```

필수 규칙:
- 모든 컬럼 값은 비어 있으면 안 됩니다.
- `agent_id`와 `config_relpath`는 중복되면 안 됩니다.
- `priority`는 정수이며 `1` 이상이어야 합니다.
- `agent_id`는 영문/숫자/`._-`만 허용합니다.
- `config_relpath`는 `agents/*.toml`만 허용합니다.
- `config_relpath`는 하위 디렉터리를 허용하지 않습니다.
- `model_reasoning_effort`: `minimal|low|medium|high|xhigh`
- `sandbox_mode`: `read-only|workspace-write|danger-full-access`
- `reason`에는 `project_profile.md` 근거와 `source_review.tsv`의 `source_id`를 반드시 포함합니다.
- 계획 반영 시 `config_file`과 실제 생성 파일 경로는 각 행의 `config_relpath`를 그대로 사용합니다.

샘플:

```tsv
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
paf_explorer	Project Explorer	10	stack-map(package+tests), source=official-1 web-1	agents/paf_explorer.toml	Explore repo structure and constraints.	Map architecture with evidence-first notes.	gpt-5	medium	workspace-write
paf_implementer	Project Implementer	20	delivery-path(api+ui), source=github-1 official-1	agents/paf_implementer.toml	Implement scoped changes with verification.	Apply requested edits and run available checks.	gpt-5	high	workspace-write
```

## Step 4) 계획 반영 (직접 파일 편집)

자동 스크립트 없이 아래를 직접 반영합니다.

1. `.codex/<config_relpath>` 생성/갱신
- 파일 상단에 `# managed_by=project-agent-factory` 마커를 남깁니다.
- `developer_instructions`를 멀티라인 문자열로 기록합니다.
- 파일 경로는 `agent_id`가 아니라 해당 행의 `config_relpath`를 사용합니다
  (예: `config_relpath=agents/paf_qa.toml`이면 `.codex/agents/paf_qa.toml` 생성).

에이전트 파일 템플릿:

```toml
# managed_by=project-agent-factory
# role=<role_name>
model = "<model>"
model_reasoning_effort = "<model_reasoning_effort>"
sandbox_mode = "<sandbox_mode>"

developer_instructions = """
<developer_instructions>
Do not write outside the project root.
"""
```

2. `.codex/config.toml`의 managed block 동기화
- 기존 파일을 통째로 덮어쓰지 않습니다.
- 아래 마커 사이만 교체/생성합니다.

```toml
# BEGIN project-agent-factory managed agents
# generated_at=<YYYY-MM-DDTHH:MM:SSZ>
# This block is managed by project-agent-factory.

[agents."<agent_id>"]
description = "<description>"
config_file = "<config_relpath>"

# END project-agent-factory managed agents
```

3. `features.multi_agent = true` 보장
- `[features]`가 없으면 생성합니다.
- `multi_agent = false`이면 `true`로 수정합니다.
- 다른 feature 키는 보존합니다.

4. stale managed agent 파일 정리
- `.codex/agents/*.toml` 중 `# managed_by=project-agent-factory`가 있고,
  이번 `agent_plan.tsv`의 `config_relpath` 목록에 없는 파일은 제거합니다.

## Step 5) 결과 검증 (`scope_validation.md` + `apply_report.md`)

검증 체크:
- 모든 생성/갱신 파일 경로가 `<project-root>/.codex/` 하위인지 확인
- `.codex/config.toml`에 `multi_agent = true` 존재 확인
- managed block의 agent 목록과 `agent_plan.tsv`가 일치하는지 확인
- 각 `config_file` 경로가 `agents/*.toml` 형식이며 해당 행의 `config_relpath`와 일치하는지 확인

권장 확인 명령:

```bash
rg -n '^\[features\]|^multi_agent\s*=' .codex/config.toml
rg -n '^\[agents\.".*"\]$|^config_file\s*=\s*"agents/[A-Za-z0-9._-]+\.toml"$' .codex/config.toml
rg -n '^# managed_by=project-agent-factory$|^model\s*=|^model_reasoning_effort\s*=|^sandbox_mode\s*=|^developer_instructions\s*=' .codex/agents/*.toml
```

`scope_validation.md` 템플릿:

```markdown
# Scope Validation
generated_at_utc: <YYYY-MM-DDTHH:MM:SSZ>
project_root: <path>

- checked_paths:
  - <path>
- outside_scope_paths:
  - none
- result: pass|fail
- note: <if fail, explain>
```

`apply_report.md` 템플릿:

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
- 생성/수정/삭제 파일 목록
- `.codex/config.toml` managed block 반영 결과
- `features.multi_agent` 보장 여부

## 5) Scope Validation
- 프로젝트 루트 밖 경로 변경 여부

## 6) Open Risks
- 네트워크 차단, 미검증 테스트, 버전 호환성 등
```

## Migration Note

- 레거시 스크립트 기반 커맨드(`apply-plan`, `run`, `scan-project`, `plan-agents`, `validate-*`, `audit`)를 사용하지 않습니다.
- 반영/검증은 이 문서의 절차에 따라 AI가 직접 편집/점검합니다.

## References

- 멀티 에이전트 설정 핵심은 `references/codex-multi-agent-notes.md`를 읽으세요.
- 역할 구성 기준은 `references/agent-role-patterns.md`를 읽으세요.
- 소스 수집/검증 기준은 `references/multi-agent-case-sources.md`를 읽으세요.
