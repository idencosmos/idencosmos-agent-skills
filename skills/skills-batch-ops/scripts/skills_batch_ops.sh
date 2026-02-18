#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  skills_batch_ops.sh run [options]
  skills_batch_ops.sh prepare-ai-discovery --project-root PATH --project-context-files PATH --project-context-chunks PATH --project-intent PATH [--out PATH] [--channel find|top|github|web ...]
  skills_batch_ops.sh verify-parallel-proof --stage discovery|review --queue PATH --out PATH --summary PATH <worker_tsv_1> [worker_tsv_2 ...]
  skills_batch_ops.sh merge-ai-discovery --out PATH --manifest PATH --proof PATH <discovery_worker_1.tsv> [discovery_worker_2.tsv ...]
  skills_batch_ops.sh validate-content --manifest PATH [--out PATH] [--status pending|approved|rejected|all] [--skill-ref REF ...] [--limit N]
  skills_batch_ops.sh prepare-ai-reviews --manifest PATH --content-report PATH [--project-intent PATH] [--out PATH] [--status pending|approved|rejected|all] [--limit N] [--include-gate-fail]
  skills_batch_ops.sh merge-ai-reviews --out PATH --proof PATH <ai_review_worker_1.tsv> [ai_review_worker_2.tsv ...]
  skills_batch_ops.sh apply-ai-reviews --manifest PATH --ai-reviews PATH [--out PATH]
  skills_batch_ops.sh install-approved --manifest PATH [--report PATH] [--dry-run] [--no-yes]
  skills_batch_ops.sh install --file PATH [--dry-run] [--no-yes]
  skills_batch_ops.sh audit [--out PATH]

Deprecated (AI-only redesign):
  collect-find, collect-top, collect-github, import-web, merge, collect
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

now_stamp() {
  local now
  now="$(now_utc)"
  printf '%s\n' "${now//[-:]/}" | sed 's/\.//g; s/T/_/; s/Z$//'
}

is_skill_ref() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[A-Za-z0-9_.:-]+$ ]]
}

extract_skill_names_from_list_file() {
  local input="$1"
  awk '
  {
    line=$0
    gsub(/\x1b\[[0-9;]*m/, "", line)
    if (line ~ /^[[:space:]]*│[[:space:]]{4}[A-Za-z0-9_.-]+[[:space:]]*$/) {
      gsub(/^[[:space:]]*│[[:space:]]*/, "", line)
      gsub(/[[:space:]]*$/, "", line)
      print line
    }
  }
  ' "$input" | awk '!seen[$0]++'
}

sha256_file() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return
  fi
  printf 'na\n'
}

write_project_context_files_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'abs_path\trel_path\tsize_bytes\tis_text\tis_chunked\tskip_reason\tsha256\n' > "$out"
}

write_discovery_queue_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'task_id\texpected_stage\tchannel\tproject_root\tproject_intent_file\tproject_context_files\tproject_context_chunks\tdiscovery_objective\toutput_contract\n' > "$out"
}

write_candidates_ai_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'skill_ref\trepo\tskill\tdiscovery_channels\tdiscovery_evidence\tai_relevance\tai_quality\tai_risk\tai_confidence\tai_decision\tai_recommended_status\tai_summary\tai_rationale\tai_reviewer\tai_reviewed_at\n' > "$out"
}

write_manifest_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'skill_ref\trepo\tskill\tdiscovery_channels\tdiscovery_summary\tdiscovery_confidence\tstatus\treview_notes\tapproved_by\tapproved_at\tai_relevance\tai_quality\tai_risk\tai_confidence\tai_decision\n' > "$out"
}

write_content_review_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'skill_ref\trepo\tskill\tmanifest_status\tname_check\tinstall_check\tskill_md_check\tgate_status\tgate_reason\tgate_notes\n' > "$out"
}

write_ai_review_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'task_id\texpected_stage\tskill_ref\trepo\tskill\tmanifest_status\tgate_status\tgate_reason\tproject_goal\tproject_domain\tproject_constraints\tdiscovery_summary\tai_relevance\tai_quality\tai_risk\tai_confidence\tai_decision\tai_recommended_status\tai_summary\tai_rationale\tai_reviewer\tai_reviewed_at\tworker_run_id\tworker_id\tworker_started_at\tworker_finished_at\tworker_attempt\torchestrator_name\n' > "$out"
}

write_parallel_proof_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'stage\ttask_id\tqueue_skill_ref\tworker_skill_ref\tworker_id\tworker_run_id\tworker_started_at\tworker_finished_at\tcheck_pass\treason_codes\tnotes\n' > "$out"
}

write_install_report_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'timestamp\trepo\tskills\tstatus\tcommand\n' > "$out"
}

