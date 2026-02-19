#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPELINE_SCRIPT="$ROOT_DIR/scripts/skills_batch_pipeline.py"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"

pass=0
fail=0

log() {
  printf '%s\n' "$*"
}

run_test() {
  local name="$1"
  local fn="$2"
  if "$fn"; then
    log "ok - $name"
    pass=$((pass + 1))
  else
    log "not ok - $name"
    fail=$((fail + 1))
  fi
}

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || {
    log "assertion failed: missing file: $path"
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

setup_mock_find_env() {
  local dir="$1"
  mkdir -p "$dir/bin"

  cat > "$dir/bin/npx" <<'MOCK_NPX'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "skills" || "${2:-}" != "find" ]]; then
  echo "unexpected npx call: $*" >&2
  exit 1
fi

query="${3:-}"
echo "query=$query" >&2
printf '\033[38;5;145m%s\033[0m \033[36m%s installs\033[0m\n' \
  "wshobson/agents@python-testing-patterns" "3.4K"
printf '\033[38;5;145m%s\033[0m \033[36m%s installs\033[0m\n' \
  "vercel-labs/skills@find-skills" "238.4K"
MOCK_NPX
  chmod +x "$dir/bin/npx"
}

test_collect_and_merge_process() {
  local tmp
  tmp="$(mktemp -d)"

  cp "$FIXTURE_DIR/find_sample.txt" "$tmp/find_output.txt"
  cp "$FIXTURE_DIR/skills_home_sample.html" "$tmp/popular_output.html"
  cat > "$tmp/web_candidates.tsv" <<'TSV'
skill_ref	repo	skill	installs	evidence_url	evidence_note
vercel-labs/skills@find-skills	vercel-labs/skills	find-skills	238456	https://example.com/find	web corroboration
wshobson/agents@python-testing-patterns	wshobson/agents	python-testing-patterns	3400	https://example.com/python-testing-patterns	community roundup
TSV

  python3 "$PIPELINE_SCRIPT" collect-find --input "$tmp/find_output.txt" --out "$tmp/candidates.find.tsv"
  python3 "$PIPELINE_SCRIPT" collect-popular --input "$tmp/popular_output.html" --out "$tmp/candidates.popular.tsv"
  python3 "$PIPELINE_SCRIPT" collect-web --input "$tmp/web_candidates.tsv" --out "$tmp/candidates.web.tsv"
  python3 "$PIPELINE_SCRIPT" merge-candidates \
    --out "$tmp/candidates.merged.tsv" \
    "$tmp/candidates.find.tsv" \
    "$tmp/candidates.popular.tsv" \
    "$tmp/candidates.web.tsv"

  assert_file_exists "$tmp/candidates.find.tsv" || return 1
  assert_file_exists "$tmp/candidates.popular.tsv" || return 1
  assert_file_exists "$tmp/candidates.web.tsv" || return 1
  assert_file_exists "$tmp/candidates.merged.tsv" || return 1
  assert_not_contains "$tmp/candidates.find.tsv" "owner/repo@skill" || return 1
  assert_contains "$tmp/candidates.merged.tsv" "vercel-labs/skills@find-skills" || return 1
  assert_contains "$tmp/candidates.merged.tsv" $'\t3\t238456\t' || return 1
}

test_collect_sources_live_seed_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_find_env "$tmp"

  mkdir -p "$tmp/project"
  cat > "$tmp/project/README.md" <<'EOF_README'
# Demo Project

Python automation and testing workflows.
EOF_README

  cat > "$tmp/web_seed.tsv" <<'TSV'
skill_ref	repo	skill	installs	evidence_url	evidence_note
wshobson/agents@python-testing-patterns	wshobson/agents	python-testing-patterns	3400	https://github.com/wshobson/agents	seed web result
TSV

  PATH="$tmp/bin:$PATH" python3 "$PIPELINE_SCRIPT" collect-sources-live \
    --project-root "$tmp/project" \
    --run-dir "$tmp/run" \
    --find-command "npx skills find" \
    --find-query "python testing" \
    --popular-url "file://$FIXTURE_DIR/skills_home_sample.html" \
    --web-mode seed \
    --web-seed-input "$tmp/web_seed.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"

  assert_file_exists "$tmp/run/project_profile.tsv" || return 1
  assert_file_exists "$tmp/run/find_output.txt" || return 1
  assert_file_exists "$tmp/run/popular_output.html" || return 1
  assert_file_exists "$tmp/run/web_candidates.tsv" || return 1
  assert_file_exists "$tmp/run/candidates.find.tsv" || return 1
  assert_file_exists "$tmp/run/candidates.popular.tsv" || return 1
  assert_file_exists "$tmp/run/candidates.web.tsv" || return 1
  assert_contains "$tmp/run/candidates.find.tsv" "wshobson/agents@python-testing-patterns" || return 1
  assert_not_contains "$tmp/run/candidates.find.tsv" "145m" || return 1
  assert_contains "$tmp/stdout.txt" "source_counts: find=" || return 1
}

