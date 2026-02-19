#!/usr/bin/env bash
set -euo pipefail

BEGIN_MARKER="# BEGIN project-agent-factory managed agents"
END_MARKER="# END project-agent-factory managed agents"
PLAN_HEADER=$'agent_id\trole_name\tpriority\treason\tconfig_relpath\tdescription\tdeveloper_instructions\tmodel\tmodel_reasoning_effort\tsandbox_mode'

usage() {
  cat <<'USAGE'
Usage:
  agent_factory.sh apply-plan --project-root PATH --plan PATH [--out-dir PATH]
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

toml_escape_basic_string() {
  local raw="${1:-}"
  printf '%s' "$raw" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

toml_escape_multiline_string() {
  local raw="${1:-}"
  printf '%s' "$raw" | tr -d '\r' | sed 's/"""/\\"""/g'
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

now_stamp() {
  local now
  now="$(now_utc)"
  printf '%s\n' "${now//[-:]/}" | sed 's/T/_/; s/Z$//'
}

resolve_dir() {
  local path="$1"
  [[ -d "$path" ]] || die "directory does not exist: $path"
  (
    cd "$path"
    pwd -P
  )
}

resolve_path() {
  local path="$1"
  local parent
  parent="$(dirname "$path")"
  if [[ ! -d "$parent" ]]; then
    mkdir -p "$parent"
  fi
  (
    cd "$parent"
    printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")"
  )
}

is_within_project() {
  local project_root="$1"
  local target="$2"
  case "$target" in
    "$project_root") return 0 ;;
    "$project_root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_project_child_path() {
  local project_root="$1"
  local relpath="$2"
  local normalized="$relpath"
  local resolved

  normalized="${normalized#./}"
  [[ -n "$normalized" ]] || die "relative path is empty"
  [[ "$normalized" != /* ]] || die "path must be relative to project root: $relpath"

  case "$normalized" in
    ".."|../*|*/../*|*/..)
      die "path contains parent traversal: $relpath"
      ;;
  esac

  resolved="$(resolve_path "$project_root/$normalized")"
  is_within_project "$project_root" "$resolved" || die "path escapes project root: $relpath"
  printf '%s\n' "$resolved"
}

validate_agent_config_relpath() {
  local config_relpath="$1"
  local normalized="$config_relpath"

  normalized="${normalized#./}"
  [[ -n "$normalized" ]] || die "config_relpath is empty"

  case "$normalized" in
    ".."|../*|*/../*|*/..|*\\*|*//*|*/./*|./*|*/.)
      die "invalid config_relpath: $config_relpath"
      ;;
  esac

  [[ "$normalized" =~ ^agents/[A-Za-z0-9._-]+\.toml$ ]] || die "config_relpath must match agents/*.toml: $config_relpath"
  printf '%s\n' "$normalized"
}

validate_plan_schema() {
  local plan="$1"
  local header
  local row_count=0
  local line_no=1
  local agent_id
  local role_name
  local priority
  local reason
  local config_relpath
  local description
  local developer_instructions
  local model
  local model_reasoning_effort
  local sandbox_mode
  local rest
  local duplicate_agent
  local duplicate_config

  [[ -f "$plan" ]] || die "plan file not found: $plan"
  header="$(head -n 1 "$plan" | tr -d '\r')"
  [[ "$header" == "$PLAN_HEADER" ]] || die "invalid plan header. expected: $PLAN_HEADER"

  while IFS=$'\t' read -r agent_id role_name priority reason config_relpath description developer_instructions model model_reasoning_effort sandbox_mode rest; do
    line_no=$((line_no + 1))
    if [[ "$agent_id" == "agent_id" ]]; then
      continue
    fi

    sandbox_mode="${sandbox_mode%$'\r'}"
    rest="${rest%$'\r'}"
    row_count=$((row_count + 1))

    [[ -z "$rest" ]] || die "plan row $line_no has unexpected extra columns"
    [[ -n "$agent_id" ]] || die "plan row $line_no: agent_id is required"
    [[ "$agent_id" =~ ^[A-Za-z0-9._-]+$ ]] || die "plan row $line_no: invalid agent_id '$agent_id'"
    [[ -n "$role_name" ]] || die "plan row $line_no: role_name is required"
    [[ "$priority" =~ ^[0-9]+$ ]] || die "plan row $line_no: priority must be a positive integer"
    [[ "$priority" -ge 1 ]] || die "plan row $line_no: priority must be >= 1"
    [[ -n "$reason" ]] || die "plan row $line_no: reason is required"
    validate_agent_config_relpath "$config_relpath" >/dev/null
    [[ -n "$description" ]] || die "plan row $line_no: description is required"
    [[ -n "$developer_instructions" ]] || die "plan row $line_no: developer_instructions is required"
    [[ -n "$model" ]] || die "plan row $line_no: model is required"
    case "$model_reasoning_effort" in
      minimal|low|medium|high|xhigh) ;;
      *) die "plan row $line_no: model_reasoning_effort must be one of minimal|low|medium|high|xhigh" ;;
    esac
    case "$sandbox_mode" in
      read-only|workspace-write|danger-full-access) ;;
      *) die "plan row $line_no: sandbox_mode must be one of read-only|workspace-write|danger-full-access" ;;
    esac
  done < "$plan"

  [[ "$row_count" -gt 0 ]] || die "plan must include at least one agent row"

  duplicate_agent="$(awk -F'\t' 'NR>1 {if (++seen[$1] > 1) {print $1; exit}}' "$plan")"
  [[ -z "$duplicate_agent" ]] || die "duplicate agent_id in plan: $duplicate_agent"

  duplicate_config="$(awk -F'\t' 'NR>1 {if (++seen[$5] > 1) {print $5; exit}}' "$plan")"
  [[ -z "$duplicate_config" ]] || die "duplicate config_relpath in plan: $duplicate_config"
}

