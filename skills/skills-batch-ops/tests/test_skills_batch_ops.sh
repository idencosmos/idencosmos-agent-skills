#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/skills_batch_ops.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0

log() {
  printf '%s\n' "$*"
}

run_test() {
  local suite="$1"
  local name="$2"
  local fn="$3"

  if "$fn"; then
    log "ok - [$suite] $name"
    PASS=$((PASS + 1))
  else
    log "not ok - [$suite] $name"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || {
    log "assertion failed: file missing: $path"
    return 1
  }
}

assert_contains() {
  local path="$1"
  local text="$2"
  rg -q --fixed-strings -- "$text" "$path" || {
    log "assertion failed: '$text' not found in $path"
    return 1
  }
}

assert_not_contains() {
  local path="$1"
  local text="$2"
  if rg -q --fixed-strings -- "$text" "$path"; then
    log "assertion failed: '$text' unexpectedly found in $path"
    return 1
  fi
}

assert_row_count() {
  local path="$1"
  local expected="$2"
  local rows
  rows="$(awk 'END{print NR-1}' "$path")"
  [[ "$rows" == "$expected" ]] || {
    log "assertion failed: expected $expected rows in $path, got $rows"
    return 1
  }
}

count_fixed_matches() {
  local path="$1"
  local text="$2"
  local out
  out="$(rg --fixed-strings -- "$text" "$path" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    printf '0\n'
    return
  fi
  printf '%s\n' "$out" | wc -l | tr -d ' '
}

setup_mock_env() {
  local dir="$1"
  mkdir -p "$dir/bin"

  cat > "$dir/bin/npx" <<'MOCK_NPX'
#!/usr/bin/env bash
set -euo pipefail
fixture_dir="${TEST_FIXTURE_DIR:?}"
log_file="${MOCK_NPX_LOG:-}"
list_fail_repos=",${MOCK_LIST_FAIL_REPOS:-},"
allow_any_skill="${MOCK_ALLOW_ANY_SKILL:-0}"
read_stdin_on_add="${MOCK_NPX_READ_STDIN_ON_ADD:-0}"

if [[ "${1:-}" != "skills" ]]; then
  echo "unexpected npx call: $*" >&2
  exit 1
fi
shift
sub="${1:-}"
shift || true

if [[ -n "$log_file" ]]; then
  printf 'npx skills %s' "$sub" >> "$log_file"
  if [[ $# -gt 0 ]]; then
    printf ' %s' "$*" >> "$log_file"
  fi
  printf '\n' >> "$log_file"
fi

case "$sub" in
  find)
    if [[ -n "${MOCK_FIND_FILE:-}" && -f "${MOCK_FIND_FILE}" ]]; then
      cat "${MOCK_FIND_FILE}"
    elif [[ "${MOCK_FIND_MODE:-}" == "empty" ]]; then
      echo "No skills found"
    else
      cat "$fixture_dir/find_sample.txt"
    fi
    ;;
  add)
    repo="${1:-}"
    shift || true
    implicit_skill=""

    if [[ "$read_stdin_on_add" == "1" ]]; then
      IFS= read -r _ || true
    fi

    if [[ "$repo" == *"@"* ]]; then
      implicit_skill="${repo#*@}"
      repo="${repo%@*}"
    fi

    if [[ "${1:-}" == "--list" ]]; then
      if [[ "$list_fail_repos" == *",${repo},"* ]]; then
        echo "forced list failure for repo: $repo" >&2
        exit 1
      fi

      cat <<'LIST'
┌   skills
│
◇  Available Skills
│
│    skill-alpha
│
│      Alpha skill for testing.
│
│    skill-beta
│
│      Beta skill for reliability.
│
└  Use --skill <name> to install specific skills
LIST
    else
      skills=()
      while [[ $# -gt 0 ]]; do
        case "${1:-}" in
          --skill)
            skills+=("${2:-}")
            shift 2
            ;;
          -y|--yes)
            shift
            ;;
          *)
            shift
            ;;
        esac
      done

      if [[ ${#skills[@]} -eq 0 && -n "$implicit_skill" ]]; then
        skills+=("$implicit_skill")
      fi

      if [[ ${#skills[@]} -eq 0 ]]; then
        skills=("skill-alpha" "skill-beta")
      fi

      for skill in "${skills[@]}"; do
        if [[ "$allow_any_skill" != "1" && "$skill" != "skill-alpha" && "$skill" != "skill-beta" ]]; then
          echo "unknown skill: $skill" >&2
          exit 1
        fi

        mkdir -p ".agents/skills/$skill"
        cat > ".agents/skills/$skill/SKILL.md" <<EOF_SKILL
---
name: $skill
description: ${skill} for python observability and resilience checks.
---
# $skill

This skill improves python observability and workflow reliability.
EOF_SKILL
      done

      echo "MOCK_ADD repo=${repo} skills=${skills[*]}"
    fi
    ;;
  list)
    echo "Project Skills"
    echo "mock-skill ~/.agents/skills/mock-skill"
    ;;
  check)
    echo "All skills are up to date"
    ;;
  *)
    echo "unsupported npx skills subcommand: $sub" >&2
    exit 1
    ;;
esac
MOCK_NPX
  chmod +x "$dir/bin/npx"

  cat > "$dir/bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "search" && "${2:-}" == "repos" ]]; then
  if [[ -n "${MOCK_GH_FILE:-}" && -f "${MOCK_GH_FILE}" ]]; then
    cat "${MOCK_GH_FILE}"
  else
    cat <<'JSON'
[
  {"owner":{"login":"example"},"name":"repo","stargazersCount":42,"updatedAt":"2026-02-10T00:00:00Z"},
  {"owner":{"login":"example"},"name":"toolbox","stargazersCount":11,"updatedAt":"2026-01-12T00:00:00Z"}
]
JSON
  fi
  exit 0
fi

echo "unsupported gh command: $*" >&2
exit 1
MOCK_GH
  chmod +x "$dir/bin/gh"

  cat > "$dir/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_CURL_FILE:-}" && -f "${MOCK_CURL_FILE}" ]]; then
  cat "${MOCK_CURL_FILE}"
else
  cat "${TEST_FIXTURE_DIR:?}/skills_home_sample.html"
fi
MOCK_CURL
  chmod +x "$dir/bin/curl"
}

