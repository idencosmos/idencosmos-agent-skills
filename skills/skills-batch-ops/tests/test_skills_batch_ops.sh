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

build_discovery_queue_fixture() {
  local out="$1"
  cat > "$out" <<'EOF_Q'
task_id	expected_stage	channel
D001	discovery	find
D002	discovery	github
EOF_Q
}

build_discovery_worker_success_fixture() {
  local out="$1"
  cat > "$out" <<'EOF_W'
task_id	expected_stage	skill_ref	repo	skill	discovery_channels	discovery_evidence	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at	worker_run_id	worker_id	worker_started_at	worker_finished_at	worker_attempt	orchestrator_name
D001	discovery	example/repo@skill-alpha	example/repo	skill-alpha	find	evidence-1	90	88	20	0.95	approve	approved	strong alpha	rationale-a	d-worker-a	2026-02-18T10:00:00Z	run-1	worker-1	2026-02-18T10:00:00Z	2026-02-18T10:02:00Z	1	orch-x
D002	discovery	example/repo@skill-beta	example/repo	skill-beta	github	evidence-2	84	80	25	0.90	hold	pending	beta candidate	rationale-b	d-worker-b	2026-02-18T10:00:30Z	run-2	worker-2	2026-02-18T10:00:30Z	2026-02-18T10:03:30Z	1	orch-x
EOF_W
}

build_discovery_worker_no_skill_ref_fixture() {
  local out="$1"
  cat > "$out" <<'EOF_W'
task_id	expected_stage	repo	skill	discovery_channels	discovery_evidence	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at	worker_run_id	worker_id	worker_started_at	worker_finished_at	worker_attempt	orchestrator_name
D001	discovery	example/repo	skill-alpha	find	evidence-1	90	88	20	0.95	approve	approved	strong alpha	rationale-a	d-worker-a	2026-02-18T10:00:00Z	run-1	worker-1	2026-02-18T10:00:00Z	2026-02-18T10:02:00Z	1	orch-x
D002	discovery	example/repo	skill-beta	github	evidence-2	84	80	25	0.90	hold	pending	beta candidate	rationale-b	d-worker-b	2026-02-18T10:00:30Z	run-2	worker-2	2026-02-18T10:00:30Z	2026-02-18T10:03:30Z	1	orch-x
EOF_W
}

build_discovery_worker_missing_coverage_fixture() {
  local out="$1"
  cat > "$out" <<'EOF_W'
task_id	expected_stage	skill_ref	repo	skill	discovery_channels	discovery_evidence	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at	worker_run_id	worker_id	worker_started_at	worker_finished_at	worker_attempt	orchestrator_name
D001	discovery	example/repo@skill-alpha	example/repo	skill-alpha	find	evidence-1	90	88	20	0.95	approve	approved	strong alpha	rationale-a	d-worker-a	2026-02-18T10:00:00Z	run-1	worker-1	2026-02-18T10:00:00Z	2026-02-18T10:02:00Z	1	orch-x
EOF_W
}

build_review_queue_fixture() {
  local out="$1"
  cat > "$out" <<'EOF_Q'
task_id	expected_stage	skill_ref
R001	review	example/repo@skill-alpha
R002	review	example/repo@skill-beta
EOF_Q
}

build_review_worker_stage_mismatch_fixture() {
  local out="$1"
  cat > "$out" <<'EOF_W'
task_id	expected_stage	skill_ref	repo	skill	manifest_status	gate_status	gate_reason	project_goal	project_domain	project_constraints	discovery_summary	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at	worker_run_id	worker_id	worker_started_at	worker_finished_at	worker_attempt	orchestrator_name
R001	discovery	example/repo@skill-alpha	example/repo	skill-alpha	pending	gate_pass	ok	goal	domain	[]	alpha	95	90	15	0.97	approve	approved	ready	rationale	reviewer-a	2026-02-18T11:00:00Z	run-1	worker-a	2026-02-18T11:00:00Z	2026-02-18T11:02:00Z	1	orch-y
R002	discovery	example/repo@skill-beta	example/repo	skill-beta	pending	gate_pass	ok	goal	domain	[]	beta	92	88	18	0.95	approve	approved	ready	rationale	reviewer-b	2026-02-18T11:00:20Z	run-2	worker-b	2026-02-18T11:00:20Z	2026-02-18T11:02:20Z	1	orch-y
EOF_W
}

