---
name: skills-batch-ops
description: 운영형 배치 워크플로우로 프로젝트 요구사항 분석, 다중 채널(Find/Top/GitHub/Web) 후보 수집, 리뷰 매니페스트 승인 게이트, 승인 기반 설치, 감사 로그까지 일괄 수행합니다.
---

# Skills Batch Ops v3

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
6. 리뷰 매니페스트 승인 (`review_manifest.tsv`에서 `status=approved` 지정)
7. 승인된 항목만 설치 (`install-approved`)
8. 설치 후 감사 로그 확인 (`audit.log`)

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
- 승인 대상은 가능한 한 최소 집합 유지
- 설치 후 `audit.log` 확인
- 검증/재실행 시 기존 run 디렉터리 재사용 금지 (`--out-dir`로 항상 새 경로 지정 권장)

## Fallback

- `skills.sh` 파싱 실패 시: `collect-find` + `collect-github`로 후보를 유지
- `gh` 실패 시: GitHub 채널은 경고 후 건너뛰고 나머지 채널 진행
- 전 채널 후보 0건이면 실패로 종료하여 잘못된 설치 방지
