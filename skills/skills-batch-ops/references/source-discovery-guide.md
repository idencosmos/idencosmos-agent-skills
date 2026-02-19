# Source Discovery Guide

`skills-batch-ops`의 탐색 단계(2~4)를 일관되게 수행하기 위한 가이드입니다.

## 1) 공통 규칙

- 후보 식별자는 항상 `owner/repo@skill` 형식을 사용합니다.
- 각 후보에는 최소 1개의 근거 URL을 남깁니다.
- 각 후보에는 프로젝트 적합성 한 줄 설명(`fit_note`)을 남깁니다.
- 동일 후보가 여러 채널에서 나오면 채널 수(`method_count`)를 누적합니다.

## 2) find-skills 채널

권장 명령:

```bash
npx --yes skills add vercel-labs/skills --skill find-skills -y
npx --yes skills find "<project keyword query>"
```

수집 포인트:

- 상위 결과 위주로 후보를 추출합니다.
- 설치 수치가 보이면 함께 기록합니다.
- 명령어와 질의문을 문서에 남겨 재현 가능하게 만듭니다.

## 3) 인기/사용량 채널

수집 포인트:

- 공개 인기 목록의 후보를 추립니다.
- 인기 지표(예: installs, ranking)가 있으면 함께 기록합니다.
- 인기만 높고 프로젝트와 무관하면 `pending` 또는 `rejected` 후보로 표시합니다.

## 4) 인터넷 검색 채널

수집 포인트:

- 공식 문서, GitHub, 실사용 사례 글을 우선합니다.
- 근거 URL과 함께 "왜 이 프로젝트에 맞는지"를 반드시 기록합니다.
- 최신성이 중요한 경우 확인 날짜를 함께 적습니다.

## 5) 병합 규칙

병합 시 권장 필드:

- `skill_ref`
- `repo`
- `skill`
- `methods` (예: `find,popular,web`)
- `method_count`
- `evidence_urls`
- `fit_note`

권장 우선순위:

1. `method_count`가 높은 후보
2. 프로젝트 적합성이 높은 후보
3. 근거 품질이 높은 후보(공식 문서/검증 가능한 출처)