# --------------------------
# Process Tests
# --------------------------

test_verify_parallel_proof_success_process() {
  local tmp
  tmp="$(mktemp -d)"

  build_discovery_queue_fixture "$tmp/review_discovery.queue.tsv"
  build_discovery_worker_success_fixture "$tmp/worker.tsv"

  "$SCRIPT_PATH" verify-parallel-proof \
    --stage discovery \
    --queue "$tmp/review_discovery.queue.tsv" \
    --out "$tmp/discovery_parallel_proof.tsv" \
    --summary "$tmp/discovery_parallel_summary.json" \
    "$tmp/worker.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$tmp/discovery_parallel_proof.tsv" || return 1
  assert_file_exists "$tmp/discovery_parallel_summary.json" || return 1
  assert_file_exists "$tmp/parallel_proof.summary.json" || return 1
  assert_contains "$tmp/discovery_parallel_summary.json" '"passed": true' || return 1
  assert_contains "$tmp/discovery_parallel_summary.json" '"unique_workers": 2' || return 1
  assert_contains "$tmp/discovery_parallel_summary.json" '"overlap_pairs": 1' || return 1
}

test_verify_parallel_proof_discovery_skill_ref_optional_process() {
  local tmp
  tmp="$(mktemp -d)"

  build_discovery_queue_fixture "$tmp/review_discovery.queue.tsv"
  build_discovery_worker_no_skill_ref_fixture "$tmp/worker.tsv"

  "$SCRIPT_PATH" verify-parallel-proof \
    --stage discovery \
    --queue "$tmp/review_discovery.queue.tsv" \
    --out "$tmp/discovery_parallel_proof.tsv" \
    --summary "$tmp/discovery_parallel_summary.json" \
    "$tmp/worker.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_contains "$tmp/discovery_parallel_summary.json" '"passed": true' || return 1
  assert_not_contains "$tmp/discovery_parallel_summary.json" 'missing_worker_metadata' || return 1
}

test_verify_parallel_proof_fail_coverage_process() {
  local tmp
  tmp="$(mktemp -d)"

  build_discovery_queue_fixture "$tmp/review_discovery.queue.tsv"
  build_discovery_worker_missing_coverage_fixture "$tmp/worker.tsv"

  if "$SCRIPT_PATH" verify-parallel-proof \
    --stage discovery \
    --queue "$tmp/review_discovery.queue.tsv" \
    --out "$tmp/discovery_parallel_proof.tsv" \
    --summary "$tmp/discovery_parallel_summary.json" \
    "$tmp/worker.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"; then
    log "assertion failed: expected coverage proof failure"
    return 1
  fi

  assert_contains "$tmp/discovery_parallel_summary.json" 'missing_task_coverage' || return 1
}

test_verify_parallel_proof_fail_stage_mismatch_process() {
  local tmp
  tmp="$(mktemp -d)"

  build_review_queue_fixture "$tmp/review_ai.queue.tsv"
  build_review_worker_stage_mismatch_fixture "$tmp/worker.tsv"

  if "$SCRIPT_PATH" verify-parallel-proof \
    --stage review \
    --queue "$tmp/review_ai.queue.tsv" \
    --out "$tmp/review_parallel_proof.tsv" \
    --summary "$tmp/review_parallel_summary.json" \
    "$tmp/worker.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"; then
    log "assertion failed: expected stage mismatch proof failure"
    return 1
  fi

  assert_contains "$tmp/review_parallel_summary.json" 'expected_stage_mismatch' || return 1
}