# --------------------------
# Process Tests
# --------------------------

test_collect_find_process() {
  local tmp out rows
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"
  out="$tmp/candidates.find.tsv"

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" collect-find --out "$out" "python testing" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$out" || return 1
  assert_contains "$out" $'skill_ref\tfind_installs\tfind_queries' || return 1
  assert_contains "$out" "example/repo@skill-alpha" || return 1
  rows="$(awk 'END{print NR-1}' "$out")"
  [[ "$rows" -ge 1 ]] || return 1
}

test_collect_top_process() {
  local tmp out
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"
  out="$tmp/candidates.top.tsv"

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" SKILLS_BATCH_TOP_HTML_FILE="$FIXTURE_DIR/skills_home_sample.html" "$SCRIPT_PATH" collect-top --out "$out" --top 2 > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$out" || return 1
  assert_row_count "$out" 2 || return 1
  assert_contains "$out" "vercel-labs/skills@find-skills" || return 1
}

test_collect_github_process() {
  local tmp out rows
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"
  out="$tmp/candidates.github.tsv"

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" collect-github --out "$out" --limit 2 --github-query "python skills" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$out" || return 1
  assert_contains "$out" $'skill_ref\trepo\tskill\tgithub_stars\tgithub_updated_at\tgithub_queries' || return 1
  assert_contains "$out" "example/repo@skill-alpha" || return 1
  rows="$(awk 'END{print NR-1}' "$out")"
  [[ "$rows" -ge 2 ]] || return 1
}

test_collect_github_stdin_safe_process() {
  local tmp out
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"
  out="$tmp/candidates.github.tsv"

  TEST_FIXTURE_DIR="$FIXTURE_DIR" MOCK_NPX_READ_STDIN_ON_ADD="1" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" collect-github --out "$out" --limit 2 --github-query "python skills" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$out" || return 1
  assert_row_count "$out" 4 || return 1
  assert_contains "$out" "example/repo@skill-alpha" || return 1
  assert_contains "$out" "example/toolbox@skill-beta" || return 1
}

