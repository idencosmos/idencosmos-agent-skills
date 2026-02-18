---
name: skills-batch-ops
description: 운영형 배치 워크플로우로 프로젝트 요구사항 분석, 다중 채널(Find/Top/GitHub/Web) 후보 수집, 리뷰 매니페스트 승인 게이트, 승인 기반 설치, 감사 로그까지 일괄 수행합니다.
---

# Skills Batch Ops v4

이 스킬은 단발성 설치가 아니라, **재현 가능한 운영 절차**로 스킬 탐색/검토/설치를 수행할 때 사용합니다.

## When To Use

- "프로젝트 요구사항에 맞는 스킬을 일괄 탐색하고 설치하고 싶다"
- "Find 기반 + Top 스킬 기반 + 인터넷 검토를 같이 하고 싶다"
- "후보 근거를 남기고 승인된 항목만 설치하고 싶다"
- "여러 프로젝트에서 같은 프로세스를 반복 실행하고 싶다"

## Core Workflow

1. 프로젝트 요구사항 분석 (`project_signals.md`, `query_seeds.txt` 생성)
2. Find 채널 수집 (`collect-find`)
3. Top 스킬 채널 수집 (`collect-top`)
4. 인터넷 검토 채널 수집 (`collect-github`, `import-web`)
5. 채널 병합/점수화 (`merge`)
6. 스킬명 + 본문 검증 (`validate-content`)
7. AI 검토 큐 생성 (`prepare-ai-reviews`)
8. 멀티 에이전트 의미 기반 검토 (각 `skill_ref`를 개별 에이전트가 처리)
9. AI 분산 결과 병합 (`merge-ai-reviews`)
10. AI 결과를 매니페스트에 반영 (`apply-ai-reviews`)
11. 리뷰 매니페스트 승인 (`review_manifest.tsv` 또는 `review_manifest.ai.tsv`에서 `status=approved` 지정)
12. 승인된 항목만 설치 (`install-approved`)
13. 설치 후 감사 로그 확인 (`audit.log`)

## Fast Path

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh run \
  --project-root "$(pwd)" \
  --top 30 \
  --find-query "python testing" \
  --github-query "python observability"
```

생성된 `review_manifest.tsv`에서 승인 후 설치:

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh install-approved \
  --manifest .agents/skills-batch-ops/runs/<timestamp>/review_manifest.tsv
```

본문 검증 리포트 생성:

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh validate-content \
  --manifest .agents/skills-batch-ops/runs/<timestamp>/review_manifest.tsv \
  --query-file .agents/skills-batch-ops/runs/<timestamp>/query_seeds.txt
```

AI 검토 큐 생성:

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh prepare-ai-reviews \
  --manifest .agents/skills-batch-ops/runs/<timestamp>/review_manifest.tsv \
  --content-report .agents/skills-batch-ops/runs/<timestamp>/review_content.tsv \
  --status pending
```

## Command Reference

### `run`

전체 파이프라인 실행.

옵션:

- `--project-root PATH` (기본: 현재 디렉터리)
- `--out-dir PATH` (기본: `<project-root>/.agents/skills-batch-ops/runs/<timestamp>/`)
- `--top N` (`collect-top` 상위 개수)
- `--find-query "..."` (복수 지정 가능)
- `--github-query "..."` (복수 지정 가능)
- `--web-links-file PATH` (웹 검색 결과 URL 파일)

### `collect-find`

`npx skills find` 기반 후보 수집.

출력 컬럼:
- `skill_ref`
- `find_installs`
- `find_queries`

레거시 호환:
- `collect`는 `collect-find` 별칭으로 유지.

### `collect-top`

`https://skills.sh/` 임베딩 데이터에서 상위 스킬 후보 수집.

출력 컬럼:
- `skill_ref`
- `top_installs`
- `top_rank`

### `collect-github`

GitHub 저장소 검색 후, `npx skills add <repo> --list`로 실제 스킬 후보 추출.

옵션:

- `--github-query "..."` (반복)
- `--limit N` (쿼리당 저장소 수)

출력 컬럼:
- `skill_ref`
- `repo`
- `skill`
- `github_stars`
- `github_updated_at`
- `github_queries`

### `import-web`

웹 검색 URL 파일에서 후보를 가져옵니다.

지원 URL:

- `https://skills.sh/<owner>/<repo>/<skill>`: 직접 skill_ref 변환
- `https://github.com/<owner>/<repo>`: `--list` 결과 기반 후보 추출

옵션:

- `--web-links-file PATH` (필수)
- `--query-file PATH` (선택, 키워드 필터)

출력 컬럼:
- `skill_ref`
- `repo`
- `skill`
- `web_sources`
- `web_origin`

