---
name: skills-batch-ops
description: 프로젝트 분석 후 find-skills, 인기/사용량 기반 후보, 인터넷 검색 후보를 함께 수집하고, 각 후보의 실제 SKILL.md 내용을 검증한 뒤 승인 항목만 설치합니다. 멀티소스 탐색+내용 검토+설치를 한 번에 실행할 때 사용합니다.
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
- 설치 전에는 기본적으로 `--dry-run`을 먼저 실행합니다.

## Script Path

```bash
SBP_SCRIPT="${SBP_SCRIPT:-$HOME/.agents/skills/skills-batch-ops/scripts/skills_batch_pipeline.py}"
if [[ ! -x "$SBP_SCRIPT" && -x "$(pwd)/skills/skills-batch-ops/scripts/skills_batch_pipeline.py" ]]; then
  SBP_SCRIPT="$(pwd)/skills/skills-batch-ops/scripts/skills_batch_pipeline.py"
fi
if [[ ! -x "$SBP_SCRIPT" ]]; then
  echo "error: set SBP_SCRIPT to skills-batch-ops/scripts/skills_batch_pipeline.py" >&2
  exit 1
fi
```

## Quick Start (End-to-End)

아래 예시는 1~6단계를 한 번에 실행합니다.

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

### `--popular-input`
- 인기 스킬 페이지 HTML/텍스트 덤프 파일.
- `source`, `skillId`, `installs` 필드를 파싱합니다.

### `--web-input`
- 인터넷 검색 결과를 정리한 TSV/CSV 파일.
- 권장 헤더:

```tsv
skill_ref	repo	skill	installs	evidence_url	evidence_note
vercel-labs/skills@find-skills	vercel-labs/skills	find-skills	238456	https://...	Official discovery helper
```

- `skill_ref`만 있어도 되고, `repo+skill` 조합으로도 입력할 수 있습니다.

## Commands

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

### `build-manifest`

```bash
python3 "$SBP_SCRIPT" build-manifest \
  --merged "$RUN_DIR/candidates.merged.tsv" \
  --content-report "$RUN_DIR/review_content.tsv" \
  --project-profile "$RUN_DIR/project_profile.tsv" \
  --out "$RUN_DIR/review_manifest.ai.tsv" \
  --min-methods 2 \
  --limit 8
```

`content_status=passed` + 멀티소스 조건(`min_methods`)을 만족한 항목만 `approved`로 생성합니다.

### `install-manifest`

```bash
python3 "$SBP_SCRIPT" install-manifest \
  --manifest "$RUN_DIR/review_manifest.ai.tsv" \
  --report "$RUN_DIR/install.report.tsv" \
  --dry-run
```

실설치 시 `--dry-run`을 제거하세요.

## Decision Rules

- `SKILL.md` 검증 실패(`content_status!=passed`)는 `rejected`.
- 검증 통과 + `method_count >= min_methods`만 `approved`.
- `limit` 초과 승인 후보는 `pending`으로 조정합니다.

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