test_manifest_and_install_dry_run_process() {
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/candidates.merged.tsv" <<'TSV'
skill_ref	repo	skill	methods	method_count	installs_max	evidence_count	source_files
vercel-labs/skills@find-skills	vercel-labs/skills	find-skills	find,web	2	238456	2	a.tsv,b.tsv
wshobson/agents@python-testing-patterns	wshobson/agents	python-testing-patterns	find	1	3400	1	a.tsv
TSV

  cat > "$tmp/review_content.tsv" <<'TSV'
skill_ref	repo	skill	content_status	content_checked	source_url	frontmatter_name	frontmatter_description	reason
vercel-labs/skills@find-skills	vercel-labs/skills	find-skills	passed	true	https://example.com/find.md	find-skills	ok	ok
wshobson/agents@python-testing-patterns	wshobson/agents	python-testing-patterns	failed	false				skill_md_not_found
TSV

  python3 "$PIPELINE_SCRIPT" build-manifest \
    --merged "$tmp/candidates.merged.tsv" \
    --content-report "$tmp/review_content.tsv" \
    --out "$tmp/review_manifest.ai.tsv" \
    --min-methods 2 \
    --limit 8

  python3 "$PIPELINE_SCRIPT" install-manifest \
    --manifest "$tmp/review_manifest.ai.tsv" \
    --report "$tmp/install.report.tsv" \
    --dry-run

  assert_file_exists "$tmp/review_manifest.ai.tsv" || return 1
  assert_file_exists "$tmp/install.report.tsv" || return 1
  assert_contains "$tmp/review_manifest.ai.tsv" $'\tapproved\tapproved\tapprove\t' || return 1
  assert_contains "$tmp/review_manifest.ai.tsv" $'\trejected\trejected\treject\t' || return 1
  assert_row_count "$tmp/install.report.tsv" 1 || return 1
  assert_contains "$tmp/install.report.tsv" $'\tdry-run\tnpx skills add vercel-labs/skills --skill find-skills -y\tdry-run' || return 1
}

test_manifest_project_keyword_gate_process() {
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/candidates.merged.tsv" <<'TSV'
skill_ref	repo	skill	methods	method_count	installs_max	evidence_count	source_files
example/repo@generic-skill	example/repo	generic-skill	find,popular,web	3	9000	3	a.tsv,b.tsv,c.tsv
TSV

  cat > "$tmp/review_content.tsv" <<'TSV'
skill_ref	repo	skill	content_status	content_checked	source_url	frontmatter_name	frontmatter_description	body_line_count	body_char_count	content_keywords	reason
example/repo@generic-skill	example/repo	generic-skill	passed	true	https://example.com/skill.md	generic-skill	Generic skill	10	240	marketing,content,cms	ok
TSV

  cat > "$tmp/project_profile.tsv" <<'TSV'
key	value
generated_at	2026-02-19T00:00:00Z
project_root	/tmp/example
technologies	python,nodejs
top_keywords	python,testing,pytest
TSV

  python3 "$PIPELINE_SCRIPT" build-manifest \
    --merged "$tmp/candidates.merged.tsv" \
    --content-report "$tmp/review_content.tsv" \
    --project-profile "$tmp/project_profile.tsv" \
    --out "$tmp/review_manifest.keyword-gated.tsv" \
    --min-methods 2 \
    --limit 8

  python3 "$PIPELINE_SCRIPT" build-manifest \
    --merged "$tmp/candidates.merged.tsv" \
    --content-report "$tmp/review_content.tsv" \
    --project-profile "$tmp/project_profile.tsv" \
    --out "$tmp/review_manifest.keyword-optional.tsv" \
    --min-methods 2 \
    --limit 8 \
    --min-project-keyword-hits 0

  assert_contains "$tmp/review_manifest.keyword-gated.tsv" $'\tpending\tpending\thold\t' || return 1
  assert_contains "$tmp/review_manifest.keyword-gated.tsv" "project keyword hits are below min_project_keyword_hits=1" || return 1
  assert_contains "$tmp/review_manifest.keyword-optional.tsv" $'\tapproved\tapproved\tapprove\t' || return 1
}

test_parser_root_skill_and_crlf_support_process() {
  local tmp
  tmp="$(mktemp -d)"

  PIPELINE_SCRIPT_PATH="$PIPELINE_SCRIPT" python3 - > "$tmp/parser_check.txt" <<'PY'
import importlib.util
import os
from pathlib import Path

script_path = Path(os.environ["PIPELINE_SCRIPT_PATH"]).resolve()
spec = importlib.util.spec_from_file_location("skills_batch_pipeline", script_path)
if spec is None or spec.loader is None:
    raise RuntimeError("failed to load skills_batch_pipeline module")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

urls = module.candidate_skill_md_urls("example/repo", "skill-alpha")
assert urls[0] == "https://raw.githubusercontent.com/example/repo/main/SKILL.md"
assert urls[1] == "https://raw.githubusercontent.com/example/repo/master/SKILL.md"

parsed = module.parse_skill_markdown(
    "---\r\nname: skill-alpha\r\ndescription: Demo skill\r\n---\r\n# Heading\r\n\r\nBody line.\r\n"
)
assert parsed is not None
name, description, body = parsed
assert name == "skill-alpha"
assert description == "Demo skill"
assert "Body line." in body
print("ok")
PY

  assert_contains "$tmp/parser_check.txt" "ok" || return 1
}

log "## Pipeline Suite"
run_test "collect-find/popular/web + merge" test_collect_and_merge_process
run_test "collect-sources-live seed mode" test_collect_sources_live_seed_process
run_test "build-manifest + install-manifest dry-run" test_manifest_and_install_dry_run_process
run_test "build-manifest project keyword gate" test_manifest_project_keyword_gate_process
run_test "parser root SKILL.md + CRLF support" test_parser_root_skill_and_crlf_support_process

log ""
log "summary: pass=$pass fail=$fail"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
