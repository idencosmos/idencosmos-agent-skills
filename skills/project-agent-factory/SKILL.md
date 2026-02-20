---
name: project-agent-factory
description: 프로젝트에 필요한 Codex 멀티 에이전트를 설계/생성할 때 사용하는 순수 Markdown 지시형 스킬입니다. 프로젝트 분석 → 공식/사례 검증 → agent_plan.tsv 설계 → .codex 수동 반영 → 검증 보고까지를 SKILL.md와 references만으로 수행합니다.
---

# Project Agent Factory (Markdown-Only)

`project-agent-factory`는 프로젝트에 필요한 멀티 에이전트를 **분석 → 설계 → 반영 → 검증** 순서로 수행하는 순수 Markdown 지시형 스킬입니다.

핵심 원칙:
- 자동 적용 스크립트(`apply-plan` 등)를 사용하지 않습니다.
- 반영은 AI가 직접 `.codex/config.toml`, `.codex/agents/*.toml`을 편집해서 수행합니다.
- 모든 판단 근거는 실행 산출물(`project_profile.md`, `source_review.tsv`, `source_probe.tsv`, `agent_plan.tsv`, `apply_report.md`)에 남깁니다.

고정 파이프라인:
0. trusted preflight (`trust_preflight.md`)
1. 프로젝트 분석 (`project_profile.md`)
2. 공식/사례 검증 (`source_review.tsv`, `source_probe.tsv`)
3. 멀티 에이전트 계획 생성 (`agent_plan.tsv`)
3.5. 계획 정합성 검증 (fail-fast)
4. 계획 반영 (직접 파일 편집)
5. 결과 감사 (`apply_report.md`, `scope_validation.md`)

## Step 0) 프로젝트 루트 고정 + Run 디렉터리 준비

```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_ROOT"

RUN_BASE="${PAF_RUN_BASE:-$PROJECT_ROOT/.agents/project-agent-factory/runs}"
RUN_DIR="$RUN_BASE/$(date -u +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_DIR" "$PROJECT_ROOT/.codex/agents"

WRITE_PROBE="$RUN_DIR/.write_probe"
if ! : > "$WRITE_PROBE" 2>/dev/null; then
  echo "ERR: run_dir_not_writable=$RUN_DIR"
  echo "HINT: 권한/샌드박스 상태를 점검하거나 PAF_RUN_BASE를 쓰기 가능한 경로로 지정하세요."
  exit 1
fi
rm -f "$WRITE_PROBE"

echo "project_root=$PROJECT_ROOT"
echo "run_dir=$RUN_DIR"
```

이후 단계의 모든 상대경로는 `PROJECT_ROOT` 기준으로 해석합니다.

Step 0 fail-fast 규칙:
- `RUN_DIR` 생성 또는 write probe 실패 시 즉시 중단합니다.
- 권한 이슈를 우회하려고 프로젝트 루트 밖 임의 경로를 사용하지 말고, `PAF_RUN_BASE`를 명시적으로 설정해 재실행합니다.

## Step 0.5) Trusted 프로젝트 preflight (`trust_preflight.md`)

Codex는 trusted 프로젝트에서만 프로젝트 로컬 `.codex/config.toml`를 반영합니다.
이 스킬은 `.codex/` 반영이 핵심이므로 trust 상태를 **fail-closed**로 다룹니다.

```bash
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$RUN_DIR/trust_preflight.md" <<EOF
# Trust Preflight
generated_at_utc: $NOW_UTC
project_root: $PROJECT_ROOT

- requirement: project must be trusted before applying .codex changes
- trust_status: <set_after_check: trusted|untrusted|unknown>
- evidence:
  - (예) Codex UI/CLI에서 trusted 상태 확인
  - (예) 세션 재시작 후 프로젝트 .codex 설정이 유효하게 반영됨을 확인
- action_if_not_trusted: skip_step_4_and_run_step_5_plan_only
EOF
```