require_parallel_proof_passed() {
  local proof="$1"
  local expected_stage="$2"
  local passed="false"
  local stage=""

  [[ -n "$proof" && -f "$proof" ]] || die "missing parallel proof summary: $proof"

  if command -v jq >/dev/null 2>&1; then
    passed="$(jq -r '.passed // false' "$proof" 2>/dev/null || printf 'false')"
    stage="$(jq -r '.stage // ""' "$proof" 2>/dev/null || true)"
  else
    passed="$(grep -Eo '"passed"[[:space:]]*:[[:space:]]*(true|false)' "$proof" | head -n 1 | grep -Eo '(true|false)' || printf 'false')"
    stage="$(grep -Eo '"stage"[[:space:]]*:[[:space:]]*"[^"]+"' "$proof" | head -n 1 | sed -E 's/.*"stage"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
  fi

  [[ "$passed" == "true" ]] || die "parallel proof failed: $proof"
  if [[ -n "$stage" && "$stage" != "$expected_stage" ]]; then
    die "parallel proof stage mismatch: expected '$expected_stage', got '$stage' ($proof)"
  fi
}

write_run_contract() {
  local out="$1"
  local project_root="$2"
  local run_dir="$3"
  local discovery_queue="$4"
  local review_queue="$5"
  local discovery_proof_tsv="$6"
  local discovery_summary_json="$7"
  local review_proof_tsv="$8"
  local review_summary_json="$9"
  local aggregate_summary_json="${10}"

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg generated_at "$(now_utc)" \
      --arg project_root "$project_root" \
      --arg run_dir "$run_dir" \
      --arg discovery_queue "$discovery_queue" \
      --arg review_queue "$review_queue" \
      --arg discovery_proof_tsv "$discovery_proof_tsv" \
      --arg discovery_summary_json "$discovery_summary_json" \
      --arg review_proof_tsv "$review_proof_tsv" \
      --arg review_summary_json "$review_summary_json" \
      --arg aggregate_summary_json "$aggregate_summary_json" \
      '{
        generated_at: $generated_at,
        project_root: $project_root,
        run_dir: $run_dir,
        contracts: {
          discovery: {
            queue: $discovery_queue,
            worker_glob: ($run_dir + "/review_discovery.workers/*.tsv"),
            proof_tsv: $discovery_proof_tsv,
            summary_json: $discovery_summary_json
          },
          review: {
            queue: $review_queue,
            worker_glob: ($run_dir + "/review_ai.workers/*.tsv"),
            proof_tsv: $review_proof_tsv,
            summary_json: $review_summary_json
          },
          aggregate_summary_json: $aggregate_summary_json
        },
        required_worker_columns: [
          "task_id",
          "worker_run_id",
          "worker_id",
          "worker_started_at",
          "worker_finished_at",
          "worker_attempt",
          "orchestrator_name"
        ]
      }' > "$out"
  else
    cat > "$out" <<JSON
{
  "generated_at": "$(now_utc)",
  "project_root": "$(sanitize_field "$project_root")",
  "run_dir": "$(sanitize_field "$run_dir")",
  "contracts": {
    "discovery": {
      "queue": "$(sanitize_field "$discovery_queue")",
      "worker_glob": "$(sanitize_field "$run_dir")/review_discovery.workers/*.tsv",
      "proof_tsv": "$(sanitize_field "$discovery_proof_tsv")",
      "summary_json": "$(sanitize_field "$discovery_summary_json")"
    },
    "review": {
      "queue": "$(sanitize_field "$review_queue")",
      "worker_glob": "$(sanitize_field "$run_dir")/review_ai.workers/*.tsv",
      "proof_tsv": "$(sanitize_field "$review_proof_tsv")",
      "summary_json": "$(sanitize_field "$review_summary_json")"
    },
    "aggregate_summary_json": "$(sanitize_field "$aggregate_summary_json")"
  },
  "required_worker_columns": [
    "task_id",
    "worker_run_id",
    "worker_id",
    "worker_started_at",
    "worker_finished_at",
    "worker_attempt",
    "orchestrator_name"
  ]
}
JSON
  fi
}

is_binary_extension() {
  local path="$1"
  case "${path##*.}" in
    png|jpg|jpeg|gif|webp|ico|pdf|zip|gz|tgz|tar|7z|jar|pyc|so|dylib|dll|exe|bin|class|wasm|mp4|mov|avi|mp3)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

collect_project_files() {
  local project_root="$1"

  find "$project_root" \
    -type d \( \
      -name '.git' -o \
      -name 'node_modules' -o \
      -name '.venv' -o \
      -name 'venv' -o \
      -name '__pycache__' -o \
      -name '.pytest_cache' -o \
      -name '.mypy_cache' -o \
      -name '.next' -o \
      -name 'dist' -o \
      -name 'build' -o \
      -name 'target' -o \
      -name '.turbo' \
    \) -prune -o -type f -print
}

append_chunks_with_node() {
  local abs_path="$1"
  local rel_path="$2"
  local out_file="$3"
  local chunk_chars="$4"

  node - "$abs_path" "$rel_path" "$out_file" "$chunk_chars" <<'NODE'
const fs = require('fs');

const [absPath, relPath, outFile, chunkCharsRaw] = process.argv.slice(2);
const chunkChars = Math.max(200, Number(chunkCharsRaw) || 4000);
const raw = fs.readFileSync(absPath, 'utf8');
const lines = raw.split(/\r?\n/);

let buffer = [];
let startLine = 1;
let currentSize = 0;
let chunks = 0;

const flush = (endLine) => {
  if (buffer.length === 0) return;
  const content = buffer.join('\n');
  const payload = {
    chunk_id: `${relPath}:${startLine}-${endLine}`,
    rel_path: relPath,
    abs_path: absPath,
    start_line: startLine,
    end_line: endLine,
    content,
  };
  fs.appendFileSync(outFile, JSON.stringify(payload) + '\n');
  chunks += 1;
  buffer = [];
  currentSize = 0;
};

for (let i = 0; i < lines.length; i += 1) {
  const line = lines[i];
  const lineLen = line.length + 1;

  if (buffer.length === 0) {
    startLine = i + 1;
  }

  if (buffer.length > 0 && currentSize + lineLen > chunkChars) {
    flush(i);
    startLine = i + 1;
  }

  buffer.push(line);
  currentSize += lineLen;
}

flush(lines.length);
process.stdout.write(String(chunks));
NODE
}

