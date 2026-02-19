---
name: skills-batch-ops
description: 프로젝트에 맞는 스킬을 찾아 설치해야 할 때 사용합니다. 프로젝트 분석 후 (1) find-skills 결과, (2) 인기/사용량 기반 후보, (3) 인터넷 검색 후보를 함께 수집하고, 후보별 실제 SKILL.md 본문까지 검토한 뒤 승인 항목만 설치합니다.
---

# Skills Batch Ops

`skills-batch-ops`는 아래 1~6 단계를 하나의 파이프라인으로 고정합니다.

1. 프로젝트 분석
2. `find-skills` 기반 후보 수집
3. 사용자 수/인지도(인기 목록) 기반 후보 수집
4. 인터넷 검색 기반 후보 수집
5. 2~4번 후보의 실제 `SKILL.md` 내용 검증
6. 승인(`approved`) 후보 설치

핵심 원칙:
- 3개 탐색 채널(`find`, `popular`, `web`)을 모두 사용합니다.
- 이름만으로 설치하지 않고 반드시 `SKILL.md` 실체를 검증합니다.
- 프로젝트 키워드와 무관한 후보는 기본적으로 `approved`에 올리지 않습니다.
- 설치 전에는 기본적으로 `--dry-run`을 먼저 실행합니다.
- 기본 `run`은 3개 채널 중 하나라도 비어 있으면 실패합니다. 예외가 필요할 때만 `--allow-empty-sources`를 사용합니다.

## Script Path

```bash
SBP_SCRIPT="${SBP_SCRIPT:-$HOME/.agents/skills/skills-batch-ops/scripts/skills_batch_pipeline.py}"
if [[ ! -x "$SBP_SCRIPT" && -x "$(pwd)/idencosmos-agent-skills/skills/skills-batch-ops/scripts/skills_batch_pipeline.py" ]]; then
  SBP_SCRIPT="$(pwd)/idencosmos-agent-skills/skills/skills-batch-ops/scripts/skills_batch_pipeline.py"
fi
if [[ ! -x "$SBP_SCRIPT" && -x "$(pwd)/skills/skills-batch-ops/scripts/skills_batch_pipeline.py" ]]; then
  SBP_SCRIPT="$(pwd)/skills/skills-batch-ops/scripts/skills_batch_pipeline.py"
fi
if [[ ! -x "$SBP_SCRIPT" ]]; then
  echo "error: set SBP_SCRIPT to skills-batch-ops/scripts/skills_batch_pipeline.py (or idencosmos-agent-skills/... path)" >&2
  exit 1
fi
```

## Preflight (필수)

```bash
# 1) discovery 명령이 실행 가능한지 확인
npx --yes skills find "test" >/dev/null

# 2) find-skills 스킬 설치가 필요한 환경이면 먼저 설치
# (이미 설치되어 있으면 skip 가능)
npx skills add vercel-labs/skills --skill find-skills -y

# 3) 파이프라인 엔트리포인트 확인
python3 "$SBP_SCRIPT" --help >/dev/null
```

## Quick Start (End-to-End)

아래 예시는 1~6단계를 한 번에 실행합니다. 실행 전에 2~4단계 입력 파일(`find_output.txt`, `popular_output.html`, `web_candidates.tsv`)을 먼저 준비하세요.

```bash
RUN_DIR=".agents/skills-batch-ops/runs/$(date -u +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_DIR"

python3 "$SBP_SCRIPT" run \
  --project-root "$(pwd)" \
  --run-dir "$RUN_DIR" \
  --find-input "$RUN_DIR/find_output.txt" \
  --popular-input "$RUN_DIR/popular_output.html" \
  --web-input "$RUN_DIR/web_candidates.tsv" \
  --min-methods 2 \
  --min-project-keyword-hits 1 \
  --limit 8 \
  --dry-run
```

라이브 수집(2~4단계 자동화)부터 설치 전 dry-run까지 한 번에 하려면:

```bash
python3 "$SBP_SCRIPT" collect-sources-live \
  --project-root "$(pwd)" \
  --run-dir "$RUN_DIR" \
  --find-command "npx --yes skills find" \
  --find-timeout-sec 45 \
  --run-after-collect \
  --min-methods 2 \
  --min-project-keyword-hits 1 \
  --limit 8 \
  --dry-run
```

`run`이 생성하는 기본 산출물:
- `project_profile.tsv`
- `candidates.find.tsv`
- `candidates.popular.tsv`
- `candidates.web.tsv`
- `candidates.merged.tsv`
- `review_content.tsv`
- `review_manifest.ai.tsv`
- `install.report.tsv`