실행 규칙:
- `trust_status`는 템플릿 문자열이 아니라 `trusted|untrusted|unknown` 중 하나의 실제 값으로 확정해야 합니다.
- `trust_status=trusted` + Step 3.5 통과 전에는 Step 4를 수행하지 않습니다.
- `untrusted|unknown`이면 Step 4(반영)를 건너뛰고, Step 5를 `apply_mode=plan_only`로 수행합니다.
- trust 확인 정규식에서 `\s`는 휴대성이 떨어질 수 있으므로 `awk/sed`에서는 `[[:space:]]`를 사용합니다.

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

## Step 2) 공식 문서 + GitHub/인터넷 사례 검증 (`source_review.tsv`, `source_probe.tsv`)

먼저 아래 레퍼런스를 읽습니다.
- `references/codex-multi-agent-notes.md`
- `references/multi-agent-case-sources.md`

그 다음 실제 원문 링크를 열람하고 `source_review.tsv`를 작성합니다.
연결성/본문 유효성 증빙은 `source_probe.tsv` + `source_evidence/*.md`로 별도 남깁니다.

`source_review.tsv`의 헤더/컬럼 규칙/품질 기준은
`references/multi-agent-case-sources.md`의
`source_review.tsv 계약` + `품질 기준`을 **단일 기준(SSOT)**으로 사용합니다.
이 `SKILL.md`에는 동일 계약을 중복 정의하지 않습니다.

샘플:

```bash
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$RUN_DIR/source_evidence"

cat > "$RUN_DIR/source_review.tsv" <<TSV
source_id	source_type	url	checked_at_utc	relevance_note	key_constraints
official-1	official	https://developers.openai.com/codex/multi-agent	$NOW_UTC	multi_agent 기능 플래그 및 에이전트 등록 키 검증	experimental 기능/버전 차이 확인 필요
github-1	github	https://github.com/openai/codex/pull/11917	$NOW_UTC	config_file 분리형 role 구성 사례 검증	PR 기준이므로 현재 CLI 버전과 교차 확인 필요
web-1	web	https://learn.microsoft.com/en-us/azure/architecture/ai-ml/guide/ai-agent-design-patterns	$NOW_UTC	역할 분해/오케스트레이션 패턴 참고	Codex 설정 키의 1차 근거로 사용하지 않음
TSV

cat > "$RUN_DIR/source_probe.tsv" <<TSV
source_id	http_status	final_url	body_not_found	evidence_relpath	checked_at_utc	probe_note
official-1	200	https://developers.openai.com/codex/multi-agent	no	source_evidence/official-1.md	$NOW_UTC	문서 핵심 섹션 열람 완료
github-1	200	https://github.com/openai/codex/pull/11917	no	source_evidence/github-1.md	$NOW_UTC	PR 변경 맥락/설정 키 확인
web-1	200	https://learn.microsoft.com/en-us/azure/architecture/ai-ml/guide/ai-agent-design-patterns	no	source_evidence/web-1.md	$NOW_UTC	역할 분해 패턴 참고 내용 확인
TSV

cat > "$RUN_DIR/source_evidence/official-1.md" <<'MD'
# Source Evidence: official-1
- fetch_method: browser/manual
- http_status: 200
- body_not_found: no
- evidence_note: multi_agent 설정 관련 본문 섹션 확인
MD
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

## Step 3.5) `agent_plan.tsv` 정합성 검증 (fail-fast)

Step 4로 넘어가기 전에 아래 검증을 통과해야 합니다.

```bash
awk -F'\t' '
BEGIN {
  expected="agent_id\trole_name\tpriority\treason\tconfig_relpath\tdescription\tdeveloper_instructions\tmodel\tmodel_reasoning_effort\tsandbox_mode"
  split("minimal low medium high xhigh", e, " "); for (i in e) eff[e[i]]=1
  split("read-only workspace-write danger-full-access", s, " "); for (i in s) sandbox[s[i]]=1
}
NR==1 {
  if ($0 != expected) { print "ERR header mismatch"; bad=1 }
  next
}
{
  if (NF != 10) { print "ERR col_count line=" NR; bad=1; next }
  for (i=1; i<=10; i++) if ($i == "") { print "ERR empty_col line=" NR " col=" i; bad=1 }
  if ($1 !~ /^[A-Za-z0-9._-]+$/) { print "ERR agent_id line=" NR " value=" $1; bad=1 }
  if ($3 !~ /^[1-9][0-9]*$/) { print "ERR priority line=" NR " value=" $3; bad=1 }
  if ($5 !~ /^agents\/[A-Za-z0-9._-]+\.toml$/) { print "ERR config_relpath line=" NR " value=" $5; bad=1 }
  if (!($9 in eff)) { print "ERR model_reasoning_effort line=" NR " value=" $9; bad=1 }
  if (!($10 in sandbox)) { print "ERR sandbox_mode line=" NR " value=" $10; bad=1 }
  if ($4 !~ /(official|github|web)-[0-9]+/) { print "ERR reason_missing_source_id line=" NR; bad=1 }
  if (++aid[$1] > 1) { print "ERR duplicate agent_id=" $1; bad=1 }
  if (++cfg[$5] > 1) { print "ERR duplicate config_relpath=" $5; bad=1 }
}
END { exit bad ? 1 : 0 }
' "$RUN_DIR/agent_plan.tsv"

