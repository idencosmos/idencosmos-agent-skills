#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  skills_batch_ops.sh verify-parallel-proof --stage discovery|review --queue PATH --out PATH --summary PATH <worker_tsv_1> [worker_tsv_2 ...]
  skills_batch_ops.sh validate-content --manifest PATH [--out PATH] [--status pending|approved|rejected|all] [--skill-ref REF ...] [--limit N]
  skills_batch_ops.sh install-approved --manifest PATH [--proof PATH] [--content-report PATH] [--report PATH] [--dry-run] [--no-yes]
  skills_batch_ops.sh audit [--out PATH] [--proof PATH]

Removed in gate-only mode:
  run, prepare-ai-discovery, merge-ai-discovery, prepare-ai-reviews,
  merge-ai-reviews, apply-ai-reviews, install, collect-find, collect-top,
  collect-github, import-web, merge, collect
USAGE
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'warn: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
}

ensure_parent_dir() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
}

sanitize_field() {
  local raw="${1:-}"
  printf '%s' "$raw" | tr '\t\r\n' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

now_utc() {
  if [[ -n "${SKILLS_BATCH_NOW:-}" ]]; then
    printf '%s\n' "$SKILLS_BATCH_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

is_skill_ref() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[A-Za-z0-9_.:-]+$ ]]
}

write_content_review_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'skill_ref\trepo\tskill\tmanifest_status\tname_check\tinstall_check\tskill_md_check\tgate_status\tgate_reason\tgate_notes\n' > "$out"
}

write_install_report_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'timestamp\trepo\tskills\tstatus\tcommand\n' > "$out"
}

json_passed_value() {
  local proof="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.passed // false' "$proof" 2>/dev/null || printf 'false'
  else
    grep -Eo '"passed"[[:space:]]*:[[:space:]]*(true|false)' "$proof" | head -n 1 | grep -Eo '(true|false)' || printf 'false'
  fi
}

require_parallel_summary_passed() {
  local proof="$1"
  local passed="false"

  [[ -n "$proof" && -f "$proof" ]] || die "missing parallel proof summary: $proof"
  passed="$(json_passed_value "$proof")"
  [[ "$passed" == "true" ]] || die "parallel proof failed: $proof"
}

extract_manifest_rows() {
  local manifest="$1"
  local out="$2"

  awk -F '\t' '
  function trim(s) {
    gsub(/^[[:space:]]+/, "", s)
    gsub(/[[:space:]]+$/, "", s)
    return s
  }
  function header_key(s, pos) {
    s = trim(tolower(s))
    if (pos == 1) sub(/^\xef\xbb\xbf/, "", s)
    return s
  }
  NR == 1 {
    for (i = 1; i <= NF; i++) {
      key = header_key($i, i)
      idx[key] = i
    }
    ref_idx = idx["skill_ref"]
    repo_idx = idx["repo"]
    skill_idx = idx["skill"]
    status_idx = idx["status"]
    if (!status_idx) status_idx = idx["manifest_status"]

    if (!ref_idx || !repo_idx || !skill_idx || !status_idx) {
      print "error: manifest missing required headers: skill_ref, repo, skill, status|manifest_status" > "/dev/stderr"
      exit 2
    }
    next
  }
  {
    ref = trim($(ref_idx))
    repo = trim($(repo_idx))
    skill = trim($(skill_idx))
    status = tolower(trim($(status_idx)))
    print ref "\t" repo "\t" skill "\t" status
  }
  ' "$manifest" > "$out"
}

extract_content_gate_rows() {
  local content_report="$1"
  local out="$2"

  awk -F '\t' '
  function trim(s) {
    gsub(/^[[:space:]]+/, "", s)
    gsub(/[[:space:]]+$/, "", s)
    return s
  }
  function header_key(s, pos) {
    s = trim(tolower(s))
    if (pos == 1) sub(/^\xef\xbb\xbf/, "", s)
    return s
  }
  NR == 1 {
    for (i = 1; i <= NF; i++) {
      key = header_key($i, i)
      idx[key] = i
    }
    ref_idx = idx["skill_ref"]
    gate_idx = idx["gate_status"]

    if (!ref_idx || !gate_idx) {
      print "error: content report missing required headers: skill_ref, gate_status" > "/dev/stderr"
      exit 2
    }
    next
  }
  {
    ref = trim($(ref_idx))
    gate = tolower(trim($(gate_idx)))
    print ref "\t" gate
  }
  ' "$content_report" > "$out"
}