build_project_context() {
  local project_root="$1"
  local files_out="$2"
  local chunks_out="$3"
  local intent_out="$4"
  local max_file_bytes="$5"
  local chunk_chars="$6"

  require_cmd awk
  require_cmd wc
  require_cmd node

  write_project_context_files_header "$files_out"
  : > "$chunks_out"

  local abs rel size sha is_text is_chunked skip_reason
  local file_count text_count chunked_count skipped_count chunk_count

  file_count=0
  text_count=0
  chunked_count=0
  skipped_count=0
  chunk_count=0

  while IFS= read -r abs; do
    [[ -n "$abs" ]] || continue
    file_count=$((file_count + 1))

    rel="${abs#$project_root/}"
    size="$(wc -c < "$abs" | tr -d ' ')"
    sha="$(sha256_file "$abs")"
    is_text="no"
    is_chunked="no"
    skip_reason=""

    if is_binary_extension "$rel"; then
      skip_reason="binary_extension"
    elif [[ "$size" -gt "$max_file_bytes" ]]; then
      skip_reason="too_large"
    elif LC_ALL=C grep -Iq . "$abs" 2>/dev/null || [[ ! -s "$abs" ]]; then
      is_text="yes"
      text_count=$((text_count + 1))
      is_chunked="yes"
      chunked_count=$((chunked_count + 1))
      chunk_count=$((chunk_count + $(append_chunks_with_node "$abs" "$rel" "$chunks_out" "$chunk_chars")))
    else
      skip_reason="binary_content"
    fi

    if [[ -n "$skip_reason" ]]; then
      skipped_count=$((skipped_count + 1))
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$abs" "$rel" "$size" "$is_text" "$is_chunked" "$skip_reason" "$sha" >> "$files_out"
  done < <(collect_project_files "$project_root")

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg generated_at "$(now_utc)" \
      --arg project_root "$project_root" \
      --arg status "pending_ai_interpretation" \
      --arg analysis_prompt "Analyze the entire repository context and produce structured intent for skill discovery and evaluation." \
      --argjson file_count "$file_count" \
      --argjson text_file_count "$text_count" \
      --argjson chunked_file_count "$chunked_count" \
      --argjson skipped_file_count "$skipped_count" \
      --argjson chunk_count "$chunk_count" \
      '{
        generated_at: $generated_at,
        status: $status,
        project_root: $project_root,
        counts: {
          file_count: $file_count,
          text_file_count: $text_file_count,
          chunked_file_count: $chunked_file_count,
          skipped_file_count: $skipped_file_count,
          chunk_count: $chunk_count
        },
        goal: "",
        domain: "",
        architecture: "",
        constraints: [],
        priorities: [],
        analysis_prompt: $analysis_prompt
      }' > "$intent_out"
  else
    cat > "$intent_out" <<JSON
{
  "generated_at": "$(now_utc)",
  "status": "pending_ai_interpretation",
  "project_root": "$(sanitize_field "$project_root")",
  "counts": {
    "file_count": $file_count,
    "text_file_count": $text_count,
    "chunked_file_count": $chunked_count,
    "skipped_file_count": $skipped_count,
    "chunk_count": $chunk_count
  },
  "goal": "",
  "domain": "",
  "architecture": "",
  "constraints": [],
  "priorities": [],
  "analysis_prompt": "Analyze the entire repository context and produce structured intent for skill discovery and evaluation."
}
JSON
  fi
}

