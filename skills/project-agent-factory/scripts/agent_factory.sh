#!/usr/bin/env bash
set -euo pipefail

BEGIN_MARKER="# BEGIN project-agent-factory managed agents"
END_MARKER="# END project-agent-factory managed agents"

usage() {
  cat <<'USAGE'
Usage:
  agent_factory.sh run --project-root PATH [--run-dir PATH] [--max-agents N]
  agent_factory.sh apply-plan --project-root PATH --plan PATH [--profile PATH] [--out-dir PATH]
  agent_factory.sh scan-project --project-root PATH --out PATH
  agent_factory.sh plan-agents --profile PATH --out PATH [--max-agents N]
  agent_factory.sh render-config --project-root PATH --plan PATH --report PATH
  agent_factory.sh validate-scope --project-root PATH --report PATH --out PATH
  agent_factory.sh audit --profile PATH --plan PATH --report PATH --out PATH
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

  [[ "$normalized" =~ ^agents/[A-Za-z0-9._/-]+\.toml$ ]] || die "config_relpath must match agents/*.toml: $config_relpath"
  printf '%s\n' "$normalized"
}

project_find() {
  local root="$1"
  local nested_git_dir
  local nested_repo
  local -a prune_paths
  shift

  prune_paths=(
    -path "$root/.git" -o
    -path "$root/node_modules" -o
    -path "$root/.venv" -o
    -path "$root/venv" -o
    -path "$root/.next" -o
    -path "$root/dist" -o
    -path "$root/build" -o
    -path "$root/.agents/project-agent-factory/runs"
  )

  while IFS= read -r nested_git_dir; do
    nested_repo="$(dirname "$nested_git_dir")"
    if [[ "$nested_repo" != "$root" ]]; then
      prune_paths+=( -o -path "$nested_repo" )
    fi
  done < <(find "$root" -mindepth 2 -type d -name .git -prune 2>/dev/null)

  find "$root" \
    \( "${prune_paths[@]}" \) -prune -o "$@" -print
}

count_files_by_name() {
  local root="$1"
  local pattern="$2"
  local count
  count="$(project_find "$root" -type f -name "$pattern" | wc -l | tr -d ' ')"
  printf '%s\n' "$count"
}

has_any_file() {
  local root="$1"
  shift
  project_find "$root" "$@" | head -n 1 | grep -q .
}

write_profile_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'key\tvalue\n' > "$out"
}

append_profile_value() {
  local out="$1"
  local key="$2"
  local value="$3"
  printf '%s\t%s\n' "$(sanitize_field "$key")" "$(sanitize_field "$value")" >> "$out"
}

profile_value() {
  local file="$1"
  local key="$2"
  awk -F'\t' -v k="$key" 'NR>1 && $1==k {print $2; found=1; exit} END {if (!found) print ""}' "$file"
}

write_plan_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'agent_id\trole_name\tpriority\treason\tconfig_relpath\tdescription\tdeveloper_instructions\tmodel\tmodel_reasoning_effort\tsandbox_mode\n' > "$out"
}

append_plan_row() {
  local out="$1"
  local agent_id="$2"
  local role_name="$3"
  local priority="$4"
  local reason="$5"
  local config_relpath="$6"
  local description="${7:-}"
  local developer_instructions="${8:-}"
  local model="${9:-}"
  local model_reasoning_effort="${10:-}"
  local sandbox_mode="${11:-}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(sanitize_field "$agent_id")" \
    "$(sanitize_field "$role_name")" \
    "$(sanitize_field "$priority")" \
    "$(sanitize_field "$reason")" \
    "$(sanitize_field "$config_relpath")" \
    "$(sanitize_field "$description")" \
    "$(sanitize_field "$developer_instructions")" \
    "$(sanitize_field "$model")" \
    "$(sanitize_field "$model_reasoning_effort")" \
    "$(sanitize_field "$sandbox_mode")" >> "$out"
}

