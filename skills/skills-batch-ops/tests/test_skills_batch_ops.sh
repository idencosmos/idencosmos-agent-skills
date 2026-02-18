#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/skills_batch_ops.sh"

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

log_file="${MOCK_NPX_LOG:-}"
list_fail_repos=",${MOCK_LIST_FAIL_REPOS:-},"
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
│      Alpha skill.
│
│    skill-beta
│
│      Beta skill.
│
│    skill-fail-install
│
│      Install should fail.
│
│    skill-missing-md
│
│      Installed without SKILL.md.
│
└  Use --skill <name> to install specific skills
LIST
      exit 0
    fi

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
      if [[ "$skill" == "skill-fail-install" ]]; then
        echo "forced install failure for skill-fail-install" >&2
        exit 1
      fi

      mkdir -p ".agents/skills/$skill"
      if [[ "$skill" != "skill-missing-md" ]]; then
        cat > ".agents/skills/$skill/SKILL.md" <<EOF_SKILL
---
name: $skill
description: Mock skill $skill
---
# $skill

This is a mock skill.
EOF_SKILL
      fi
    done

    echo "MOCK_ADD repo=$repo skills=${skills[*]}"
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
}

# --------------------------
# Process Tests
# --------------------------

test_run_ai_only_process() {
  local tmp project run_dir
  tmp="$(mktemp -d)"
  project="$tmp/project"
  run_dir="$tmp/run"
  mkdir -p "$project/src" "$project/docs"
  setup_mock_env "$tmp"

  cat > "$project/README.md" <<'EOF_README'
# Demo
AI-only pipeline verification target.
EOF_README

  cat > "$project/src/main.py" <<'EOF_PY'
print("hello")
EOF_PY

  printf '\x89PNG\r\n\x1a\n' > "$project/docs/image.png"

  PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" run --project-root "$project" --out-dir "$run_dir" --channel find --channel github > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$run_dir/project_context.files.tsv" || return 1
  assert_file_exists "$run_dir/project_context.chunks.ndjson" || return 1
  assert_file_exists "$run_dir/project_intent.ai.json" || return 1
  assert_file_exists "$run_dir/review_discovery.queue.tsv" || return 1
  assert_file_exists "$run_dir/candidates.ai.tsv" || return 1
  assert_file_exists "$run_dir/review_manifest.tsv" || return 1

  assert_row_count "$run_dir/review_discovery.queue.tsv" 2 || return 1
  assert_contains "$run_dir/project_context.files.tsv" "README.md" || return 1
}

test_prepare_ai_discovery_process() {
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/context.files.tsv" <<'EOF_FILES'
abs_path	rel_path	size_bytes	is_text	is_chunked	skip_reason	sha256
/tmp/a	README.md	10	yes	yes		deadbeef
EOF_FILES

  cat > "$tmp/context.chunks.ndjson" <<'EOF_CHUNKS'
{"chunk_id":"README.md:1-1","content":"demo"}
EOF_CHUNKS

  cat > "$tmp/intent.json" <<'EOF_INTENT'
{"goal":"Build resilient investment agent","domain":"autonomous-investment","constraints":["safety"]}
EOF_INTENT

  "$SCRIPT_PATH" prepare-ai-discovery \
    --project-root "$tmp" \
    --project-context-files "$tmp/context.files.tsv" \
    --project-context-chunks "$tmp/context.chunks.ndjson" \
    --project-intent "$tmp/intent.json" \
    --out "$tmp/review_discovery.queue.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$tmp/review_discovery.queue.tsv" || return 1
  assert_row_count "$tmp/review_discovery.queue.tsv" 4 || return 1
  assert_contains "$tmp/review_discovery.queue.tsv" $'\tfind\t' || return 1
  assert_contains "$tmp/review_discovery.queue.tsv" $'\tgithub\t' || return 1
}