### `merge`

채널별 결과를 통합하고 `candidates.merged.tsv` + `review_manifest.tsv` 생성.

점수식:

`auto_score = 0.40*query_overlap + 0.35*install_signal + 0.15*repo_health + 0.10*channel_diversity`

### `validate-content`

`review_manifest.tsv` 후보를 대상으로 실제 스킬명과 `SKILL.md` 본문을 1개씩 검증합니다.

- `npx skills add <repo> --list`로 스킬명 존재 확인
- 격리된 임시 워크스페이스에 단일 스킬 설치 후 `SKILL.md` 존재/제목/설명/본문 일부 확인
- `query_seeds.txt` 토큰과 본문 매칭률(`content_overlap`) 계산

옵션:

- `--manifest PATH` (필수)
- `--out PATH` (기본: `<manifest_dir>/review_content.tsv`)
- `--query-file PATH` (기본: `<manifest_dir>/query_seeds.txt`가 있으면 자동 사용)
- `--status pending|approved|rejected|all` (기본: `pending`)
- `--skill-ref REF` (복수 지정 가능, 멀티 에이전트 분할 시 사용)
- `--limit N`

출력 컬럼:
- `skill_ref`
- `repo`
- `skill`
- `manifest_status`
- `auto_score`
- `name_check`
- `install_check`
- `skill_md_check`
- `content_overlap`
- `review_status` (`verified|manual|failed`)
- `skill_title`
- `skill_description`
- `content_preview`
- `review_notes`

### `merge-content-reviews`

여러 에이전트가 생성한 `review_content.*.tsv`를 병합해 단일 리포트로 만듭니다.

옵션:

- `--out PATH` (필수)
- 입력 파일들: `<content_review_1.tsv> <content_review_2.tsv> ...`

동일 `skill_ref`가 여러 파일에 있으면 `review_status` 우선순위(`verified > manual > failed`)로 대표 항목을 선택합니다.

### `prepare-ai-reviews`

`review_manifest.tsv` + `review_content.tsv`를 기준으로 AI 멀티 에이전트 검토 대상을 추려 큐를 생성합니다.

옵션:

- `--manifest PATH` (필수)
- `--content-report PATH` (필수, 보통 `validate-content` 결과)
- `--out PATH` (기본: `<content_report_dir>/review_ai.queue.tsv`)
- `--status pending|approved|rejected|all` (기본: `pending`)
- `--limit N`
- `--include-failed` (`validate-content`에서 `failed`인 후보도 큐에 포함)

출력 컬럼:
- `skill_ref`
- `repo`
- `skill`
- `manifest_status`
- `auto_score`
- `content_overlap`
- `heuristic_status`
- `skill_title`
- `skill_description`
- `content_preview`
- `ai_relevance`
- `ai_quality`
- `ai_risk`
- `ai_confidence`
- `ai_decision` (`approve|hold|reject`)
- `ai_recommended_status` (`approved|pending|rejected`)
- `ai_summary`
- `ai_rationale`
- `ai_reviewer`
- `ai_reviewed_at`

### `merge-ai-reviews`

여러 워커 에이전트가 작성한 AI 검토 TSV를 병합해 단일 AI 검토 결과를 만듭니다.

옵션:

- `--out PATH` (필수)
- 입력 파일들: `<ai_review_worker_1.tsv> <ai_review_worker_2.tsv> ...`

동일 `skill_ref` 중복 시 우선순위:
1. `ai_recommended_status` (`approved > pending > rejected > empty`)
2. `ai_decision` (`approve > hold > reject > empty`)
3. `ai_confidence` (높을수록 우선)

### `apply-ai-reviews`

`merge-ai-reviews` 결과를 `review_manifest.tsv`에 반영해 최종 승인용 매니페스트를 생성합니다.

옵션:

- `--manifest PATH` (필수)
- `--ai-reviews PATH` (필수)
- `--out PATH` (기본: `<manifest_dir>/review_manifest.ai.tsv`)

동작:
- `ai_recommended_status`를 `status`에 반영
- `review_notes`에 AI 요약 메모 추가
- `approved_by`, `approved_at`을 `ai_reviewer`, `ai_reviewed_at`으로 채움

### `install-approved`

`review_manifest.tsv`에서 `status=approved`인 항목만 설치.

- repo 단위로 그룹화해 `npx skills add <repo> --skill ... -y` 실행
- 설치 후 자동 `audit.log` 생성

### `audit`

설치 상태 및 업데이트 점검 로그 생성.

- `npx skills list`
- `npx skills check`

## Review Manifest Schema

`review_manifest.tsv` 고정 컬럼:

