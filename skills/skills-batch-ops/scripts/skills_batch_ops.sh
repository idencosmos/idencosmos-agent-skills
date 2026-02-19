#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  skills_batch_ops.sh verify-parallel-proof --stage discovery|review --queue PATH --out PATH --summary PATH <worker_tsv_1> [worker_tsv_2 ...]
  skills_batch_ops.sh install-approved --manifest PATH [--proof PATH] [--report PATH] [--dry-run] [--no-yes]

Removed in gate-only mode:
  validate-content, audit, run, prepare-ai-discovery, merge-ai-discovery, prepare-ai-reviews,
  merge-ai-reviews, apply-ai-reviews, install, collect-find, collect-top,
  collect-github, import-web, merge, collect
USAGE
}

log() {
  printf '%s\n' "$*"
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

if (
  qTaskIdIdx < 0
  || qExpectedStageIdx < 0
  || (stage === 'review' && qSkillRefIdx < 0)
) {
  reasonCodes.add('missing_worker_metadata');
}

for (const row of queueParsed.rows) {
  const taskId = safeCell(row, qTaskIdIdx);
  if (!taskId) continue;
  const expectedStage = safeCell(row, qExpectedStageIdx);
  const skillRef = safeCell(row, qSkillRefIdx);
  queueTasks.set(taskId, { expectedStage, skillRef });
  if (!expectedStage) {
    addTaskReason(taskId, 'missing_worker_metadata');
  }
  if (stage === 'review' && !skillRef) {
    addTaskReason(taskId, 'missing_worker_metadata');
  }
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

    if (stage === 'review' && (!queueSkillRef || !skillRef)) {
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
const crossWorkerOverlapPairs = new Set();
for (let i = 0; i < intervals.length; i += 1) {
  for (let j = i + 1; j < intervals.length; j += 1) {
    const a = intervals[i];
    const b = intervals[j];
    if (a.taskId === b.taskId) continue;
    if (a.startMs <= b.endMs && b.startMs <= a.endMs) {
      const taskPairKey = [a.taskId, b.taskId].sort().join('~~');
      overlapPairs.add(taskPairKey);
      if (a.workerId && b.workerId && a.workerId !== b.workerId) {
        const workerPairKey = [a.workerId, b.workerId].sort().join('~~');
        crossWorkerOverlapPairs.add(`${taskPairKey}@@${workerPairKey}`);
      }
    }
  }
}

if (queueTasks.size >= 2) {
  if (uniqueWorkers.size < 2) {
    reasonCodes.add('insufficient_unique_workers');
  }
  if (crossWorkerOverlapPairs.size === 0) {
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
  overlap_pairs: crossWorkerOverlapPairs.size,
  overlap_pairs_total: overlapPairs.size,
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

cmd_install_approved() {
  require_cmd npx
  require_cmd awk

  local manifest=""
  local proof=""
  local report=""
  local dry_run="0"
  local yes="1"
  local any_failed="0"
  local now command_str status
  local tmp_dir approved_unique manifest_rows approved_rows invalid_refs
  local invalid_csv
  local repo skill skills_csv skill_ref expected_repo expected_skill

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

  require_parallel_summary_passed "$proof"

  write_install_report_header "$report"
  now="$(now_utc)"

  tmp_dir="$(mktemp -d)"
  approved_unique="$tmp_dir/approved.unique.tsv"
  manifest_rows="$tmp_dir/manifest.rows.tsv"
  approved_rows="$tmp_dir/approved.rows.tsv"
  invalid_refs="$tmp_dir/invalid_approved_refs.txt"

  extract_manifest_rows "$manifest" "$manifest_rows" || die "failed to parse manifest headers: $manifest"

  awk -F '\t' 'tolower($4) == "approved" { print $1 "\t" $2 "\t" $3 }' "$manifest_rows" > "$approved_rows"
  if [[ ! -s "$approved_rows" ]]; then
    rm -rf "$tmp_dir"
    log "No approved skills found in manifest: $manifest"
    return 0
  fi

  while IFS=$'\t' read -r skill_ref repo skill; do
    [[ -n "$skill_ref" ]] || continue
    expected_repo="${skill_ref%@*}"
    expected_skill="${skill_ref#*@}"

    if ! is_skill_ref "$skill_ref" || [[ "$repo" != "$expected_repo" || "$skill" != "$expected_skill" ]]; then
      printf '%s\n' "$skill_ref" >> "$invalid_refs"
    fi
  done < "$approved_rows"

  if [[ -s "$invalid_refs" ]]; then
    invalid_csv="$(sort -u "$invalid_refs" | paste -sd',' -)"
    rm -rf "$tmp_dir"
    die "approved skills failed structure gate (invalid skill_ref/repo/skill): $invalid_csv"
  fi

  awk -F '\t' '
  {
    repo = $2
    skill = $3
    if (repo == "" || skill == "") next
    key = repo "\t" skill
    if (!(key in seen)) {
      seen[key] = 1
      print repo "\t" skill
    }
  }
  ' "$approved_rows" | sort -t $'\t' -k1,1 -k2,2 > "$approved_unique"

  if [[ ! -s "$approved_unique" ]]; then
    rm -rf "$tmp_dir"
    log "No approved skills found in manifest: $manifest"
    return 0
  fi

  while IFS=$'\t' read -r repo skill; do
    [[ -n "$repo" && -n "$skill" ]] || continue

    skills_csv="$skill"
    command_str="npx skills add $repo --skill $skill"
    if [[ "$yes" == "1" ]]; then
      command_str+=" -y"
    fi

    if [[ "$dry_run" == "1" ]]; then
      status="dry-run"
      log "DRY-RUN: $command_str"
    else
      if [[ "$yes" == "1" ]]; then
        if npx skills add "$repo" --skill "$skill" -y < /dev/null; then
          status="installed"
        else
          status="failed"
          any_failed="1"
        fi
      else
        if npx skills add "$repo" --skill "$skill" < /dev/null; then
          status="installed"
        else
          status="failed"
          any_failed="1"
        fi
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$repo" "$skills_csv" "$status" "$(sanitize_field "$command_str")" >> "$report"
  done < "$approved_unique"

  log "Saved install report: $report"
  rm -rf "$tmp_dir"

  if [[ "$any_failed" == "1" ]]; then
    die "one or more skill installs failed; see report: $report"
  fi
}

cmd_deprecated() {
  local sub="$1"
  die "subcommand '$sub' is removed in gate-only mode. Use external AI orchestration + verify-parallel-proof + install-approved (and AI-generated audit if needed)."
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
    install-approved) cmd_install_approved "$@" ;;
    validate-content|audit|run|prepare-ai-discovery|merge-ai-discovery|prepare-ai-reviews|merge-ai-reviews|apply-ai-reviews|install|collect-find|collect-top|collect-github|import-web|merge|collect)
      cmd_deprecated "$sub"
      ;;
    -h|--help) usage ;;
    *) die "unknown subcommand: $sub" ;;
  esac
}

main "$@"