cmd_prepare_ai_discovery() {
  local project_root=""
  local context_files=""
  local context_chunks=""
  local project_intent=""
  local out=""
  local channel
  local -a channels=()
  local idx objective

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-root)
        project_root="${2:-}"
        shift 2
        ;;
      --project-context-files)
        context_files="${2:-}"
        shift 2
        ;;
      --project-context-chunks)
        context_chunks="${2:-}"
        shift 2
        ;;
      --project-intent)
        project_intent="${2:-}"
        shift 2
        ;;
      --out)
        out="${2:-}"
        shift 2
        ;;
      --channel)
        channels+=("$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')")
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option for prepare-ai-discovery: $1"
        ;;
    esac
  done

  [[ -n "$project_root" && -d "$project_root" ]] || die "prepare-ai-discovery requires --project-root PATH"
  [[ -n "$context_files" && -f "$context_files" ]] || die "prepare-ai-discovery requires --project-context-files PATH"
  [[ -n "$context_chunks" && -f "$context_chunks" ]] || die "prepare-ai-discovery requires --project-context-chunks PATH"
  [[ -n "$project_intent" && -f "$project_intent" ]] || die "prepare-ai-discovery requires --project-intent PATH"

  if [[ -z "$out" ]]; then
    out="$(dirname "$context_files")/review_discovery.queue.tsv"
  fi

  if [[ ${#channels[@]} -eq 0 ]]; then
    channels=(find top github web)
  fi

  write_discovery_queue_header "$out"

  idx=0
  for channel in "${channels[@]}"; do
    case "$channel" in
      find)
        objective="Use the intent and context to generate high-relevance find queries and propose candidate skill_ref entries with evidence."
        ;;
      top)
        objective="Inspect top ecosystem skills and select candidates aligned with project constraints and architecture."
        ;;
      github)
        objective="Search GitHub skill repositories and nominate candidate skill_ref entries with trust/risk commentary."
        ;;
      web)
        objective="Explore additional web-discovered skill sources and extract candidate skill_ref entries with rationale."
        ;;
      *)
        warn "unsupported discovery channel ignored: $channel"
        continue
        ;;
    esac

    idx=$((idx + 1))
    printf 'D%03d\tdiscovery\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$idx" "$channel" "$project_root" "$project_intent" "$context_files" "$context_chunks" \
      "$(sanitize_field "$objective")" \
      "Emit TSV rows: task_id,expected_stage,skill_ref,repo,skill,discovery_channels,discovery_evidence,ai_relevance,ai_quality,ai_risk,ai_confidence,ai_decision,ai_recommended_status,ai_summary,ai_rationale,ai_reviewer,ai_reviewed_at,worker_run_id,worker_id,worker_started_at,worker_finished_at,worker_attempt,orchestrator_name" >> "$out"
  done

  log "Saved AI discovery queue: $out"
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
    skillRef: indexOf(h, 'skill_ref'),
    workerRunId: indexOf(h, 'worker_run_id'),
    workerId: indexOf(h, 'worker_id'),
    startedAt: indexOf(h, 'worker_started_at'),
    finishedAt: indexOf(h, 'worker_finished_at'),
    attempt: indexOf(h, 'worker_attempt'),
    orchestrator: indexOf(h, 'orchestrator_name'),
  };
  const requiredHeaderMissing = Object.values(idx).some((v) => v < 0);
  if (requiredHeaderMissing) {
    reasonCodes.add('missing_worker_metadata');
  }

  for (const row of parsed.rows) {
    const taskId = safeCell(row, idx.taskId);
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

cmd_merge_ai_discovery() {
  require_cmd awk
  require_cmd sort

  local out=""
  local manifest=""
  local proof=""
  local file
  local -a inputs=()
  local tmp_dir raw

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        out="${2:-}"
        shift 2
        ;;
      --manifest)
        manifest="${2:-}"
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
        inputs+=("$1")
        shift
        ;;
    esac
  done

  [[ -n "$out" ]] || die "merge-ai-discovery requires --out PATH"
  [[ -n "$manifest" ]] || die "merge-ai-discovery requires --manifest PATH"
  [[ -n "$proof" ]] || die "merge-ai-discovery requires --proof PATH"
  require_parallel_proof_passed "$proof" "discovery"
  [[ ${#inputs[@]} -gt 0 ]] || die "merge-ai-discovery requires at least one worker TSV"

  write_candidates_ai_header "$out"
  write_manifest_header "$manifest"

  tmp_dir="$(mktemp -d)"
  raw="$tmp_dir/raw.tsv"
  : > "$raw"

  for file in "${inputs[@]}"; do
    [[ -f "$file" ]] || die "AI discovery worker file does not exist: $file"
    awk 'NR>1' "$file" >> "$raw"
  done

  if [[ ! -s "$raw" ]]; then
    rm -rf "$tmp_dir"
    warn "merge-ai-discovery found no rows"
    log "Saved AI candidates: $out"
    log "Saved review manifest: $manifest"
    return 0
  fi

  awk -F '\t' '
  function add_unique_csv(existing, item,    n, i, arr) {
    if (item == "") return existing
    if (existing == "") return item
    n = split(existing, arr, ",")
    for (i = 1; i <= n; i++) if (arr[i] == item) return existing
    return existing "," item
  }
  function add_unique_pipe(existing, item,    n, i, arr) {
    if (item == "") return existing
    if (existing == "") return item
    n = split(existing, arr, " ~~ ")
    for (i = 1; i <= n; i++) if (arr[i] == item) return existing
    return existing " ~~ " item
  }
  function rec_rank(rec) {
    r = tolower(rec)
    if (r == "approved") return 3
    if (r == "pending") return 2
    if (r == "rejected") return 1
    return 0
  }
  function decision_rank(dec) {
    d = tolower(dec)
    if (d == "approve") return 4
    if (d == "hold") return 3
    if (d == "reject") return 2
    if (d == "") return 0
    return 1
  }
  {
    ref=$3
    if (ref == "") next

    channels[ref] = add_unique_csv(channels[ref], $6)
    evidence[ref] = add_unique_pipe(evidence[ref], $7)

    rr = rec_rank($13)
    dr = decision_rank($12)
    conf = ($11 == "" ? 0 : $11 + 0)
    rel = ($8 == "" ? 0 : $8 + 0)

    if (!(ref in best_line) ||
        rr > best_rec[ref] ||
        (rr == best_rec[ref] && dr > best_dec[ref]) ||
        (rr == best_rec[ref] && dr == best_dec[ref] && conf > best_conf[ref]) ||
        (rr == best_rec[ref] && dr == best_dec[ref] && conf == best_conf[ref] && rel > best_rel[ref])) {
      best_line[ref] = $0
      best_rec[ref] = rr
      best_dec[ref] = dr
      best_conf[ref] = conf
      best_rel[ref] = rel
    }
  }
  END {
    for (ref in best_line) {
      split(best_line[ref], f, FS)
      f[6] = channels[ref]
      f[7] = evidence[ref]
      print f[3]"\t"f[4]"\t"f[5]"\t"f[6]"\t"f[7]"\t"f[8]"\t"f[9]"\t"f[10]"\t"f[11]"\t"f[12]"\t"f[13]"\t"f[14]"\t"f[15]"\t"f[16]"\t"f[17]
    }
  }
  ' "$raw" | sort -t $'\t' -k9,9nr -k1,1 >> "$out"

  awk -F '\t' -v OFS='\t' '
  NR>1 {
    summary = $12
    if (summary == "") summary = "ai-discovery candidate"
    note = "ai-discovery(decision=" tolower($10) ", confidence=" $9 ", summary=" summary ")"
    print $1, $2, $3, $4, summary, $9, "pending", note, "", "", $6, $7, $8, $9, tolower($10)
  }
  ' "$out" >> "$manifest"

  log "Saved AI candidates: $out"
  log "Saved review manifest: $manifest"
  rm -rf "$tmp_dir"
}

cmd_validate_content() {
  require_cmd npx
  require_cmd awk

  local manifest=""
  local out=""
  local status_filter="pending"
  local limit=""
  local processed=0
  local manifest_dir tmp_dir list_cache_dir
  local preview_max=180
  local -a selected_refs=()

  local skill_ref repo skill manifest_status_lc expected_repo expected_skill
  local name_check install_check skill_md_check gate_status gate_reason gate_notes
  local sandbox_dir install_out skill_md_file list_cache_file list_cache_status_file cached_list_status
  local repo_cache_key listed_skill

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

  manifest_dir="$(dirname "$manifest")"
  if [[ -z "$out" ]]; then
    out="$manifest_dir/review_content.tsv"
  fi

  write_content_review_header "$out"
  tmp_dir="$(mktemp -d)"
  list_cache_dir="$tmp_dir/list_cache"
  mkdir -p "$list_cache_dir"

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

  while IFS=$'\037' read -r skill_ref repo skill manifest_status_lc; do
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
    install_check="skipped"
    skill_md_check="missing"
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
      repo_cache_key="$(printf '%s' "$repo" | tr '/:@.' '____' | tr -cs '[:alnum:]_' '_')"
      list_cache_file="$list_cache_dir/${repo_cache_key}.list.txt"
      list_cache_status_file="$list_cache_dir/${repo_cache_key}.status"

      if [[ ! -f "$list_cache_status_file" ]]; then
        if FORCE_COLOR=0 npx skills add "$repo" --list > "$list_cache_file" 2>&1 < /dev/null; then
          printf 'ok\n' > "$list_cache_status_file"
        else
          printf 'failed\n' > "$list_cache_status_file"
        fi
      fi

      cached_list_status="$(head -n 1 "$list_cache_status_file" 2>/dev/null || true)"
      if [[ "$cached_list_status" != "ok" ]]; then
        name_check="list_failed"
        gate_reason="list_failed"
        gate_notes="repository skill list query failed"
      else
        name_check="not_found"
        while IFS= read -r listed_skill; do
          if [[ "$listed_skill" == "$skill" ]]; then
            name_check="matched"
            break
          fi
        done < <(extract_skill_names_from_list_file "$list_cache_file")

        if [[ "$name_check" != "matched" ]]; then
          gate_reason="not_found"
          gate_notes="skill not found in repository list"
        else
          sandbox_dir="$tmp_dir/work_${processed}"
          mkdir -p "$sandbox_dir"
          install_out="$tmp_dir/install_${processed}.txt"

          if (cd "$sandbox_dir" && FORCE_COLOR=0 npx skills add "$repo" --skill "$skill" -y > "$install_out" 2>&1 < /dev/null); then
            install_check="installed"
            skill_md_file="$sandbox_dir/.agents/skills/$skill/SKILL.md"
            if [[ -f "$skill_md_file" ]]; then
              skill_md_check="present"
              gate_status="gate_pass"
              gate_reason="ok"
              gate_notes="all safety gates passed"
            else
              skill_md_check="missing"
              gate_reason="skill_md_missing"
              gate_notes="install succeeded but SKILL.md not found"
            fi
          else
            install_check="install_failed"
            gate_reason="install_failed"
            gate_notes="single skill installation failed"
          fi
        fi
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$skill_ref" "$repo" "$skill" "$manifest_status_lc" "$name_check" "$install_check" "$skill_md_check" \
      "$gate_status" "$gate_reason" "$(sanitize_field "$gate_notes")" >> "$out"
  done < <(
    awk -F '\t' 'NR>1{printf "%s\037%s\037%s\037%s\n", $1,$2,$3,tolower($7)}' "$manifest"
  )

  if [[ "$processed" -eq 0 ]]; then
    warn "validate-content found no rows for the current filters"
  fi

  log "Saved content review report: $out"
  rm -rf "$tmp_dir"
}

cmd_prepare_ai_reviews() {
  require_cmd awk

  local manifest=""
  local content_report=""
  local project_intent=""
  local out=""
  local status_filter="pending"
  local limit=""
  local include_gate_fail="0"
  local tmp_dir raw
  local project_goal=""
  local project_domain=""
  local project_constraints=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manifest)
        manifest="${2:-}"
        shift 2
        ;;
      --content-report)
        content_report="${2:-}"
        shift 2
        ;;
      --project-intent)
        project_intent="${2:-}"
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
      --limit)
        limit="${2:-}"
        shift 2
        ;;
      --include-gate-fail)
        include_gate_fail="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option for prepare-ai-reviews: $1"
        ;;
    esac
  done

  [[ -n "$manifest" && -f "$manifest" ]] || die "prepare-ai-reviews requires --manifest PATH"
  [[ -n "$content_report" && -f "$content_report" ]] || die "prepare-ai-reviews requires --content-report PATH"
  case "$status_filter" in
    pending|approved|rejected|all) ;;
    *) die "prepare-ai-reviews --status must be one of: pending, approved, rejected, all" ;;
  esac
  if [[ -n "$limit" && ! "$limit" =~ ^[0-9]+$ ]]; then
    die "prepare-ai-reviews --limit must be a non-negative integer"
  fi

  if [[ -z "$project_intent" ]]; then
    if [[ -f "$(dirname "$manifest")/project_intent.ai.json" ]]; then
      project_intent="$(dirname "$manifest")/project_intent.ai.json"
    fi
  fi

  if [[ -n "$project_intent" && -f "$project_intent" && $(command -v jq >/dev/null 2>&1; echo $?) -eq 0 ]]; then
    project_goal="$(jq -r '.goal // ""' "$project_intent" 2>/dev/null || true)"
    project_domain="$(jq -r '.domain // ""' "$project_intent" 2>/dev/null || true)"
    project_constraints="$(jq -c '.constraints // []' "$project_intent" 2>/dev/null || true)"
  fi

  if [[ -z "$out" ]]; then
    out="$(dirname "$content_report")/review_ai.queue.tsv"
  fi

  write_ai_review_header "$out"
  tmp_dir="$(mktemp -d)"
  raw="$tmp_dir/raw.tsv"

  awk -F '\t' -v OFS='\t' \
    -v status_filter="$status_filter" \
    -v include_gate_fail="$include_gate_fail" \
    -v project_goal="$(sanitize_field "$project_goal")" \
    -v project_domain="$(sanitize_field "$project_domain")" \
    -v project_constraints="$(sanitize_field "$project_constraints")" '
  BEGIN { task_counter = 0 }
  FNR==NR {
    if (FNR == 1) next
    m_status[$1] = tolower($7)
    m_summary[$1] = $5
    next
  }
  FNR==1 { next }
  {
    ref = $1
    if (!(ref in m_status)) next

    gate_status = tolower($8)
    if (status_filter != "all" && m_status[ref] != status_filter) next
    if (include_gate_fail != "1" && gate_status != "gate_pass") next

    task_counter += 1
    task_id = sprintf("R%03d", task_counter)
    print task_id, "review", ref, $2, $3, m_status[ref], gate_status, tolower($9), project_goal, project_domain, project_constraints, m_summary[ref], "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", ""
  }
  ' "$manifest" "$content_report" > "$raw"

  if [[ ! -s "$raw" ]]; then
    rm -rf "$tmp_dir"
    warn "prepare-ai-reviews found no candidates"
    log "Saved AI review queue: $out"
    return 0
  fi

  if [[ -n "$limit" ]]; then
    awk -v lim="$limit" 'NR<=lim' "$raw" >> "$out"
  else
    cat "$raw" >> "$out"
  fi

  log "Saved AI review queue: $out"
  rm -rf "$tmp_dir"
}

