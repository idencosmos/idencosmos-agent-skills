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
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
paf_explorer	Project Explorer	10	context	agents/paf_explorer.toml	Explore project structure.	Collect evidence-backed architecture notes.	gpt-5	medium	workspace-write
paf_implementer	Project Implementer	20	delivery	agents/paf_implementer.toml	Implement requested changes.	Apply scoped edits and run available checks.	gpt-5-codex	high	danger-full-access
TSV

bash "$SCRIPT_PATH" validate-plan --plan "$run_dir/agent_plan.tsv" >/dev/null

bash "$SCRIPT_PATH" apply-plan \
  --project-root "$project_root" \
  --plan "$run_dir/agent_plan.tsv" \
  --out-dir "$run_dir" >/dev/null

[[ -f "$project_root/.codex/config.toml" ]]
[[ -f "$project_root/.codex/agents/paf_explorer.toml" ]]
[[ -f "$project_root/.codex/agents/paf_implementer.toml" ]]
[[ -f "$run_dir/apply_report.tsv" ]]
[[ -f "$run_dir/scope_validation.tsv" ]]
[[ -f "$run_dir/audit.tsv" ]]
[[ -f "$run_dir/project_profile.tsv" ]]

rg -q "^# BEGIN project-agent-factory managed agents$" "$project_root/.codex/config.toml"
rg -q "^\[agents.paf_explorer\]$" "$project_root/.codex/config.toml"
rg -q "^\[agents.paf_implementer\]$" "$project_root/.codex/config.toml"
rg -q 'model = "gpt-5-codex"' "$project_root/.codex/agents/paf_implementer.toml"
rg -q 'model_reasoning_effort = "high"' "$project_root/.codex/agents/paf_implementer.toml"
rg -q 'sandbox_mode = "danger-full-access"' "$project_root/.codex/agents/paf_implementer.toml"
rg -q 'Do not write outside the project root\.' "$project_root/.codex/agents/paf_implementer.toml"
rg -q '^frontend_signal	unknown$' "$run_dir/project_profile.tsv"

# stale managed configs should be removed when plan shrinks
cat > "$run_dir/reduced_plan.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
paf_explorer	Project Explorer	10	keep	agents/paf_explorer.toml	Explore project structure.	Collect evidence-backed architecture notes.	gpt-5	medium	workspace-write
TSV

bash "$SCRIPT_PATH" render-config \
  --project-root "$project_root" \
  --plan "$run_dir/reduced_plan.tsv" \
  --report "$run_dir/reduced_report.tsv" >/dev/null

[[ -f "$project_root/.codex/agents/paf_explorer.toml" ]]
[[ ! -f "$project_root/.codex/agents/paf_implementer.toml" ]]
rg -q 'remove_stale_agent_config.*paf_implementer.toml.*removed' "$run_dir/reduced_report.tsv"
if rg -q "^\[agents.paf_implementer\]$" "$project_root/.codex/config.toml"; then
  echo "error: stale implementer block should have been removed" >&2
  exit 1
fi

# validate-plan should reject malformed headers
cat > "$run_dir/bad_header.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	sandbox_mode
paf_explorer	Project Explorer	10	bad	agents/paf_explorer.toml	Explore project structure.	Collect evidence.	gpt-5	workspace-write
TSV

if bash "$SCRIPT_PATH" validate-plan --plan "$run_dir/bad_header.tsv" >/dev/null 2>&1; then
  echo "error: validate-plan should reject malformed header" >&2
  exit 1
fi

# validate-plan should reject empty required fields
cat > "$run_dir/bad_empty_field.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
paf_explorer	Project Explorer	10	bad	agents/paf_explorer.toml	Explore project structure.		gpt-5	medium	workspace-write
TSV

if bash "$SCRIPT_PATH" validate-plan --plan "$run_dir/bad_empty_field.tsv" >/dev/null 2>&1; then
  echo "error: validate-plan should reject empty required fields" >&2
  exit 1
fi

# validate-plan should reject duplicate ids/config paths
cat > "$run_dir/bad_duplicate.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
dup	A	10	one	agents/dup.toml	Desc A	Instr A	gpt-5	medium	workspace-write
dup	B	20	two	agents/dup2.toml	Desc B	Instr B	gpt-5	medium	workspace-write
TSV

if bash "$SCRIPT_PATH" validate-plan --plan "$run_dir/bad_duplicate.tsv" >/dev/null 2>&1; then
  echo "error: validate-plan should reject duplicate agent ids" >&2
  exit 1
fi

cat > "$run_dir/bad_duplicate_config.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
a1	A	10	one	agents/same.toml	Desc A	Instr A	gpt-5	medium	workspace-write
a2	B	20	two	agents/same.toml	Desc B	Instr B	gpt-5	medium	workspace-write
TSV

if bash "$SCRIPT_PATH" validate-plan --plan "$run_dir/bad_duplicate_config.tsv" >/dev/null 2>&1; then
  echo "error: validate-plan should reject duplicate config paths" >&2
  exit 1
fi

# render-config must reject path traversal in config_relpath
outside_target="$tmp_dir/escape.toml"
rm -f "$outside_target"
cat > "$run_dir/malicious_plan.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
evil	Evil	10	attempt	../../escape.toml	Malicious	Do bad things	gpt-5	medium	workspace-write
TSV

if bash "$SCRIPT_PATH" render-config \
  --project-root "$project_root" \
  --plan "$run_dir/malicious_plan.tsv" \
  --report "$run_dir/malicious_report.tsv" >/dev/null 2>&1; then
  echo "error: render-config should reject traversal config_relpath" >&2
  exit 1
fi
[[ ! -f "$outside_target" ]]

# render-config should fail safely when managed block markers are corrupted
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

if bash "$SCRIPT_PATH" render-config \
  --project-root "$corrupt_root" \
  --plan "$corrupt_root/plan.tsv" \
  --report "$corrupt_root/report.tsv" >/dev/null 2>&1; then
  echo "error: render-config should reject corrupted managed markers" >&2
  exit 1
fi

rg -q '^keep_after = true$' "$corrupt_root/.codex/config.toml"

echo "ok: project-agent-factory smoke test passed"
