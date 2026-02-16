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
  local name="$1"
  shift
  if "$@"; then
    log "ok - $name"
    PASS=$((PASS + 1))
  else
    log "not ok - $name"
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
  rg -q --fixed-strings "$text" "$path" || {
    log "assertion failed: '$text' not found in $path"
    return 1
  }
}

assert_not_contains() {
  local path="$1"
  local text="$2"
  if rg -q --fixed-strings "$text" "$path"; then
    log "assertion failed: '$text' unexpectedly found in $path"
    return 1
  fi
}

setup_mock_env() {
  local dir="$1"
  mkdir -p "$dir/bin"

  cat > "$dir/bin/npx" <<'MOCK_NPX'
#!/usr/bin/env bash
set -euo pipefail
fixture_dir="${TEST_FIXTURE_DIR:?}"

if [[ "${1:-}" != "skills" ]]; then
  echo "unexpected npx call: $*" >&2
  exit 1
fi
shift
sub="${1:-}"
shift || true

case "$sub" in
  find)
    if [[ "${MOCK_FIND_MODE:-}" == "empty" ]]; then
      echo "No skills found"
    else
      cat "$fixture_dir/find_sample.txt"
    fi
    ;;
  add)
    repo="${1:-}"
    shift || true
    if [[ "${1:-}" == "--list" ]]; then
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
      echo "MOCK_ADD repo=${repo} args=$*"
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
  cat <<'JSON'
[
  {"owner":{"login":"example"},"name":"repo","stargazersCount":42,"updatedAt":"2026-02-10T00:00:00Z"},
  {"owner":{"login":"example"},"name":"toolbox","stargazersCount":11,"updatedAt":"2026-01-12T00:00:00Z"}
]
JSON
  exit 0
fi
echo "unsupported gh command: $*" >&2
exit 1
MOCK_GH
  chmod +x "$dir/bin/gh"

  cat > "$dir/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
cat "${TEST_FIXTURE_DIR:?}/skills_home_sample.html"
MOCK_CURL
  chmod +x "$dir/bin/curl"
}

run_collect_find_regression() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  local out="$tmp/candidates.find.tsv"
  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" collect-find --out "$out" "python testing" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$out" || return 1
  assert_contains "$out" $'skill_ref\tfind_installs\tfind_queries' || return 1
  assert_contains "$out" "wshobson/agents@python-testing-patterns" || return 1

  local rows
  rows="$(awk 'END {print NR-1}' "$out")"
  [[ "$rows" -ge 1 ]] || return 1
}

run_collect_top_fixture_parse() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  local out="$tmp/candidates.top.tsv"
  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" SKILLS_BATCH_TOP_HTML_FILE="$FIXTURE_DIR/skills_home_sample.html" "$SCRIPT_PATH" collect-top --out "$out" --top 2 > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$out" || return 1
  assert_contains "$out" "vercel-labs/skills@find-skills" || return 1

  local rows
  rows="$(awk 'END {print NR-1}' "$out")"
  [[ "$rows" -eq 2 ]] || return 1
}

run_merge_dedupe() {
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

  "$SCRIPT_PATH" merge \
    --find "$tmp/find.tsv" \
    --top "$tmp/top.tsv" \
    --github "$tmp/github.tsv" \
    --web "$tmp/web.tsv" \
    --query-file "$tmp/query.txt" \
    --out "$tmp/merged.tsv" \
    --manifest "$tmp/manifest.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$tmp/merged.tsv" || return 1
  assert_file_exists "$tmp/manifest.tsv" || return 1

  awk -F '\t' '$1=="example/repo@skill-alpha"{c++} END{exit !(c==1)}' "$tmp/merged.tsv" || return 1
  assert_contains "$tmp/merged.tsv" "find,top,github,web" || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-alpha" {exit !($12=="pending")}' "$tmp/manifest.tsv" || return 1
}

run_install_approved_dry_run_gate() {
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

run_install_approved_no_approved() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	channels	find_installs	top_installs	github_stars	github_updated_at	query_overlap	auto_score	risk_level	status	review_notes	approved_by	approved_at
example/repo@skill-beta	example/repo	skill-beta	find	80	0	0		20.00	30.00	high	pending	manual		
EOF_MANIFEST

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.tsv" --dry-run > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_contains "$tmp/stdout.txt" "No approved skills found" || return 1
}

run_e2e_run_outputs() {
  local tmp project
  tmp="$(mktemp -d)"
  project="$tmp/project"
  mkdir -p "$project/docs"
  setup_mock_env "$tmp"

  cat > "$project/README.md" <<'EOF_README'
# Demo
This project uses python, async workers, observability metrics, and llm prompts.
EOF_README

  cat > "$project/docs/backlog.md" <<'EOF_BACKLOG'
- Add pytest test suite
- Improve retry/timeout resilience
EOF_BACKLOG

  TEST_FIXTURE_DIR="$FIXTURE_DIR" \
  PATH="$tmp/bin:$PATH" \
  SKILLS_BATCH_TOP_HTML_FILE="$FIXTURE_DIR/skills_home_sample.html" \
  "$SCRIPT_PATH" run \
    --project-root "$project" \
    --top 3 \
    --find-query "python testing" \
    --github-query "python observability" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  local run_dir
  run_dir="$(ls -1d "$project/.agents/skills-batch-ops/runs/"* | sort | tail -n 1)"

  assert_file_exists "$run_dir/project_signals.md" || return 1
  assert_file_exists "$run_dir/query_seeds.txt" || return 1
  assert_file_exists "$run_dir/candidates.find.tsv" || return 1
  assert_file_exists "$run_dir/candidates.top.tsv" || return 1
  assert_file_exists "$run_dir/candidates.github.tsv" || return 1
  assert_file_exists "$run_dir/candidates.merged.tsv" || return 1
  assert_file_exists "$run_dir/review_manifest.tsv" || return 1
}

run_install_audit_log() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	channels	find_installs	top_installs	github_stars	github_updated_at	query_overlap	auto_score	risk_level	status	review_notes	approved_by	approved_at
example/repo@skill-alpha	example/repo	skill-alpha	find	120	0	0		50.00	60.00	medium	approved	manual	me	2026-02-16T00:00:00Z
EOF_MANIFEST

  TEST_FIXTURE_DIR="$FIXTURE_DIR" PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.tsv" --report "$tmp/install.report.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$tmp/install.report.tsv" || return 1
  assert_file_exists "$tmp/audit.log" || return 1
  assert_contains "$tmp/audit.log" "Project Skills" || return 1
  assert_contains "$tmp/audit.log" "All skills are up to date" || return 1
}

run_test "collect-find regression" run_collect_find_regression
run_test "collect-top fixture parsing" run_collect_top_fixture_parse
run_test "merge dedupe and channels" run_merge_dedupe
run_test "install-approved dry-run gate" run_install_approved_dry_run_gate
run_test "install-approved no-approved" run_install_approved_no_approved
run_test "run e2e artifacts" run_e2e_run_outputs
run_test "install-approved writes audit" run_install_audit_log

log ""
log "summary: pass=$PASS fail=$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