test_import_web_process() {
  local tmp out
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"
  out="$tmp/candidates.web.tsv"

  cat > "$tmp/web_links.txt" <<'EOF_WEB'
https://skills.sh/example/repo/skill-alpha
https://github.com/example/repo
https://unsupported.example.com/somewhere
EOF_WEB

  cat > "$tmp/query.txt" <<'EOF_QUERY'
alpha
EOF_QUERY

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" import-web --web-links-file "$tmp/web_links.txt" --query-file "$tmp/query.txt" --out "$out" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$out" || return 1
  assert_contains "$out" "example/repo@skill-alpha" || return 1
  assert_not_contains "$out" "example/repo@skill-beta" || return 1
}

test_import_web_stdin_safe_process() {
  local tmp out
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"
  out="$tmp/candidates.web.tsv"

  cat > "$tmp/web_links.txt" <<'EOF_WEB'
https://skills.sh/example/repo/skill-alpha
https://github.com/example/repo
https://github.com/example/toolbox
EOF_WEB

  TEST_FIXTURE_DIR="$FIXTURE_DIR" MOCK_NPX_READ_STDIN_ON_ADD="1" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" import-web --web-links-file "$tmp/web_links.txt" --out "$out" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$out" || return 1
  assert_row_count "$out" 4 || return 1
  assert_contains "$out" "example/repo@skill-alpha" || return 1
  assert_contains "$out" "example/toolbox@skill-beta" || return 1
}

test_merge_process() {
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/find.tsv" <<'EOF_FIND'
skill_ref	find_installs	find_queries
example/repo@skill-alpha	120	python testing
example/repo@skill-beta	80	python observability
EOF_FIND

  cat > "$tmp/top.tsv" <<'EOF_TOP'
skill_ref	top_installs	top_rank
example/repo@skill-alpha	1000	2
EOF_TOP

  cat > "$tmp/github.tsv" <<'EOF_GH'
skill_ref	repo	skill	github_stars	github_updated_at	github_queries
example/repo@skill-alpha	example/repo	skill-alpha	42	2026-02-10T00:00:00Z	python testing
EOF_GH

  cat > "$tmp/web.tsv" <<'EOF_WEB'
skill_ref	repo	skill	web_sources	web_origin
example/repo@skill-alpha	example/repo	skill-alpha	https://skills.sh/example/repo/skill-alpha	skills.sh
EOF_WEB

  cat > "$tmp/query.txt" <<'EOF_QUERY'
python testing
python observability
EOF_QUERY

  "$SCRIPT_PATH" merge --find "$tmp/find.tsv" --top "$tmp/top.tsv" --github "$tmp/github.tsv" --web "$tmp/web.tsv" --query-file "$tmp/query.txt" --out "$tmp/merged.tsv" --manifest "$tmp/review_manifest.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$tmp/merged.tsv" || return 1
  assert_file_exists "$tmp/review_manifest.tsv" || return 1
  awk -F '\t' '$1=="example/repo@skill-alpha"{c++} END{exit !(c==1)}' "$tmp/merged.tsv" || return 1
  assert_contains "$tmp/merged.tsv" "find,top,github,web" || return 1
}

test_validate_content_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	channels	find_installs	top_installs	github_stars	github_updated_at	query_overlap	auto_score	risk_level	status	review_notes	approved_by	approved_at
example/repo@skill-alpha	example/repo	skill-alpha	find	120	0	0		50.00	60.00	medium	pending	auto	me	
example/repo@skill-gamma	example/repo	skill-gamma	find	80	0	0		20.00	30.00	high	pending	auto	me	
EOF_MANIFEST

  cat > "$tmp/query.txt" <<'EOF_QUERY'
python observability
workflow reliability
EOF_QUERY

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" validate-content --manifest "$tmp/review_manifest.tsv" --query-file "$tmp/query.txt" --status pending --out "$tmp/review_content.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$tmp/review_content.tsv" || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-alpha" {exit !($6=="matched" && $7=="installed" && $8=="present" && $10=="verified")}' "$tmp/review_content.tsv" || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-gamma" {exit !($6=="not_found" && $7=="install_failed" && $8=="missing" && $10=="failed")}' "$tmp/review_content.tsv" || return 1
}

