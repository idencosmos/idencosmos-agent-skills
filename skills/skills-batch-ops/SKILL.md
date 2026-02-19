---
name: skills-batch-ops
description: 외부 AI 오케스트레이터가 생성한 discovery/review queue, worker TSV, review_manifest.ai.tsv를 대상으로 병렬 실행 증거와 설치 직전 구조 게이트만 강제 검증합니다. 후보 탐색/평가/승인 판단은 이미 완료됐고 gate-only 검증 및 승인 항목 설치가 필요할 때 사용합니다.
---

# Skills Batch Ops (Gate-Only)

이 스킬은 **AI 판단 자체를 스크립트로 대체하지 않습니다.**
스크립트는 아래 2가지 게이트 업무만 수행합니다.

1. `verify-parallel-proof`: 워커 병렬 실행 증거 strict 검증 (서로 다른 `worker_id` 간 시간 overlap 필수)
2. `install-approved`: `approved`만 스킬 단위 설치 (병렬 증거 `passed=true` + 설치 직전 구조 게이트 필수, 일부 실패 시 전체 실패)

## 책임 분리

스크립트 외부(오케스트레이터/AI)가 담당:
- 프로젝트 분석
- discovery/review 태스크 생성
- 후보 탐색/평가
- 최종 승인 상태(`approved|pending|rejected`) 결정

스크립트가 담당:
- 산출물의 안전성 게이트 검증
- 설치 실행 전후 감사 흔적 보존

## 실행 전 체크

- 필수 명령: `bash`, `node`, `npx`, `awk`
- 권장 명령: `jq` (`parallel_proof.summary.json` 파싱 안정성 향상)
- 시간 컬럼(`worker_started_at`, `worker_finished_at`)은 ISO 8601 UTC(`...Z`) 형식을 권장합니다.

## 표준 흐름

1. 외부 AI 오케스트레이터가 queue/worker TSV를 생성
2. `verify-parallel-proof --stage discovery`
3. `verify-parallel-proof --stage review`
4. 외부 AI가 최종 `review_manifest.ai.tsv` 작성 (`status` 포함)
5. `install-approved --proof <parallel_proof.summary.json>`
6. (선택) AI가 `parallel_proof.summary.json` + `install.report.tsv`를 읽어 감사 로그를 생성

## 필수 입력 계약

- Queue TSV 공통 필드: `task_id`, `expected_stage`
- Worker TSV 공통 필드:
  - `task_id`, `expected_stage`
  - `worker_run_id`, `worker_id`
  - `worker_started_at`, `worker_finished_at`
  - `worker_attempt`, `orchestrator_name`
- Review stage에서는 queue/worker 모두 `skill_ref`를 필수로 채웁니다.

## 구조 gate 의미

- `install-approved`는 승인 항목에 대해 `skill_ref/repo/skill` 정합성 오류를 차단합니다.
- 구조 게이트와 승인 판단은 분리됩니다. 승인 판단은 AI가 담당하고, 스크립트는 설치 직전 정합성만 강제합니다.

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

# 2) 승인 항목 설치 (parallel_proof.summary.json passed=true 필요)
bash scripts/skills_batch_ops.sh install-approved \
  --manifest <review_manifest.ai.tsv> \
  --proof <parallel_proof.summary.json> \
  --report <install.report.tsv> \
  --dry-run

# 3) (선택) AI가 증거/설치 리포트를 읽어 감사 로그 생성
```

## install-approved 옵션

- `--proof`: 병렬 증거 집계 파일. 미지정 시 manifest 폴더의 `parallel_proof.summary.json` 사용
- `--report`: 설치 리포트 경로. 미지정 시 manifest 폴더의 `install.report.tsv` 사용
- `--dry-run`: 실제 설치 없이 설치 대상/명령 기록만 생성
- `--no-yes`: `npx skills add ... -y` 대신 확인 프롬프트 허용 모드로 실행

## 실패 동작

- `verify-parallel-proof`: strict 조건 미충족 시 리포트/요약 파일을 남기고 non-zero 종료
- `install-approved`: 승인 대상 중 하나라도 설치 실패 시 전체를 실패로 처리하고 non-zero 종료

## Removed (Gate-Only)

아래는 더 이상 제공하지 않습니다.

- `run`
- `validate-content`
- `audit`
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
