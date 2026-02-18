---
name: skills-batch-ops
description: 프로젝트 전수 분석 기반 AI 멀티 에이전트 탐색/심사 파이프라인으로 스킬 후보를 생성하고, 3개 안전 게이트를 통과한 승인 항목만 설치합니다.
---

# Skills Batch Ops (AI-Only + Strict Parallel Proof)

이 스킬의 목적은 **프로젝트에 맞는 스킬을 AI가 전면 탐색/평가**하도록 만들고,
아래 3개만 기계적 안전 게이트로 강제하는 것입니다.

1. `skill_ref/repo` 유효성 체크
2. 실제 설치 가능 여부 + `SKILL.md` 존재 확인
3. `approved` 상태만 설치

추가 원칙:
- 외부 멀티 워커 실행 책임은 외부 오케스트레이터가 가집니다.
- 이 스크립트는 **병렬 실행 증거를 strict로 검증**하며, 증거 부족 시 병합/설치를 차단합니다.

## 핵심 원칙

- 휴리스틱 점수식(`auto_score`, `query_overlap`)에 의존하지 않습니다.
- 프로젝트 분석은 전체 레포 텍스트 파일을 대상으로 합니다.
- 후보 탐색/적합도 평가는 외부 멀티 에이전트 워커가 담당합니다.
- 설치는 반드시 `install-approved`로만 수행합니다.
- `merge-ai-discovery`, `merge-ai-reviews`는 `--proof`를 필수로 요구합니다.

## 표준 흐름

1. `run`
2. `prepare-ai-discovery` 결과 큐를 기준으로 외부 워커 병렬 실행
3. `verify-parallel-proof --stage discovery`
4. `merge-ai-discovery --proof <discovery_summary.json>`
5. `validate-content` (Gate 1/2)
6. `prepare-ai-reviews`
7. 외부 review 워커 병렬 실행
8. `verify-parallel-proof --stage review`
9. `merge-ai-reviews --proof <review_summary.json>`
10. `apply-ai-reviews`
11. `install-approved` (Gate 3)
12. `audit`

## 실행 예시

### 1) 초기 실행 (프로젝트 전수 분석 + discovery 큐 생성)

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh run \
  --project-root "$(pwd)"
```

생성물:
- `project_context.files.tsv`
- `project_context.chunks.ndjson`
- `project_intent.ai.json`
- `review_discovery.queue.tsv`
- `run_contract.json` (증거 검증 대상 경로 계약)
- `candidates.ai.tsv` (헤더만 생성 가능)
- `review_manifest.tsv` (헤더만 생성 가능)

### 2) discovery 워커 결과 검증 + 병합

외부 워커 출력 필수 컬럼(Discovery):
- `task_id`, `expected_stage`, `skill_ref`, `repo`, `skill`
- `discovery_channels`, `discovery_evidence`
- `ai_relevance`, `ai_quality`, `ai_risk`, `ai_confidence`
- `ai_decision`, `ai_recommended_status`, `ai_summary`, `ai_rationale`
- `ai_reviewer`, `ai_reviewed_at`
- `worker_run_id`, `worker_id`, `worker_started_at`, `worker_finished_at`, `worker_attempt`, `orchestrator_name`

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh verify-parallel-proof \
  --stage discovery \
  --queue .agents/skills-batch-ops/runs/<timestamp>/review_discovery.queue.tsv \
  --out .agents/skills-batch-ops/runs/<timestamp>/discovery_parallel_proof.tsv \
  --summary .agents/skills-batch-ops/runs/<timestamp>/discovery_parallel_summary.json \
  .agents/skills-batch-ops/runs/<timestamp>/review_discovery.workers/*.tsv

bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh merge-ai-discovery \
  --out .agents/skills-batch-ops/runs/<timestamp>/candidates.ai.tsv \
  --manifest .agents/skills-batch-ops/runs/<timestamp>/review_manifest.tsv \
  --proof .agents/skills-batch-ops/runs/<timestamp>/discovery_parallel_summary.json \
  .agents/skills-batch-ops/runs/<timestamp>/review_discovery.workers/*.tsv
```

### 3) Gate 1/2 검증

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh validate-content \
  --manifest .agents/skills-batch-ops/runs/<timestamp>/review_manifest.tsv \
  --out .agents/skills-batch-ops/runs/<timestamp>/review_content.tsv