## Input Contracts

### `--find-input`
- `find-skills` 실행 결과 텍스트 파일.
- 라인 중 `owner/repo@skill` 패턴과 `installs` 수치를 자동 추출합니다.
- `find-skills` 실행 로그 원문을 그대로 저장하는 것을 권장합니다.

### `--popular-input`
- 인기 스킬 페이지 HTML/텍스트 덤프 파일.
- `source`, `skillId`, `installs` 필드를 파싱합니다.
- `installs`가 있는 공개 인기 목록(사용량/인지도 지표)을 사용하세요.

### `--web-input`
- 인터넷 검색 결과를 정리한 TSV/CSV 파일.
- 권장 헤더:

```tsv
skill_ref	repo	skill	installs	evidence_url	evidence_note
vercel-labs/skills@find-skills	vercel-labs/skills	find-skills	238456	https://...	Official discovery helper
```

- `skill_ref`만 있어도 되고, `repo+skill` 조합으로도 입력할 수 있습니다.
- `evidence_url`은 실제 근거 페이지 URL을 기록하고, `evidence_note`에는 왜 프로젝트에 맞는지 한 줄 근거를 남깁니다.

## Source Collection Checklist (2~4단계)

1. `find-skills` 결과 확보:
- 프로젝트 요구를 기준으로 `find-skills`를 실행해 raw 결과를 `find_output.txt`에 저장합니다.
- 기본 명령은 `npx --yes skills find "<project query>"`이며, `vercel-labs/skills@find-skills` 계열 출력 포맷(`owner/repo@skill`, installs)을 그대로 보존합니다.

2. 인기/사용량 기반 후보 확보:
- 공개 인기 목록에서 후보를 수집해 `popular_output.html`(또는 text dump)로 저장합니다.

3. 인터넷 검색 기반 후보 확보:
- 검색 결과를 `web_candidates.tsv`로 정규화하며, 각 행에 `evidence_url`을 채웁니다.

4. 최소 품질 조건:
- `find/popular/web` 3채널을 모두 채웁니다.
- 후보마다 `owner/repo@skill` 식별이 가능해야 합니다.

## Commands

### `collect-sources-live` (신규)

```bash
python3 "$SBP_SCRIPT" collect-sources-live \
  --project-root "$(pwd)" \
  --run-dir "$RUN_DIR"
```

자동 수행 항목:

1. 프로젝트 분석(`project_profile.tsv`)
2. `npx --yes skills find <query>` 실행 후 `find_output.txt` 생성
3. `https://skills.sh/` 수집 후 `popular_output.html` 생성
4. GitHub 검색 API 기반 인터넷 후보 `web_candidates.tsv` 생성 (API 실패/응답 0건 시 `skills find` 기반 웹 후보로 자동 fallback)
5. `candidates.find.tsv`, `candidates.popular.tsv`, `candidates.web.tsv`까지 정규화

주요 옵션:

- `--find-query`: find 검색어 고정
- `--web-query`: 웹 검색어 추가(여러 번 지정 가능)
- `--find-command`: find 실행 명령 커스터마이즈 (기본 `npx --yes skills find`)
- `--find-timeout-sec`: find 명령 타임아웃 초 (기본 `45`)
- `--web-mode seed --web-seed-input <path>`: 인터넷 검색 대신 사전 정리 TSV 사용(오프라인/테스트용)
- 기본 `web-mode=github`에서 GitHub API 호출이 실패하거나 후보가 0건이면 `skills find` 기반 웹 후보 수집으로 자동 fallback합니다.
- `--allow-empty-sources`: 비어 있는 채널 허용
- `--run-after-collect`: 수집 직후 `run` 단계 자동 실행
- `--min-project-keyword-hits`: 승인 최소 프로젝트 키워드 히트 수 (기본 `1`, 느슨하게 하려면 `0`)

### `analyze-project`

```bash
python3 "$SBP_SCRIPT" analyze-project \
  --project-root "$(pwd)" \
  --out "$RUN_DIR/project_profile.tsv"
```

프로젝트 기술 스택/키워드를 추출합니다.

### `collect-find`

```bash
python3 "$SBP_SCRIPT" collect-find \
  --input "$RUN_DIR/find_output.txt" \
  --out "$RUN_DIR/candidates.find.tsv"
```

### `collect-popular`

```bash
python3 "$SBP_SCRIPT" collect-popular \
  --input "$RUN_DIR/popular_output.html" \
  --out "$RUN_DIR/candidates.popular.tsv"
```

### `collect-web`