write_apply_report_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'timestamp\taction\tpath\tstatus\tnote\n' > "$out"
}

append_apply_report() {
  local out="$1"
  local action="$2"
  local path="$3"
  local status="$4"
  local note="$5"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(now_utc)" \
    "$(sanitize_field "$action")" \
    "$(sanitize_field "$path")" \
    "$(sanitize_field "$status")" \
    "$(sanitize_field "$note")" >> "$out"
}

write_scope_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'path\twithin_scope\tnote\n' > "$out"
}

append_scope_row() {
  local out="$1"
  local path="$2"
  local within_scope="$3"
  local note="$4"
  printf '%s\t%s\t%s\n' \
    "$(sanitize_field "$path")" \
    "$(sanitize_field "$within_scope")" \
    "$(sanitize_field "$note")" >> "$out"
}

build_agent_file() {
  local out="$1"
  local role_name="$2"
  local developer_instructions="$3"
  local model="$4"
  local model_reasoning_effort="$5"
  local sandbox_mode="$6"
  local escaped_instructions

  escaped_instructions="$(toml_escape_multiline_string "$developer_instructions")"

  cat > "$out" <<EOF_AGENT
# managed_by=project-agent-factory
# role=${role_name}
model = "$(toml_escape_basic_string "$model")"
model_reasoning_effort = "$(toml_escape_basic_string "$model_reasoning_effort")"
sandbox_mode = "$(toml_escape_basic_string "$sandbox_mode")"

developer_instructions = """
${escaped_instructions}
Do not write outside the project root.
"""
EOF_AGENT
}

build_managed_block() {
  local plan="$1"
  local out="$2"
  local generated_at
  local safe_config_relpath

  generated_at="$(now_utc)"

  {
    printf '%s\n' "$BEGIN_MARKER"
    printf '# generated_at=%s\n' "$generated_at"
    printf '# This block is managed by project-agent-factory.\n'
    while IFS=$'\t' read -r agent_id _role_name _priority _reason config_relpath description _developer_instructions _model _model_reasoning_effort _sandbox_mode _rest; do
      if [[ "$agent_id" == "agent_id" ]]; then
        continue
      fi
      safe_config_relpath="$(validate_agent_config_relpath "$config_relpath")"
      printf '\n[agents."%s"]\n' "$(toml_escape_basic_string "$agent_id")"
      printf 'description = "%s"\n' "$(toml_escape_basic_string "$(sanitize_field "$description")")"
      printf 'config_file = "%s"\n' "$safe_config_relpath"
    done < "$plan"
    printf '\n%s\n' "$END_MARKER"
  } > "$out"
}

