---
name: skills-batch-ops
description: 프로젝트에 필요한 스킬을 3채널(find-skills/인기/웹)로 탐색해 합집합 후보를 만들고, 실제 SKILL.md 본문 검토와 유사 스킬 비교를 거쳐 최적 조합만 설치할 때 사용하는 Markdown 지시형 스킬입니다.
---

# Skills Batch Ops

`skills-batch-ops`는 아래 6단계를 고정으로 수행하는 문서 지시형 스킬입니다.

1. 프로젝트 분석
2. `find-skills` 기반 후보 탐색
3. 인기/사용량 기반 후보 탐색
4. 인터넷 검색 기반 후보 탐색
5. 합집합 병합 + 실제 `SKILL.md` 본문 검토 + 유사/중복 후보 대표 선정
6. 최종 승인 후보 설치

## 실행 원칙

- 이 스킬은 문서 지시만 제공합니다. 스킬 내부 실행 스크립트 의존 경로를 만들지 마세요.
- 탐색 채널 `find`, `popular`, `web` 3개를 모두 시도하세요.
- 채널이 막히면 억지로 채우지 말고 `blocked`로 기록하세요.
- 후보 병합은 교집합이 아니라 합집합 기준으로 수행하세요.
- 스킬 이름만 보고 설치하지 말고, 반드시 실제 `SKILL.md` 본문을 확인하세요.
- 유사 기능군에서는 대표 스킬을 선정하고 나머지는 대체안으로 남기세요.
- 설치 전에는 반드시 dry-run 계획을 먼저 제시하세요.
- 정보가 부족해도 질문을 남발하지 말고, 합리적 기본 가정을 적용한 뒤 `가정/영향`을 기록하세요.
- 본 스킬의 결과물 구조는 `SKILL.md`와 `references/*.md`만 허용합니다.

## 기본 산출물

실행 중 아래 문서를 생성/갱신하세요.

- `project_profile.md`
- `candidates.find.md`
- `candidates.popular.md`
- `candidates.web.md`
- `candidates.merged.md`
- `review.content.md`
- `review.manifest.md`
- `install.plan.md`
- `install.result.md`

템플릿은 `references/report-templates.md`를 사용하세요.

## Step 1) 프로젝트 분석

프로젝트 목표, 기술 스택, 제약사항을 먼저 정리하세요.

- 코드/문서에서 핵심 키워드(도메인, 언어, 런타임, 배포환경)를 추출합니다.
- 설치 가능한 스킬 수 상한(예: 최대 5개)과 우선순위(안정성/속도/범용성)를 정합니다.
- 사용자 입력이 부족하면 기본값을 사용하되 `가정/영향`을 남깁니다.

결과는 `project_profile.md`로 정리하세요.

## Step 2) `find-skills` 기반 후보 탐색

`find-skills`를 이용해 프로젝트 맞춤 후보를 수집하세요.

- 필요 시 `npx --yes skills add vercel-labs/skills --skill find-skills -y`로 준비합니다.
- 프로젝트 키워드 기반 질의를 2~3개 실행합니다.
- raw 결과와 함께 `owner/repo@skill`, 설치 지표, 한 줄 근거를 정리합니다.
- 채널 수행 결과를 `done | blocked`로 기록하고, `blocked`면 원인/영향을 함께 남깁니다.

결과는 `candidates.find.md`로 정리하세요.

## Step 3) 인기/사용량 기반 후보 탐색

공개 인기 목록에서 프로젝트와 맞는 스킬을 수집하세요.

- 인기 페이지/목록에서 후보를 추립니다.
- 단순 인기만으로 승인하지 말고 프로젝트 관련성을 함께 기록합니다.
- 각 후보에 근거 URL을 남깁니다.
- 지표 정의(예: installs, ranking, stars)와 확인 시각을 남깁니다.
- 채널 수행 결과를 `done | blocked`로 기록하고, `blocked`면 원인/영향을 함께 남깁니다.