trim_plan() {
  local file="$1"
  local max_agents="$2"
  local tmp
  tmp="$(mktemp)"
  awk -F'\t' -v max="$max_agents" '
    NR==1 {print; next}
    NR-1 <= max {print}
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
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

write_audit_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'metric\tvalue\n' > "$out"
}

append_audit_value() {
  local out="$1"
  local metric="$2"
  local value="$3"
  printf '%s\t%s\n' "$(sanitize_field "$metric")" "$(sanitize_field "$value")" >> "$out"
}

detect_frontend_signal() {
  local root="$1"
  local package_json="$root/package.json"
  if [[ -f "$package_json" ]] && rg -q '"(react|next|vue|svelte|nuxt|vite|astro)"' "$package_json"; then
    printf 'yes\n'
    return
  fi
  if has_any_file "$root" -type f \( -name "*.tsx" -o -name "*.jsx" \); then
    printf 'yes\n'
    return
  fi
  printf 'no\n'
}

detect_backend_signal() {
  local root="$1"
  local package_json="$root/package.json"
  if [[ -f "$root/pyproject.toml" || -f "$root/requirements.txt" || -f "$root/go.mod" || -f "$root/Cargo.toml" ]]; then
    printf 'yes\n'
    return
  fi
  if [[ -f "$package_json" ]] && rg -q '"(express|fastify|koa|nestjs|hono|@hapi)"' "$package_json"; then
    printf 'yes\n'
    return
  fi
  if has_any_file "$root" -type f -path "*/api/*"; then
    printf 'yes\n'
    return
  fi
  printf 'no\n'
}

detect_ops_signal() {
  local root="$1"
  if has_any_file "$root" -type f \( \
    -name "Dockerfile" -o \
    -name "Dockerfile.*" -o \
    -name "docker-compose*.yml" -o \
    -name "docker-compose*.yaml" -o \
    -name "*.tf" -o \
    -name "*.tfvars" -o \
    -path "*/.github/workflows/*" \
  \); then
    printf 'yes\n'
    return
  fi
  printf 'no\n'
}

detect_test_signal() {
  local root="$1"
  if has_any_file "$root" -type f \( \
    -name "*test*.py" -o \
    -name "*_test.py" -o \
    -name "*.test.ts" -o \
    -name "*.test.tsx" -o \
    -name "*.spec.ts" -o \
    -name "*.spec.tsx" -o \
    -name "*.test.js" -o \
    -name "*.spec.js" -o \
    -path "*/tests/*" \
  \); then
    printf 'yes\n'
    return
  fi
  printf 'no\n'
}

