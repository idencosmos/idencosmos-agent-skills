#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/agent_factory.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/src" "$tmp_dir/backend" "$tmp_dir/tests" "$tmp_dir/.github/workflows"
cat > "$tmp_dir/package.json" <<'JSON'
{
  "name": "agent-factory-smoke",
  "private": true,
  "dependencies": {
    "react": "^19.0.0",
    "express": "^4.19.0"
  }
}
JSON

cat > "$tmp_dir/src/app.tsx" <<'TS'
export const App = () => "ok";
TS

cat > "$tmp_dir/backend/app.py" <<'PY'
def healthcheck():
    return "ok"
PY

cat > "$tmp_dir/tests/app.test.ts" <<'TS'
describe("app", () => {
  it("works", () => {
    expect(true).toBe(true);
  });
});
TS

cat > "$tmp_dir/Dockerfile" <<'DOCKER'
FROM alpine:3.20
DOCKER

cat > "$tmp_dir/.github/workflows/ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML

bash "$SCRIPT_PATH" run --project-root "$tmp_dir" --max-agents 6 >/dev/null

[[ -f "$tmp_dir/.codex/config.toml" ]]
[[ -f "$tmp_dir/.codex/agents/paf_explorer.toml" ]]
[[ -f "$tmp_dir/.codex/agents/paf_implementer.toml" ]]
[[ -f "$tmp_dir/.codex/agents/paf_backend.toml" ]]
[[ -f "$tmp_dir/.codex/agents/paf_frontend.toml" ]]
[[ -f "$tmp_dir/.codex/agents/paf_qa.toml" ]]
[[ -f "$tmp_dir/.codex/agents/paf_ops.toml" ]]

rg -q "^# BEGIN project-agent-factory managed agents$" "$tmp_dir/.codex/config.toml"
rg -q "^\[agents.paf_explorer\]$" "$tmp_dir/.codex/config.toml"

run_root="$tmp_dir/.agents/project-agent-factory/runs"
latest_run="$(find "$run_root" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
[[ -f "$latest_run/project_profile.tsv" ]]
[[ -f "$latest_run/agent_plan.tsv" ]]
[[ -f "$latest_run/apply_report.tsv" ]]
[[ -f "$latest_run/scope_validation.tsv" ]]
[[ -f "$latest_run/audit.tsv" ]]
rg -q '^file_count_tsx\t1$' "$latest_run/project_profile.tsv"
rg -q '^file_count_code_total\t3$' "$latest_run/project_profile.tsv"

# stale managed configs should be removed when plan shrinks
cat > "$tmp_dir/reduced_plan.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath
paf_explorer	Project Explorer	10	keep	agents/paf_explorer.toml
paf_implementer	Project Implementer	20	keep	agents/paf_implementer.toml
TSV

bash "$SCRIPT_PATH" render-config \
  --project-root "$tmp_dir" \
  --plan "$tmp_dir/reduced_plan.tsv" \
  --report "$tmp_dir/reduced_report.tsv" >/dev/null

[[ -f "$tmp_dir/.codex/agents/paf_explorer.toml" ]]
[[ -f "$tmp_dir/.codex/agents/paf_implementer.toml" ]]
[[ ! -f "$tmp_dir/.codex/agents/paf_backend.toml" ]]
[[ ! -f "$tmp_dir/.codex/agents/paf_frontend.toml" ]]
[[ ! -f "$tmp_dir/.codex/agents/paf_qa.toml" ]]
[[ ! -f "$tmp_dir/.codex/agents/paf_ops.toml" ]]

rg -q 'remove_stale_agent_config.*paf_backend.toml.*removed' "$tmp_dir/reduced_report.tsv"
rg -q 'remove_stale_agent_config.*paf_frontend.toml.*removed' "$tmp_dir/reduced_report.tsv"
rg -q 'remove_stale_agent_config.*paf_qa.toml.*removed' "$tmp_dir/reduced_report.tsv"
rg -q 'remove_stale_agent_config.*paf_ops.toml.*removed' "$tmp_dir/reduced_report.tsv"

rg -q "^\[agents.paf_explorer\]$" "$tmp_dir/.codex/config.toml"
rg -q "^\[agents.paf_implementer\]$" "$tmp_dir/.codex/config.toml"
if rg -q "^\[agents.paf_backend\]$" "$tmp_dir/.codex/config.toml"; then
  echo "error: stale backend block should have been removed" >&2
  exit 1