test_verify_parallel_proof_fail_same_worker_overlap_process() {
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/review_discovery.queue.tsv" <<'EOF_Q'
task_id	expected_stage
D001	discovery
D002	discovery
D003	discovery
EOF_Q

  cat > "$tmp/worker.tsv" <<'EOF_W'
task_id	expected_stage	worker_run_id	worker_id	worker_started_at	worker_finished_at	worker_attempt	orchestrator_name
D001	discovery	run-1	worker-1	2026-02-18T10:00:00Z	2026-02-18T10:10:00Z	1	orch-x
D002	discovery	run-2	worker-1	2026-02-18T10:05:00Z	2026-02-18T10:15:00Z	1	orch-x
D003	discovery	run-3	worker-2	2026-02-18T10:20:00Z	2026-02-18T10:30:00Z	1	orch-x
EOF_W

  if "$SCRIPT_PATH" verify-parallel-proof \
    --stage discovery \
    --queue "$tmp/review_discovery.queue.tsv" \
    --out "$tmp/discovery_parallel_proof.tsv" \
    --summary "$tmp/discovery_parallel_summary.json" \
    "$tmp/worker.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"; then
    log "assertion failed: expected serial execution failure when overlap is single-worker only"
    return 1
  fi

  assert_contains "$tmp/discovery_parallel_summary.json" 'serial_execution_detected' || return 1
  assert_contains "$tmp/discovery_parallel_summary.json" '"unique_workers": 2' || return 1
  assert_contains "$tmp/discovery_parallel_summary.json" '"overlap_pairs": 0' || return 1
  assert_contains "$tmp/discovery_parallel_summary.json" '"overlap_pairs_total": 1' || return 1
}

test_validate_content_deprecated_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.ai.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	discovery_channels	discovery_summary	discovery_confidence	status	review_notes	approved_by	approved_at	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision
example/repo@skill-alpha	example/repo	skill-alpha	find	alpha	0.9	approved	note	reviewer	2026-02-18T12:00:00Z	90	88	20	0.95	approve
EOF_MANIFEST

  if PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" validate-content --manifest "$tmp/review_manifest.ai.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"; then
    log "assertion failed: validate-content should be deprecated"
    return 1
  fi

  assert_contains "$tmp/stderr.txt" "removed in gate-only mode" || return 1
}

test_install_approved_requires_proof_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

cat > "$tmp/review_manifest.ai.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	discovery_channels	discovery_summary	discovery_confidence	status	review_notes	approved_by	approved_at	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision
example/repo@skill-alpha	example/repo	skill-alpha	find	alpha	0.9	approved	note	reviewer	2026-02-18T12:00:00Z	90	88	20	0.95	approve
EOF_MANIFEST

  if PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.ai.tsv" --dry-run > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"; then
    log "assertion failed: install-approved must fail without proof"
    return 1
  fi

  assert_contains "$tmp/stderr.txt" 'missing parallel proof summary' || return 1
}

test_install_approved_fails_when_proof_failed_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

cat > "$tmp/review_manifest.ai.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	discovery_channels	discovery_summary	discovery_confidence	status	review_notes	approved_by	approved_at	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision
example/repo@skill-alpha	example/repo	skill-alpha	find	alpha	0.9	approved	note	reviewer	2026-02-18T12:00:00Z	90	88	20	0.95	approve
EOF_MANIFEST

  cat > "$tmp/parallel_proof.summary.json" <<'EOF_SUMMARY'
{"passed":false,"reason_codes":["serial_execution_detected"],"stages":{}}
EOF_SUMMARY

  if PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.ai.tsv" --proof "$tmp/parallel_proof.summary.json" --dry-run > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"; then
    log "assertion failed: install-approved must fail when proof is not passed"
    return 1
  fi

  assert_contains "$tmp/stderr.txt" 'parallel proof failed' || return 1
}