scan_project() {
  local project_root="$1"
  local out="$2"
  local top_dirs
  local language_python="no"
  local language_js_ts="no"
  local language_go="no"
  local language_rust="no"
  local frontend_signal
  local backend_signal
  local ops_signal
  local test_signal
  local py_count
  local ts_count
  local tsx_count
  local js_count
  local jsx_count
  local go_count
  local rs_count
  local code_count

  py_count="$(count_files_by_name "$project_root" "*.py")"
  ts_count="$(count_files_by_name "$project_root" "*.ts")"
  tsx_count="$(count_files_by_name "$project_root" "*.tsx")"
  js_count="$(count_files_by_name "$project_root" "*.js")"
  jsx_count="$(count_files_by_name "$project_root" "*.jsx")"
  go_count="$(count_files_by_name "$project_root" "*.go")"
  rs_count="$(count_files_by_name "$project_root" "*.rs")"
  code_count=$((py_count + ts_count + tsx_count + js_count + jsx_count + go_count + rs_count))

  [[ "$py_count" -gt 0 || -f "$project_root/pyproject.toml" || -f "$project_root/requirements.txt" ]] && language_python="yes"
  [[ "$ts_count" -gt 0 || "$tsx_count" -gt 0 || "$js_count" -gt 0 || "$jsx_count" -gt 0 || -f "$project_root/package.json" ]] && language_js_ts="yes"
  [[ "$go_count" -gt 0 || -f "$project_root/go.mod" ]] && language_go="yes"
  [[ "$rs_count" -gt 0 || -f "$project_root/Cargo.toml" ]] && language_rust="yes"

  frontend_signal="$(detect_frontend_signal "$project_root")"
  backend_signal="$(detect_backend_signal "$project_root")"
  ops_signal="$(detect_ops_signal "$project_root")"
  test_signal="$(detect_test_signal "$project_root")"
  top_dirs="$(find "$project_root" -mindepth 1 -maxdepth 1 -type d \
    ! -name ".git" ! -name "node_modules" ! -name ".venv" ! -name "venv" ! -name ".next" ! -name "dist" ! -name "build" \
    -exec basename {} \; | sort | tr '\n' ',' | sed 's/,$//')"

  write_profile_header "$out"
  append_profile_value "$out" "project_root" "$project_root"
  append_profile_value "$out" "generated_at" "$(now_utc)"
  append_profile_value "$out" "top_level_dirs" "${top_dirs:-none}"
  append_profile_value "$out" "language_python" "$language_python"
  append_profile_value "$out" "language_js_ts" "$language_js_ts"
  append_profile_value "$out" "language_go" "$language_go"
  append_profile_value "$out" "language_rust" "$language_rust"
  append_profile_value "$out" "frontend_signal" "$frontend_signal"
  append_profile_value "$out" "backend_signal" "$backend_signal"
  append_profile_value "$out" "ops_signal" "$ops_signal"
  append_profile_value "$out" "test_signal" "$test_signal"
  append_profile_value "$out" "file_count_py" "$py_count"
  append_profile_value "$out" "file_count_ts" "$ts_count"
  append_profile_value "$out" "file_count_tsx" "$tsx_count"
  append_profile_value "$out" "file_count_js" "$js_count"
  append_profile_value "$out" "file_count_jsx" "$jsx_count"
  append_profile_value "$out" "file_count_go" "$go_count"
  append_profile_value "$out" "file_count_rs" "$rs_count"
  append_profile_value "$out" "file_count_code_total" "$code_count"
}

plan_agents() {
  local profile="$1"
  local out="$2"
  local max_agents="$3"
  local frontend_signal
  local backend_signal
  local ops_signal
  local test_signal
  local code_count

  frontend_signal="$(profile_value "$profile" "frontend_signal")"
  backend_signal="$(profile_value "$profile" "backend_signal")"
  ops_signal="$(profile_value "$profile" "ops_signal")"
  test_signal="$(profile_value "$profile" "test_signal")"
  code_count="$(profile_value "$profile" "file_count_code_total")"

  write_plan_header "$out"
  append_plan_row "$out" \
    "paf_explorer" "Project Explorer" "10" \
    "프로젝트 구조/의존성/핵심 파일 맥락 수집" \
    "agents/paf_explorer.toml" \
    "$(agent_description "paf_explorer")" \
    "$(sanitize_field "$(agent_instruction_block "paf_explorer")")" \
    "gpt-5" "medium" "workspace-write"
  append_plan_row "$out" \
    "paf_implementer" "Project Implementer" "20" \
    "요구사항 구현, 리팩터링, 코드 변경 실행" \
    "agents/paf_implementer.toml" \
    "$(agent_description "paf_implementer")" \
    "$(sanitize_field "$(agent_instruction_block "paf_implementer")")" \
    "gpt-5" "medium" "workspace-write"

  if [[ "$backend_signal" == "yes" ]]; then
    append_plan_row "$out" \
      "paf_backend" "Backend Specialist" "30" \
      "백엔드 API/도메인 로직/데이터 흐름 변경 대응" \
      "agents/paf_backend.toml" \
      "$(agent_description "paf_backend")" \
      "$(sanitize_field "$(agent_instruction_block "paf_backend")")" \
      "gpt-5" "medium" "workspace-write"
  fi

  if [[ "$frontend_signal" == "yes" ]]; then
    append_plan_row "$out" \
      "paf_frontend" "Frontend Specialist" "40" \
      "프론트엔드 UI/상태/접근성 관련 변경 대응" \
      "agents/paf_frontend.toml" \
      "$(agent_description "paf_frontend")" \
      "$(sanitize_field "$(agent_instruction_block "paf_frontend")")" \
      "gpt-5" "medium" "workspace-write"
  fi

  if [[ "$test_signal" == "yes" || "${code_count:-0}" -ge 40 ]]; then
    append_plan_row "$out" \
      "paf_qa" "QA and Validation" "50" \
      "회귀 위험 점검, 테스트/검증 범위 점검" \
      "agents/paf_qa.toml" \
      "$(agent_description "paf_qa")" \
      "$(sanitize_field "$(agent_instruction_block "paf_qa")")" \
      "gpt-5" "medium" "workspace-write"
  fi

  if [[ "$ops_signal" == "yes" ]]; then
    append_plan_row "$out" \
      "paf_ops" "Ops and Runtime" "60" \
      "배포/런타임/CI 및 운영 안전성 점검" \
      "agents/paf_ops.toml" \
      "$(agent_description "paf_ops")" \
      "$(sanitize_field "$(agent_instruction_block "paf_ops")")" \
      "gpt-5" "medium" "workspace-write"
  fi

  trim_plan "$out" "$max_agents"
}

