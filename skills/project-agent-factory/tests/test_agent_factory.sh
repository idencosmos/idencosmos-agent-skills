#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/agent_factory.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

project_root="$tmp_dir/project"
mkdir -p "$project_root"

run_dir="$project_root/.agents/project-agent-factory/runs/manual"
mkdir -p "$run_dir"

cat > "$run_dir/agent_plan.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	prompt	model	model_reasoning_effort	sandbox_mode
paf_explorer	Project Explorer	10	context	agents/paf_explorer.toml	Explore project structure.	Collect evidence-backed architecture notes.	gpt-5	medium	workspace-write
paf.implementer	Project Implementer	20	delivery	agents/paf_implementer.toml	Implement requested changes.	Apply scoped edits and run available checks.	gpt-5-codex	xhigh	danger-full-access
TSV

bash "$SCRIPT_PATH" apply-plan \
  --project-root "$project_root" \
  --plan "$run_dir/agent_plan.tsv" \
  --out-dir "$run_dir" >/dev/null

[[ -f "$project_root/.codex/config.toml" ]]
[[ -f "$project_root/.codex/agents/paf_explorer.toml" ]]
[[ -f "$project_root/.codex/agents/paf_implementer.toml" ]]
[[ -f "$run_dir/apply_report.tsv" ]]
[[ -f "$run_dir/scope_validation.tsv" ]]
[[ ! -f "$run_dir/audit.tsv" ]]
[[ ! -f "$run_dir/project_profile.tsv" ]]

rg -q "^# BEGIN project-agent-factory managed agents$" "$project_root/.codex/config.toml"
rg -q '^\[agents."paf_explorer"\]$' "$project_root/.codex/config.toml"
rg -q '^\[agents."paf.implementer"\]$' "$project_root/.codex/config.toml"
rg -q '^multi_agent = true$' "$project_root/.codex/config.toml"
rg -q 'model = "gpt-5-codex"' "$project_root/.codex/agents/paf_implementer.toml"
rg -q 'model_reasoning_effort = "xhigh"' "$project_root/.codex/agents/paf_implementer.toml"
rg -q 'sandbox_mode = "danger-full-access"' "$project_root/.codex/agents/paf_implementer.toml"
rg -q '^prompt = """$' "$project_root/.codex/agents/paf_implementer.toml"
if rg -q '^developer_instructions[[:space:]]*=' "$project_root/.codex/agents/paf_implementer.toml"; then
  echo "error: generated agent config should use prompt key, not developer_instructions" >&2
  exit 1
fi
rg -q 'Do not write outside the project root\.' "$project_root/.codex/agents/paf_implementer.toml"

# stale managed configs should be removed when plan shrinks
cat > "$run_dir/reduced_plan.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	prompt	model	model_reasoning_effort	sandbox_mode
paf_explorer	Project Explorer	10	keep	agents/paf_explorer.toml	Explore project structure.	Collect evidence-backed architecture notes.	gpt-5	medium	workspace-write
TSV

reduced_run_dir="$project_root/.agents/project-agent-factory/runs/reduced"

bash "$SCRIPT_PATH" apply-plan \
  --project-root "$project_root" \
  --plan "$run_dir/reduced_plan.tsv" \
  --out-dir "$reduced_run_dir" >/dev/null

[[ -f "$project_root/.codex/agents/paf_explorer.toml" ]]
[[ ! -f "$project_root/.codex/agents/paf_implementer.toml" ]]
rg -q 'remove_stale_agent_config.*paf_implementer.toml.*removed' "$reduced_run_dir/apply_report.tsv"
if rg -q '^\[agents."paf.implementer"\]$' "$project_root/.codex/config.toml"; then
  echo "error: stale implementer block should have been removed" >&2
  exit 1
fi

# legacy developer_instructions header should still be accepted
cat > "$run_dir/legacy_plan.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
paf_legacy	Legacy Agent	15	compat	agents/paf_legacy.toml	Verify legacy header compatibility.	Support old plan header.	gpt-5	low	workspace-write
TSV

legacy_run_dir="$project_root/.agents/project-agent-factory/runs/legacy"
bash "$SCRIPT_PATH" apply-plan \
  --project-root "$project_root" \
  --plan "$run_dir/legacy_plan.tsv" \
  --out-dir "$legacy_run_dir" >/dev/null