test_install_approved_rejects_content_report_option_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.ai.tsv" <<'EOF_MANIFEST'
repo	skill_ref	skill	discovery_channels	discovery_summary	discovery_confidence	manifest_status	review_notes	approved_by	approved_at	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision
example/repo	example/repo@skill-alpha	skill-alpha	find	alpha	0.9	approved	note	reviewer	2026-02-18T12:00:00Z	90	88	20	0.95	approve
example/toolbox	example/toolbox@skill-beta	skill-beta	github	beta	0.8	approved	note	reviewer	2026-02-18T12:01:00Z	88	84	25	0.90	approve
EOF_MANIFEST

  cat > "$tmp/parallel_proof.summary.json" <<'EOF_SUMMARY'
{"passed":true,"reason_codes":[],"stages":{"discovery":{"passed":true},"review":{"passed":true}}}
EOF_SUMMARY

  if PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.ai.tsv" --proof "$tmp/parallel_proof.summary.json" --content-report "$tmp/review_content.tsv" --dry-run > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"; then
    log "assertion failed: install-approved must reject deprecated --content-report option"
    return 1
  fi

  assert_contains "$tmp/stderr.txt" 'unknown option for install-approved: --content-report' || return 1
}

test_install_approved_structure_gate_without_content_report_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/review_manifest.ai.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	discovery_channels	discovery_summary	discovery_confidence	status	review_notes	approved_by	approved_at	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision
example/repo@skill-alpha	example/repo	skill-alpha	find	alpha	0.9	approved	note	reviewer	2026-02-18T12:00:00Z	90	88	20	0.95	approve
bad-format	example/repo	skill-alpha	find	alpha	0.7	approved	note	reviewer	2026-02-18T12:01:00Z	80	75	30	0.80	approve
EOF_MANIFEST

  cat > "$tmp/parallel_proof.summary.json" <<'EOF_SUMMARY'
{"passed":true,"reason_codes":[],"stages":{"discovery":{"passed":true},"review":{"passed":true}}}
EOF_SUMMARY

  if PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.ai.tsv" --proof "$tmp/parallel_proof.summary.json" --dry-run > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"; then
    log "assertion failed: install-approved must fail when approved row fails structure gate"
    return 1
  fi

  assert_contains "$tmp/stderr.txt" 'failed structure gate' || return 1
  assert_contains "$tmp/stderr.txt" 'bad-format' || return 1
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

  cat > "$tmp/parallel_proof.summary.json" <<'EOF_SUMMARY'
{"passed":true,"reason_codes":[],"stages":{"discovery":{"passed":true},"review":{"passed":true}}}
EOF_SUMMARY

  PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.ai.tsv" --proof "$tmp/parallel_proof.summary.json" --report "$tmp/install.report.tsv" --dry-run > "$tmp/stdout.txt" 2> "$tmp/stderr.txt" || return 1

  assert_file_exists "$tmp/install.report.tsv" || return 1
  assert_row_count "$tmp/install.report.tsv" 2 || return 1
  assert_contains "$tmp/stdout.txt" "example/repo" || return 1
  assert_contains "$tmp/stdout.txt" "example/toolbox" || return 1
  assert_not_contains "$tmp/stdout.txt" "pending" || return 1

  (cd "$tmp" && PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.ai.tsv" --proof "$tmp/parallel_proof.summary.json" --report "$tmp/install.exec.report.tsv" > "$tmp/exec.stdout.txt" 2> "$tmp/exec.stderr.txt") || return 1
  assert_file_exists "$tmp/install.exec.report.tsv" || return 1
  assert_file_exists "$tmp/.agents/skills/skill-alpha/SKILL.md" || return 1
  assert_file_exists "$tmp/.agents/skills/skill-beta/SKILL.md" || return 1
}

test_install_approved_fails_on_runtime_install_failure_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

cat > "$tmp/review_manifest.ai.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	discovery_channels	discovery_summary	discovery_confidence	status	review_notes	approved_by	approved_at	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision
example/repo@skill-alpha	example/repo	skill-alpha	find	alpha	0.9	approved	note	reviewer	2026-02-18T12:00:00Z	90	88	20	0.95	approve
example/repo@skill-fail-install	example/repo	skill-fail-install	find	fail	0.8	approved	note	reviewer	2026-02-18T12:01:00Z	88	84	25	0.90	approve
EOF_MANIFEST

  cat > "$tmp/parallel_proof.summary.json" <<'EOF_SUMMARY'
{"passed":true,"reason_codes":[],"stages":{"discovery":{"passed":true},"review":{"passed":true}}}
EOF_SUMMARY

  if (cd "$tmp" && PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$tmp/review_manifest.ai.tsv" --proof "$tmp/parallel_proof.summary.json" --report "$tmp/install.report.tsv" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"); then
    log "assertion failed: install-approved must fail when any approved install fails"
    return 1
  fi

  assert_file_exists "$tmp/install.report.tsv" || return 1
  assert_contains "$tmp/install.report.tsv" $'\texample/repo\tskill-alpha\tinstalled\t' || return 1
  assert_contains "$tmp/install.report.tsv" $'\texample/repo\tskill-fail-install\tfailed\t' || return 1
  assert_contains "$tmp/stderr.txt" "one or more skill installs failed" || return 1
}