agent_description() {
  local agent_id="$1"
  case "$agent_id" in
    paf_explorer) printf 'Explore repository structure and produce scoped evidence maps.' ;;
    paf_implementer) printf 'Implement code changes with clear constraints and verification.' ;;
    paf_backend) printf 'Handle backend logic, APIs, and data layer modifications.' ;;
    paf_frontend) printf 'Handle frontend UI, state flows, and interaction quality.' ;;
    paf_qa) printf 'Design verification plans and identify regression risks.' ;;
    paf_ops) printf 'Review runtime, deployment, and reliability-related changes.' ;;
    *) printf 'Project-specialized helper agent.' ;;
  esac
}

agent_instruction_block() {
  local agent_id="$1"
  case "$agent_id" in
    paf_explorer)
      cat <<'TXT'
Gather context before proposing changes. Prefer repo-local evidence (files, commands, tests).
Return concise findings with direct file paths.
TXT
      ;;
    paf_implementer)
      cat <<'TXT'
Implement requested changes directly in this project.
Avoid speculative rewrites. Validate with runnable checks when available.
TXT
      ;;
    paf_backend)
      cat <<'TXT'
Focus on backend correctness, data contracts, and failure handling.
Flag schema or API behavior risks explicitly.
TXT
      ;;
    paf_frontend)
      cat <<'TXT'
Focus on UI behavior, accessibility, and state consistency.
Prefer targeted, design-system-consistent changes over broad rewrites.
TXT
      ;;
    paf_qa)
      cat <<'TXT'
Focus on verification quality: regression risks, missing tests, and reproducibility.
Separate confirmed findings from assumptions.
TXT
      ;;
    paf_ops)
      cat <<'TXT'
Focus on runtime safety, deployment steps, and observability impact.
Prefer reversible and low-risk operational changes.
TXT
      ;;
    *)
      cat <<'TXT'
Work only within this repository and keep outputs evidence-backed.
TXT
      ;;
  esac
}