rg -q '^prompt = """$' "$project_root/.codex/agents/paf_legacy.toml"

# public CLI should stay minimal
if bash "$SCRIPT_PATH" render-config >/dev/null 2>&1; then
  echo "error: render-config should not be exposed as a public command" >&2
  exit 1
fi

if bash "$SCRIPT_PATH" validate-scope >/dev/null 2>&1; then
  echo "error: validate-scope should not be exposed as a public command" >&2
  exit 1
fi

if bash "$SCRIPT_PATH" audit >/dev/null 2>&1; then
  echo "error: audit should not be exposed as a public command" >&2
  exit 1
fi

if bash "$SCRIPT_PATH" validate-plan >/dev/null 2>&1; then
  echo "error: validate-plan should not be exposed as a public command" >&2
  exit 1
fi

# apply-plan should reject malformed headers
cat > "$run_dir/bad_header.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	sandbox_mode
paf_explorer	Project Explorer	10	bad	agents/paf_explorer.toml	Explore project structure.	Collect evidence.	gpt-5	workspace-write
TSV

if bash "$SCRIPT_PATH" apply-plan \
  --project-root "$project_root" \
  --plan "$run_dir/bad_header.tsv" \
  --out-dir "$run_dir/bad_header_run" >/dev/null 2>&1; then
  echo "error: apply-plan should reject malformed header" >&2
  exit 1
fi

# apply-plan should reject empty required fields
cat > "$run_dir/bad_empty_field.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
paf_explorer	Project Explorer	10	bad	agents/paf_explorer.toml	Explore project structure.		gpt-5	medium	workspace-write
TSV

if bash "$SCRIPT_PATH" apply-plan \
  --project-root "$project_root" \
  --plan "$run_dir/bad_empty_field.tsv" \
  --out-dir "$run_dir/bad_empty_run" >/dev/null 2>&1; then
  echo "error: apply-plan should reject empty required fields" >&2
  exit 1
fi

# apply-plan should reject duplicate ids/config paths
cat > "$run_dir/bad_duplicate.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
dup	A	10	one	agents/dup.toml	Desc A	Instr A	gpt-5	medium	workspace-write
dup	B	20	two	agents/dup2.toml	Desc B	Instr B	gpt-5	medium	workspace-write
TSV

if bash "$SCRIPT_PATH" apply-plan \
  --project-root "$project_root" \
  --plan "$run_dir/bad_duplicate.tsv" \
  --out-dir "$run_dir/bad_duplicate_run" >/dev/null 2>&1; then
  echo "error: apply-plan should reject duplicate agent ids" >&2
  exit 1
fi

cat > "$run_dir/bad_duplicate_config.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
a1	A	10	one	agents/same.toml	Desc A	Instr A	gpt-5	medium	workspace-write
a2	B	20	two	agents/same.toml	Desc B	Instr B	gpt-5	medium	workspace-write
TSV

if bash "$SCRIPT_PATH" apply-plan \
  --project-root "$project_root" \
  --plan "$run_dir/bad_duplicate_config.tsv" \
  --out-dir "$run_dir/bad_duplicate_config_run" >/dev/null 2>&1; then
  echo "error: apply-plan should reject duplicate config paths" >&2
  exit 1
fi

# apply-plan must reject path traversal in config_relpath
outside_target="$tmp_dir/escape.toml"
rm -f "$outside_target"
cat > "$run_dir/malicious_plan.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
evil	Evil	10	attempt	../../escape.toml	Malicious	Do bad things	gpt-5	medium	workspace-write
TSV

if bash "$SCRIPT_PATH" apply-plan \
  --project-root "$project_root" \
  --plan "$run_dir/malicious_plan.tsv" \
  --out-dir "$run_dir/malicious" >/dev/null 2>&1; then
  echo "error: apply-plan should reject traversal config_relpath" >&2
  exit 1
fi
[[ ! -f "$outside_target" ]]

# apply-plan must reject nested config_relpath (only agents/*.toml allowed)
cat > "$run_dir/bad_nested_config.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
nested	Nested Agent	10	invalid	agents/nested/nested.toml	Nested path should fail.	Stay at one level.	gpt-5	medium	workspace-write
TSV

