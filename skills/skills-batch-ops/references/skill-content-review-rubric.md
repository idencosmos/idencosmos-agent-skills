# Skill Content Review Rubric

후보 스킬을 이름이 아니라 실제 `SKILL.md` 본문으로 검토하기 위한 기준입니다.

## A. 위치 확인

`SKILL.md`를 아래 경로 우선순위로 확인합니다.

1. `/SKILL.md`
2. `/skills/<skill>/SKILL.md`
3. `/<skill>/SKILL.md`

브랜치가 다르면 기본 브랜치에서 다시 확인합니다.

## B. 필수 통과 조건

아래 조건 중 하나라도 실패하면 `content_status=failed`입니다.

1. frontmatter에 `name`, `description`이 존재한다.
2. `name`과 후보 `skill`이 실질적으로 일치한다.
3. 본문에 실행 가능한 워크플로/절차가 있다.
4. 본문이 빈 문서가 아니며 placeholder가 과도하지 않다.

## C. 적합성 평가

아래 4개 축을 평가합니다.

- 목표 적합성: 현재 프로젝트 목표와 직접 관련이 있는가
- 실행 가능성: 현재 환경에서 바로 적용 가능한가
- 안정성: 도입 시 리스크가 큰가
- 유지보수성: 문서/지시가 명확하고 재현 가능한가

평가 레벨:

- `high`: 즉시 도입해도 무방
- `medium`: 보완 후 도입 권장
- `low`: 현 프로젝트에는 부적합

## D. 판정 규칙

권장 규칙:

- `approved`: `content_status=passed` and `method_count >= 2` and 적합성 `high`
- `pending`: `content_status=passed` but 근거/적합성 보완 필요
- `rejected`: `content_status=failed` or 적합성 `low`

## E. 기록 원칙

각 후보마다 아래를 남깁니다.

- 확인한 `SKILL.md` URL
- 통과/실패 사유(한 줄이 아닌 구체 문장)
- 프로젝트와의 관련 키워드
- 최종 판정(`approved|pending|rejected`)