결과는 `candidates.popular.md`로 정리하세요.

## Step 4) 인터넷 검색 기반 후보 탐색

일반 웹 검색으로 추가 후보를 수집하세요.

- 블로그, 문서, GitHub, 커뮤니티 글 등에서 후보를 찾습니다.
- 최신성/신뢰도를 보고 우선순위를 나눕니다.
- 각 후보에 근거 URL, 왜 적합한지 한 줄 설명을 남깁니다.
- 채널 수행 결과를 `done | blocked`로 기록하고, `blocked`면 원인/영향을 함께 남깁니다.

결과는 `candidates.web.md`로 정리하세요.

## Step 5) 합집합 병합 + 실제 `SKILL.md` 본문 검토 + 유사/중복 정리

2~4단계에서 모은 후보를 합집합으로 병합한 뒤, 각 후보의 실제 `SKILL.md`를 확인하고 유사 후보를 정리하세요.

- 우선 후보 병합표를 `candidates.merged.md`에 합집합 기준으로 만듭니다.
- 각 후보에 대해 실제 `SKILL.md`를 찾아 읽습니다.
- 아래 항목을 반드시 확인하세요:
  - frontmatter `name`, `description` 유효성
  - 본문이 구체적 워크플로를 제공하는지
  - placeholder(`TODO`, `TBD`, `PLACEHOLDER`) 과다 여부
  - 프로젝트 키워드와의 실질 적합성
- 유사/중복 후보를 기능 기준으로 클러스터링하고 대표 스킬을 선정합니다.
- 동일 기능군에서 여러 스킬을 설치하려면 보완 관계를 근거로 제시하세요.

검토 기준 상세는 `references/skill-content-review-rubric.md`를 사용하세요.

검토 결과:

- `review.content.md`: 후보별 본문 검토 상세
- `review.manifest.md`: `approved | pending | rejected` 최종 판정과 선정/대체안 기록

권장 판정 규칙:

- `approved`: 본문 검토 통과 + 유사군 대표 선정 통과 + 프로젝트 적합성 높음
- `pending`: 본문은 양호하지만 근거나 적합성, 실행 가능성 보완 필요
- `rejected`: 본문 검토 실패 또는 프로젝트와 부적합

## Step 6) 필요한 스킬 설치

설치는 `review.manifest.md`에서 `approved`만 대상으로 진행하세요.

1. 먼저 `install.plan.md`에 dry-run 계획을 작성합니다.
2. 승인된 항목별 설치 명령을 준비합니다.
3. 실설치 실행 후 `install.result.md`에 성공/실패/원인/재시도 계획을 기록합니다.

명령 예시:

```bash
npx --yes skills add <owner/repo> --skill <skill-name> -y
```

## 품질 게이트

- 3개 탐색 채널은 모두 시도하되, 실패/차단 시 `blocked` 기록과 영향 보고가 있으면 완료로 처리할 수 있습니다.
- 실제 `SKILL.md`를 읽지 않은 후보는 `approved`로 올리지 마세요.
- 유사군 내 다중 `approved`는 보완 관계 근거가 없으면 허용하지 마세요.
- 설치 실패를 숨기지 말고 `install.result.md`에 그대로 기록하세요.
- 테스트/실행이 막힌 경우, 막힌 원인과 영향 범위를 분리해서 보고하세요.

## 최종 보고 형식

최종 응답은 아래 순서를 기본으로 사용하세요.

1. 프로젝트 분석 요약
2. 채널별 탐색 결과(find/popular/web)
3. 합집합 병합 및 유사/중복 정리 결과(대표/대체안)
4. `SKILL.md` 본문 검토 요약(통과/실패 사유)
5. 설치 계획 또는 설치 결과
6. 남은 리스크/추가 확인 항목

## References

- `references/source-discovery-guide.md`
- `references/skill-content-review-rubric.md`
- `references/report-templates.md`
