# Codex Multi-Agent Notes

이 문서는 `project-agent-factory`가 의존하는 멀티 에이전트 설정 핵심만 요약합니다.

## 핵심 포인트

1. 멀티 에이전트 기능은 실험적 기능이며, `[features]`의 `multi_agent = true`가 필요합니다(기본값 `false`). 활성화되면 `spawn_agent`, `send_input`, `wait`, `resume_agent`, `close_agent` 같은 도구를 사용할 수 있습니다.
2. 프로젝트별 구성은 `<project-root>/.codex/config.toml`에서 관리할 수 있습니다.
3. 에이전트는 `[agents.<name>]` 블록으로 등록하며, `description`과 `config_file` 분리 구성이 가능합니다. `config_file`는 `.codex/config.toml` 기준 상대경로여야 합니다.
4. 기본 `agent_type`은 `default`, `explorer`, `worker`입니다.
5. 역할별 파일(`agents/*.toml`)에서는 `model`, `model_reasoning_effort`, `sandbox_mode`, `approval_policy`, `cwd`, `developer_instructions`, `env` 등을 설정할 수 있습니다.
6. `model_reasoning_effort` 허용값은 `minimal|low|medium|high|xhigh`이며, `xhigh`는 deprecated입니다(신규 계획은 `high` 우선).
7. 병렬 처리 상한은 `agents.max_threads`로 조정 가능합니다.
8. 설정 키는 Codex 버전에 따라 alias/마이그레이션이 있을 수 있으므로, 적용 전 공식 Config Reference와 현재 CLI 버전을 교차 확인하세요.

## 버전 호환 메모

- 과거 자료에는 `agents.<id>.config` 표기가 남아 있을 수 있습니다. 신규 계획은 `config_file` 기준으로 유지하세요.
- 일부 과거 자료에는 `prompt` 또는 `instructions` alias가 보일 수 있습니다. 이 스킬은 역할 프롬프트를 역할 파일(`agents/*.toml`)의 `developer_instructions`로 기록합니다.
- 오래된 사례를 그대로 복사하면 스키마 오류가 날 수 있으므로, `source_review.tsv`의 `key_constraints`에 버전 리스크를 명시하세요.

## 권장 운영 원칙

- 프로젝트 스코프 원칙: 글로벌 `~/.codex`는 건드리지 않고, 프로젝트 내부 `.codex/`만 변경합니다.
- 기능 플래그 원칙: 적용 시 `.codex/config.toml`에서 `features.multi_agent`를 강제로 `true`로 맞춥니다.
- 가시성 원칙: 어떤 에이전트를 왜 만들었는지 `agent_plan.tsv`에 근거를 남깁니다.
- 안전 원칙: 생성/갱신한 파일 경로가 모두 프로젝트 루트 하위인지 자동 검증합니다.

## 공식 문서

- [Codex Multi-agents](https://developers.openai.com/codex/multi-agent)
- [Codex Config Basics](https://developers.openai.com/codex/config-basic)
- [Codex Config Reference](https://developers.openai.com/codex/config-reference)
- [Codex PR #11917: customizable roles for multi-agents](https://github.com/openai/codex/pull/11917)
- [Codex PR #8376: developer_instructions config docs](https://github.com/openai/codex/pull/8376)
