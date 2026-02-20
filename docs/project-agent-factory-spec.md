# project-agent-factory Spec (Maintainer Guide)

- Owner: `idencosmos-agent-skills` maintainers
- Scope: `skills/project-agent-factory`
- SSOT: This file is the single source of truth for maintainer-level operation rules.
- Last Updated: `2026-02-20`

## Detailed Spec

이 섹션은 `skills/project-agent-factory`를 리뷰/개발할 때 사용하는 운영 스펙입니다.
실행 절차의 기준 문서는 `skills/project-agent-factory/SKILL.md`이며, 아래는 해당 기준의 유지보수 계약입니다.

### 1) 목표와 범위

- 목표: 프로젝트별 멀티 에이전트 구성을 분석 → 설계 → 반영 → 검증까지 재현 가능하게 수행한다.
- 범위: 프로젝트 루트 내부 `.codex/`만 변경한다.
- 비목표: 글로벌 `~/.codex` 변경, 레거시 자동 스크립트(`apply-plan`, `run`, `scan-project`, `plan-agents`) 사용.

### 2) 필수 실행 산출물

- `project_profile.md`
- `source_review.tsv`
- `agent_plan.tsv`
- `trust_preflight.md`
- `scope_validation.md`
- `apply_report.md`

산출물 생성 규칙:
- 위 6개 산출물은 `full_apply|plan_only` 모두에서 생성한다.
- `plan_only`일 때 `scope_validation.md`의 `checked_paths`는 `none(plan_only)`로 기록한다.

### 3) 표준 파이프라인

1. Step 0: 프로젝트 루트 고정 + run 디렉터리 준비
2. Step 0.5: trusted preflight (fail-closed)
3. Step 1: 프로젝트 분석
4. Step 2: 공식/사례 소스 검증
5. Step 3: 에이전트 계획 생성
6. Step 3.5: `agent_plan.tsv` 정합성 검증 (fail-fast)
7. Step 4: `.codex/config.toml`, `.codex/agents/*.toml` 직접 반영
8. Step 5: 범위/정합성 검증 및 감사 보고

### 4) Trust Gate (Fail-Closed)

- `trust_preflight.md`의 `trust_status`는 placeholder 문자열이 아니라 `trusted|untrusted|unknown` 중 하나의 실제 값이어야 한다.
- 신뢰 상태(`trust_status`)가 `trusted`로 확인되고 Step 3.5가 통과되기 전에는 Step 4를 수행하지 않는다.
- `untrusted` 또는 `unknown`이면 Step 4를 생략하고, Step 5를 `apply_mode=plan_only`로 수행한다.
- false success 방지 원칙:
  - 파일 생성 여부가 아니라, trusted 상태에서 프로젝트 `.codex` 레이어가 유효 반영되는지로 성공을 판단한다.

### 5) Source Review 계약

- `source_review.tsv`의 스키마/도메인/품질 규칙의 단일 기준(SSOT)은 아래 문서다.
  - `skills/project-agent-factory/references/multi-agent-case-sources.md`
- 타입별 최소 기준:
  - `official`: 1개 이상 (OpenAI 공식 도메인)
  - `github`: 1개 이상 (GitHub URL)
  - `web`: 1개 이상 (공개 웹 URL, OpenAI/GitHub 제외)
- 품질 기준:
  - HTTP 200이어도 본문이 `Not Found`/`Page not found`이면 invalid로 간주하고 교체한다.
  - `web` 자료는 설계 패턴 보조 근거로만 쓰고, Codex 설정 키의 1차 근거로 사용하지 않는다.

### 6) Agent Plan 계약

- 필수 헤더:
  - `agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode`
- 핵심 제약:
  - `agent_id`, `config_relpath` 중복 금지
  - `config_relpath`는 `agents/*.toml`만 허용
  - `reason`은 `project_profile.md` 근거 + `source_review.tsv`의 `source_id`를 포함
  - `model_reasoning_effort`는 `minimal|low|medium|high|xhigh`
  - `sandbox_mode`는 `read-only|workspace-write|danger-full-access`
- Step 3.5 fail-fast 검증:
  - 헤더/컬럼 수/빈값/중복/패턴/enum 제약을 적용 전 확인
  - `agent_plan.tsv`의 `reason`에 나온 `source_id`가 `source_review.tsv`에 실제 존재하는지 확인

### 7) 반영/검증 계약

- 반영 시:
  - `.codex/agents/*.toml`에 `# managed_by=project-agent-factory` 마커를 사용
  - `.codex/config.toml`은 managed block만 교체하고 파일 전체를 덮어쓰지 않음
  - `[features] multi_agent = true` 보장
  - 이번 계획에 없는 stale managed agent 파일 정리
- 검증 시:
  - `trust_status`가 placeholder가 아닌 실제 값인지 확인
  - 변경 경로가 프로젝트 루트 밖으로 나가지 않았는지 확인
  - `apply_mode=full_apply`에서만 managed block의 role 목록과 `agent_plan.tsv` 일치 여부를 확인
  - `apply_mode=full_apply`에서만 각 `config_file`과 `config_relpath` 일치 여부를 확인
  - `apply_mode=plan_only`에서는 `scope_validation.md`에 `checked_paths=none(plan_only)` 기록 여부를 확인
  - zsh no-match를 피하기 위해 `rg ... .codex/agents -g '*.toml'` 형태를 사용한다.

### 8) 리뷰 체크리스트 (PR/수정 공통)

1. 파이프라인 순서(0 → 0.5 → 1 → 2 → 3 → 3.5 → 4 → 5)가 유지되는가?
2. trust fail-closed 정책이 약화되지 않았는가?
3. `source_review.tsv` 계약이 SKILL.md와 references 사이에서 중복/충돌 없이 SSOT를 따르는가?
4. 샘플 URL/도메인 규칙이 실제로 유효한가?
5. `trust_status` placeholder가 남아도 통과되는 경로가 없는가?
6. 산출물 템플릿(`trust_preflight.md`, `apply_report.md`, `scope_validation.md`)이 최신 계약과 일치하는가?
7. 레거시 자동 스크립트 의존이 재도입되지 않았는가?
8. README에 상세 규정 복붙이 없고, 스펙 문서 링크만 유지되는가?

### 9) 개발 규제 (Hard Constraints)

`project-agent-factory`는 **스킬 본체를 SKILL.md + references 구조로만 유지**한다.

- 허용 (스킬 본체):
  - `skills/project-agent-factory/SKILL.md`
  - `skills/project-agent-factory/references/*`
- 금지 (스킬 본체 내부):
  - `scripts/`, `assets/`, 추가 문서 파일(예: `README.md`, `QUICK_REFERENCE.md`, `CHANGELOG.md`)
- 예외:
  - 저장소 운영 문서/정책 문서는 스킬 폴더 바깥(예: 저장소 루트 `README.md`)에 둘 수 있다.