build_agent_file() {
  local out="$1"
  local agent_id="$2"
  local role_name="$3"
  local developer_instructions="${4:-}"
  local model="${5:-gpt-5}"
  local model_reasoning_effort="${6:-medium}"
  local sandbox_mode="${7:-workspace-write}"
  local instruction
  local escaped_instructions

  if [[ -n "$developer_instructions" ]]; then
    instruction="$developer_instructions"
  else
    instruction="$(agent_instruction_block "$agent_id")"
  fi
  escaped_instructions="$(toml_escape_multiline_string "$instruction")"

  cat > "$out" <<EOF
# managed_by=project-agent-factory
# role=${role_name}
model = "$(toml_escape_basic_string "${model:-gpt-5}")"
model_reasoning_effort = "$(toml_escape_basic_string "${model_reasoning_effort:-medium}")"
sandbox_mode = "$(toml_escape_basic_string "${sandbox_mode:-workspace-write}")"

developer_instructions = """
${escaped_instructions}
Do not write outside the project root.
"""
EOF
}

build_managed_block() {
  local plan="$1"
  local out="$2"
  local generated_at
  local safe_config_relpath
  local description
  generated_at="$(now_utc)"

  {
    printf '%s\n' "$BEGIN_MARKER"
    printf '# generated_at=%s\n' "$generated_at"
    printf '# This block is managed by project-agent-factory.\n'
    while IFS=$'\t' read -r agent_id role_name _priority _reason config_relpath description _developer_instructions _model _model_reasoning_effort _sandbox_mode _rest; do
      if [[ "$agent_id" == "agent_id" ]]; then
        continue
      fi
      safe_config_relpath="$(validate_agent_config_relpath "$config_relpath")"
      if [[ -z "${description:-}" ]]; then
        description="$(agent_description "$agent_id")"
      fi
      printf '\n[agents.%s]\n' "$agent_id"
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
      "$agent_id" \
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

run_audit() {
  local profile="$1"
  local plan="$2"
  local report="$3"
  local out="$4"
  local plan_count
  local write_count
  local managed_paths

  plan_count="$(awk 'NR>1 {count++} END {print count+0}' "$plan")"
  write_count="$(awk -F'\t' 'NR>1 && $2 ~ /^write_/ {count++} END {print count+0}' "$report")"
  managed_paths="$(awk -F'\t' 'NR>1 {print $3}' "$report" | sort -u | tr '\n' ',' | sed 's/,$//')"

  write_audit_header "$out"
  append_audit_value "$out" "generated_at" "$(now_utc)"
  append_audit_value "$out" "project_root" "$(profile_value "$profile" "project_root")"
  append_audit_value "$out" "frontend_signal" "$(profile_value "$profile" "frontend_signal")"
  append_audit_value "$out" "backend_signal" "$(profile_value "$profile" "backend_signal")"
  append_audit_value "$out" "ops_signal" "$(profile_value "$profile" "ops_signal")"
  append_audit_value "$out" "test_signal" "$(profile_value "$profile" "test_signal")"
  append_audit_value "$out" "file_count_code_total" "$(profile_value "$profile" "file_count_code_total")"
  append_audit_value "$out" "planned_agents" "$plan_count"
  append_audit_value "$out" "write_operations" "$write_count"
  append_audit_value "$out" "managed_paths" "${managed_paths:-none}"
}

run_pipeline() {
  local project_root="$1"
  local run_dir="$2"
  local max_agents="$3"
  local profile_file="$run_dir/project_profile.tsv"
  local plan_file="$run_dir/agent_plan.tsv"
  local report_file="$run_dir/apply_report.tsv"
  local scope_file="$run_dir/scope_validation.tsv"
  local audit_file="$run_dir/audit.tsv"

  mkdir -p "$run_dir"
  scan_project "$project_root" "$profile_file"
  plan_agents "$profile_file" "$plan_file" "$max_agents"
  render_config "$project_root" "$plan_file" "$report_file"
  validate_scope "$project_root" "$report_file" "$scope_file"
  run_audit "$profile_file" "$plan_file" "$report_file" "$audit_file"

  log "run_dir: $run_dir"
  log "profile: $profile_file"
  log "plan: $plan_file"
  log "report: $report_file"
  log "scope: $scope_file"
  log "audit: $audit_file"
}

generate_profile_stub() {
  local out="$1"
  local project_root="$2"
  write_profile_header "$out"
  append_profile_value "$out" "project_root" "$project_root"
  append_profile_value "$out" "generated_at" "$(now_utc)"
  append_profile_value "$out" "frontend_signal" "unknown"
  append_profile_value "$out" "backend_signal" "unknown"
  append_profile_value "$out" "ops_signal" "unknown"
  append_profile_value "$out" "test_signal" "unknown"
  append_profile_value "$out" "file_count_code_total" "unknown"
}

apply_plan_pipeline() {
  local project_root="$1"
  local plan="$2"
  local profile="${3:-}"
  local out_dir="$4"
  local profile_file="$out_dir/project_profile.tsv"
  local report_file="$out_dir/apply_report.tsv"
  local scope_file="$out_dir/scope_validation.tsv"
  local audit_file="$out_dir/audit.tsv"

  mkdir -p "$out_dir"
  render_config "$project_root" "$plan" "$report_file"
  validate_scope "$project_root" "$report_file" "$scope_file"
  if [[ -n "$profile" ]]; then
    run_audit "$profile" "$plan" "$report_file" "$audit_file"
  else
    generate_profile_stub "$profile_file" "$project_root"
    run_audit "$profile_file" "$plan" "$report_file" "$audit_file"
  fi

  log "run_dir: $out_dir"
  log "profile: ${profile:-$profile_file}"
  log "plan: $plan"
  log "report: $report_file"
  log "scope: $scope_file"
  log "audit: $audit_file"
}

parse_run_args() {
  local project_root=""
  local run_dir=""
  local max_agents="6"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-root)
        project_root="$2"
        shift 2
        ;;
      --run-dir)
        run_dir="$2"
        shift 2
        ;;
      --max-agents)
        max_agents="$2"
        shift 2
        ;;
      *)
        die "unknown option for run: $1"
        ;;
    esac
  done

  [[ -n "$project_root" ]] || die "--project-root is required"
  [[ "$max_agents" =~ ^[0-9]+$ ]] || die "--max-agents must be a positive integer"
  [[ "$max_agents" -ge 2 ]] || die "--max-agents must be >= 2"

  project_root="$(resolve_dir "$project_root")"
  if [[ -z "$run_dir" ]]; then
    run_dir="$project_root/.agents/project-agent-factory/runs/$(now_stamp)"
  fi
  run_dir="$(resolve_path "$run_dir")"
  is_within_project "$project_root" "$run_dir" || die "--run-dir must be within project root"

  run_pipeline "$project_root" "$run_dir" "$max_agents"
}