1. `skill_ref`
2. `repo`
3. `skill`
4. `channels`
5. `find_installs`
6. `top_installs`
7. `github_stars`
8. `github_updated_at`
9. `query_overlap`
10. `auto_score`
11. `risk_level` (`low|medium|high`)
12. `status` (`pending|approved|rejected`)
13. `review_notes`
14. `approved_by`
15. `approved_at`

## Output Layout

기본 산출물 경로:

`<project-root>/.agents/skills-batch-ops/runs/<timestamp>/`

주요 파일:

- `project_signals.md`
- `query_seeds.txt`
- `candidates.find.tsv`
- `candidates.top.tsv`
- `candidates.github.tsv`
- `candidates.web.tsv` (선택)
- `candidates.merged.tsv`
- `review_manifest.tsv`
- `review_content.tsv` (본문 검증 결과)
- `review_content.workers/*.tsv` (멀티 에이전트 개별 결과, 선택)
- `review_content.merged.tsv` (멀티 에이전트 병합 결과, 선택)
- `review_ai.queue.tsv` (AI 검토 큐)
- `review_ai.workers/*.tsv` (AI 워커 개별 결과)
- `review_ai.merged.tsv` (AI 결과 병합본)
- `review_manifest.ai.tsv` (AI 반영 매니페스트)
- `install.report.tsv` (설치 실행 시)
- `audit.log` (설치 실행 시)

## Internet Review Query Templates

광범위 인터넷 검토 시 예시 쿼리:

- `python testing agent skills`
- `python observability skills.sh`
- `llm evaluation agent skill`
- `prompt engineering claude skills`
- `queue concurrency worker skill`
- `resilience retry timeout skill`

웹 검색 결과 URL은 텍스트 파일로 저장 후 `import-web --web-links-file`에 전달합니다.

## Safety Rules

- 기본 설치는 프로젝트 로컬(`.agents/skills`)을 유지
- `review_manifest.tsv` 승인 전 자동 설치 금지
- 승인 전 `validate-content` 또는 동등한 본문 검증 필수
- 운영 승인 전 `prepare-ai-reviews` + 멀티 에이전트 AI 검토 결과 확인 권장
- 승인 대상은 가능한 한 최소 집합 유지
- 설치 후 `audit.log` 확인
- 검증/재실행 시 기존 run 디렉터리 재사용 금지 (`--out-dir`로 항상 새 경로 지정 권장)

## Multi-Agent Review Pattern

1. `validate-content` 완료 후 AI 큐를 생성합니다.

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh prepare-ai-reviews \
  --manifest .agents/skills-batch-ops/runs/<timestamp>/review_manifest.tsv \
  --content-report .agents/skills-batch-ops/runs/<timestamp>/review_content.tsv \
  --status pending \
  --out .agents/skills-batch-ops/runs/<timestamp>/review_ai.queue.tsv
```

2. 부모 에이전트가 `review_ai.queue.tsv`를 읽고, 각 `skill_ref`마다 개별 워커 에이전트를 병렬 생성합니다.
3. 워커 에이전트는 의미 기반으로 아래 항목을 채워 1행 TSV를 저장합니다.
- `ai_relevance` (프로젝트 맥락 적합도)
- `ai_quality` (스킬 설명/실행 가이드 품질)
- `ai_risk` (오남용/과장/보안/유지보수 위험)
- `ai_confidence`
- `ai_decision` / `ai_recommended_status`
- `ai_summary` / `ai_rationale`
- `ai_reviewer` / `ai_reviewed_at`

4. 부모 에이전트가 워커 결과를 병합합니다.

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh merge-ai-reviews \
  --out .agents/skills-batch-ops/runs/<timestamp>/review_ai.merged.tsv \
  .agents/skills-batch-ops/runs/<timestamp>/review_ai.workers/*.tsv
```

5. 병합 결과를 최종 매니페스트에 반영합니다.

```bash
bash .agents/skills/skills-batch-ops/scripts/skills_batch_ops.sh apply-ai-reviews \
  --manifest .agents/skills-batch-ops/runs/<timestamp>/review_manifest.tsv \
  --ai-reviews .agents/skills-batch-ops/runs/<timestamp>/review_ai.merged.tsv \
  --out .agents/skills-batch-ops/runs/<timestamp>/review_manifest.ai.tsv
```

6. `review_manifest.ai.tsv` 기준으로 설치 승인 여부를 결정합니다.

## Fallback

- `skills.sh` 파싱 실패 시: `collect-find` + `collect-github`로 후보를 유지
- `gh` 실패 시: GitHub 채널은 경고 후 건너뛰고 나머지 채널 진행
- 전 채널 후보 0건이면 실패로 종료하여 잘못된 설치 방지