```bash
python3 "$SBP_SCRIPT" collect-web \
  --input "$RUN_DIR/web_candidates.tsv" \
  --out "$RUN_DIR/candidates.web.tsv"
```

### `merge-candidates`

```bash
python3 "$SBP_SCRIPT" merge-candidates \
  --out "$RUN_DIR/candidates.merged.tsv" \
  "$RUN_DIR/candidates.find.tsv" \
  "$RUN_DIR/candidates.popular.tsv" \
  "$RUN_DIR/candidates.web.tsv"
```

### `validate-content`

```bash
python3 "$SBP_SCRIPT" validate-content \
  --candidates "$RUN_DIR/candidates.merged.tsv" \
  --out "$RUN_DIR/review_content.tsv"
```

각 후보의 원격 저장소에서 `SKILL.md`를 가져와 frontmatter(`name`, `description`)를 점검합니다.
검증은 이름 확인을 넘어서 본문 품질도 함께 확인합니다.

- 경로 후보: `main|master` 브랜치의 `/SKILL.md`, `/skills/<skill>/SKILL.md`, `/<skill>/SKILL.md`

- frontmatter `name` / `description` 유효성
- 본문 길이(너무 짧은 문서 차단)
- 본문 placeholder(TODO/TBD/PLACEHOLDER) 포함 여부
- 본문 기반 `content_keywords` 추출 (프로젝트 키워드 매칭용)

### `build-manifest`

```bash
python3 "$SBP_SCRIPT" build-manifest \
  --merged "$RUN_DIR/candidates.merged.tsv" \
  --content-report "$RUN_DIR/review_content.tsv" \
  --project-profile "$RUN_DIR/project_profile.tsv" \
  --out "$RUN_DIR/review_manifest.ai.tsv" \
  --min-methods 2 \
  --min-project-keyword-hits 1 \
  --limit 8
```

`content_status=passed` + 멀티소스 조건(`min_methods`) + 프로젝트 키워드 조건(`min_project_keyword_hits`)을 만족한 항목만 `approved`로 생성합니다.
`project_keyword_hits`는 프로젝트 키워드와 스킬 본문/설명 기반 매칭 근거를 제공합니다. 키워드 게이트를 완화하려면 `--min-project-keyword-hits 0`을 사용하세요.

### `install-manifest`

```bash
python3 "$SBP_SCRIPT" install-manifest \
  --manifest "$RUN_DIR/review_manifest.ai.tsv" \
  --report "$RUN_DIR/install.report.tsv" \
  --dry-run
```

실설치 시 `--dry-run`을 제거하세요. 설치 전에는 승인 항목을 먼저 눈으로 확인합니다.

```bash
awk -F '\t' 'NR==1 || $11=="approved"' "$RUN_DIR/review_manifest.ai.tsv"
```

## Decision Rules

- `SKILL.md` 검증 실패(`content_status!=passed`)는 `rejected`.
- 검증 통과 + `method_count >= min_methods` + `project_keyword_hits >= min_project_keyword_hits`만 `approved`.
- 기본값은 `min_project_keyword_hits=1`이며, 프로젝트 적합성 게이트를 완화하려면 `--min-project-keyword-hits 0`을 사용합니다.
- `limit` 초과 승인 후보는 `pending`으로 조정합니다.

## Review Output Format

최종 보고는 아래 형식을 기본으로 사용합니다.

```markdown
# Skills Batch Ops 결과

## Source Coverage
- find: <count>
- popular: <count>
- web: <count>

## Content Review
- passed: <count>
- failed: <count>
- failed reasons top3: <reason1>, <reason2>, <reason3>

## Install Plan
- approved: <count>
- pending: <count>
- rejected: <count>
- dry-run report: <path>

## Installed (or Dry-run) Skills
- owner/repo@skill - rationale
```

## Legacy Gate-Only Script

기존 외부 오케스트레이터 호환이 필요하면 아래 레거시 스크립트를 계속 사용할 수 있습니다.

- `scripts/skills_batch_ops.sh`
- 주요 커맨드: `verify-parallel-proof`, `install-approved`

새 파이프라인(`skills_batch_pipeline.py`)이 기본 경로이며, 레거시는 호환 목적입니다.

## Smoke Test

```bash
bash "$HOME/.agents/skills/skills-batch-ops/tests/test_skills_batch_ops.sh"
bash "$HOME/.agents/skills/skills-batch-ops/tests/test_skills_batch_pipeline.sh"
python3 "$HOME/.agents/skills/skills-batch-ops/scripts/skills_batch_pipeline.py" --help
```