test_merge_ai_discovery_process() {
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/worker1.tsv" <<'EOF_W1'
skill_ref	repo	skill	discovery_channels	discovery_evidence	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at
example/repo@skill-alpha	example/repo	skill-alpha	find	find evidence	80	78	30	0.70	hold	pending	candidate alpha	worker1 rationale	worker-1	2026-02-18T10:00:00Z
example/repo@skill-beta	example/repo	skill-beta	github	github evidence	70	65	35	0.60	hold	pending	candidate beta	worker1 rationale	worker-1	2026-02-18T10:01:00Z
EOF_W1

  cat > "$tmp/worker2.tsv" <<'EOF_W2'
skill_ref	repo	skill	discovery_channels	discovery_evidence	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at
example/repo@skill-alpha	example/repo	skill-alpha	github	github evidence alpha	90	88	22	0.92	approve	approved	strong candidate alpha	worker2 rationale	worker-2	2026-02-18T10:02:00Z
EOF_W2

  "$SCRIPT_PATH" merge-ai-discovery --out "$tmp/candidates.ai.tsv" --manifest "$tmp/review_manifest.tsv" "$tmp/worker1.tsv" "$tmp/worker2.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_row_count "$tmp/candidates.ai.tsv" 2 || return 1
  assert_row_count "$tmp/review_manifest.tsv" 2 || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-alpha" {exit !($4=="find,github" && $9=="0.92")}' "$tmp/candidates.ai.tsv" || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-alpha" {exit !($7=="pending")}' "$tmp/review_manifest.tsv" || return 1
}

test_validate_content_gate_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	discovery_channels	discovery_summary	discovery_confidence	status	review_notes	approved_by	approved_at	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision
example/repo@skill-alpha	example/repo	skill-alpha	find	alpha	0.8	pending	note							
bad-format	example/repo	skill-alpha	find	bad	0.3	pending	note							
example/repo@unknown-skill	example/repo	unknown-skill	find	unknown	0.3	pending	note							
example/repo@skill-fail-install	example/repo	skill-fail-install	find	fail-install	0.3	pending	note							
example/repo@skill-missing-md	example/repo	skill-missing-md	find	missing-md	0.3	pending	note							
EOF_MANIFEST

  PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" validate-content --manifest "$tmp/review_manifest.tsv" --status pending --out "$tmp/review_content.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_row_count "$tmp/review_content.tsv" 5 || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-alpha" {exit !($8=="gate_pass" && $9=="ok")}' "$tmp/review_content.tsv" || return 1
  awk -F '\t' 'NR>1 && $1=="bad-format" {exit !($5=="invalid_ref" && $8=="gate_fail" && $9=="invalid_ref")}' "$tmp/review_content.tsv" || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@unknown-skill" {exit !($5=="not_found" && $8=="gate_fail" && $9=="not_found")}' "$tmp/review_content.tsv" || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-fail-install" {exit !($6=="install_failed" && $8=="gate_fail" && $9=="install_failed")}' "$tmp/review_content.tsv" || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-missing-md" {exit !($7=="missing" && $8=="gate_fail" && $9=="skill_md_missing")}' "$tmp/review_content.tsv" || return 1
}

test_validate_content_stdin_safe_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	discovery_channels	discovery_summary	discovery_confidence	status	review_notes	approved_by	approved_at	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision
example/repo@skill-alpha	example/repo	skill-alpha	find	alpha	0.8	pending	note							
example/repo2@skill-beta	example/repo2	skill-beta	find	beta	0.7	pending	note							
example/repo3@skill-alpha	example/repo3	skill-alpha	find	alpha2	0.6	pending	note							
EOF_MANIFEST

  PATH="$tmp/bin:$PATH" MOCK_NPX_READ_STDIN_ON_ADD="1" "$SCRIPT_PATH" validate-content --manifest "$tmp/review_manifest.tsv" --status pending --out "$tmp/review_content.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_row_count "$tmp/review_content.tsv" 3 || return 1
}