test_validate_content_filter_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	channels	find_installs	top_installs	github_stars	github_updated_at	query_overlap	auto_score	risk_level	status	review_notes	approved_by	approved_at
example/repo@skill-alpha	example/repo	skill-alpha	find	120	0	0		50.00	60.00	medium	pending	auto	me	
example/repo@skill-beta	example/repo	skill-beta	find	80	0	0		20.00	30.00	high	pending	auto	me	
EOF_MANIFEST

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" validate-content --manifest "$tmp/review_manifest.tsv" --status pending --skill-ref "example/repo@skill-beta" --out "$tmp/review_content.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_row_count "$tmp/review_content.tsv" 1 || return 1
  awk -F '\t' 'NR==2 {exit !($1=="example/repo@skill-beta")}' "$tmp/review_content.tsv" || return 1
}

test_validate_content_stdin_safe_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	channels	find_installs	top_installs	github_stars	github_updated_at	query_overlap	auto_score	risk_level	status	review_notes	approved_by	approved_at
example/repo@skill-alpha	example/repo	skill-alpha	find	120	0	0		50.00	60.00	medium	pending	auto	me	
example/repo2@skill-beta	example/repo2	skill-beta	find	80	0	0		20.00	30.00	high	pending	auto	me	
example/repo3@skill-alpha	example/repo3	skill-alpha	find	70	0	0		20.00	25.00	high	pending	auto	me	
EOF_MANIFEST

  TEST_FIXTURE_DIR="$FIXTURE_DIR" MOCK_NPX_READ_STDIN_ON_ADD="1" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" validate-content --manifest "$tmp/review_manifest.tsv" --status pending --out "$tmp/review_content.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$tmp/review_content.tsv" || return 1
  assert_row_count "$tmp/review_content.tsv" 3 || return 1
}

test_validate_content_optimization_success_process() {
  local tmp list_calls
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	channels	find_installs	top_installs	github_stars	github_updated_at	query_overlap	auto_score	risk_level	status	review_notes	approved_by	approved_at
example/repo@skill-alpha	example/repo	skill-alpha	find	120	0	0		50.00	60.00	medium	pending	auto	me	
example/repo@skill-beta	example/repo	skill-beta	find	80	0	0		20.00	30.00	high	pending	auto	me	
EOF_MANIFEST

  TEST_FIXTURE_DIR="$FIXTURE_DIR" MOCK_NPX_LOG="$tmp/npx.log" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" validate-content --manifest "$tmp/review_manifest.tsv" --status pending --out "$tmp/review_content.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  list_calls="$(count_fixed_matches "$tmp/npx.log" "--list")"
  [[ "$list_calls" -eq 0 ]] || {
    log "assertion failed: expected 0 --list calls, got $list_calls"
    return 1
  }
}

test_validate_content_optimization_failure_cache_process() {
  local tmp list_calls
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	channels	find_installs	top_installs	github_stars	github_updated_at	query_overlap	auto_score	risk_level	status	review_notes	approved_by	approved_at
example/repo@skill-gamma	example/repo	skill-gamma	find	120	0	0		50.00	60.00	medium	pending	auto	me	
example/repo@skill-delta	example/repo	skill-delta	find	80	0	0		20.00	30.00	high	pending	auto	me	
EOF_MANIFEST

  TEST_FIXTURE_DIR="$FIXTURE_DIR" MOCK_NPX_LOG="$tmp/npx.log" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" validate-content --manifest "$tmp/review_manifest.tsv" --status pending --out "$tmp/review_content.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  list_calls="$(count_fixed_matches "$tmp/npx.log" "--list")"
  [[ "$list_calls" -eq 1 ]] || {
    log "assertion failed: expected 1 cached --list call, got $list_calls"
    return 1
  }
}

test_merge_content_reviews_process() {
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/worker1.tsv" <<'EOF_REVIEW'
skill_ref	repo	skill	manifest_status	auto_score	name_check	install_check	skill_md_check	content_overlap	review_status	skill_title	skill_description	content_preview	review_notes
example/repo@skill-alpha	example/repo	skill-alpha	pending	60.00	matched	installed	present	80.00	manual	Skill Alpha	alpha desc	alpha preview	worker1
example/repo@skill-beta	example/repo	skill-beta	pending	40.00	matched	installed	present	75.00	verified	Skill Beta	beta desc	beta preview	worker1
EOF_REVIEW

  cat > "$tmp/worker2.tsv" <<'EOF_REVIEW'
skill_ref	repo	skill	manifest_status	auto_score	name_check	install_check	skill_md_check	content_overlap	review_status	skill_title	skill_description	content_preview	review_notes
example/repo@skill-alpha	example/repo	skill-alpha	pending	58.00	matched	installed	present	70.00	verified	Skill Alpha	alpha desc	alpha preview	worker2
EOF_REVIEW

  "$SCRIPT_PATH" merge-content-reviews --out "$tmp/merged.tsv" "$tmp/worker1.tsv" "$tmp/worker2.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_row_count "$tmp/merged.tsv" 2 || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-alpha" {exit !($10=="verified")}' "$tmp/merged.tsv" || return 1
}