cmd_merge_ai_reviews() {
  require_cmd awk
  require_cmd sort

  local out=""
  local proof=""
  local file
  local -a inputs=()
  local tmp_dir raw

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
        inputs+=("$1")
        shift
        ;;
    esac
  done

  [[ -n "$out" ]] || die "merge-ai-reviews requires --out PATH"
  [[ -n "$proof" ]] || die "merge-ai-reviews requires --proof PATH"
  require_parallel_proof_passed "$proof" "review"
  [[ ${#inputs[@]} -gt 0 ]] || die "merge-ai-reviews requires at least one input report file"

  write_ai_review_header "$out"
  tmp_dir="$(mktemp -d)"
  raw="$tmp_dir/raw.tsv"
  : > "$raw"

  for file in "${inputs[@]}"; do
    [[ -f "$file" ]] || die "AI review input file does not exist: $file"
    awk 'NR>1' "$file" >> "$raw"
  done

  if [[ ! -s "$raw" ]]; then
    rm -rf "$tmp_dir"
    warn "merge-ai-reviews found no rows"
    log "Saved merged AI review report: $out"
    return 0
  fi

  awk -F '\t' '
  function rec_rank(rec) {
    r=tolower(rec)
    if (r=="approved") return 3
    if (r=="pending") return 2
    if (r=="rejected") return 1
    return 0
  }
  function decision_rank(dec) {
    d=tolower(dec)
    if (d=="approve") return 4
    if (d=="hold") return 3
    if (d=="reject") return 2
    if (d=="") return 0
    return 1
  }
  {
    ref=$3
    if (ref == "") next

    rr=rec_rank($18)
    dr=decision_rank($17)
    conf=($16=="" ? 0 : $16 + 0)
    rel=($13=="" ? 0 : $13 + 0)

    if (!(ref in best_line) ||
        rr > best_rec[ref] ||
        (rr == best_rec[ref] && dr > best_dec[ref]) ||
        (rr == best_rec[ref] && dr == best_dec[ref] && conf > best_conf[ref]) ||
        (rr == best_rec[ref] && dr == best_dec[ref] && conf == best_conf[ref] && rel > best_rel[ref])) {
      best_line[ref]=$0
      best_rec[ref]=rr
      best_dec[ref]=dr
      best_conf[ref]=conf
      best_rel[ref]=rel
    }
  }
  END {
    for (ref in best_line) print best_line[ref]
  }
  ' "$raw" | sort -t $'\t' -k16,16nr -k3,3 >> "$out"

  log "Saved merged AI review report: $out"
  rm -rf "$tmp_dir"
}

cmd_apply_ai_reviews() {
  require_cmd awk

  local manifest=""
  local ai_reviews=""
  local out=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manifest)
        manifest="${2:-}"
        shift 2
        ;;
      --ai-reviews)
        ai_reviews="${2:-}"
        shift 2
        ;;
      --out)
        out="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option for apply-ai-reviews: $1"
        ;;
    esac
  done

  [[ -n "$manifest" && -f "$manifest" ]] || die "apply-ai-reviews requires --manifest PATH"
  [[ -n "$ai_reviews" && -f "$ai_reviews" ]] || die "apply-ai-reviews requires --ai-reviews PATH"

  if [[ -z "$out" ]]; then
    out="$(dirname "$manifest")/review_manifest.ai.tsv"
  fi

  awk -F '\t' -v OFS='\t' '
  FNR==NR {
    if (FNR == 1) next
    ref=$3
    rec=tolower($18)
    if (rec!="approved" && rec!="pending" && rec!="rejected") next

    map_status[ref]=rec
    map_rel[ref]=$13
    map_qual[ref]=$14
    map_risk[ref]=$15
    map_conf[ref]=$16
    map_decision[ref]=tolower($17)
    map_summary[ref]=$19
    map_reviewer[ref]=$21
    map_reviewed_at[ref]=$22
    next
  }
  FNR==1 { print; next }
  {
    ref=$1
    if (ref in map_status) {
      $7=map_status[ref]
      note="ai-review(decision=" map_decision[ref] ", confidence=" map_conf[ref]
      if (map_summary[ref] != "") note=note ", summary=" map_summary[ref]
      note=note ")"

      if ($8 == "") $8=note
      else $8=$8 "; " note

      if (map_reviewer[ref] != "") $9=map_reviewer[ref]
      if (map_reviewed_at[ref] != "") $10=map_reviewed_at[ref]
      $11=map_rel[ref]
      $12=map_qual[ref]
      $13=map_risk[ref]
      $14=map_conf[ref]
      $15=map_decision[ref]
    }
    print
  }
  ' "$ai_reviews" "$manifest" > "$out"

  log "Saved AI-applied manifest: $out"
}