test_prepare_ai_reviews_process() {
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	discovery_channels	discovery_summary	discovery_confidence	status	review_notes	approved_by	approved_at	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision
example/repo@skill-alpha	example/repo	skill-alpha	find	alpha summary	0.9	pending	note							
example/repo@skill-beta	example/repo	skill-beta	find	beta summary	0.7	pending	note							
example/repo@skill-gamma	example/repo	skill-gamma	find	gamma summary	0.6	rejected	note							
EOF_MANIFEST

  cat > "$tmp/review_content.tsv" <<'EOF_CONTENT'
skill_ref	repo	skill	manifest_status	name_check	install_check	skill_md_check	gate_status	gate_reason	gate_notes
example/repo@skill-alpha	example/repo	skill-alpha	pending	matched	installed	present	gate_pass	ok	all good
example/repo@skill-beta	example/repo	skill-beta	pending	matched	install_failed	missing	gate_fail	install_failed	failed
example/repo@skill-gamma	example/repo	skill-gamma	rejected	matched	installed	present	gate_pass	ok	all good
EOF_CONTENT

  cat > "$tmp/project_intent.ai.json" <<'EOF_INTENT'
{"goal":"find project-fit skills","domain":"autonomous-investment","constraints":["safety","ops"]}
EOF_INTENT

  "$SCRIPT_PATH" prepare-ai-reviews --manifest "$tmp/review_manifest.tsv" --content-report "$tmp/review_content.tsv" --project-intent "$tmp/project_intent.ai.json" --status pending --out "$tmp/review_ai.queue.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_row_count "$tmp/review_ai.queue.tsv" 1 || return 1
  awk -F '\t' 'NR==2 {exit !($1=="example/repo@skill-alpha" && $7=="find project-fit skills" && $8=="autonomous-investment")}' "$tmp/review_ai.queue.tsv" || return 1

  "$SCRIPT_PATH" prepare-ai-reviews --manifest "$tmp/review_manifest.tsv" --content-report "$tmp/review_content.tsv" --project-intent "$tmp/project_intent.ai.json" --status pending --include-gate-fail --out "$tmp/review_ai_all.queue.tsv" > "$tmp/stdout2.txt" 2> "$tmp/stderr2.txt" || return 1
  assert_row_count "$tmp/review_ai_all.queue.tsv" 2 || return 1
}

test_merge_ai_reviews_process() {
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/worker1.tsv" <<'EOF_W1'
skill_ref	repo	skill	manifest_status	gate_status	gate_reason	project_goal	project_domain	project_constraints	discovery_summary	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at
example/repo@skill-alpha	example/repo	skill-alpha	pending	gate_pass	ok	goal	domain	[]	alpha	70	60	40	0.50	hold	pending	worker1 summary	rationale	worker-1	2026-02-18T11:00:00Z
example/repo@skill-beta	example/repo	skill-beta	pending	gate_pass	ok	goal	domain	[]	beta	80	75	30	0.80	approve	approved	worker1 summary	rationale	worker-1	2026-02-18T11:01:00Z
EOF_W1

  cat > "$tmp/worker2.tsv" <<'EOF_W2'
skill_ref	repo	skill	manifest_status	gate_status	gate_reason	project_goal	project_domain	project_constraints	discovery_summary	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at
example/repo@skill-alpha	example/repo	skill-alpha	pending	gate_pass	ok	goal	domain	[]	alpha	95	90	20	0.92	approve	approved	worker2 summary	rationale	worker-2	2026-02-18T11:02:00Z
EOF_W2

  "$SCRIPT_PATH" merge-ai-reviews --out "$tmp/review_ai.merged.tsv" "$tmp/worker1.tsv" "$tmp/worker2.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_row_count "$tmp/review_ai.merged.tsv" 2 || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-alpha" {exit !($16=="approved" && $19=="worker-2")}' "$tmp/review_ai.merged.tsv" || return 1
}