fi

# plan-agents also enforces max-agents >= 2
if bash "$SCRIPT_PATH" plan-agents \
  --profile "$latest_run/project_profile.tsv" \
  --out "$tmp_dir/plan_invalid.tsv" \
  --max-agents 1 >/dev/null 2>&1; then
  echo "error: plan-agents should reject --max-agents 1" >&2
  exit 1
fi

# nested git repositories should be excluded from signal detection
nested_root="$tmp_dir/nested-scan"
mkdir -p "$nested_root/src" "$nested_root/vendor-subrepo/.git" "$nested_root/vendor-subrepo/tests" "$nested_root/vendor-subrepo/.github/workflows"

cat > "$nested_root/src/main.py" <<'PY'
def run():
    return "ok"
PY

cat > "$nested_root/vendor-subrepo/tests/vendor.test.ts" <<'TS'
describe("vendor", () => {
  it("noise", () => {
    expect(true).toBe(true);
  });
});
TS

cat > "$nested_root/vendor-subrepo/.github/workflows/vendor.yml" <<'YAML'
name: vendor
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo vendor
YAML

bash "$SCRIPT_PATH" scan-project --project-root "$nested_root" --out "$nested_root/profile.tsv" >/dev/null
rg -q '^ops_signal\tno$' "$nested_root/profile.tsv"
rg -q '^test_signal\tno$' "$nested_root/profile.tsv"

# render-config must reject path traversal in config_relpath
guard_root="$tmp_dir/path-guard"
mkdir -p "$guard_root"
outside_target="$tmp_dir/escape.toml"
rm -f "$outside_target"

cat > "$guard_root/malicious_plan.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath
evil	Evil	10	attempt	../../escape.toml
TSV

if bash "$SCRIPT_PATH" render-config \
  --project-root "$guard_root" \
  --plan "$guard_root/malicious_plan.tsv" \
  --report "$guard_root/report.tsv" >/dev/null 2>&1; then
  echo "error: render-config should reject traversal config_relpath" >&2
  exit 1
fi

[[ ! -f "$outside_target" ]]

# apply-plan should accept AI-generated plan fields
ai_root="$tmp_dir/ai-apply"
mkdir -p "$ai_root"

cat > "$ai_root/ai_plan.tsv" <<'TSV'
agent_id	role_name	priority	reason	config_relpath	description	developer_instructions	model	model_reasoning_effort	sandbox_mode
paf_explorer	Project Explorer	10	ai-plan	agents/paf_explorer.toml	AI "generated" explorer	Use AI-generated explorer policy.	gpt-5	high	workspace-write
paf_implementer	Project Implementer	20	ai-plan	agents/paf_implementer.toml	AI generated implementer	Use AI-generated implementer policy.	gpt-5-codex	medium	danger-full-access
TSV

bash "$SCRIPT_PATH" apply-plan \
  --project-root "$ai_root" \
  --plan "$ai_root/ai_plan.tsv" \
  --out-dir "$ai_root/.agents/project-agent-factory/runs/manual" >/dev/null

[[ -f "$ai_root/.codex/config.toml" ]]
[[ -f "$ai_root/.codex/agents/paf_explorer.toml" ]]
[[ -f "$ai_root/.codex/agents/paf_implementer.toml" ]]
[[ -f "$ai_root/.agents/project-agent-factory/runs/manual/apply_report.tsv" ]]
[[ -f "$ai_root/.agents/project-agent-factory/runs/manual/scope_validation.tsv" ]]
[[ -f "$ai_root/.agents/project-agent-factory/runs/manual/audit.tsv" ]]

rg -q 'description = "AI \\"generated\\" explorer"' "$ai_root/.codex/config.toml"
rg -q 'model = "gpt-5-codex"' "$ai_root/.codex/agents/paf_implementer.toml"
rg -q 'sandbox_mode = "danger-full-access"' "$ai_root/.codex/agents/paf_implementer.toml"
rg -q 'Use AI-generated implementer policy\.' "$ai_root/.codex/agents/paf_implementer.toml"

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
agent_id	role_name	priority	reason	config_relpath
paf_explorer	Project Explorer	10	keep	agents/paf_explorer.toml
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