cut -f1 "$RUN_DIR/source_review.tsv" | tail -n +2 | sort -u > "$RUN_DIR/source_ids.txt"
rg -o '(official|github|web)-[0-9]+' "$RUN_DIR/agent_plan.tsv" | sort -u > "$RUN_DIR/reason_source_ids.txt"
comm -23 "$RUN_DIR/reason_source_ids.txt" "$RUN_DIR/source_ids.txt" > "$RUN_DIR/missing_source_ids.txt"
test ! -s "$RUN_DIR/missing_source_ids.txt"

awk -F'\t' '
BEGIN {
  expected="source_id\thttp_status\tfinal_url\tbody_not_found\tevidence_relpath\tchecked_at_utc\tprobe_note"
}
NR==1 {
  if ($0 != expected) { print "ERR source_probe_header_mismatch"; bad=1 }
  next
}
{
  if (NF != 7) { print "ERR source_probe_col_count line=" NR; bad=1; next }
  if ($1 !~ /^(official|github|web)-[0-9]+$/) { print "ERR source_probe_id line=" NR " value=" $1; bad=1 }
  if ($2 !~ /^(blocked|[1-5][0-9][0-9])$/) { print "ERR source_probe_http_status line=" NR " value=" $2; bad=1 }
  if ($4 !~ /^(yes|no|blocked)$/) { print "ERR source_probe_body_not_found line=" NR " value=" $4; bad=1 }
  if ($5 !~ /^source_evidence\/[A-Za-z0-9._-]+\.md$/) { print "ERR source_probe_evidence_relpath line=" NR " value=" $5; bad=1 }
  if ($6 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/) { print "ERR source_probe_checked_at line=" NR " value=" $6; bad=1 }
  if (++sid[$1] > 1) { print "ERR source_probe_duplicate_source_id=" $1; bad=1 }
  if ($2 ~ /^2/ && $4 == "yes") { print "ERR source_probe_invalid_not_found line=" NR; bad=1 }
}
END { exit bad ? 1 : 0 }
' "$RUN_DIR/source_probe.tsv"

cut -f1 "$RUN_DIR/source_probe.tsv" | tail -n +2 | sort -u > "$RUN_DIR/probe_source_ids.txt"
comm -3 "$RUN_DIR/source_ids.txt" "$RUN_DIR/probe_source_ids.txt" > "$RUN_DIR/source_probe_id_diff.txt"
test ! -s "$RUN_DIR/source_probe_id_diff.txt"

awk -F'\t' 'NR>1 { print $5 }' "$RUN_DIR/source_probe.tsv" \
  | while IFS= read -r rel; do
      test -f "$RUN_DIR/$rel" || { echo "ERR missing_evidence_file=$rel"; exit 1; }
    done