test_apply_ai_reviews_process() {
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/review_manifest.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	discovery_channels	discovery_summary	discovery_confidence	status	review_notes	approved_by	approved_at	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision
example/repo@skill-alpha	example/repo	skill-alpha	find	alpha summary	0.9	pending	seed							
example/repo@skill-beta	example/repo	skill-beta	github	beta summary	0.6	pending	seed							
EOF_MANIFEST

  cat > "$tmp/review_ai.merged.tsv" <<'EOF_AI'
skill_ref	repo	skill	manifest_status	gate_status	gate_reason	project_goal	project_domain	project_constraints	discovery_summary	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at
example/repo@skill-alpha	example/repo	skill-alpha	pending	gate_pass	ok	goal	domain	[]	alpha	91	89	18	0.95	approve	approved	high fit	rationale	reviewer-a	2026-02-18T12:00:00Z
example/repo@skill-beta	example/repo	skill-beta	pending	gate_pass	ok	goal	domain	[]	beta	30	25	85	0.77	reject	rejected	low fit	rationale	reviewer-b	2026-02-18T12:01:00Z
EOF_AI

  "$SCRIPT_PATH" apply-ai-reviews --manifest "$tmp/review_manifest.tsv" --ai-reviews "$tmp/review_ai.merged.tsv" --out "$tmp/review_manifest.ai.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_row_count "$tmp/review_manifest.ai.tsv" 2 || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-alpha" {exit !($7=="approved" && $9=="reviewer-a" && $10=="2026-02-18T12:00:00Z" && $11=="91" && $15=="approve")}' "$tmp/review_manifest.ai.tsv" || return 1
  awk -F '\t' 'NR>1 && $1=="example/repo@skill-beta" {exit !($7=="rejected" && $9=="reviewer-b" && $15=="reject")}' "$tmp/review_manifest.ai.tsv" || return 1
}

test_install_approved_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.ai.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	discovery_channels	discovery_summary	discovery_confidence	status	review_notes	approved_by	approved_at	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision
example/repo@skill-alpha	example/repo	skill-alpha	find	alpha	0.9	approved	note	reviewer	2026-02-18T12:00:00Z	90	88	20	0.95	approve
example/repo@skill-beta	example/repo	skill-beta	find	beta	0.7	pending	note			60	55	40	0.70	hold
example/toolbox@skill-beta	example/toolbox	skill-beta	github	beta2	0.8	approved	note	reviewer	2026-02-18T12:03:00Z	88	80	25	0.90	approve
EOF_MANIFEST

  PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.ai.tsv" --report "$tmp/install.report.tsv" --dry-run > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$tmp/install.report.tsv" || return 1
  assert_row_count "$tmp/install.report.tsv" 2 || return 1
  assert_contains "$tmp/stdout.txt" "example/repo" || return 1
  assert_contains "$tmp/stdout.txt" "example/toolbox" || return 1
  assert_not_contains "$tmp/stdout.txt" "pending" || return 1

  (cd "$tmp" && PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.ai.tsv" --report "$tmp/install.exec.report.tsv" > "$tmp/exec.stdout.txt" 2> "$tmp/exec.stderr.txt") || return 1
  assert_file_exists "$tmp/install.exec.report.tsv" || return 1
  assert_file_exists "$tmp/.agents/skills/skill-alpha/SKILL.md" || return 1
  assert_file_exists "$tmp/.agents/skills/skill-beta/SKILL.md" || return 1
}

test_audit_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" audit --out "$tmp/audit.log" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$tmp/audit.log" || return 1
  assert_contains "$tmp/audit.log" "# Audit Log" || return 1
  assert_contains "$tmp/audit.log" "## npx skills list" || return 1
  assert_contains "$tmp/audit.log" "All skills are up to date" || return 1
}

test_deprecated_collect_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  if PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" collect-find --out "$tmp/x.tsv" "python" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"; then
    log "assertion failed: deprecated command should fail"
    return 1
  fi

  assert_contains "$tmp/stderr.txt" "removed in AI-only mode" || return 1
}

# --------------------------
# Integration Test
# --------------------------

