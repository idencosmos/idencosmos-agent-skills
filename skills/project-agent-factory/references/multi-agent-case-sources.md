# Multi-Agent Case Sources

`project-agent-factory`의 계획 생성 단계에서 소스를 검증할 때 사용하는 기준입니다.

## 최소 수집 기준

아래 3개 타입을 모두 포함하세요.

1. `official`: Codex 공식 문서
2. `github`: GitHub의 실제 멀티 에이전트 사례(이슈/PR/템플릿/코드)
3. `web`: GitHub/OpenAI 공식 도메인 외 공개 웹 자료(블로그/가이드/문서)

권장 최소 개수:
- `official` 1개 이상
- `github` 1개 이상
- `web` 1개 이상

## 추천 시작 소스

- 공식 문서:
  - `https://developers.openai.com/codex/multi-agent`
  - `https://developers.openai.com/codex/config-reference`
- GitHub 사례:
  - `https://github.com/openai/codex/pull/8783` (agent control 명령 기반 멀티 에이전트 실행 경로)
  - `https://github.com/openai/codex/pull/11917` (사용자 정의 role + `config_file` 분리 구성 사례)
  - `https://github.com/openai/codex/pull/8376` (`developer_instructions` 설정 문서화 변경 근거)
  - `https://github.com/openai/codex/releases/tag/rust-v0.79.0` (멀티 에이전트 관련 릴리스 노트)
- GitHub 외 웹 사례:
  - `https://learn.microsoft.com/en-us/azure/architecture/ai-ml/guide/ai-agent-design-patterns` (역할 분해/오케스트레이션 패턴 참고)
  - `https://platform.claude.com/docs/en/agent-sdk/subagents` (서브에이전트 협업 패턴 참고)
  - `https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/design-patterns/mixture-of-agents.html` (역할 분해/협업 패턴 참고)

위 링크만 복사하지 말고, 현재 프로젝트 요구와 직접 연결되는 근거를 반드시 작성하세요.
추천 시작 소스도 시간에 따라 invalid가 될 수 있으므로, 수집 시점에 상태를 다시 확인하고 교체하세요.

## source_review.tsv 계약

헤더:

```tsv
source_id	source_type	url	checked_at_utc	relevance_note	key_constraints
```

컬럼 규칙:
- `source_id`: `official-1`, `github-1`, `web-1`처럼 타입 접두어를 사용하세요.
- `source_type`: `official|github|web` 중 하나만 사용하세요.
- `source_type=github`: `github.com` 또는 `raw.githubusercontent.com` URL만 허용합니다.
- `source_type=web`: GitHub/OpenAI 공식 도메인을 제외한 공개 웹 URL만 허용합니다.
- `source_type=official`: `developers.openai.com` 또는 `openai.com` URL만 사용하세요.
- `url`: 실제 확인한 원문 URL을 기록하세요.
- `checked_at_utc`: `YYYY-MM-DDTHH:MM:SSZ` 형식을 사용하세요.
- `relevance_note`: 프로젝트에 왜 필요한지 한 줄로 요약하세요.
- `key_constraints`: 적용 시 주의점/한계를 남기세요.
- 동일한 URL을 타입만 바꿔 중복 기록하지 마세요.

## source_probe.tsv 계약

`source_review.tsv`와 별개로 연결성/본문 유효성 증빙을 남기세요.

헤더:

```tsv
source_id	http_status	final_url	body_not_found	evidence_relpath	checked_at_utc	probe_note
```

컬럼 규칙:
- `source_id`: `source_review.tsv`에 존재하는 동일 ID를 사용하세요.
- `http_status`: `blocked` 또는 3자리 HTTP 코드(`200`, `301`, `404` 등)를 사용하세요.
- `final_url`: 리다이렉트 이후 실제 최종 URL을 기록하세요.
- `body_not_found`: `yes|no|blocked` 중 하나를 사용하세요.
- `evidence_relpath`: `source_evidence/<source_id>.md` 형식 상대경로를 사용하세요.
- `checked_at_utc`: `YYYY-MM-DDTHH:MM:SSZ` 형식을 사용하세요.
- `probe_note`: 연결성/본문 판단 근거를 한 줄로 요약하세요.
- `http_status`가 `2xx`인데 `body_not_found=yes`이면 invalid로 간주하고 URL을 교체하세요.

## source_evidence 파일 계약

- 각 `source_id`마다 `source_evidence/<source_id>.md` 파일을 만드세요.
- 최소 포함 항목:
  - `fetch_method`
  - `http_status`
  - `body_not_found`
  - `evidence_note` (어떤 본문 단서를 보고 유효 판정했는지)
- 네트워크 차단 시에도 파일은 만들고 `blocked` 사유를 남기세요.

## 품질 기준

- 소스는 최신 상태를 확인하고 날짜를 남기세요.
- 마케팅 소개 글보다 실제 설정/실행 예시가 있는 자료를 우선하세요.
- 링크가 HTTP 200이어도 본문에 `Not Found` 또는 `Page not found`가 포함되면 invalid로 간주하고 다른 URL로 교체하세요.
- `source_probe.tsv`와 `source_evidence/*.md`를 반드시 함께 남기고, 둘의 `source_id` 매핑이 일치해야 합니다.
- `relevance_note`가 빈약하면 해당 소스는 계획 근거로 사용하지 마세요.
- `reason`에서 사용할 수 있게 `source_id`를 명시적으로 추적하세요(예: `source=official-1 github-1`).
- 네트워크가 막혀 수집하지 못하면 `relevance_note`에 `blocked`를 기록하고 부분 검증으로 보고하세요.
- GitHub 소스는 가능하면 PR/커밋/릴리스처럼 변경 근거가 추적되는 문서를 우선하세요.
- `web` 소스는 Codex 설정 키의 1차 근거로 쓰지 말고, 역할 분해/오케스트레이션 패턴 보조 근거로만 사용하세요.

## 수동 연결성 체크 (Markdown-Only)

`agent_plan.tsv` 작성 후 아래를 직접 확인하세요.
- `reason`에 등장하는 `source_id`가 `source_review.tsv`에 모두 존재하는지
- `official/github/web` 3종류가 모두 포함되었는지
- URL 도메인 규칙이 타입과 일치하는지
- `source_probe.tsv`의 `source_id` 집합이 `source_review.tsv`와 완전히 일치하는지
- `source_probe.tsv`의 `evidence_relpath`가 실제 파일(`source_evidence/*.md`)로 존재하는지