test_prepare_ai_reviews_process() {
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	channels	find_installs	top_installs	github_stars	github_updated_at	query_overlap	auto_score	risk_level	status	review_notes	approved_by	approved_at
example/repo@skill-alpha	example/repo	skill-alpha	find	120	0	0		50.00	60.00	medium	pending	auto	me	
example/repo@skill-beta	example/repo	skill-beta	find	80	0	0		20.00	30.00	high	approved	auto	me	2026-02-16T00:00:00Z
EOF_MANIFEST

  cat > "$tmp/review_content.tsv" <<'EOF_CONTENT'
skill_ref	repo	skill	manifest_status	auto_score	name_check	install_check	skill_md_check	content_overlap	review_status	skill_title	skill_description	content_preview	review_notes
example/repo@skill-alpha	example/repo	skill-alpha	pending	60.00	matched	installed	present	80.00	verified	Skill Alpha	alpha desc	alpha preview	ok
example/repo@skill-beta	example/repo	skill-beta	approved	30.00	matched	installed	present	50.00	manual	Skill Beta	beta desc	beta preview	ok
example/repo@skill-gamma	example/repo	skill-gamma	pending	20.00	matched	installed	present	10.00	failed	Skill Gamma	gamma desc	gamma preview	fail
EOF_CONTENT

  "$SCRIPT_PATH" prepare-ai-reviews --manifest "$tmp/review_manifest.tsv" --content-report "$tmp/review_content.tsv" --status pending --out "$tmp/review_ai.queue.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_row_count "$tmp/review_ai.queue.tsv" 1 || return 1
  awk -F '\t' 'NR==2 {exit !($1=="example/repo@skill-alpha" && $7=="verified")}' "$tmp/review_ai.queue.tsv" || return 1
}

test_merge_ai_reviews_process() {
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/worker1.tsv" <<'EOF_AI'
skill_ref	repo	skill	manifest_status	auto_score	content_overlap	heuristic_status	skill_title	skill_description	content_preview	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at
example/repo@skill-alpha	example/repo	skill-alpha	pending	60.00	80.00	verified	Skill Alpha	alpha desc	alpha preview	70	65	40	0.50	hold	pending	worker1 summary	worker1 rationale	worker-1	2026-02-18T00:00:00Z
example/repo@skill-beta	example/repo	skill-beta	pending	40.00	75.00	verified	Skill Beta	beta desc	beta preview	90	88	20	0.90	approve	approved	worker1 summary	worker1 rationale	worker-1	2026-02-18T00:00:00Z
EOF_AI

  cat > "$tmp/worker2.tsv" <<'EOF_AI'
skill_ref	repo	skill	manifest_status	auto_score	content_overlap	heuristic_status	skill_title	skill_description	content_preview	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at
example/repo@skill-alpha	example/repo	skill-alpha	pending	58.00	78.00	verified	Skill Alpha	alpha desc	alpha preview	85	82	25	0.70	approve	approved	worker2 summary	worker2 rationale	worker-2	2026-02-18T00:01:00Z
EOF_AI

  "$SCRIPT_PATH" merge-ai-reviews --out "$tmp/merged_ai.tsv" "$tmp/worker1.tsv" "$tmp/worker2.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_row_count "$tmp/merged_ai.tsv" 2 || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-alpha" {exit !($16=="approved" && $19=="worker-2")}' "$tmp/merged_ai.tsv" || return 1
}