parse_apply_plan_args() {
  local project_root=""
  local plan=""
  local profile=""
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
      --profile)
        profile="$2"
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

  if [[ -n "$profile" ]]; then
    [[ -f "$profile" ]] || die "profile file not found: $profile"
    profile="$(resolve_path "$profile")"
  fi

  apply_plan_pipeline "$project_root" "$plan" "$profile" "$out_dir"
}

parse_scan_args() {
  local project_root=""
  local out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-root)
        project_root="$2"
        shift 2
        ;;
      --out)
        out="$2"
        shift 2
        ;;
      *)
        die "unknown option for scan-project: $1"
        ;;
    esac
  done
  [[ -n "$project_root" ]] || die "--project-root is required"
  [[ -n "$out" ]] || die "--out is required"
  project_root="$(resolve_dir "$project_root")"
  out="$(resolve_path "$out")"
  is_within_project "$project_root" "$out" || die "--out must be within project root"
  scan_project "$project_root" "$out"
  log "profile: $out"
}

parse_plan_args() {
  local profile=""
  local out=""
  local max_agents="6"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        profile="$2"
        shift 2
        ;;
      --out)
        out="$2"
        shift 2
        ;;
      --max-agents)
        max_agents="$2"
        shift 2
        ;;
      *)
        die "unknown option for plan-agents: $1"
        ;;
    esac
  done
  [[ -n "$profile" ]] || die "--profile is required"
  [[ -n "$out" ]] || die "--out is required"
  [[ "$max_agents" =~ ^[0-9]+$ ]] || die "--max-agents must be a positive integer"
  [[ "$max_agents" -ge 2 ]] || die "--max-agents must be >= 2"
  [[ -f "$profile" ]] || die "profile file not found: $profile"
  profile="$(resolve_path "$profile")"
  out="$(resolve_path "$out")"
  plan_agents "$profile" "$out" "$max_agents"
  log "plan: $out"
}

