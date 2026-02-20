# Source Discovery Guide

`skills-batch-ops`의 탐색 단계(2~4)와 합집합 병합/중복 정리를 일관되게 수행하기 위한 가이드입니다.

## 1) 공통 규칙

- 후보 식별자는 항상 `owner/repo@skill` 형식을 사용합니다.
- 각 후보에는 최소 1개의 근거 URL을 남깁니다.
- 각 후보에는 프로젝트 적합성 한 줄 설명(`fit_note`)을 남깁니다.
- 채널별 수행 상태를 `done | blocked`로 기록합니다.
- `blocked` 채널은 오류 메시지와 영향 범위를 함께 기록합니다.
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
- 인기 지표(예: installs, ranking, stars)를 기록하고 확인 시각(`checked_at_utc`)을 남깁니다.
- 인기만 높고 프로젝트와 무관하면 `pending` 또는 `rejected` 후보로 표시합니다.

권장 출처 우선순위:

1. 스킬 공식 레지스트리/공식 목록의 설치 지표
2. GitHub 저장소 지표(stars, 최근 커밋 활동)
3. 커뮤니티 큐레이션 글/목록

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
- `cluster_key` (유사 기능군 식별자)
- `selection_note` (대표 선정 또는 대체 사유)

병합 원칙:

1. 교집합 축소를 하지 말고 3채널 결과의 합집합을 만든다.
2. `skill_ref` 기준으로 중복 제거하고 `methods`, `evidence_urls`를 누적한다.
3. 누락 채널이 있어도 `blocked` 기록이 있으면 다음 단계로 진행한다.

## 6) 유사/중복 후보 정리

클러스터링 기준:

- 해결하려는 핵심 문제(작업 목적)가 같은가
- 제공하는 워크플로/산출물이 사실상 같은가
- 함께 설치 시 충돌하거나 관리 비용만 증가하는가

대표 선정 권장 순서:

1. 프로젝트 적합성
2. `SKILL.md` 본문 품질(절차 명확성/재현성)
3. 근거 신뢰도(공식 문서/검증 가능한 출처)
4. 운영 리스크(의존성, 유지보수 부담)

선정 결과 기록:

- 대표 후보: `selection=selected`
- 중복 대체안: `selection=alternate`
- 검토 보류: `selection=hold`