test_audit_deprecated_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  cat > "$tmp/parallel_proof.summary.json" <<'EOF_SUMMARY'
{"passed":true,"reason_codes":[],"stages":{"discovery":{"passed":true},"review":{"passed":true}}}
EOF_SUMMARY

  if PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" audit --out "$tmp/audit.log" --proof "$tmp/parallel_proof.summary.json" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"; then
    log "assertion failed: audit should be deprecated"
    return 1
  fi

  assert_contains "$tmp/stderr.txt" "removed in gate-only mode" || return 1
}

test_deprecated_command_process() {
  local tmp
  tmp="$(mktemp -d)"
  setup_mock_env "$tmp"

  if PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" run --project-root "$tmp" > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"; then
    log "assertion failed: deprecated command should fail"
    return 1
  fi

  assert_contains "$tmp/stderr.txt" "removed in gate-only mode" || return 1
}

# --------------------------
# Integration Test
# --------------------------

test_integration_gate_only_e2e() {
  local tmp run_dir
  tmp="$(mktemp -d)"
  run_dir="$tmp/run"
  mkdir -p "$run_dir/review_discovery.workers" "$run_dir/review_ai.workers"
  setup_mock_env "$tmp"

  cat > "$run_dir/review_discovery.queue.tsv" <<'EOF_QD'
task_id	expected_stage	channel
D001	discovery	find
D002	discovery	github
EOF_QD

  cat > "$run_dir/review_discovery.workers/discovery.tsv" <<'EOF_DISCOVERY'
task_id	expected_stage	skill_ref	repo	skill	discovery_channels	discovery_evidence	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at	worker_run_id	worker_id	worker_started_at	worker_finished_at	worker_attempt	orchestrator_name
D001	discovery	example/repo@skill-alpha	example/repo	skill-alpha	find	project-fit discovery evidence	92	87	20	0.93	approve	approved	strong discovery fit	rationale	discovery-worker	2026-02-18T13:00:00Z	run-d1	worker-d1	2026-02-18T13:00:00Z	2026-02-18T13:02:00Z	1	orch-z
D002	discovery	example/repo@skill-alpha	example/repo	skill-alpha	github	corroborating evidence	90	86	22	0.91	approve	approved	strong discovery fit	rationale	discovery-worker	2026-02-18T13:00:15Z	run-d2	worker-d2	2026-02-18T13:00:15Z	2026-02-18T13:02:15Z	1	orch-z
EOF_DISCOVERY

  "$SCRIPT_PATH" verify-parallel-proof --stage discovery --queue "$run_dir/review_discovery.queue.tsv" --out "$run_dir/discovery_parallel_proof.tsv" --summary "$run_dir/discovery_parallel_summary.json" "$run_dir/review_discovery.workers/discovery.tsv" > "$tmp/discovery.proof.stdout.txt" 2> "$tmp/discovery.proof.stderr.txt" || return 1

  cat > "$run_dir/review_ai.queue.tsv" <<'EOF_QR'
task_id	expected_stage	skill_ref
R001	review	example/repo@skill-alpha
R002	review	example/repo@skill-beta
EOF_QR

  cat > "$run_dir/review_ai.workers/review.tsv" <<'EOF_REVIEW'
task_id	expected_stage	skill_ref	repo	skill	manifest_status	gate_status	gate_reason	project_goal	project_domain	project_constraints	discovery_summary	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision	ai_recommended_status	ai_summary	ai_rationale	ai_reviewer	ai_reviewed_at	worker_run_id	worker_id	worker_started_at	worker_finished_at	worker_attempt	orchestrator_name
R001	review	example/repo@skill-alpha	example/repo	skill-alpha	pending	gate_pass	ok	goal	domain	[]	alpha	95	90	15	0.97	approve	approved	ready to install	meets project goals	review-worker	2026-02-18T13:10:00Z	run-r1	worker-r1	2026-02-18T13:09:00Z	2026-02-18T13:10:00Z	1	orch-z
R002	review	example/repo@skill-beta	example/repo	skill-beta	pending	gate_pass	ok	goal	domain	[]	beta	93	89	16	0.95	approve	approved	ready to install	meets project goals	review-worker	2026-02-18T13:10:30Z	run-r2	worker-r2	2026-02-18T13:09:30Z	2026-02-18T13:10:30Z	1	orch-z
EOF_REVIEW

  "$SCRIPT_PATH" verify-parallel-proof --stage review --queue "$run_dir/review_ai.queue.tsv" --out "$run_dir/review_parallel_proof.tsv" --summary "$run_dir/review_parallel_summary.json" "$run_dir/review_ai.workers/review.tsv" > "$tmp/review.proof.stdout.txt" 2> "$tmp/review.proof.stderr.txt" || return 1

  cat > "$run_dir/review_manifest.ai.tsv" <<'EOF_MANIFEST'
skill_ref	repo	skill	discovery_channels	discovery_summary	discovery_confidence	status	review_notes	approved_by	approved_at	ai_relevance	ai_quality	ai_risk	ai_confidence	ai_decision
example/repo@skill-alpha	example/repo	skill-alpha	find	alpha	0.9	approved	note	reviewer	2026-02-18T12:00:00Z	90	88	20	0.95	approve
example/repo@skill-beta	example/repo	skill-beta	find	beta	0.8	approved	note	reviewer	2026-02-18T12:01:00Z	88	84	25	0.90	approve
EOF_MANIFEST

  PATH="$tmp/bin:$PATH" "$SCRIPT_PATH" install-approved --manifest "$run_dir/review_manifest.ai.tsv" --proof "$run_dir/parallel_proof.summary.json" --report "$run_dir/install.report.tsv" --dry-run > "$tmp/install.stdout.txt" 2> "$tmp/install.stderr.txt" || return 1
  assert_file_exists "$run_dir/install.report.tsv" || return 1
  assert_row_count "$run_dir/install.report.tsv" 2 || return 1
}

