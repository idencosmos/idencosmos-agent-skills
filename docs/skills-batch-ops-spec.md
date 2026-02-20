# Skills Batch Ops Spec (Maintainer Guide)

- Owner: `idencosmos-agent-skills` maintainers
- Scope: `skills/skills-batch-ops`
- SSOT: This file is the single source of truth for maintainer-level operation rules.
- Last Updated: `2026-02-20`

## Skills Batch Ops Specification (Union-First + Installed-Aware)

This section is the working spec for reviewing and developing
`skills/skills-batch-ops`.

### 1) Objective

- 프로젝트에 필요한 스킬 후보를 `find`, `popular`, `web` 3개 채널에서 수집한다.
- 현재 이미 설치된 스킬을 인벤토리로 수집한다.
- 3개 채널의 결과를 교집합으로 줄이지 않고 합집합으로 병합한다.
- 합집합 후보(탐색+기존 설치) 중 기능이 겹치거나 유사한 스킬을 비교해 최적안을 선택한다.
- 최종 결과를 `keep/install/remove/hold` 액션으로 확정한다.
- 최종 적용은 "중복 제거 + 적합성 최대화 + 기존 셋 정리"를 목표로 한다.

### 2) Operating Model

1. 프로젝트 분석:
- 목표, 기술 스택, 제약, 리스크 허용 범위를 정리한다.
- 설치 상한(예: 최대 N개)과 우선순위(안정성/속도/범용성)를 정의한다.

2. 3채널 탐색:
- `find`: 프로젝트 키워드 기반 후보 수집
- `popular`: 사용량/인지도 기반 후보 수집
- `web`: 일반 검색 기반 후보 수집

3. 기존 설치 스킬 인벤토리:
- 현재 환경에서 지원되는 목록 명령을 확인하고 설치 스킬 목록을 수집한다.
- 목록을 `owner/repo@skill` 형식으로 정규화한다.

4. 합집합 병합:
- 채널별 후보를 병합해 `union candidate set`을 만든다.
- 인벤토리 결과를 overlay해 설치 상태를 붙인다.
- 동일 `owner/repo@skill`는 중복 제거하고 출처 채널만 누적한다.

5. 본문 검토:
- 모든 유효 후보(기존 설치 포함)에 대해 실제 `SKILL.md`를 확인한다.
- 이름/설명/frontmatter, 워크플로 구체성, placeholder 과다 여부를 점검한다.

6. 유사/중복 정리:
- 기능 기준으로 후보를 클러스터링한다.
- 각 클러스터에서 대표 스킬(필요 시 2개)을 선정한다.
- 비선정 후보는 탈락 사유(중복, 품질, 적합성)를 기록한다.

7. 최종 셋 결정(dry-run):
- 현재 셋 대비 목표 셋의 차이를 문서화한다.
- 각 항목의 최종 액션(`keep/install/remove/hold`)을 확정한다.

8. 최종 적용:
- `install` 대상은 설치하고 `remove` 대상은 삭제한다.
- `keep`/`hold`는 변경 없이 근거를 남긴다.
- 설치/삭제 실패는 숨기지 않고 원인과 영향, 재시도 계획을 기록한다.

### 3) Selection Rules for Similar Skills

- 클러스터 기준:
  - 핵심 문제영역이 같은가
  - 출력 산출물/워크플로가 사실상 동일한가
  - 함께 설치 시 충돌 또는 불필요한 중복이 발생하는가
- 비교 축:
  - 프로젝트 적합성
  - `SKILL.md` 품질(절차 명확성/재현성)
  - 신뢰도(근거 출처 품질, 유지보수 시그널)
  - 운영 리스크(복잡도, 의존성, 실패 영향)
- 기본 원칙:
  - 교집합 우선이 아니라 "합집합 탐색 후 최적 조합 선택"을 따른다.
  - 동일 기능군에서 우열이 명확하면 1개만 설치한다.
  - 보완적 관계가 확실할 때만 2개 이상 병행 설치를 허용한다.

액션 매핑 원칙:

- `selected + installed` -> `keep`
- `selected + not_installed` -> `install`
- `alternate/rejected + installed` -> `remove` 후보
- 근거 부족/차단 -> `hold`

### 4) Completion and Quality Gates

- 3채널 탐색 자체는 필수다.
- 기존 설치 스킬 인벤토리 시도도 필수다.
- 단, 외부 제약(네트워크/도구/권한)으로 채널 수행 불가 시:
  - 채널 상태를 `blocked`로 기록한다.
  - 명령, 오류, 영향 범위를 남기고 부분 완료로 보고한다.
- 실제 `SKILL.md`를 읽지 않은 후보는 설치 승인하지 않는다.
- 실제 `SKILL.md`를 읽지 않은 기존 설치 스킬은 `keep` 확정하지 않는다.
- 기존 설치 스킬은 모두 `keep/remove/hold` 중 하나로 분류해야 한다.
- 적용 결과는 성공/실패/원인/복구 계획까지 포함해야 완료로 본다.

### 5) Required Artifacts

- `project_profile.md`
- `candidates.find.md`
- `candidates.popular.md`
- `candidates.web.md`
- `inventory.installed.md`
- `candidates.merged.md` (합집합 기준)
- `review.content.md`
- `review.manifest.md`
- `install.plan.md`
- `install.result.md`

### 6) Packaging and Structure Regulation (Hard Constraint)

`skills-batch-ops`를 포함한 본 저장소의 스킬 산출물은 아래 구조만 허용한다.

```text
<skill-name>/
  SKILL.md
  references/
    *.md
```

- 허용:
  - `SKILL.md` (필수)
  - `references/` 하위 참조 문서(선택)
- 비허용:
  - `scripts/`, `assets/`, `README.md`, 임시 파일, 기타 부가 문서
- 이유:
  - 문서 지시형 스킬로 유지해 실행 복잡도와 유지비를 낮춘다.
  - 리뷰/검증 시 "SKILL.md + references"만 보면 되게 만든다.

### 7) Change Control

- `skills-batch-ops` 수정 시 이 스펙을 먼저 기준으로 검토한다.
- 스펙과 구현이 다르면, 먼저 이 스펙 문서 갱신 여부를 결정한 뒤 구현을 변경한다.
- 검증은 최소 아래 명령으로 수행한다:
  - 실행 위치: `~/Projects/skills-hub/idencosmos-agent-skills`
  - `python3 .github/scripts/validate_skill.py skills/skills-batch-ops`
  - 실행 위치: `~/Projects/skills-hub`
  - `python3 ./scripts/package_skill.py ./idencosmos-agent-skills/skills/skills-batch-ops ./dist`