test_integration_ai_only_e2e() {
  local tmp project run_dir
  local queue worker_d worker_r
  tmp="$(mktemp -d)"
  project="$tmp/project"
  run_dir="$tmp/run"
  mkdir -p "$project/src" "$project/docs"
  setup_mock_env "$tmp"

  cat > "$project/README.md" <<'EOF_README'
# Autonomous Investment Agent
Need resilient workflow and strong observability.
EOF_README

  cat > "$project/src/app.py" <<'EOF_APP'
print("workflow")
EOF_APP

  PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" run --project-root "$project" --out-dir "$run_dir" > "$tmp/run.stdout.txt" 2> "$tmp/run.stderr.txt" || return 1

  queue="$run_dir/review_discovery.queue.tsv"
  worker_d="$run_dir/review_discovery.worker.tsv"
  worker_r="$run_dir/review_ai.worker.tsv"

  assert_file_exists "$queue" || return 1

  cat > "$worker_d" <<'EOF_DISCOVERY'
skill_ref	repo	skill	discovery_channels	discovery_evidence	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at
example/repo@skill-alpha	example/repo	skill-alpha	find	project-fit discovery evidence	92	87	20	0.93	approve	approved	strong discovery fit	rationale	discovery-worker	2026-02-18T13:00:00Z
EOF_DISCOVERY

  "$SCRIPT_PATH" merge-ai-discovery --out "$run_dir/candidates.ai.tsv" --manifest "$run_dir/review_manifest.tsv" "$worker_d" > "$tmp/merge_discovery.stdout.txt" 2> "$tmp/merge_discovery.stderr.txt" || return 1

  PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" validate-content --manifest "$run_dir/review_manifest.tsv" --out "$run_dir/review_content.tsv" > "$tmp/validate.stdout.txt" 2> "$tmp/validate.stderr.txt" || return 1

  "$SCRIPT_PATH" prepare-ai-reviews --manifest "$run_dir/review_manifest.tsv" --content-report "$run_dir/review_content.tsv" --project-intent "$run_dir/project_intent.ai.json" --out "$run_dir/review_ai.queue.tsv" > "$tmp/prepare_ai.stdout.txt" 2> "$tmp/prepare_ai.stderr.txt" || return 1

  assert_row_count "$run_dir/review_ai.queue.tsv" 1 || return 1

  head -n 1 "$run_dir/review_ai.queue.tsv" > "$worker_r"
  awk -F '\t' -v OFS='\t' 'NR==2 {$11="95"; $12="90"; $13="15"; $14="0.97"; $15="approve"; $16="approved"; $17="ready to install"; $18="meets project goals"; $19="review-worker"; $20="2026-02-18T13:10:00Z"; print}' "$run_dir/review_ai.queue.tsv" >> "$worker_r"

  "$SCRIPT_PATH" merge-ai-reviews --out "$run_dir/review_ai.merged.tsv" "$worker_r" > "$tmp/merge_ai.stdout.txt" 2> "$tmp/merge_ai.stderr.txt" || return 1
  "$SCRIPT_PATH" apply-ai-reviews --manifest "$run_dir/review_manifest.tsv" --ai-reviews "$run_dir/review_ai.merged.tsv" --out "$run_dir/review_manifest.ai.tsv" > "$tmp/apply_ai.stdout.txt" 2> "$tmp/apply_ai.stderr.txt" || return 1

  awk -F '\t' 'NR>1 && $1=="example/repo@skill-alpha" {exit !($7=="approved" && $9=="review-worker")}' "$run_dir/review_manifest.ai.tsv" || return 1

  PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$run_dir/review_manifest.ai.tsv" --report "$run_dir/install.report.tsv" --dry-run > "$tmp/install.stdout.txt" 2> "$tmp/install.stderr.txt" || return 1
  assert_file_exists "$run_dir/install.report.tsv" || return 1
  assert_row_count "$run_dir/install.report.tsv" 1 || return 1
}

# --------------------------
# Runner
# --------------------------

log "## Process Suite"
run_test "process" "run ai-only" test_run_ai_only_process
run_test "process" "prepare-ai-discovery" test_prepare_ai_discovery_process
run_test "process" "merge-ai-discovery" test_merge_ai_discovery_process
run_test "process" "validate-content gate" test_validate_content_gate_process
run_test "process" "validate-content stdin-safe" test_validate_content_stdin_safe_process
run_test "process" "prepare-ai-reviews" test_prepare_ai_reviews_process
run_test "process" "merge-ai-reviews" test_merge_ai_reviews_process
run_test "process" "apply-ai-reviews" test_apply_ai_reviews_process
run_test "process" "install-approved" test_install_approved_process
run_test "process" "audit" test_audit_process
run_test "process" "deprecated collect" test_deprecated_collect_process

log ""
log "## Integration Suite"
run_test "integration" "ai-only end-to-end" test_integration_ai_only_e2e

log ""
log "summary: pass=$PASS fail=$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