validate_managed_block_markers() {
  local config_file="$1"
  local begin_count
  local end_count
  local begin_line
  local end_line

  begin_count="$(awk -v begin="$BEGIN_MARKER" '$0 == begin {count++} END {print count+0}' "$config_file")"
  end_count="$(awk -v end="$END_MARKER" '$0 == end {count++} END {print count+0}' "$config_file")"

  if [[ "$begin_count" -eq 0 && "$end_count" -eq 0 ]]; then
    return
  fi

  if [[ "$begin_count" -ne 1 || "$end_count" -ne 1 ]]; then
    die "invalid managed block markers in $config_file (BEGIN=$begin_count, END=$end_count)"
  fi

  begin_line="$(awk -v begin="$BEGIN_MARKER" '$0 == begin {print NR; exit}' "$config_file")"
  end_line="$(awk -v end="$END_MARKER" '$0 == end {print NR; exit}' "$config_file")"
  if [[ -z "$begin_line" || -z "$end_line" || "$begin_line" -ge "$end_line" ]]; then
    die "invalid managed block ordering in $config_file"
  fi
}

replace_managed_block() {
  local config_file="$1"
  local managed_block="$2"
  local tmp

  if [[ ! -f "$config_file" ]]; then
    cat "$managed_block" > "$config_file"
    return
  fi

  validate_managed_block_markers "$config_file"

  if rg -q "^${BEGIN_MARKER}$" "$config_file"; then
    tmp="$(mktemp)"
    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v block="$managed_block" '
      BEGIN {in_block = 0}
      $0 == begin {
        while ((getline line < block) > 0) {
          print line
        }
        close(block)
        in_block = 1
        next
      }
      $0 == end {
        in_block = 0
        next
      }
      in_block == 0 {
        print
      }
    ' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
    return
  fi

  if [[ -s "$config_file" ]]; then
    printf '\n' >> "$config_file"
  fi
  cat "$managed_block" >> "$config_file"
}

ensure_multi_agent_feature_enabled() {
  local config_file="$1"
  local report="$2"
  local tmp

  tmp="$(mktemp)"

  awk '
    function is_table_header(line) {
      return line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/
    }
    function is_features_header(line) {
      return line ~ /^[[:space:]]*\[features\][[:space:]]*$/
    }
    function maybe_emit_feature_key() {
      if (in_features == 1 && current_features_has_multi == 0 && emitted_multi == 0) {
        print "multi_agent = true"
        emitted_multi = 1
      }
    }
    BEGIN {
      in_features = 0
      seen_features_table = 0
      current_features_has_multi = 0
      emitted_multi = 0
      has_lines = 0
    }
    {
      line = $0
      has_lines = 1

      if (is_table_header(line)) {
        maybe_emit_feature_key()
        in_features = 0
        current_features_has_multi = 0
        if (is_features_header(line)) {
          in_features = 1
          seen_features_table = 1
        }
        print line
        next
      }

      if (in_features == 1 && line ~ /^[[:space:]]*multi_agent[[:space:]]*=/) {
        if (emitted_multi == 0) {
          print "multi_agent = true"
          emitted_multi = 1
          current_features_has_multi = 1
        }
        next
      }

      print line
    }
    END {
      maybe_emit_feature_key()
      if (seen_features_table == 0) {
        if (has_lines == 1) {
          print ""
        }
        print "[features]"
        print "multi_agent = true"
      }
    }
  ' "$config_file" > "$tmp"

  if cmp -s "$config_file" "$tmp"; then
    rm -f "$tmp"
    append_apply_report "$report" "enable_multi_agent_feature" "$config_file" "ok" "features.multi_agent already enabled"
    return
  fi

  mv "$tmp" "$config_file"
  append_apply_report "$report" "enable_multi_agent_feature" "$config_file" "updated" "ensure features.multi_agent = true"
}