if bash "$SCRIPT_PATH" apply-plan \
  --project-root "$project_root" \
  --plan "$run_dir/bad_nested_config.tsv" \
  --out-dir "$run_dir/bad_nested_run" >/dev/null 2>&1; then
  echo "error: apply-plan should reject nested config_relpath" >&2
  exit 1
fi

# apply-plan should handle CRLF plans without leaking carriage returns to TOML
printf 'agent_id\trole_name\tpriority\treason\tconfig_relpath\tdescription\tdeveloper_instructions\tmodel\tmodel_reasoning_effort\tsandbox_mode\r\n' > "$run_dir/crlf_plan.tsv"
printf 'paf_windows\tWindows Agent\t30\tcrlf\tagents/paf_windows.toml\tHandle CRLF plan rows.\tKeep outputs normalized.\tgpt-5\tmedium\tworkspace-write\r\n' >> "$run_dir/crlf_plan.tsv"

crlf_run_dir="$project_root/.agents/project-agent-factory/runs/crlf"
bash "$SCRIPT_PATH" apply-plan \
  --project-root "$project_root" \
  --plan "$run_dir/crlf_plan.tsv" \
  --out-dir "$crlf_run_dir" >/dev/null

rg -q 'sandbox_mode = "workspace-write"' "$project_root/.codex/agents/paf_windows.toml"
if LC_ALL=C grep -q $'\r' "$project_root/.codex/agents/paf_windows.toml"; then
  echo "error: generated agent config should not include carriage returns" >&2
  exit 1
fi

# apply-plan should fail safely when managed block markers are corrupted
corrupt_root="$tmp_dir/corrupt-marker"
mkdir -p "$corrupt_root/.codex"
cat > "$corrupt_root/.codex/config.toml" <<'TOML'
keep_before = true
# BEGIN project-agent-factory managed agents
stale = true
# missing end marker on purpose
keep_after = true
TOML

cat > "$corrupt_root/plan.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
paf_explorer	Project Explorer	10	keep	agents/paf_explorer.toml	Explore project structure.	Collect evidence-backed architecture notes.	gpt-5	medium	workspace-write
TSV

if bash "$SCRIPT_PATH" apply-plan \
  --project-root "$corrupt_root" \
  --plan "$corrupt_root/plan.tsv" \
  --out-dir "$corrupt_root/.agents/project-agent-factory/runs/corrupt" >/dev/null 2>&1; then
  echo "error: apply-plan should reject corrupted managed markers" >&2
  exit 1
fi

rg -q '^keep_after = true$' "$corrupt_root/.codex/config.toml"

# apply-plan should force-enable features.multi_agent while preserving other feature keys
feature_root="$tmp_dir/feature-flag"
mkdir -p "$feature_root/.codex"
cat > "$feature_root/.codex/config.toml" <<'TOML'
[features]
multi_agent = false
experimental_use_rmcp_client = true

[workspace_write]
network_access = true
TOML

cat > "$feature_root/plan.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
paf_explorer	Project Explorer	10	feature	agents/paf_explorer.toml	Explore project structure.	Collect evidence-backed architecture notes.	gpt-5	minimal	workspace-write
TSV

feature_run_dir="$feature_root/.agents/project-agent-factory/runs/feature"
bash "$SCRIPT_PATH" apply-plan \
  --project-root "$feature_root" \
  --plan "$feature_root/plan.tsv" \
  --out-dir "$feature_run_dir" >/dev/null

rg -q '^multi_agent = true$' "$feature_root/.codex/config.toml"
rg -q '^experimental_use_rmcp_client = true$' "$feature_root/.codex/config.toml"
rg -q '^\[workspace_write\]$' "$feature_root/.codex/config.toml"
rg -q '^network_access = true$' "$feature_root/.codex/config.toml"
rg -q 'model_reasoning_effort = "minimal"' "$feature_root/.codex/agents/paf_explorer.toml"
rg -q 'enable_multi_agent_feature.*updated.*ensure features.multi_agent = true' "$feature_run_dir/apply_report.tsv"

echo "ok: project-agent-factory smoke test passed"