```

`review_content.tsv` 핵심 컬럼:
- `name_check`
- `install_check`
- `skill_md_check`
- `gate_status` (`gate_pass|gate_fail`)
- `gate_reason` (`invalid_ref|list_failed|not_found|install_failed|skill_md_missing|ok`)

### 4) AI 심사 큐 생성 (Gate 통과 후보 전량)

`review_ai.queue.tsv`는 `task_id` + `expected_stage=review`를 포함하며,
1 task = 1 skill_ref로 생성됩니다.

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh prepare-ai-reviews \
  --manifest .agents/skills-batch-ops/runs/<timestamp>/review_manifest.tsv \
  --content-report .agents/skills-batch-ops/runs/<timestamp>/review_content.tsv \
  --project-intent .agents/skills-batch-ops/runs/<timestamp>/project_intent.ai.json \
  --out .agents/skills-batch-ops/runs/<timestamp>/review_ai.queue.tsv
```

### 5) review 워커 결과 검증 + 병합/반영

외부 워커 출력 필수 컬럼(Review):
- `task_id`, `expected_stage`, `skill_ref`, `repo`, `skill`
- `manifest_status`, `gate_status`, `gate_reason`
- `project_goal`, `project_domain`, `project_constraints`, `discovery_summary`
- `ai_relevance`, `ai_quality`, `ai_risk`, `ai_confidence`
- `ai_decision`, `ai_recommended_status`, `ai_summary`, `ai_rationale`
- `ai_reviewer`, `ai_reviewed_at`
- `worker_run_id`, `worker_id`, `worker_started_at`, `worker_finished_at`, `worker_attempt`, `orchestrator_name`

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh verify-parallel-proof \
  --stage review \
  --queue .agents/skills-batch-ops/runs/<timestamp>/review_ai.queue.tsv \
  --out .agents/skills-batch-ops/runs/<timestamp>/review_parallel_proof.tsv \
  --summary .agents/skills-batch-ops/runs/<timestamp>/review_parallel_summary.json \
  .agents/skills-batch-ops/runs/<timestamp>/review_ai.workers/*.tsv

bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh merge-ai-reviews \
  --out .agents/skills-batch-ops/runs/<timestamp>/review_ai.merged.tsv \
  --proof .agents/skills-batch-ops/runs/<timestamp>/review_parallel_summary.json \
  .agents/skills-batch-ops/runs/<timestamp>/review_ai.workers/*.tsv

bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh apply-ai-reviews \
  --manifest .agents/skills-batch-ops/runs/<timestamp>/review_manifest.tsv \
  --ai-reviews .agents/skills-batch-ops/runs/<timestamp>/review_ai.merged.tsv \
  --out .agents/skills-batch-ops/runs/<timestamp>/review_manifest.ai.tsv
```

### 6) Gate 3 설치

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh install-approved \
  --manifest .agents/skills-batch-ops/runs/<timestamp>/review_manifest.ai.tsv
```

설치는 `status=approved`만 대상입니다.

## Strict 병렬 증거 규칙

검증 실패 코드:
- `missing_task_coverage`
- `task_not_in_queue`
- `task_ref_mismatch`
- `invalid_time_range`
- `serial_execution_detected`
- `insufficient_unique_workers`
- `missing_worker_metadata`

요약 산출물:
- `<stage>_parallel_proof.tsv`
- `<stage>_parallel_summary.json`
- `parallel_proof.summary.json` (통합)

## 승인/설치 체크리스트

설치 직전 최소 점검:
1. `review_content.tsv`에서 설치 대상 후보가 `gate_pass`인지
2. `review_manifest.ai.tsv`에서 상태가 `approved`인지
3. `discovery_parallel_summary.json`, `review_parallel_summary.json`이 `passed=true`인지
4. 승인 근거(`review_notes`, `ai_summary`, `ai_rationale`)가 남아 있는지

## Deprecated

아래 커맨드는 AI-only 재설계에서 제거되었습니다.

- `collect-find`
- `collect-top`
- `collect-github`
- `import-web`
- `merge`
- `collect`

필요하면 `run` + `prepare-ai-discovery` + 외부 워커 + `verify-parallel-proof` + `merge-ai-discovery`로 대체합니다.