# --------------------------
# Runner
# --------------------------

log "## Process Suite"
run_test "process" "verify-parallel-proof success" test_verify_parallel_proof_success_process
run_test "process" "verify-parallel-proof discovery skill_ref optional" test_verify_parallel_proof_discovery_skill_ref_optional_process
run_test "process" "verify-parallel-proof coverage fail" test_verify_parallel_proof_fail_coverage_process
run_test "process" "verify-parallel-proof stage mismatch fail" test_verify_parallel_proof_fail_stage_mismatch_process
run_test "process" "verify-parallel-proof single-worker overlap fail" test_verify_parallel_proof_fail_same_worker_overlap_process
run_test "process" "validate-content deprecated" test_validate_content_deprecated_process
run_test "process" "install-approved requires proof" test_install_approved_requires_proof_process
run_test "process" "install-approved proof failed" test_install_approved_fails_when_proof_failed_process
run_test "process" "install-approved rejects content-report option" test_install_approved_rejects_content_report_option_process
run_test "process" "install-approved structure gate without content report" test_install_approved_structure_gate_without_content_report_process
run_test "process" "install-approved" test_install_approved_process
run_test "process" "install-approved runtime failure returns non-zero" test_install_approved_fails_on_runtime_install_failure_process
run_test "process" "audit deprecated" test_audit_deprecated_process
run_test "process" "deprecated run command" test_deprecated_command_process

log ""
log "## Integration Suite"
run_test "integration" "gate-only end-to-end" test_integration_gate_only_e2e

log ""
log "summary: pass=$PASS fail=$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