test_apply_ai_reviews_process() {
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	channels	find_installs	top_installs	github_stars	github_updated_at	query_overlap	auto_score	risk_level	status	review_notes	approved_by	approved_at
example/repo@skill-alpha	example/repo	skill-alpha	find	120	0	0		50.00	60.00	medium	pending	auto		
example/repo@skill-beta	example/repo	skill-beta	find	80	0	0		20.00	30.00	high	pending	auto		
EOF_MANIFEST

  cat > "$tmp/review_ai.merged.tsv" <<'EOF_AI'
skill_ref	repo	skill	manifest_status	auto_score	content_overlap	heuristic_status	skill_title	skill_description	content_preview	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at
example/repo@skill-alpha	example/repo	skill-alpha	pending	60.00	80.00	verified	Skill Alpha	alpha desc	alpha preview	91	88	22	0.92	approve	approved	good fit	rationale	reviewer-a	2026-02-18T01:00:00Z
example/repo@skill-beta	example/repo	skill-beta	pending	30.00	20.00	manual	Skill Beta	beta desc	beta preview	30	25	85	0.81	reject	rejected	poor fit	rationale	reviewer-b	2026-02-18T01:01:00Z
EOF_AI

  "$SCRIPT_PATH" apply-ai-reviews --manifest "$tmp/review_manifest.tsv" --ai-reviews "$tmp/review_ai.merged.tsv" --out "$tmp/review_manifest.ai.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$tmp/review_manifest.ai.tsv" || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-alpha" {exit !($12=="approved" && $14=="reviewer-a" && $15=="2026-02-18T01:00:00Z")}' "$tmp/review_manifest.ai.tsv" || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-beta" {exit !($12=="rejected" && $14=="reviewer-b" && $15=="2026-02-18T01:01:00Z")}' "$tmp/review_manifest.ai.tsv" || return 1
}

test_install_file_process() {
  local tmp alpha_calls beta_calls
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/install.list.tsv" <<'EOF_LIST'
example/repo@skill-alpha
example/repo@skill-alpha
invalid-entry
example/repo@skill-beta
EOF_LIST

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install --file "$tmp/install.list.tsv" --dry-run > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  alpha_calls="$(count_fixed_matches "$tmp/stdout.txt" "DRY-RUN: npx skills add example/repo@skill-alpha -y")"
  beta_calls="$(count_fixed_matches "$tmp/stdout.txt" "DRY-RUN: npx skills add example/repo@skill-beta -y")"
  [[ "$alpha_calls" -eq 1 ]] || return 1
  [[ "$beta_calls" -eq 1 ]] || return 1
}

test_install_file_exec_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/install.list.tsv" <<'EOF_LIST'
example/repo@skill-alpha
EOF_LIST

  (cd "$tmp" && TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install --file "$tmp/install.list.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt") || return 1

  assert_file_exists "$tmp/.agents/skills/skill-alpha/SKILL.md" || return 1
}

test_install_approved_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	channels	find_installs	top_installs	github_stars	github_updated_at	query_overlap	auto_score	risk_level	status	review_notes	approved_by	approved_at
example/repo@skill-alpha	example/repo	skill-alpha	find	120	0	0		50.00	60.00	medium	approved	manual	me	2026-02-16T00:00:00Z
example/repo@skill-beta	example/repo	skill-beta	find	80	0	0		20.00	30.00	high	pending	manual		
EOF_MANIFEST

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.tsv" --report "$tmp/install.report.tsv" --dry-run > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_contains "$tmp/stdout.txt" "skill-alpha" || return 1
  assert_not_contains "$tmp/stdout.txt" "skill-beta" || return 1
  assert_file_exists "$tmp/install.report.tsv" || return 1
}

test_install_approved_stdin_safe_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	channels	find_installs	top_installs	github_stars	github_updated_at	query_overlap	auto_score	risk_level	status	review_notes	approved_by	approved_at
example/repo@skill-alpha	example/repo	skill-alpha	find	120	0	0		50.00	60.00	medium	approved	manual	me	2026-02-16T00:00:00Z
example/toolbox@skill-beta	example/toolbox	skill-beta	find	100	0	0		45.00	58.00	medium	approved	manual	me	2026-02-16T00:00:00Z
EOF_MANIFEST

  (cd "$tmp" && TEST_FIXTURE_DIR="$FIXTURE_DIR" MOCK_NPX_READ_STDIN_ON_ADD="1" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.tsv" --report "$tmp/install.report.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt") || return 1

  assert_file_exists "$tmp/install.report.tsv" || return 1
  assert_row_count "$tmp/install.report.tsv" 2 || return 1
  assert_contains "$tmp/install.report.tsv" $'\texample/repo\t' || return 1
  assert_contains "$tmp/install.report.tsv" $'\texample/toolbox\t' || return 1
}

