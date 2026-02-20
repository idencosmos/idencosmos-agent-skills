# Codex Multi-Agent Notes

이 문서는 `project-agent-factory`가 의존하는 멀티 에이전트 설정 핵심을 요약합니다.

## 핵심 포인트

1. 멀티 에이전트는 실험적 기능이며 `[features]`의 `multi_agent = true`가 필요합니다.
2. 프로젝트별 구성은 `<project-root>/.codex/config.toml`에서 관리합니다.
3. 에이전트 등록은 `[agents."<name>"]` 블록 + `config_file` 상대경로(`agents/*.toml`) 분리 구성을 권장합니다.
4. 기본 `agent_type`은 `default`, `explorer`, `worker`입니다.
5. 역할 파일(`agents/*.toml`)에는 `model`, `model_reasoning_effort`, `sandbox_mode`, `approval_policy`, `cwd`, `developer_instructions`, `env` 등을 설정할 수 있습니다.
6. `model_reasoning_effort` 허용값은 `minimal|low|medium|high|xhigh`입니다(모델/버전별 지원 범위는 공식 문서로 확인).
7. 병렬 처리 상한은 `agents.max_threads`로 조정할 수 있습니다.
8. 설정 키 alias/마이그레이션이 있을 수 있으므로 적용 전 공식 Config Reference와 현재 CLI 버전을 교차 확인하세요.

## 버전 호환 메모

- 과거 자료에는 `agents.<id>.config` 표기가 남아 있을 수 있습니다. 신규 구성은 `config_file` 기준으로 유지하세요.
- 일부 과거 자료에는 `prompt` 또는 `instructions` alias가 보일 수 있습니다. 신규 구성은 `developer_instructions`를 기본으로 사용하세요.
- 오래된 사례를 그대로 복사하면 스키마 오류가 날 수 있으므로, `source_review.tsv`의 `key_constraints`에 버전 리스크를 남기세요.

## 권장 운영 원칙 (Markdown-Only)

- 프로젝트 스코프 원칙: 글로벌 `~/.codex`를 건드리지 않고, 프로젝트 내부 `.codex/`만 변경합니다.
- 기능 플래그 원칙: 최종 상태에서 `.codex/config.toml`의 `features.multi_agent`는 반드시 `true`여야 합니다.
- trust 게이트 원칙: `trust_status`는 placeholder가 아니라 `trusted|untrusted|unknown` 실제 값이어야 합니다.
- 적용 모드 원칙: `untrusted|unknown`이면 Step 4를 생략하고 `plan_only` 보고(`scope_validation.md`, `apply_report.md`)를 남깁니다.
- 추적성 원칙: 왜 해당 에이전트를 만들었는지 `agent_plan.tsv`의 `reason(source_id 포함)`에 남깁니다.
- 안전 원칙: 생성/갱신/삭제 경로를 모두 기록하고, 프로젝트 루트 바깥 변경이 없는지 `scope_validation.md`로 검증합니다.
- 쓰기 프리플라이트 원칙: Step 0에서 `RUN_DIR` write probe를 수행하고 실패 시 즉시 중단합니다.
- 적용 fallback 원칙: `apply_patch` 실패는 비치명으로 보고 `cat > file`/`rm`/`mv` 대체를 허용하되, Step 5 검증은 동일하게 수행합니다.
- 정규식 휴대성 원칙: `awk/sed` 정규식에서는 `\s` 대신 `[[:space:]]`를 사용합니다.

## 수동 검증 체크

- `apply_mode=plan_only`에서는 trust/scope/report 정합만 확인하고, `.codex` 파일 존재 기반 체크는 생략 가능
- `.codex/config.toml`에 managed block이 있고 `agent_plan.tsv`와 엔트리 수/ID가 일치하는지 확인
- 각 `[agents."<id>"]`의 `config_file`이 `agents/*.toml` 형식인지 확인
- Step 3.5 제약(헤더/빈값/중복/패턴/enum/source_id 연결성)을 통과했는지 확인
- `source_probe.tsv`와 `source_evidence/*.md`가 존재하고 `source_id`/경로 매핑이 맞는지 확인
- 각 역할 파일에 `model`, `model_reasoning_effort`, `sandbox_mode`, `developer_instructions`가 존재하는지 확인
- stale managed 파일이 제거되었는지 확인
- zsh no-match 회피를 위해 `.codex/agents/*.toml` 글롭 대신 `rg ... .codex/agents -g '*.toml'` 형식을 사용

## 공식 문서

- [Codex Multi-agents](https://developers.openai.com/codex/multi-agent)
- [Codex Config Basics](https://developers.openai.com/codex/config-basic)
- [Codex Config Reference](https://developers.openai.com/codex/config-reference)
- [Codex PR #11917: customizable roles for multi-agents](https://github.com/openai/codex/pull/11917)
- [Codex PR #8376: developer_instructions config docs](https://github.com/openai/codex/pull/8376)