```

## Step 4) 계획 반영 (직접 파일 편집)

자동 스크립트 없이 아래를 직접 반영합니다.

적용 방식:
- `apply_patch`를 우선 사용하되, 환경 제약으로 실패하면 `cat > file`, `rm`, `mv`로 대체 반영할 수 있습니다.
- 반영 방식과 무관하게 Step 5 검증을 동일하게 통과해야 합니다.

사전 조건:
- `trust_preflight.md`의 `trust_status=trusted`가 확인된 경우에만 실행합니다.
- Step 3.5 정합성 검증을 통과한 경우에만 실행합니다.
- `untrusted|unknown`이면 Step 4는 건너뜁니다(보고는 Step 5에서 수행).

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

Step 5는 항상 수행합니다.
- `full_apply`: Step 4 반영 이후 검증/보고
- `plan_only`: Step 4 생략 후 검증/보고(변경 경로는 `none`으로 기록)

검증 체크:
- `trust_preflight.md`의 trust 상태와 실제 수행 범위가 일치하는지 확인
- 모든 생성/갱신 파일 경로가 `<project-root>/.codex/` 하위인지 확인
- `source_probe.tsv`의 `source_id`가 `source_review.tsv`와 일치하고, `evidence_relpath` 실파일이 존재하는지 확인
- `apply_mode=full_apply`인 경우에만 아래를 추가 확인:
  - `.codex/config.toml`에 `multi_agent = true` 존재 확인
  - managed block의 agent 목록과 `agent_plan.tsv`가 일치하는지 확인
  - 각 `config_file` 경로가 `agents/*.toml` 형식이며 해당 행의 `config_relpath`와 일치하는지 확인

권장 확인 명령:

```bash
# portability note: awk/sed 정규식에서는 \s 대신 [[:space:]]를 사용합니다.
rg -n '^-\\s+trust_status:\\s+(trusted|untrusted|unknown)$' "$RUN_DIR/trust_preflight.md"
! rg -n '^-\\s+trust_status:\\s+<set_after_check:' "$RUN_DIR/trust_preflight.md"
if [ -f .codex/config.toml ]; then
  rg -n '^\[features\]|^multi_agent\s*=' .codex/config.toml
  rg -n '^\[agents\.".*"\]$|^config_file\s*=\s*"agents/[A-Za-z0-9._-]+\.toml"$' .codex/config.toml
else
  echo "INFO: .codex/config.toml not found (plan_only 경로일 수 있음)"
fi
rg -n '^# managed_by=project-agent-factory$|^model\s*=|^model_reasoning_effort\s*=|^sandbox_mode\s*=|^developer_instructions\s*=' .codex/agents -g '*.toml' || true
awk -F'\t' 'NR>1 && $2 ~ /^2/ && $4 == "yes" { bad=1 } END { exit bad ? 1 : 0 }' "$RUN_DIR/source_probe.tsv"
awk -F'\t' 'NR>1 { print $5 }' "$RUN_DIR/source_probe.tsv" \
  | while IFS= read -r rel; do
      test -f "$RUN_DIR/$rel" || { echo "ERR missing_evidence_file=$rel"; exit 1; }
    done
```

템플릿 파일 생성 시 백틱/`$()` 치환 오염을 막기 위해 single-quoted heredoc(`<<'MD'`)을 사용합니다.

`scope_validation.md` 템플릿:

```markdown
# Scope Validation
generated_at_utc: <YYYY-MM-DDTHH:MM:SSZ>
project_root: <path>
apply_mode: full_apply|plan_only

- checked_paths:
  - <path>|none(plan_only)
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

## 0) Trust Preflight
- trust_status: trusted|untrusted|unknown
- apply_mode: full_apply|plan_only
- blocked_reason: <if blocked, explain>

## 1) Project Analysis Summary
- stack/runtime/test 신호 요약

## 2) Source Verification Summary
- official/github/web 각 1개 이상 여부
- blocked 항목 여부
- `source_probe.tsv`의 HTTP/본문 유효성 결과 요약
- `source_evidence` 누락 여부

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
