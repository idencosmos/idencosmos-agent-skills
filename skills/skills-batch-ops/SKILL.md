---
name: skills-batch-ops
description: 프로젝트 전수 분석 기반 AI 멀티 에이전트 탐색/심사 파이프라인으로 스킬 후보를 생성하고, 3개 안전 게이트를 통과한 승인 항목만 설치합니다.
---

# Skills Batch Ops (AI-Only)

이 스킬의 목적은 **프로젝트에 맞는 스킬을 AI가 전면 탐색/평가**하도록 만들고,
아래 3개만 기계적 안전 게이트로 강제하는 것입니다.

1. `skill_ref/repo` 유효성 체크
2. 실제 설치 가능 여부 + `SKILL.md` 존재 확인
3. `approved` 상태만 설치

비용/토큰/실행 시간은 최적화 대상이 아닙니다.

## 핵심 원칙

- 휴리스틱 점수식(`auto_score`, `query_overlap`)에 의존하지 않습니다.
- 프로젝트 분석은 전체 레포 텍스트 파일을 대상으로 합니다.
- 후보 탐색/적합도 평가는 외부 멀티 에이전트 워커가 담당합니다.
- 설치는 반드시 `install-approved`로만 수행합니다.

## 표준 흐름

1. `run`
2. `prepare-ai-discovery` 결과 큐를 기준으로 워커 병렬 실행
3. `merge-ai-discovery`
4. `validate-content` (Gate 1/2)
5. `prepare-ai-reviews`
6. 워커 병렬 심사
7. `merge-ai-reviews`
8. `apply-ai-reviews`
9. `install-approved` (Gate 3)
10. `audit`

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
- `candidates.ai.tsv` (헤더만 생성 가능)
- `review_manifest.tsv` (헤더만 생성 가능)

### 2) discovery 워커 결과 병합

워커 출력 파일은 아래 컬럼 계약을 따라야 합니다.

- `skill_ref`
- `repo`
- `skill`
- `discovery_channels`
- `discovery_evidence`
- `ai_relevance`
- `ai_quality`
- `ai_risk`
- `ai_confidence`
- `ai_decision`
- `ai_recommended_status`
- `ai_summary`
- `ai_rationale`
- `ai_reviewer`
- `ai_reviewed_at`

병합:

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh merge-ai-discovery \
  --out .agents/skills-batch-ops/runs/<timestamp>/candidates.ai.tsv \
  --manifest .agents/skills-batch-ops/runs/<timestamp>/review_manifest.tsv \
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

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh prepare-ai-reviews \
  --manifest .agents/skills-batch-ops/runs/<timestamp>/review_manifest.tsv \
  --content-report .agents/skills-batch-ops/runs/<timestamp>/review_content.tsv \
  --project-intent .agents/skills-batch-ops/runs/<timestamp>/project_intent.ai.json \
  --out .agents/skills-batch-ops/runs/<timestamp>/review_ai.queue.tsv
```

### 5) AI 심사 결과 병합/반영

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh merge-ai-reviews \
  --out .agents/skills-batch-ops/runs/<timestamp>/review_ai.merged.tsv \
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

## 워커 운영 규약

- discovery 워커: 채널별 탐색 수행 후 candidate TSV 출력
- review 워커: 후보별 적합성/품질/리스크를 평가하고 `ai_recommended_status` 출력
- 워커는 한 번에 하나의 `skill_ref` 또는 작은 배치만 처리하여 컨텍스트 오염을 줄입니다.
- 워커 실패 시 해당 입력만 재시도합니다.

## 승인/설치 체크리스트

설치 직전 최소 점검:

1. `review_content.tsv`에서 설치 대상 후보가 `gate_pass`인지
2. `review_manifest.ai.tsv`에서 상태가 `approved`인지
3. 승인 근거(`review_notes`, `ai_summary`, `ai_rationale`)가 남아 있는지

## Deprecated

아래 커맨드는 AI-only 재설계에서 제거되었습니다.

- `collect-find`
- `collect-top`
- `collect-github`
- `import-web`
- `merge`
- `collect`

필요하면 `run` + `prepare-ai-discovery` + 워커 + `merge-ai-discovery`로 대체합니다.