parse_render_args() {
  local project_root=""
  local plan=""
  local report=""
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
      --report)
        report="$2"
        shift 2
        ;;
      *)
        die "unknown option for render-config: $1"
        ;;
    esac
  done
  [[ -n "$project_root" ]] || die "--project-root is required"
  [[ -n "$plan" ]] || die "--plan is required"
  [[ -n "$report" ]] || die "--report is required"
  [[ -f "$plan" ]] || die "plan file not found: $plan"
  project_root="$(resolve_dir "$project_root")"
  plan="$(resolve_path "$plan")"
  report="$(resolve_path "$report")"
  is_within_project "$project_root" "$report" || die "--report must be within project root"
  render_config "$project_root" "$plan" "$report"
  log "report: $report"
}

parse_validate_args() {
  local project_root=""
  local report=""
  local out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-root)
        project_root="$2"
        shift 2
        ;;
      --report)
        report="$2"
        shift 2
        ;;
      --out)
        out="$2"
        shift 2
        ;;
      *)
        die "unknown option for validate-scope: $1"
        ;;
    esac
  done
  [[ -n "$project_root" ]] || die "--project-root is required"
  [[ -n "$report" ]] || die "--report is required"
  [[ -n "$out" ]] || die "--out is required"
  [[ -f "$report" ]] || die "report file not found: $report"
  project_root="$(resolve_dir "$project_root")"
  report="$(resolve_path "$report")"
  out="$(resolve_path "$out")"
  is_within_project "$project_root" "$report" || die "--report must be within project root"
  is_within_project "$project_root" "$out" || die "--out must be within project root"
  validate_scope "$project_root" "$report" "$out"
  log "scope_validation: $out"
}

parse_audit_args() {
  local profile=""
  local plan=""
  local report=""
  local out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        profile="$2"
        shift 2
        ;;
      --plan)
        plan="$2"
        shift 2
        ;;
      --report)
        report="$2"
        shift 2
        ;;
      --out)
        out="$2"
        shift 2
        ;;
      *)
        die "unknown option for audit: $1"
        ;;
    esac
  done
  [[ -n "$profile" ]] || die "--profile is required"
  [[ -n "$plan" ]] || die "--plan is required"
  [[ -n "$report" ]] || die "--report is required"
  [[ -n "$out" ]] || die "--out is required"
  [[ -f "$profile" ]] || die "profile file not found: $profile"
  [[ -f "$plan" ]] || die "plan file not found: $plan"
  [[ -f "$report" ]] || die "report file not found: $report"

  profile="$(resolve_path "$profile")"
  plan="$(resolve_path "$plan")"
  report="$(resolve_path "$report")"
  out="$(resolve_path "$out")"
  run_audit "$profile" "$plan" "$report" "$out"
  log "audit: $out"
}

main() {
  require_cmd awk
  require_cmd find
  require_cmd rg

  local command="${1:-}"
  if [[ -z "$command" ]]; then
    usage
    exit 1
  fi
  shift

  case "$command" in
    run) parse_run_args "$@" ;;
    apply-plan) parse_apply_plan_args "$@" ;;
    scan-project) parse_scan_args "$@" ;;
    plan-agents) parse_plan_args "$@" ;;
    render-config) parse_render_args "$@" ;;
    validate-scope) parse_validate_args "$@" ;;
    audit) parse_audit_args "$@" ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "unknown command: $command"
      ;;
  esac
}

main "$@"