test_install_approved_exec_audit_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	channels	find_installs	top_installs	github_stars	github_updated_at	query_overlap	auto_score	risk_level	status	review_notes	approved_by	approved_at
example/repo@skill-alpha	example/repo	skill-alpha	find	120	0	0		50.00	60.00	medium	approved	manual	me	2026-02-16T00:00:00Z
EOF_MANIFEST

  (cd "$tmp" && TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.tsv" --report "$tmp/install.report.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt") || return 1

  assert_file_exists "$tmp/install.report.tsv" || return 1
  assert_file_exists "$tmp/audit.log" || return 1
  assert_file_exists "$tmp/.agents/skills/skill-alpha/SKILL.md" || return 1
  awk -F '\t' 'NR==2 {exit !($4=="installed")}' "$tmp/install.report.tsv" || return 1
  assert_contains "$tmp/audit.log" "Project Skills" || return 1
  assert_contains "$tmp/audit.log" "All skills are up to date" || return 1
}

test_audit_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" audit --out "$tmp/audit.log" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$tmp/audit.log" || return 1
  assert_contains "$tmp/audit.log" "# Audit Log" || return 1
  assert_contains "$tmp/audit.log" "## npx skills list" || return 1
}

# --------------------------
# Integration Tests
# --------------------------

test_integration_run_artifacts() {
  local tmp project run_dir
  tmp="$(mktemp -d)"
  project="$tmp/project"
  run_dir="$tmp/run-auto"
  mkdir -p "$project/docs"
  setup_mock_env "$tmp"

  cat > "$project/README.md" <<'EOF_README'
# Demo
This project uses python workers and observability.
EOF_README

  cat > "$project/docs/backlog.md" <<'EOF_BACKLOG'
- add test coverage
- improve retry handling
EOF_BACKLOG

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" SKILLS_BATCH_TOP_HTML_FILE="$FIXTURE_DIR/skills_home_sample.html" "$SCRIPT_PATH" run --project-root "$project" --out-dir "$run_dir" --top 3 > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$run_dir/project_signals.md" || return 1
  assert_file_exists "$run_dir/query_seeds.txt" || return 1
  assert_file_exists "$run_dir/candidates.find.tsv" || return 1
  assert_file_exists "$run_dir/candidates.top.tsv" || return 1
  assert_file_exists "$run_dir/candidates.github.tsv" || return 1
  assert_file_exists "$run_dir/candidates.merged.tsv" || return 1
  assert_file_exists "$run_dir/review_manifest.tsv" || return 1
}

