# Report Templates

아래 템플릿을 복사해서 실행 문서를 작성합니다.

## 1) `project_profile.md`

```markdown
# Project Profile
- generated_at_utc: <YYYY-MM-DDTHH:MM:SSZ>
- project_root: <abs-path>

## Goal
- <project goal>

## Stack Signals
- language/runtime: <...>
- package/tooling: <...>
- deploy/runtime: <...>

## Constraints
- budget/time/security/compliance constraints

## Assumptions
- assumption: <...>
- impact: <...>
```

## 2) `candidates.<channel>.md`

```markdown
# Candidates (<find|popular|web>)
- channel_status: <done|blocked>
- checked_at_utc: <YYYY-MM-DDTHH:MM:SSZ>
- block_reason: <optional, if blocked>

| skill_ref | signal | evidence_url | fit_note |
|---|---|---|---|
| owner/repo@skill-name | installs=12345 | https://... | <why fit> |
```

## 3) `inventory.installed.md`

```markdown
# Installed Skills Inventory
- inventory_status: <done|blocked>
- checked_at_utc: <YYYY-MM-DDTHH:MM:SSZ>
- command: <skills list command used>
- block_reason: <optional, if blocked>

| skill_ref | installed_state | origin | notes |
|---|---|---|---|
| owner/repo@skill-name | installed | installed | <optional notes> |
```

## 4) `candidates.merged.md`

```markdown
# Candidates Merged

| skill_ref | origin | installed_state | methods | method_count | evidence_urls | cluster_key | fit_note |
|---|---|---|---|---:|---|---|---|
| owner/repo@skill-name | both | installed | find,popular,web | 3 | <url1>, <url2> | reliability-observability | <summary> |
```

## 5) `review.content.md`

```markdown
# Content Review

| skill_ref | origin | installed_state | skill_md_url | content_status | fit_level | cluster_key | selection | reason |
|---|---|---|---|---|---|---|---|---|
| owner/repo@skill-name | both | installed | https://raw.../SKILL.md | passed | high | reliability-observability | selected | <detailed reason> |
```

## 6) `review.manifest.md`

```markdown
# Review Manifest

| skill_ref | origin | installed_state | method_count | cluster_key | selection | content_status | final_status | target_action | rationale |
|---|---|---|---:|---|---|---|---|---|---|
| owner/repo@skill-name | both | installed | 3 | reliability-observability | selected | passed | approved | keep | <유지 근거> |
| owner/repo@new-skill | discovered | not_installed | 2 | reliability-observability | selected | passed | approved | install | <신규 도입 근거> |
| owner/repo@old-skill | installed | installed | 0 | reliability-observability | alternate | passed | pending | remove | <기능 중복 제거> |
| owner/repo@unknown | discovered | not_installed | 1 | payment | hold | passed | pending | hold | <근거 보완 필요> |
```

## 7) `install.plan.md`

````markdown
# Install Plan (Dry-run)

## Current Installed Set
- owner/repo@skill-name
- owner/repo@old-skill

## Target Final Set
- owner/repo@skill-name
- owner/repo@new-skill

## Action Summary
- keep: owner/repo@skill-name
- install: owner/repo@new-skill
- remove: owner/repo@old-skill
- hold: owner/repo@unknown

## Preflight
```bash
npx --yes skills --help
```

## Install Commands
```bash
npx --yes skills add owner/repo --skill skill-name -y
npx --yes skills add owner/repo --skill new-skill -y
```

## Remove Commands
```bash
npx --yes skills remove owner/repo --skill old-skill -y
```

## Risk Check
- compatibility: <...>
- rollback: <...>
````

## 8) `install.result.md`

```markdown
# Install Result

| skill_ref | target_action | command | status | notes |
|---|---|---|---|---|
| owner/repo@skill-name | keep | <none> | kept | 기존 설치 유지 |
| owner/repo@new-skill | install | npx --yes skills add owner/repo --skill new-skill -y | installed | ok |
| owner/repo@old-skill | remove | npx --yes skills remove owner/repo --skill old-skill -y | removed | ok |
| owner/repo@unknown | hold | <none> | skipped_hold | 근거 보완 후 재검토 |
```
