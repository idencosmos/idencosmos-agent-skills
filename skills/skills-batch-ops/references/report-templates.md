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

## 3) `candidates.merged.md`

```markdown
# Candidates Merged

| skill_ref | methods | method_count | evidence_urls | cluster_key | fit_note |
|---|---|---:|---|---|---|
| owner/repo@skill-name | find,popular,web | 3 | <url1>, <url2> | reliability-observability | <summary> |
```

## 4) `review.content.md`

```markdown
# Content Review

| skill_ref | skill_md_url | content_status | fit_level | cluster_key | selection | reason |
|---|---|---|---|---|---|---|
| owner/repo@skill-name | https://raw.../SKILL.md | passed | high | reliability-observability | selected | <detailed reason> |
```

## 5) `review.manifest.md`

```markdown
# Review Manifest

| skill_ref | method_count | cluster_key | selection | content_status | final_status | rationale |
|---|---:|---|---|---|---|---|
| owner/repo@skill-name | 3 | reliability-observability | selected | passed | approved | <install rationale> |
| owner/repo@other | 2 | reliability-observability | alternate | passed | pending | <selected 후보 대비 중복> |
| owner/repo@bad | 1 | payment | hold | failed | rejected | <content failure reason> |
```

## 6) `install.plan.md`

````markdown
# Install Plan (Dry-run)

## Approved Skills
- owner/repo@skill-name

## Alternates (Not installed now)
- owner/repo@other

## Commands
```bash
npx --yes skills add owner/repo --skill skill-name -y
```

## Risk Check
- compatibility: <...>
- rollback: <...>
````

## 7) `install.result.md`

```markdown
# Install Result

| skill_ref | command | status | notes |
|---|---|---|---|
| owner/repo@skill-name | npx --yes skills add owner/repo --skill skill-name -y | installed | ok |
| owner/repo@other | <none> | skipped_alternate | selected 후보와 기능 중복 |
```
