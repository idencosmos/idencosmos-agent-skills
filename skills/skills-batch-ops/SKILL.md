---
name: skills-batch-ops
description: 외부 AI 오케스트레이터가 만든 후보/리뷰 결과에 대해 병렬 실행 증거와 설치 안전 게이트만 강제 검증합니다.
---

# Skills Batch Ops (Gate-Only)

이 스킬은 **AI 판단 자체를 스크립트로 대체하지 않습니다.**
스크립트는 아래 4가지 게이트 업무만 수행합니다.

1. `verify-parallel-proof`: 워커 병렬 실행 증거 strict 검증
2. `validate-content`: `skill_ref/repo/skill` 정합성 + 설치 가능 + `SKILL.md` 존재 게이트
3. `install-approved`: `approved`만 설치 (병렬 증거 `passed=true` + `review_content.tsv`에서 `gate_pass` 필수)
4. `audit`: 설치/검증 감사 로그 생성

## 책임 분리

스크립트 외부(오케스트레이터/AI)가 담당:
- 프로젝트 분석
- discovery/review 태스크 생성
- 후보 탐색/평가
- 최종 승인 상태(`approved|pending|rejected`) 결정

스크립트가 담당:
- 산출물의 안전성 게이트 검증
- 설치 실행 전후 감사 흔적 보존

## 표준 흐름

1. 외부 AI 오케스트레이터가 queue/worker TSV를 생성
2. `verify-parallel-proof --stage discovery`
3. `verify-parallel-proof --stage review`
4. 외부 AI가 최종 `review_manifest.ai.tsv` 작성 (`status` 포함)
5. `validate-content`로 Gate 1/2 확인
6. `install-approved --proof <parallel_proof.summary.json> --content-report <review_content.tsv>`
7. `audit`

## 필수 입력 계약

- Queue TSV 공통 필드: `task_id`, `expected_stage`
- Worker TSV 공통 필드:
  - `task_id`, `expected_stage`
  - `worker_run_id`, `worker_id`
  - `worker_started_at`, `worker_finished_at`
  - `worker_attempt`, `orchestrator_name`
- Review stage에서는 queue/worker 모두 `skill_ref`를 채워 두는 것을 권장합니다.

## 병렬 증거 실패 코드

- `missing_task_coverage`
- `task_not_in_queue`
- `task_ref_mismatch`
- `expected_stage_mismatch`
- `invalid_time_range`
- `serial_execution_detected`
- `insufficient_unique_workers`
- `missing_worker_metadata`

## 명령어

```bash
# 1) 병렬 실행 증거 검증
bash scripts/skills_batch_ops.sh verify-parallel-proof \
  --stage discovery \
  --queue <review_discovery.queue.tsv> \
  --out <discovery_parallel_proof.tsv> \
  --summary <discovery_parallel_summary.json> \
  <worker_1.tsv> <worker_2.tsv>

# 2) 설치 안전 게이트
bash scripts/skills_batch_ops.sh validate-content \
  --manifest <review_manifest.ai.tsv> \
  --out <review_content.tsv>

# 3) 승인 항목 설치 (parallel_proof.summary.json passed=true 필요)
bash scripts/skills_batch_ops.sh install-approved \
  --manifest <review_manifest.ai.tsv> \
  --proof <parallel_proof.summary.json> \
  --content-report <review_content.tsv>

# 4) 감사 로그
bash scripts/skills_batch_ops.sh audit \
  --out <audit.log> \
  --proof <parallel_proof.summary.json>
```

## Removed (Gate-Only)

아래는 더 이상 제공하지 않습니다.

- `run`
- `prepare-ai-discovery`
- `merge-ai-discovery`
- `prepare-ai-reviews`
- `merge-ai-reviews`
- `apply-ai-reviews`
- `install`
- `collect-find`
- `collect-top`
- `collect-github`
- `import-web`
- `merge`
- `collect`
