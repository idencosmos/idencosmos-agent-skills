# Codex Multi-Agent Notes

이 문서는 `project-agent-factory`가 의존하는 멀티 에이전트 설정 핵심만 요약합니다.

## 핵심 포인트

1. 멀티 에이전트 기능은 `multi_agent` 플래그가 활성화되어야 동작합니다.
2. 프로젝트별 구성은 `<project-root>/.codex/config.toml`에서 관리할 수 있습니다.
3. 에이전트는 `[agents.<name>]` 블록으로 등록하며, `description`과 `config_file` 분리 구성이 가능합니다.
4. 역할별 파일(`agents/*.toml`)에서는 `model`, `model_reasoning_effort`, `sandbox_mode`, `developer_instructions`를 오버라이드할 수 있습니다.
5. 병렬 처리 상한은 `agents.max_threads`로 조정 가능합니다.

## 권장 운영 원칙

- 프로젝트 스코프 원칙: 글로벌 `~/.codex`는 건드리지 않고, 프로젝트 내부 `.codex/`만 변경합니다.
- 가시성 원칙: 어떤 에이전트를 왜 만들었는지 `agent_plan.tsv`에 근거를 남깁니다.
- 안전 원칙: 생성/갱신한 파일 경로가 모두 프로젝트 루트 하위인지 자동 검증합니다.

## 공식 문서

- [Codex Multi-agents](https://developers.openai.com/codex/multi-agent)
- [Codex Config Basics](https://developers.openai.com/codex/config#config-basics)
- [Codex Config Reference](https://developers.openai.com/codex/config#config-reference)
