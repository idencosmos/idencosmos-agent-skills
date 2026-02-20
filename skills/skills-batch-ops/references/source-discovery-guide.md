# Source Discovery Guide

`skills-batch-ops`의 탐색 단계(2~5)와 합집합 병합/중복 정리를 일관되게 수행하기 위한 가이드입니다.

## 1) 공통 규칙

- 후보 식별자는 항상 `owner/repo@skill` 형식을 사용합니다.
- 각 후보에는 최소 1개의 근거 URL을 남깁니다.
- 각 후보에는 프로젝트 적합성 한 줄 설명(`fit_note`)을 남깁니다.
- 채널별 수행 상태를 `done | blocked`로 기록합니다.
- `blocked` 채널은 오류 메시지와 영향 범위를 함께 기록합니다.
- `blocked` 사유는 가능한 한 표준 코드로 기록합니다(`blocked_cli_hang`, `blocked_network`, `blocked_auth`).
- 동일 후보가 여러 채널에서 나오면 채널 수(`method_count`)를 누적합니다.
- 채널 차단이 있으면 `method_count`는 보정 해석을 적용합니다(아래 6절 참조).
- 최종 통합표에는 아래 상태 필드를 포함합니다.
  - `origin`: `discovered | installed | both`
  - `installed_state`: `installed | not_installed`
  - `target_action`: `keep | install | remove | hold` (검토 후 확정)
  - `channel_health`: `find=<done|blocked>;popular=<done|blocked>;web=<done|blocked>`
  - `inventory_coverage`: `complete | partial | blocked`

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
- 무쿼리 interactive 모드(`npx skills find`)는 사용하지 않고 항상 `find "<query>"` 형태를 사용합니다.
- 무출력 hang이 발생하면 중단 후 1회 재시도하고, 재시도 실패 시 `blocked_cli_hang`으로 기록합니다.

## 3) 인기/사용량 채널

수집 포인트:

- 공개 인기 목록의 후보를 추립니다.
- 인기 지표(예: installs, ranking, stars)를 기록하고 확인 시각(`checked_at_utc`)을 남깁니다.
- 인기만 높고 프로젝트와 무관하면 `pending` 또는 `rejected` 후보로 표시합니다.

권장 출처 우선순위:

1. `skills.sh/<owner>/<repo>/<skill>` 상세 페이지 설치 지표
2. `npx --yes skills find "<query>"` 결과의 installs
3. GitHub 저장소 지표(`stargazers_count`, `pushed_at`)
4. 커뮤니티 큐레이션 글/목록

재현성 원칙:

- 각 지표에 `metric_source`, `raw_value`, `checked_at_utc`를 함께 기록합니다.
- 구조화 API가 없거나 불안정하면 HTML/본문 파싱을 허용하되, 추출 규칙(어느 라벨/필드에서 읽었는지)을 함께 기록합니다.

## 4) 인터넷 검색 채널

수집 포인트:

- 공식 문서, GitHub, 실사용 사례 글을 우선합니다.
- 근거 URL과 함께 "왜 이 프로젝트에 맞는지"를 반드시 기록합니다.
- 최신성이 중요한 경우 확인 날짜를 함께 적습니다.

## 5) 기존 설치 스킬 인벤토리 채널

수집 포인트:

- 현재 환경에서 지원하는 목록 명령을 먼저 확인합니다.
- 설치된 스킬을 `owner/repo@skill`로 정규화해 목록화합니다.
- 목록 조회 자체가 불가하면 `blocked`로 기록하고 원인/영향을 남깁니다.

권장 절차:

```bash
npx --yes skills --help
# 환경에서 지원되는 목록 명령을 사용
npx --yes skills list
npx --yes skills list -g
```

fallback 절차(목록 명령 실패 시):

1. `~/.agents/skills/*/SKILL.md` 스캔
2. `<project>/.agents/skills/*/SKILL.md` 스캔
3. 중복 제거 후 `owner/repo@skill` 형식으로 정규화
4. 문서에 `inventory_coverage=partial`과 누락 가능 범위를 명시

## 6) 병합 규칙

병합 시 권장 필드:

- `skill_ref`
- `repo`
- `skill`
- `origin`
- `installed_state`
- `methods` (예: `find,popular,web`)
- `method_count`
- `evidence_urls`
- `fit_note`
- `cluster_key` (유사 기능군 식별자)
- `selection_note` (대표 선정 또는 대체 사유)

병합 원칙:

1. 교집합 축소를 하지 말고 3채널 결과의 합집합을 만든다.
2. 인벤토리 결과를 합집합에 overlay해 `installed_state`를 채운다.
3. `skill_ref` 기준으로 중복 제거하고 `methods`, `evidence_urls`를 누적한다.
4. 누락 채널이 있어도 `blocked` 기록이 있으면 다음 단계로 진행한다.

차단 채널 보정 규칙:

1. `blocked_channel_count = blocked(find,popular,web)`를 계산한다.
2. `expected_channel_count = 3 - blocked_channel_count`를 기록한다.
3. 채널 차단이 있으면 `method_count`를 절대 게이트로 사용하지 않는다.
4. 이 경우 승인 여부는 본문 검토 + 근거 품질 + 적합성 중심으로 판단한다.

## 7) 유사/중복 후보 정리

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

## 8) 최종 액션 매핑

검토/선정 결과를 최종 변경 액션으로 매핑합니다.

- `selected + installed_state=installed` -> `target_action=keep`
- `selected + installed_state=not_installed` -> `target_action=install`
- `alternate/rejected + installed_state=installed` -> `target_action=remove` 후보
- 근거 부족/차단 -> `target_action=hold`
- 적용 단계 자체가 차단되면 `target_action`은 유지하되 실행 결과를 `deferred_blocked_cli`로 기록한다.

주의:

- `remove`는 영향 범위와 롤백 경로가 확보된 경우에만 확정합니다.