test_integration_run_to_ai_to_install() {
  local tmp project run_dir queue worker1 worker2
  tmp="$(mktemp -d)"
  project="$tmp/project"
  run_dir="$tmp/run-full"
  mkdir -p "$project/docs"
  setup_mock_env "$tmp"

  cat > "$project/README.md" <<'EOF_README'
# Demo
python testing and observability for workflow reliability
EOF_README

  cat > "$project/docs/backlog.md" <<'EOF_BACKLOG'
- python testing
- workflow reliability
EOF_BACKLOG

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" SKILLS_BATCH_TOP_HTML_FILE="$FIXTURE_DIR/skills_home_sample.html" "$SCRIPT_PATH" run --project-root "$project" --out-dir "$run_dir" --top 3 --find-query "python testing" --github-query "python observability" > "$tmp/run.stdout.txt" 2> "$tmp/run.stderr.txt" || return 1

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" validate-content --manifest "$run_dir/review_manifest.tsv" --query-file "$run_dir/query_seeds.txt" --status pending --skill-ref "example/repo@skill-alpha" --out "$run_dir/review_content.tsv" > "$tmp/validate.stdout.txt" 2> "$tmp/validate.stderr.txt" || return 1

  "$SCRIPT_PATH" prepare-ai-reviews --manifest "$run_dir/review_manifest.tsv" --content-report "$run_dir/review_content.tsv" --status pending --out "$run_dir/review_ai.queue.tsv" > "$tmp/prepare_ai.stdout.txt" 2> "$tmp/prepare_ai.stderr.txt" || return 1

  queue="$run_dir/review_ai.queue.tsv"
  worker1="$run_dir/review_ai.worker1.tsv"
  worker2="$run_dir/review_ai.worker2.tsv"

  assert_row_count "$queue" 1 || return 1

  head -n 1 "$queue" > "$worker1"
  awk -F '\t' -v OFS='\t' 'NR==2 {$11="95"; $12="90"; $13="20"; $14="0.95"; $15="approve"; $16="approved"; $17="excellent fit"; $18="covers testing+reliability"; $19="worker-1"; $20="2026-02-18T02:00:00Z"; print}' "$queue" >> "$worker1"

  head -n 1 "$queue" > "$worker2"
  awk -F '\t' -v OFS='\t' 'NR==2 {$11="70"; $12="65"; $13="40"; $14="0.70"; $15="hold"; $16="pending"; $17="possible fit"; $18="needs manual confirmation"; $19="worker-2"; $20="2026-02-18T02:01:00Z"; print}' "$queue" >> "$worker2"

  "$SCRIPT_PATH" merge-ai-reviews --out "$run_dir/review_ai.merged.tsv" "$worker1" "$worker2" > "$tmp/merge_ai.stdout.txt" 2> "$tmp/merge_ai.stderr.txt" || return 1
  "$SCRIPT_PATH" apply-ai-reviews --manifest "$run_dir/review_manifest.tsv" --ai-reviews "$run_dir/review_ai.merged.tsv" --out "$run_dir/review_manifest.ai.tsv" > "$tmp/apply_ai.stdout.txt" 2> "$tmp/apply_ai.stderr.txt" || return 1

  awk -F '\t' 'NR>1 && $1=="example/repo@skill-alpha" {exit !($12=="approved" && $14=="worker-1")}' "$run_dir/review_manifest.ai.tsv" || return 1

  (cd "$project" && TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$run_dir/review_manifest.ai.tsv" --report "$run_dir/install.report.tsv" > "$tmp/install.stdout.txt" 2> "$tmp/install.stderr.txt") || return 1

  assert_file_exists "$run_dir/install.report.tsv" || return 1
  assert_file_exists "$run_dir/audit.log" || return 1
  assert_file_exists "$project/.agents/skills/skill-alpha/SKILL.md" || return 1
}

# --------------------------
# Runner
# --------------------------

log "## Process Suite"
run_test "process" "collect-find" test_collect_find_process
run_test "process" "collect-top" test_collect_top_process
run_test "process" "collect-github" test_collect_github_process
run_test "process" "collect-github stdin-safe" test_collect_github_stdin_safe_process
run_test "process" "import-web" test_import_web_process
run_test "process" "import-web stdin-safe" test_import_web_stdin_safe_process
run_test "process" "merge" test_merge_process
run_test "process" "validate-content core" test_validate_content_process
run_test "process" "validate-content filter" test_validate_content_filter_process
run_test "process" "validate-content stdin-safe" test_validate_content_stdin_safe_process
run_test "process" "validate-content optimization (skip list)" test_validate_content_optimization_success_process
run_test "process" "validate-content optimization (cache list)" test_validate_content_optimization_failure_cache_process
run_test "process" "merge-content-reviews" test_merge_content_reviews_process
run_test "process" "prepare-ai-reviews" test_prepare_ai_reviews_process
run_test "process" "merge-ai-reviews" test_merge_ai_reviews_process
run_test "process" "apply-ai-reviews" test_apply_ai_reviews_process
run_test "process" "install --file dry-run" test_install_file_process
run_test "process" "install --file exec" test_install_file_exec_process
run_test "process" "install-approved dry-run" test_install_approved_process
run_test "process" "install-approved stdin-safe" test_install_approved_stdin_safe_process
run_test "process" "install-approved exec+audit" test_install_approved_exec_audit_process
run_test "process" "audit" test_audit_process

log ""
log "## Integration Suite"
run_test "integration" "run artifacts" test_integration_run_artifacts
run_test "integration" "run -> validate -> ai -> install" test_integration_run_to_ai_to_install

log ""
log "summary: pass=$PASS fail=$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