cmd_install() {
  require_cmd npx

  local file=""
  local dry_run="0"
  local yes="1"
  local line
  local -a refs=()
  local -a deduped=()
  local ref

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)
        file="${2:-}"
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
        die "unknown option for install: $1"
        ;;
    esac
  done

  [[ -n "$file" && -f "$file" ]] || die "install requires --file PATH"

  while IFS= read -r line; do
    ref="$(sanitize_field "$line")"
    [[ -n "$ref" ]] || continue
    is_skill_ref "$ref" || { warn "skip invalid skill ref: $ref"; continue; }
    refs+=("$ref")
  done < "$file"

  if [[ ${#refs[@]} -eq 0 ]]; then
    warn "no valid skill refs found in: $file"
    return 0
  fi

  for ref in "${refs[@]}"; do
    local seen=0
    local existing
    for existing in "${deduped[@]:-}"; do
      if [[ "$existing" == "$ref" ]]; then
        seen=1
        break
      fi
    done
    [[ "$seen" -eq 1 ]] && continue
    deduped+=("$ref")
  done

  for ref in "${deduped[@]}"; do
    if [[ "$dry_run" == "1" ]]; then
      log "DRY-RUN: npx skills add $ref -y"
      continue
    fi

    if [[ "$yes" == "1" ]]; then
      npx skills add "$ref" -y < /dev/null
    else
      npx skills add "$ref" < /dev/null
    fi
  done
}

cmd_audit() {
  local out=""
  local summary_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        out="${2:-}"
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
  summary_file="$(dirname "$out")/parallel_proof.summary.json"

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
    if [[ -f "$summary_file" ]]; then
      cat "$summary_file"
    else
      printf 'parallel proof summary file not found: %s\n' "$summary_file"
    fi
  } > "$out"

  log "Saved audit log: $out"
}

cmd_install_approved() {
  require_cmd npx
  require_cmd awk

  local manifest=""
  local report=""
  local dry_run="0"
  local yes="1"
  local now cmd status
  local tmp_dir grouped
  local repo skills_csv skill_args command_str
  local -a skill_list=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manifest)
        manifest="${2:-}"
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

  write_install_report_header "$report"
  now="$(now_utc)"

  tmp_dir="$(mktemp -d)"
  grouped="$tmp_dir/grouped.tsv"

  awk -F '\t' '
  function add_unique(existing, item,    n, i, arr) {
    if (existing == "") return item
    n = split(existing, arr, ",")
    for (i = 1; i <= n; i++) if (arr[i] == item) return existing
    return existing "," item
  }
  NR>1 {
    if (tolower($7) != "approved") next
    repo=$2
    skill=$3
    if (repo == "" || skill == "") next
    skills[repo] = add_unique(skills[repo], skill)
  }
  END {
    for (repo in skills) print repo "\t" skills[repo]
  }
  ' "$manifest" | sort -t $'\t' -k1,1 > "$grouped"

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
    cmd_audit --out "$(dirname "$report")/audit.log"
  fi

  log "Saved install report: $report"
  rm -rf "$tmp_dir"
}