render_config() {
  local project_root="$1"
  local plan="$2"
  local report="$3"
  local codex_dir="$project_root/.codex"
  local agents_dir="$codex_dir/agents"
  local config_file="$codex_dir/config.toml"
  local managed_block
  local managed_status
  local agent_file
  local status
  local note
  local safe_config_relpath
  local planned_agent_files
  local existing_agent_file

  mkdir -p "$agents_dir"
  write_apply_report_header "$report"
  append_apply_report "$report" "mkdir" "$codex_dir" "ok" "ensure .codex exists"
  append_apply_report "$report" "mkdir" "$agents_dir" "ok" "ensure agents directory exists"
  planned_agent_files="$(mktemp)"
  : > "$planned_agent_files"

  while IFS=$'\t' read -r agent_id role_name _priority _reason config_relpath _description developer_instructions model model_reasoning_effort sandbox_mode _rest; do
    if [[ "$agent_id" == "agent_id" ]]; then
      continue
    fi
    sandbox_mode="${sandbox_mode%$'\r'}"
    safe_config_relpath="$(validate_agent_config_relpath "$config_relpath")"
    agent_file="$(resolve_project_child_path "$project_root" ".codex/$safe_config_relpath")"
    printf '%s\n' "$agent_file" >> "$planned_agent_files"
    ensure_parent_dir "$agent_file"
    if [[ -f "$agent_file" ]]; then
      status="updated"
      note="overwrite managed role config"
    else
      status="created"
      note="new role config"
    fi
    build_agent_file \
      "$agent_file" \
      "$role_name" \
      "$developer_instructions" \
      "$model" \
      "$model_reasoning_effort" \
      "$sandbox_mode"
    append_apply_report "$report" "write_agent_config" "$agent_file" "$status" "$note"
  done < "$plan"

  while IFS= read -r existing_agent_file; do
    if rg -qxF "$existing_agent_file" "$planned_agent_files"; then
      continue
    fi
    if rg -q "^# managed_by=project-agent-factory$" "$existing_agent_file"; then
      rm -f "$existing_agent_file"
      append_apply_report "$report" "remove_stale_agent_config" "$existing_agent_file" "removed" "removed stale managed role config"
    fi
  done < <(find "$agents_dir" -maxdepth 1 -type f -name "*.toml" | sort)

  managed_block="$(mktemp)"
  build_managed_block "$plan" "$managed_block"

  if [[ -f "$config_file" ]]; then
    managed_status="updated"
  else
    managed_status="created"
  fi
  ensure_parent_dir "$config_file"
  replace_managed_block "$config_file" "$managed_block"
  append_apply_report "$report" "write_config_block" "$config_file" "$managed_status" "managed block synced"
  ensure_multi_agent_feature_enabled "$config_file" "$report"

  rm -f "$planned_agent_files"
  rm -f "$managed_block"
}

validate_scope() {
  local project_root="$1"
  local report="$2"
  local out="$3"
  local path
  local failed=0

  write_scope_header "$out"
  while IFS=$'\t' read -r _timestamp _action path _status _note; do
    if [[ "$path" == "path" || "$path" == "" ]]; then
      continue
    fi
    if is_within_project "$project_root" "$path"; then
      append_scope_row "$out" "$path" "yes" "inside project root"
    else
      failed=1
      append_scope_row "$out" "$path" "no" "outside project root"
    fi
  done < "$report"

  if [[ "$failed" -ne 0 ]]; then
    die "scope validation failed (see $out)"
  fi
}

apply_plan_pipeline() {
  local project_root="$1"
  local plan="$2"
  local out_dir="$3"
  local report_file="$out_dir/apply_report.tsv"
  local scope_file="$out_dir/scope_validation.tsv"

  validate_plan_schema "$plan"

  mkdir -p "$out_dir"
  render_config "$project_root" "$plan" "$report_file"
  validate_scope "$project_root" "$report_file" "$scope_file"

  log "run_dir: $out_dir"
  log "plan: $plan"
  log "report: $report_file"
  log "scope: $scope_file"
}

parse_apply_plan_args() {
  local project_root=""
  local plan=""
  local out_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-root)
        project_root="$2"
        shift 2
        ;;
      --plan)
        plan="$2"
        shift 2
        ;;
      --out-dir)
        out_dir="$2"
        shift 2
        ;;
      *)
        die "unknown option for apply-plan: $1"
        ;;
    esac
  done

  [[ -n "$project_root" ]] || die "--project-root is required"
  [[ -n "$plan" ]] || die "--plan is required"
  [[ -f "$plan" ]] || die "plan file not found: $plan"

  project_root="$(resolve_dir "$project_root")"
  plan="$(resolve_path "$plan")"

  if [[ -z "$out_dir" ]]; then
    out_dir="$project_root/.agents/project-agent-factory/runs/$(now_stamp)"
  fi
  out_dir="$(resolve_path "$out_dir")"
  is_within_project "$project_root" "$out_dir" || die "--out-dir must be within project root"

  apply_plan_pipeline "$project_root" "$plan" "$out_dir"
}

main() {
  require_cmd awk
  require_cmd cmp
  require_cmd find
  require_cmd head
  require_cmd rg
  require_cmd sort

  local command="${1:-}"
  if [[ -z "$command" ]]; then
    usage
    exit 1
  fi
  shift

  case "$command" in
    apply-plan) parse_apply_plan_args "$@" ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "unknown command: $command"
      ;;
  esac
}

main "$@"
