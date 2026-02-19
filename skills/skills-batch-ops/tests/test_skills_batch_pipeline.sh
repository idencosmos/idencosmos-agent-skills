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
  assert_contains "$tmp/candidates.merged.tsv" $'\t2\t238456\t' || return 1
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

log "## Pipeline Suite"
run_test "collect-find/popular/web + merge" test_collect_and_merge_process
run_test "build-manifest + install-manifest dry-run" test_manifest_and_install_dry_run_process

log ""
log "summary: pass=$pass fail=$fail"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
