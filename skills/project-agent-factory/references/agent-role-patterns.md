# Agent Role Patterns

`project-agent-factory` 기본 역할 매핑 기준입니다.

## Baseline Roles

1. `paf_explorer`
   - 목적: 구조/의존성/핵심 파일 맥락 수집
   - 기본 포함
2. `paf_implementer`
   - 목적: 코드 변경 실행 및 수정 반영
   - 기본 포함

## Conditional Roles

1. `paf_backend`
   - 트리거: `pyproject.toml`, `go.mod`, `Cargo.toml`, 서버 프레임워크 신호
   - 목적: API/도메인/데이터 계층 변경
2. `paf_frontend`
   - 트리거: React/Next/Vue/Svelte/Nuxt/Vite 신호, `*.tsx`/`*.jsx`
   - 목적: UI/상태/상호작용 품질 개선
3. `paf_qa`
   - 트리거: 테스트 파일 존재 또는 코드량 증가
   - 목적: 회귀 위험 식별, 검증 계획 점검
4. `paf_ops`
   - 트리거: Docker, Compose, Terraform, CI 워크플로우 신호
   - 목적: 런타임/배포/운영 안정성 점검

## Priority Order

1. `paf_explorer`
2. `paf_implementer`
3. `paf_backend`
4. `paf_frontend`
5. `paf_qa`
6. `paf_ops`

`--max-agents` 상한을 넘으면 위 우선순위 순서대로 유지합니다.