cmd_verify_parallel_proof() {
  require_cmd node

  local stage=""
  local queue=""
  local out=""
  local summary=""
  local -a inputs=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage)
        stage="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
        shift 2
        ;;
      --queue)
        queue="${2:-}"
        shift 2
        ;;
      --out)
        out="${2:-}"
        shift 2
        ;;
      --summary)
        summary="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        inputs+=("$1")
        shift
        ;;
    esac
  done

  [[ "$stage" == "discovery" || "$stage" == "review" ]] || die "verify-parallel-proof --stage must be discovery or review"
  [[ -n "$queue" && -f "$queue" ]] || die "verify-parallel-proof requires --queue PATH"
  [[ -n "$out" ]] || die "verify-parallel-proof requires --out PATH"
  [[ -n "$summary" ]] || die "verify-parallel-proof requires --summary PATH"
  [[ ${#inputs[@]} -gt 0 ]] || die "verify-parallel-proof requires at least one worker TSV"

  ensure_parent_dir "$out"
  ensure_parent_dir "$summary"

  if node - "$stage" "$queue" "$out" "$summary" "${inputs[@]}" <<'NODE'
const fs = require('fs');
const path = require('path');

const [stage, queuePath, outPath, summaryPath, ...workerFiles] = process.argv.slice(2);
const now = new Date().toISOString();

const reasonCodes = new Set();
const queueTasks = new Map();
const queueTaskReasons = new Map();
const taskState = new Map();
const coveredTasks = new Set();
const unexpectedTaskIds = new Set();
const uniqueWorkers = new Set();
const intervals = [];

function parseTsv(filePath) {
  const raw = fs.readFileSync(filePath, 'utf8').replace(/\r\n/g, '\n');
  const lines = raw.split('\n').filter((line, idx) => idx === 0 || line !== '');
  if (lines.length === 0) return { header: [], rows: [] };
  const header = lines[0].split('\t');
  const rows = lines.slice(1).map((line) => line.split('\t'));
  return { header, rows };
}

function indexOf(header, name) {
  const idx = header.indexOf(name);
  return idx >= 0 ? idx : -1;
}

function safeCell(row, idx) {
  if (idx < 0) return '';
  return (row[idx] || '').trim();
}

function ensureTaskState(taskId, queueSkillRef) {
  if (!taskState.has(taskId)) {
    taskState.set(taskId, {
      queueSkillRef: queueSkillRef || '',
      workerSkillRefs: new Set(),
      workerIds: new Set(),
      workerRunIds: new Set(),
      minStart: null,
      maxEnd: null,
    });
  }
  return taskState.get(taskId);
}

function addTaskReason(taskId, code) {
  reasonCodes.add(code);
  if (!queueTaskReasons.has(taskId)) queueTaskReasons.set(taskId, new Set());
  queueTaskReasons.get(taskId).add(code);
}

function toMs(iso) {
  if (!iso) return null;
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return null;
  return ms;
}

const queueParsed = parseTsv(queuePath);
const qTaskIdIdx = indexOf(queueParsed.header, 'task_id');
const qExpectedStageIdx = indexOf(queueParsed.header, 'expected_stage');
const qSkillRefIdx = indexOf(queueParsed.header, 'skill_ref');

if (qTaskIdIdx < 0 || qExpectedStageIdx < 0) {
  reasonCodes.add('missing_worker_metadata');
}

for (const row of queueParsed.rows) {
  const taskId = safeCell(row, qTaskIdIdx);
  if (!taskId) continue;
  const expectedStage = safeCell(row, qExpectedStageIdx);
  const skillRef = safeCell(row, qSkillRefIdx);
  queueTasks.set(taskId, { expectedStage, skillRef });
  ensureTaskState(taskId, skillRef);
}

for (const workerPath of workerFiles) {
  const parsed = parseTsv(workerPath);
  const h = parsed.header;
  const idx = {
    taskId: indexOf(h, 'task_id'),
    expectedStage: indexOf(h, 'expected_stage'),
    skillRef: indexOf(h, 'skill_ref'),
    workerRunId: indexOf(h, 'worker_run_id'),
    workerId: indexOf(h, 'worker_id'),
    startedAt: indexOf(h, 'worker_started_at'),
    finishedAt: indexOf(h, 'worker_finished_at'),
    attempt: indexOf(h, 'worker_attempt'),
    orchestrator: indexOf(h, 'orchestrator_name'),
  };
  const requiredHeaderColumns = [
    idx.taskId,
    idx.expectedStage,
    idx.workerRunId,
    idx.workerId,
    idx.startedAt,
    idx.finishedAt,
    idx.attempt,
    idx.orchestrator,
  ];
  if (stage === 'review') {
    requiredHeaderColumns.push(idx.skillRef);
  }
  const requiredHeaderMissing = requiredHeaderColumns.some((v) => v < 0);
  if (requiredHeaderMissing) {
    reasonCodes.add('missing_worker_metadata');
  }

  for (const row of parsed.rows) {
    const taskId = safeCell(row, idx.taskId);
    const expectedStage = safeCell(row, idx.expectedStage);
    const skillRef = safeCell(row, idx.skillRef);
    const workerRunId = safeCell(row, idx.workerRunId);
    const workerId = safeCell(row, idx.workerId);
    const startedAt = safeCell(row, idx.startedAt);
    const finishedAt = safeCell(row, idx.finishedAt);
    const attempt = safeCell(row, idx.attempt);
    const orchestrator = safeCell(row, idx.orchestrator);

    if (!taskId) {
      reasonCodes.add('missing_worker_metadata');
      continue;
    }

    if (!queueTasks.has(taskId)) {
      reasonCodes.add('task_not_in_queue');
      unexpectedTaskIds.add(taskId);
      continue;
    }

    coveredTasks.add(taskId);

    if (expectedStage && expectedStage !== stage) {
      addTaskReason(taskId, 'expected_stage_mismatch');
    }

    const queueExpectedStage = queueTasks.get(taskId).expectedStage;
    if (expectedStage && queueExpectedStage && expectedStage !== queueExpectedStage) {
      addTaskReason(taskId, 'expected_stage_mismatch');
    }

    const queueSkillRef = queueTasks.get(taskId).skillRef;
    const state = ensureTaskState(taskId, queueSkillRef);
    if (skillRef) state.workerSkillRefs.add(skillRef);
    if (workerId) state.workerIds.add(workerId);
    if (workerRunId) state.workerRunIds.add(workerRunId);

    const metadataMissing = [workerRunId, workerId, startedAt, finishedAt, attempt, orchestrator].some((v) => !v);
    if (metadataMissing || requiredHeaderMissing) {
      addTaskReason(taskId, 'missing_worker_metadata');
    }

    if (stage === 'review' && queueSkillRef && skillRef && queueSkillRef !== skillRef) {
      addTaskReason(taskId, 'task_ref_mismatch');
    }

    const startMs = toMs(startedAt);
    const endMs = toMs(finishedAt);
    if (startMs === null || endMs === null || endMs < startMs) {
      addTaskReason(taskId, 'invalid_time_range');
      continue;
    }

    if (state.minStart === null || startMs < state.minStart) state.minStart = startMs;
    if (state.maxEnd === null || endMs > state.maxEnd) state.maxEnd = endMs;

    intervals.push({ taskId, startMs, endMs, workerId });
    if (workerId) uniqueWorkers.add(workerId);
  }
}

for (const taskId of queueTasks.keys()) {
  if (!coveredTasks.has(taskId)) {
    addTaskReason(taskId, 'missing_task_coverage');
  }
}

const overlapPairs = new Set();
for (let i = 0; i < intervals.length; i += 1) {
  for (let j = i + 1; j < intervals.length; j += 1) {
    const a = intervals[i];
    const b = intervals[j];
    if (a.taskId === b.taskId) continue;
    if (a.startMs <= b.endMs && b.startMs <= a.endMs) {
      const key = [a.taskId, b.taskId].sort().join('~~');
      overlapPairs.add(key);
    }
  }
}

if (queueTasks.size >= 2) {
  if (uniqueWorkers.size < 2) {
    reasonCodes.add('insufficient_unique_workers');
  }
  if (overlapPairs.size === 0) {
    reasonCodes.add('serial_execution_detected');
  }
}

const reasonCodeList = Array.from(reasonCodes).sort();
const taskRows = [];

for (const [taskId, queueMeta] of Array.from(queueTasks.entries()).sort((a, b) => a[0].localeCompare(b[0]))) {
  const state = taskState.get(taskId);
  const reasons = Array.from(queueTaskReasons.get(taskId) || []).sort();
  const checkPass = reasons.length === 0;
  const workerSkillRef = state ? Array.from(state.workerSkillRefs).filter(Boolean).sort().join(',') : '';
  const workerId = state ? Array.from(state.workerIds).filter(Boolean).sort().join(',') : '';
  const workerRunId = state ? Array.from(state.workerRunIds).filter(Boolean).sort().join(',') : '';
  const workerStartedAt = state && state.minStart !== null ? new Date(state.minStart).toISOString() : '';
  const workerFinishedAt = state && state.maxEnd !== null ? new Date(state.maxEnd).toISOString() : '';
  taskRows.push([
    stage,
    taskId,
    queueMeta.skillRef || '',
    workerSkillRef,
    workerId,
    workerRunId,
    workerStartedAt,
    workerFinishedAt,
    checkPass ? 'true' : 'false',
    reasons.join(','),
    checkPass ? 'task proof ok' : 'task proof failed',
  ]);
}

for (const taskId of Array.from(unexpectedTaskIds).sort()) {
  taskRows.push([
    stage,
    taskId,
    '',
    '',
    '',
    '',
    '',
    '',
    'false',
    'task_not_in_queue',
    'worker task_id not present in queue',
  ]);
}

const perTaskReasons = new Set();
for (const rows of queueTaskReasons.values()) {
  for (const code of rows.values()) perTaskReasons.add(code);
}
const globalOnlyReasons = reasonCodeList.filter((code) => !perTaskReasons.has(code));
if (globalOnlyReasons.length > 0) {
  taskRows.push([
    stage,
    '__global__',
    '',
    '',
    '',
    '',
    '',
    '',
    'false',
    globalOnlyReasons.join(','),
    'global strict checks failed',
  ]);
}

const header = [
  'stage',
  'task_id',
  'queue_skill_ref',
  'worker_skill_ref',
  'worker_id',
  'worker_run_id',
  'worker_started_at',
  'worker_finished_at',
  'check_pass',
  'reason_codes',
  'notes',
];
const proofTsv = [header.join('\t'), ...taskRows.map((row) => row.join('\t'))].join('\n') + '\n';
fs.writeFileSync(outPath, proofTsv, 'utf8');

const taskCount = queueTasks.size;
const coveredTaskCount = coveredTasks.size;
const coverageRatio = taskCount === 0 ? 1 : coveredTaskCount / taskCount;
const summary = {
  stage,
  generated_at: now,
  queue: queuePath,
  worker_files: workerFiles,
  passed: reasonCodeList.length === 0,
  reason_codes: reasonCodeList,
  task_count: taskCount,
  covered_task_count: coveredTaskCount,
  coverage_ratio: Number(coverageRatio.toFixed(4)),
  unique_workers: uniqueWorkers.size,
  overlap_pairs: overlapPairs.size,
};
fs.writeFileSync(summaryPath, JSON.stringify(summary, null, 2) + '\n', 'utf8');

const aggregatePath = path.join(path.dirname(summaryPath), 'parallel_proof.summary.json');
let aggregate = {};
if (fs.existsSync(aggregatePath)) {
  try {
    aggregate = JSON.parse(fs.readFileSync(aggregatePath, 'utf8'));
  } catch {
    aggregate = {};
  }
}
if (!aggregate || typeof aggregate !== 'object') aggregate = {};
if (!aggregate.stages || typeof aggregate.stages !== 'object') aggregate.stages = {};
aggregate.generated_at = now;
aggregate.stages[stage] = summary;
const stageSummaries = Object.values(aggregate.stages).filter((v) => v && typeof v === 'object');
aggregate.passed = stageSummaries.length > 0 && stageSummaries.every((v) => v.passed === true);
aggregate.reason_codes = Array.from(
  new Set(stageSummaries.flatMap((v) => Array.isArray(v.reason_codes) ? v.reason_codes : [])),
).sort();
fs.writeFileSync(aggregatePath, JSON.stringify(aggregate, null, 2) + '\n', 'utf8');

process.exit(summary.passed ? 0 : 7);
NODE
  then
    log "Saved parallel proof report: $out"
    log "Saved parallel proof summary: $summary"
  else
    log "Saved parallel proof report: $out"
    log "Saved parallel proof summary: $summary"
    die "parallel proof failed for stage: $stage"
  fi
}

cmd_validate_content() {
  require_cmd awk

  local manifest=""
  local out=""
  local status_filter="all"
  local limit=""
  local processed=0
  local tmp_dir manifest_rows
  local -a selected_refs=()

  local skill_ref repo skill manifest_status_lc expected_repo expected_skill
  local name_check install_check skill_md_check gate_status gate_reason gate_notes

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manifest)
        manifest="${2:-}"
        shift 2
        ;;
      --out)
        out="${2:-}"
        shift 2
        ;;
      --status)
        status_filter="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
        shift 2
        ;;
      --skill-ref)
        selected_refs+=("${2:-}")
        shift 2
        ;;
      --limit)
        limit="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option for validate-content: $1"
        ;;
    esac
  done

  [[ -n "$manifest" && -f "$manifest" ]] || die "validate-content requires --manifest PATH"
  case "$status_filter" in
    pending|approved|rejected|all) ;;
    *) die "validate-content --status must be one of: pending, approved, rejected, all" ;;
  esac
  if [[ -n "$limit" && ! "$limit" =~ ^[0-9]+$ ]]; then
    die "validate-content --limit must be a non-negative integer"
  fi

  if [[ -z "$out" ]]; then
    out="$(dirname "$manifest")/review_content.tsv"
  fi

  write_content_review_header "$out"
  tmp_dir="$(mktemp -d)"
  manifest_rows="$tmp_dir/manifest.rows.tsv"
  extract_manifest_rows "$manifest" "$manifest_rows" || die "failed to parse manifest headers: $manifest"

  is_selected_ref() {
    local target_ref="$1"
    local wanted_ref
    if [[ ${#selected_refs[@]} -eq 0 ]]; then
      return 0
    fi
    for wanted_ref in "${selected_refs[@]}"; do
      if [[ "$target_ref" == "$wanted_ref" ]]; then
        return 0
      fi
    done
    return 1
  }

  while IFS=$'\t' read -r skill_ref repo skill manifest_status_lc; do
    [[ -n "$skill_ref" ]] || continue

    if [[ "$status_filter" != "all" && "$manifest_status_lc" != "$status_filter" ]]; then
      continue
    fi

    if ! is_selected_ref "$skill_ref"; then
      continue
    fi

    if [[ -n "$limit" && "$processed" -ge "$limit" ]]; then
      break
    fi

    processed=$((processed + 1))
    name_check=""
    install_check="deferred_to_install"
    skill_md_check="deferred_to_install"
    gate_status="gate_fail"
    gate_reason=""
    gate_notes=""

    expected_repo="${skill_ref%@*}"
    expected_skill="${skill_ref#*@}"

    if ! is_skill_ref "$skill_ref" || [[ "$repo" != "$expected_repo" || "$skill" != "$expected_skill" ]]; then
      name_check="invalid_ref"
      gate_reason="invalid_ref"
      gate_notes="skill_ref/repo/skill consistency check failed"
    else
      name_check="format_ok"
      gate_status="gate_pass"
      gate_reason="provisional_ai_gate"
      gate_notes="structure-only validation passed; install/runtime checks deferred to install-approved"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$skill_ref" "$repo" "$skill" "$manifest_status_lc" "$name_check" "$install_check" "$skill_md_check" \
      "$gate_status" "$gate_reason" "$(sanitize_field "$gate_notes")" >> "$out"
  done < "$manifest_rows"

  if [[ "$processed" -eq 0 ]]; then
    warn "validate-content found no rows for the current filters"
  fi

  log "Saved content review report: $out"
  rm -rf "$tmp_dir"
}

cmd_audit() {
  local out=""
  local proof=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        out="${2:-}"
        shift 2
        ;;
      --proof)
        proof="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option for audit: $1"
        ;;
    esac
  done

  if [[ -z "$out" ]]; then
    out="$(pwd)/audit.log"
  fi

  ensure_parent_dir "$out"
  if [[ -z "$proof" ]]; then
    proof="$(dirname "$out")/parallel_proof.summary.json"
  fi

  {
    printf '# Audit Log\n\n'
    printf -- '- generated_at: %s\n' "$(now_utc)"
    printf -- '- cwd: %s\n\n' "$(pwd)"

    printf '## npx skills list\n\n'
    if command -v npx >/dev/null 2>&1; then
      FORCE_COLOR=0 npx skills list 2>&1 || true
    else
      printf 'npx is not installed\n'
    fi

    printf '\n## npx skills check\n\n'
    if command -v npx >/dev/null 2>&1; then
      FORCE_COLOR=0 npx skills check 2>&1 || true
    else
      printf 'npx is not installed\n'
    fi

    printf '\n## parallel proof summary\n\n'
    if [[ -f "$proof" ]]; then
      cat "$proof"
    else
      printf 'parallel proof summary file not found: %s\n' "$proof"
    fi
  } > "$out"

  log "Saved audit log: $out"
}

cmd_install_approved() {
  require_cmd npx
  require_cmd awk

  local manifest=""
  local proof=""
  local content_report=""
  local report=""
  local dry_run="0"
  local yes="1"
  local now command_str status
  local tmp_dir grouped manifest_rows gate_rows approved_rows missing_refs missing_csv
  local repo skills_csv skill
  local -a skill_args=()
  local -a skill_list=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manifest)
        manifest="${2:-}"
        shift 2
        ;;
      --proof)
        proof="${2:-}"
        shift 2
        ;;
      --content-report)
        content_report="${2:-}"
        shift 2
        ;;
      --report)
        report="${2:-}"
        shift 2
        ;;
      --dry-run)
        dry_run="1"
        shift
        ;;
      --no-yes)
        yes="0"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option for install-approved: $1"
        ;;
    esac
  done

  [[ -n "$manifest" && -f "$manifest" ]] || die "install-approved requires --manifest PATH"

  if [[ -z "$report" ]]; then
    report="$(dirname "$manifest")/install.report.tsv"
  fi
  if [[ -z "$proof" ]]; then
    proof="$(dirname "$manifest")/parallel_proof.summary.json"
  fi
  if [[ -z "$content_report" ]]; then
    content_report="$(dirname "$manifest")/review_content.tsv"
  fi
  [[ -f "$content_report" ]] || die "install-approved requires --content-report PATH (file not found: $content_report)"

  require_parallel_summary_passed "$proof"

  write_install_report_header "$report"
  now="$(now_utc)"

  tmp_dir="$(mktemp -d)"
  grouped="$tmp_dir/grouped.tsv"
  manifest_rows="$tmp_dir/manifest.rows.tsv"
  gate_rows="$tmp_dir/gate.rows.tsv"
  approved_rows="$tmp_dir/approved.rows.tsv"
  missing_refs="$tmp_dir/missing_gate_refs.txt"

  extract_manifest_rows "$manifest" "$manifest_rows" || die "failed to parse manifest headers: $manifest"
  extract_content_gate_rows "$content_report" "$gate_rows" || die "failed to parse content report headers: $content_report"

  awk -F '\t' 'tolower($4) == "approved" { print $1 "\t" $2 "\t" $3 }' "$manifest_rows" > "$approved_rows"
  if [[ ! -s "$approved_rows" ]]; then
    rm -rf "$tmp_dir"
    log "No approved skills found in manifest: $manifest"
    return 0
  fi

  awk -F '\t' '
  NR == FNR {
    if ($1 != "" && tolower($2) == "gate_pass") {
      gate_pass[$1] = 1
    }
    next
  }
  {
    ref = $1
    if (ref == "") next
    if (!(ref in gate_pass)) {
      missing[ref] = 1
    }
  }
  END {
    for (ref in missing) print ref
  }
  ' "$gate_rows" "$approved_rows" | sort > "$missing_refs"

  if [[ -s "$missing_refs" ]]; then
    missing_csv="$(paste -sd',' "$missing_refs")"
    rm -rf "$tmp_dir"
    die "approved skills missing gate_pass in content report: $missing_csv"
  fi

  awk -F '\t' '
  function add_unique(existing, item,    n, i, arr) {
    if (existing == "") return item
    n = split(existing, arr, ",")
    for (i = 1; i <= n; i++) if (arr[i] == item) return existing
    return existing "," item
  }
  {
    repo=$2
    skill=$3
    if (repo == "" || skill == "") next
    skills[repo] = add_unique(skills[repo], skill)
  }
  END {
    for (repo in skills) print repo "\t" skills[repo]
  }
  ' "$approved_rows" | sort -t $'\t' -k1,1 > "$grouped"

  if [[ ! -s "$grouped" ]]; then
    rm -rf "$tmp_dir"
    log "No approved skills found in manifest: $manifest"
    return 0
  fi

  while IFS=$'\t' read -r repo skills_csv; do
    [[ -n "$repo" ]] || continue

    skill_args=()
    IFS=',' read -r -a skill_list <<< "$skills_csv"
    for skill in "${skill_list[@]}"; do
      [[ -n "$skill" ]] || continue
      skill_args+=(--skill "$skill")
    done

    command_str="npx skills add $repo"
    for skill in "${skill_list[@]}"; do
      [[ -n "$skill" ]] || continue
      command_str+=" --skill $skill"
    done
    if [[ "$yes" == "1" ]]; then
      command_str+=" -y"
    fi

    if [[ "$dry_run" == "1" ]]; then
      status="dry-run"
      log "DRY-RUN: $command_str"
    else
      if [[ "$yes" == "1" ]]; then
        if npx skills add "$repo" "${skill_args[@]}" -y < /dev/null; then
          status="installed"
        else
          status="failed"
        fi
      else
        if npx skills add "$repo" "${skill_args[@]}" < /dev/null; then
          status="installed"
        else
          status="failed"
        fi
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$repo" "$skills_csv" "$status" "$(sanitize_field "$command_str")" >> "$report"
  done < "$grouped"

  if [[ "$dry_run" == "0" ]]; then
    cmd_audit --out "$(dirname "$report")/audit.log" --proof "$proof"
  fi

  log "Saved install report: $report"
  rm -rf "$tmp_dir"
}

cmd_deprecated() {
  local sub="$1"
  die "subcommand '$sub' is removed in gate-only mode. Use external AI orchestration + verify-parallel-proof + validate-content + install-approved."
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local sub="$1"
  shift

  case "$sub" in
    verify-parallel-proof) cmd_verify_parallel_proof "$@" ;;
    validate-content) cmd_validate_content "$@" ;;
    install-approved) cmd_install_approved "$@" ;;
    audit) cmd_audit "$@" ;;
    run|prepare-ai-discovery|merge-ai-discovery|prepare-ai-reviews|merge-ai-reviews|apply-ai-reviews|install|collect-find|collect-top|collect-github|import-web|merge|collect)
      cmd_deprecated "$sub"
      ;;
    -h|--help) usage ;;
    *) die "unknown subcommand: $sub" ;;
  esac
}

main "$@"