cmd_run() {
  local project_root out_dir
  local max_file_bytes chunk_chars
  local files_out chunks_out intent_out
  local discovery_queue_out review_queue_out candidates_out manifest_out
  local discovery_proof_out discovery_summary_out
  local review_proof_out review_summary_out aggregate_summary_out
  local run_contract_out
  local discovery_merge_proof=""
  local channel
  local -a channels=()
  local -a discovery_worker_files=()

  project_root="$(pwd)"
  out_dir=""
  max_file_bytes="200000"
  chunk_chars="4000"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-root)
        project_root="${2:-}"
        shift 2
        ;;
      --out-dir)
        out_dir="${2:-}"
        shift 2
        ;;
      --max-file-bytes)
        max_file_bytes="${2:-}"
        shift 2
        ;;
      --chunk-chars)
        chunk_chars="${2:-}"
        shift 2
        ;;
      --channel)
        channel="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
        channels+=("$channel")
        shift 2
        ;;
      --discovery-worker-file)
        discovery_worker_files+=("${2:-}")
        shift 2
        ;;
      --discovery-proof)
        discovery_merge_proof="${2:-}"
        shift 2
        ;;
      --top|--find-query|--github-query|--web-links-file)
        die "legacy option is removed in AI-only mode: $1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option for run: $1"
        ;;
    esac
  done

  [[ -d "$project_root" ]] || die "project root does not exist: $project_root"
  [[ "$max_file_bytes" =~ ^[0-9]+$ ]] || die "--max-file-bytes must be numeric"
  [[ "$chunk_chars" =~ ^[0-9]+$ ]] || die "--chunk-chars must be numeric"

  if [[ -z "$out_dir" ]]; then
    out_dir="$project_root/.agents/skills-batch-ops/runs/$(now_stamp)"
  fi
  mkdir -p "$out_dir"

  files_out="$out_dir/project_context.files.tsv"
  chunks_out="$out_dir/project_context.chunks.ndjson"
  intent_out="$out_dir/project_intent.ai.json"
  discovery_queue_out="$out_dir/review_discovery.queue.tsv"
  review_queue_out="$out_dir/review_ai.queue.tsv"
  candidates_out="$out_dir/candidates.ai.tsv"
  manifest_out="$out_dir/review_manifest.tsv"
  discovery_proof_out="$out_dir/discovery_parallel_proof.tsv"
  discovery_summary_out="$out_dir/discovery_parallel_summary.json"
  review_proof_out="$out_dir/review_parallel_proof.tsv"
  review_summary_out="$out_dir/review_parallel_summary.json"
  aggregate_summary_out="$out_dir/parallel_proof.summary.json"
  run_contract_out="$out_dir/run_contract.json"

  build_project_context "$project_root" "$files_out" "$chunks_out" "$intent_out" "$max_file_bytes" "$chunk_chars"

  if [[ ${#channels[@]} -gt 0 ]]; then
    local args=()
    for channel in "${channels[@]}"; do
      args+=(--channel "$channel")
    done
    cmd_prepare_ai_discovery \
      --project-root "$project_root" \
      --project-context-files "$files_out" \
      --project-context-chunks "$chunks_out" \
      --project-intent "$intent_out" \
      --out "$discovery_queue_out" \
      "${args[@]}"
  else
    cmd_prepare_ai_discovery \
      --project-root "$project_root" \
      --project-context-files "$files_out" \
      --project-context-chunks "$chunks_out" \
      --project-intent "$intent_out" \
      --out "$discovery_queue_out"
  fi

  if [[ ${#discovery_worker_files[@]} -gt 0 ]]; then
    [[ -n "$discovery_merge_proof" ]] || die "run with --discovery-worker-file requires --discovery-proof PATH"
    cmd_merge_ai_discovery --out "$candidates_out" --manifest "$manifest_out" --proof "$discovery_merge_proof" "${discovery_worker_files[@]}"
  else
    write_candidates_ai_header "$candidates_out"
    write_manifest_header "$manifest_out"
  fi

  write_run_contract \
    "$run_contract_out" \
    "$project_root" \
    "$out_dir" \
    "$discovery_queue_out" \
    "$review_queue_out" \
    "$discovery_proof_out" \
    "$discovery_summary_out" \
    "$review_proof_out" \
    "$review_summary_out" \
    "$aggregate_summary_out"

  log "Saved run contract: $run_contract_out"
  log "Run complete: $out_dir"
}

cmd_deprecated() {
  local sub="$1"
  die "subcommand '$sub' is removed in AI-only mode. Use run + prepare-ai-discovery + merge-ai-discovery instead."
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local sub="$1"
  shift

  case "$sub" in
    run) cmd_run "$@" ;;
    prepare-ai-discovery) cmd_prepare_ai_discovery "$@" ;;
    verify-parallel-proof) cmd_verify_parallel_proof "$@" ;;
    merge-ai-discovery) cmd_merge_ai_discovery "$@" ;;
    validate-content) cmd_validate_content "$@" ;;
    prepare-ai-reviews) cmd_prepare_ai_reviews "$@" ;;
    merge-ai-reviews) cmd_merge_ai_reviews "$@" ;;
    apply-ai-reviews) cmd_apply_ai_reviews "$@" ;;
    install-approved) cmd_install_approved "$@" ;;
    install) cmd_install "$@" ;;
    audit) cmd_audit "$@" ;;
    collect-find|collect-top|collect-github|import-web|merge|collect) cmd_deprecated "$sub" ;;
    -h|--help) usage ;;
    *) die "unknown subcommand: $sub" ;;
  esac
}

main "$@"
