#!/usr/bin/env bash
set -euo pipefail

SKILLS_HOME_URL="https://skills.sh/"

usage() {
  cat <<'USAGE'
Usage:
  skills_batch_ops.sh run [options]
  skills_batch_ops.sh collect-find [--out PATH] [--top N] "query 1" "query 2" ...
  skills_batch_ops.sh collect [--out PATH] [--top N] "query 1" "query 2" ...
  skills_batch_ops.sh collect-top [--out PATH] [--top N]
  skills_batch_ops.sh collect-github --out PATH --github-query "query" [--github-query "query" ...] [--limit N]
  skills_batch_ops.sh import-web --web-links-file PATH [--out PATH] [--query-file PATH]
  skills_batch_ops.sh merge --out PATH --manifest PATH [--find PATH] [--top PATH] [--github PATH] [--web PATH] [--query-file PATH]
  skills_batch_ops.sh validate-content --manifest PATH [--out PATH] [--query-file PATH] [--status pending|approved|rejected|all] [--skill-ref REF ...] [--limit N]
  skills_batch_ops.sh merge-content-reviews --out PATH <content_review_1.tsv> [content_review_2.tsv ...]
  skills_batch_ops.sh prepare-ai-reviews --manifest PATH --content-report PATH [--out PATH] [--status pending|approved|rejected|all] [--limit N] [--include-failed]
  skills_batch_ops.sh merge-ai-reviews --out PATH <ai_review_worker_1.tsv> [ai_review_worker_2.tsv ...]
  skills_batch_ops.sh apply-ai-reviews --manifest PATH --ai-reviews PATH [--out PATH]
  skills_batch_ops.sh install-approved --manifest PATH [--report PATH] [--dry-run] [--no-yes]
  skills_batch_ops.sh install --file PATH [--dry-run] [--no-yes]
  skills_batch_ops.sh audit [--out PATH]
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

append_csv_unique() {
  local current="${1:-}"
  local item="${2:-}"
  local part
  local -a parts=()

  if [[ -z "$item" ]]; then
    printf '%s' "$current"
    return
  fi
  if [[ -z "$current" ]]; then
    printf '%s' "$item"
    return
  fi

  IFS=',' read -r -a parts <<<"$current"
  for part in "${parts[@]}"; do
    if [[ "$part" == "$item" ]]; then
      printf '%s' "$current"
      return
    fi
  done

  printf '%s,%s' "$current" "$item"
}

dedupe_lines_in_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk 'NF && !seen[$0]++ { print $0 }' "$file" > "${file}.tmp"
  mv "${file}.tmp" "$file"
}

to_top_file() {
  local out="$1"
  local top="$2"
  if [[ "$out" == *.tsv ]]; then
    printf '%s\n' "${out%.tsv}.top${top}.tsv"
  else
    printf '%s\n' "${out}.top${top}.tsv"
  fi
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

write_find_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'skill_ref\tfind_installs\tfind_queries\n' > "$out"
}

write_top_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'skill_ref\ttop_installs\ttop_rank\n' > "$out"
}

write_github_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'skill_ref\trepo\tskill\tgithub_stars\tgithub_updated_at\tgithub_queries\n' > "$out"
}

write_web_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'skill_ref\trepo\tskill\tweb_sources\tweb_origin\n' > "$out"
}

write_merged_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'skill_ref\trepo\tskill\tchannels\tfind_installs\ttop_installs\tgithub_stars\tgithub_updated_at\tquery_overlap\tinstall_signal\trepo_health\tchannel_diversity\tauto_score\trisk_level\n' > "$out"
}

write_manifest_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'skill_ref\trepo\tskill\tchannels\tfind_installs\ttop_installs\tgithub_stars\tgithub_updated_at\tquery_overlap\tauto_score\trisk_level\tstatus\treview_notes\tapproved_by\tapproved_at\n' > "$out"
}

write_install_report_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'timestamp\trepo\tskills\tstatus\tcommand\n' > "$out"
}

write_content_review_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'skill_ref\trepo\tskill\tmanifest_status\tauto_score\tname_check\tinstall_check\tskill_md_check\tcontent_overlap\treview_status\tskill_title\tskill_description\tcontent_preview\treview_notes\n' > "$out"
}

write_ai_review_header() {
  local out="$1"
  ensure_parent_dir "$out"
  printf 'skill_ref\trepo\tskill\tmanifest_status\tauto_score\tcontent_overlap\theuristic_status\tskill_title\tskill_description\tcontent_preview\tai_relevance\tai_quality\tai_risk\tai_confidence\tai_decision\tai_recommended_status\tai_summary\tai_rationale\tai_reviewer\tai_reviewed_at\n' > "$out"
}

cmd_collect_find() {
  require_cmd npx
  require_cmd awk
  require_cmd sort

  local out="/tmp/skills_candidates.find.tsv"
  local top=""
  local -a queries=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        out="${2:-}"
        shift 2
        ;;
      --top)
        top="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        queries+=("$1")
        shift
        ;;
    esac
  done

  [[ ${#queries[@]} -gt 0 ]] || die "collect-find requires at least one query"

  local tmp_dir raw q i out_file
  tmp_dir="$(mktemp -d)"
  raw="$tmp_dir/raw.tsv"
  : > "$raw"

  i=0
  for q in "${queries[@]}"; do
    i=$((i + 1))
    out_file="$tmp_dir/find_${i}.txt"

    if ! FORCE_COLOR=0 npx skills find "$q" > "$out_file" 2>&1; then
      warn "npx skills find failed for query: $q"
    fi

    awk -v query="$q" '
    function to_num(x) {
      gsub(/,/, "", x)
      if (x ~ /K$/) { sub(/K$/, "", x); return int(x * 1000) }
      if (x ~ /M$/) { sub(/M$/, "", x); return int(x * 1000000) }
      return int(x)
    }
    {
      line=$0
      gsub(/\x1b\[[0-9;]*m/, "", line)
      if (line ~ /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+@[A-Za-z0-9_.:-]+[[:space:]]+[0-9.,]+[KM]?[[:space:]]+installs/) {
        match(line, /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+@[A-Za-z0-9_.:-]+/)
        skill = substr(line, RSTART, RLENGTH)
        match(line, /[0-9.,]+[KM]?[[:space:]]+installs/)
        raw = substr(line, RSTART, RLENGTH)
        sub(/[[:space:]]+installs$/, "", raw)
        cnt = to_num(raw)
        if (cnt > 0) print skill "\t" cnt "\t" query
      }
    }
    ' "$out_file" >> "$raw"
  done

  if [[ ! -s "$raw" ]]; then
    rm -rf "$tmp_dir"
    die "collect-find produced no candidates"
  fi

  write_find_header "$out"
  awk -F '\t' '
  function add_unique(existing, item,    n, i, arr) {
    if (existing == "") return item
    n = split(existing, arr, ",")
    for (i = 1; i <= n; i++) if (arr[i] == item) return existing
    return existing "," item
  }
  {
    ref=$1
    installs=$2 + 0
    q=$3
    if (installs > best[ref]) best[ref] = installs
    queries[ref] = add_unique(queries[ref], q)
  }
  END {
    for (ref in best) print ref "\t" best[ref] "\t" queries[ref]
  }
  ' "$raw" | sort -t $'\t' -k2,2nr -k1,1 >> "$out"

  local rows
  rows="$(awk 'END {print NR-1}' "$out")"
  if [[ "${rows:-0}" -le 0 ]]; then
    rm -rf "$tmp_dir"
    die "collect-find parsing failed: zero parsed rows"
  fi

  if [[ -n "$top" ]]; then
    local top_file
    top_file="$(to_top_file "$out" "$top")"
    {
      head -n 1 "$out"
      tail -n +2 "$out" | head -n "$top"
    } > "$top_file"
    log "Saved top-${top} find candidates: $top_file"
  fi

  log "Saved find candidates: $out"
  rm -rf "$tmp_dir"
}

cmd_collect_top() {
  require_cmd awk
  require_cmd sort
  require_cmd rg
  require_cmd sed
  require_cmd jq

  local out="/tmp/skills_candidates.top.tsv"
  local top="20"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        out="${2:-}"
        shift 2
        ;;
      --top)
        top="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option for collect-top: $1"
        ;;
    esac
  done

  local html_file="${SKILLS_BATCH_TOP_HTML_FILE:-}"
  local tmp_dir html_source normalized raw rank line json repo skill installs
  tmp_dir="$(mktemp -d)"
  html_source="$tmp_dir/skills_home.html"
  normalized="$tmp_dir/skills_home.normalized.txt"
  raw="$tmp_dir/raw.tsv"

  if [[ -n "$html_file" ]]; then
    [[ -f "$html_file" ]] || die "SKILLS_BATCH_TOP_HTML_FILE does not exist: $html_file"
    cp "$html_file" "$html_source"
  else
    require_cmd curl
    curl -fsSL "$SKILLS_HOME_URL" > "$html_source" || { rm -rf "$tmp_dir"; die "failed to fetch $SKILLS_HOME_URL"; }
  fi

  sed -E 's/\\+"/"/g' "$html_source" > "$normalized"
  : > "$raw"

  rank=0
  while IFS= read -r line; do
    rank=$((rank + 1))
    json="{${line}}"
    repo="$(printf '%s' "$json" | jq -r '.source // empty' 2>/dev/null || true)"
    skill="$(printf '%s' "$json" | jq -r '.skillId // empty' 2>/dev/null || true)"
    installs="$(printf '%s' "$json" | jq -r '.installs // 0' 2>/dev/null || true)"

    if [[ -n "$repo" && -n "$skill" && "$installs" =~ ^[0-9]+$ ]]; then
      printf '%s\t%s\t%s\n' "${repo}@${skill}" "$installs" "$rank" >> "$raw"
    fi
  done < <(rg -o '"source":"[^"]+","skillId":"[^"]+","name":"[^"]+","installs":[0-9]+' "$normalized" || true)

  if [[ ! -s "$raw" ]]; then
    rm -rf "$tmp_dir"
    die "collect-top produced no candidates"
  fi

  write_top_header "$out"
  awk -F '\t' '
  {
    ref=$1
    installs=$2 + 0
    rank=$3 + 0
    if (!(ref in best_installs) || installs > best_installs[ref]) best_installs[ref] = installs
    if (!(ref in best_rank) || rank < best_rank[ref]) best_rank[ref] = rank
  }
  END {
    for (ref in best_installs) print ref "\t" best_installs[ref] "\t" best_rank[ref]
  }
  ' "$raw" | sort -t $'\t' -k2,2nr -k3,3n -k1,1 | head -n "$top" >> "$out"

  local rows
  rows="$(awk 'END {print NR-1}' "$out")"
  if [[ "${rows:-0}" -le 0 ]]; then
    rm -rf "$tmp_dir"
    die "collect-top parsing failed: zero parsed rows"
  fi

  log "Saved top candidates: $out"
  rm -rf "$tmp_dir"
}

cmd_collect_github() {
  require_cmd awk
  require_cmd sort
  require_cmd jq

  local out="/tmp/skills_candidates.github.tsv"
  local limit="8"
  local -a queries=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        out="${2:-}"
        shift 2
        ;;
      --limit)
        limit="${2:-}"
        shift 2
        ;;
      --github-query)
        queries+=("${2:-}")
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        queries+=("$1")
        shift
        ;;
    esac
  done

  [[ ${#queries[@]} -gt 0 ]] || die "collect-github requires at least one --github-query"

  write_github_header "$out"

  if ! command -v gh >/dev/null 2>&1; then
    warn "gh is not installed; github channel skipped"
    return 0
  fi
  if ! command -v npx >/dev/null 2>&1; then
    warn "npx is not installed; github channel skipped"
    return 0
  fi

  local tmp_dir raw q repo_rows repo stars updated list_out skill
  tmp_dir="$(mktemp -d)"
  raw="$tmp_dir/raw.tsv"
  : > "$raw"

  for q in "${queries[@]}"; do
    repo_rows="$(gh search repos "$q" --limit "$limit" --json owner,name,stargazersCount,updatedAt 2>/dev/null || true)"

    if [[ -z "$repo_rows" || "$repo_rows" == "[]" ]]; then
      warn "gh search returned no repositories for query: $q"
      continue
    fi

    while IFS=$'\t' read -r repo stars updated; do
      [[ -n "$repo" ]] || continue
      list_out="$tmp_dir/$(printf '%s' "$repo" | tr '/.' '__').list.txt"

      if ! FORCE_COLOR=0 npx skills add "$repo" --list > "$list_out" 2>&1 < /dev/null; then
        warn "failed to list skills for repo: $repo"
        continue
      fi

      while IFS= read -r skill; do
        [[ -n "$skill" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
          "${repo}@${skill}" "$repo" "$skill" "${stars:-0}" "${updated:-}" "$q" >> "$raw"
      done < <(extract_skill_names_from_list_file "$list_out")
    done < <(printf '%s' "$repo_rows" | jq -r '.[] | [(.owner.login + "/" + .name), (.stargazersCount // 0), (.updatedAt // "")] | @tsv' 2>/dev/null || true)
  done

  if [[ ! -s "$raw" ]]; then
    warn "collect-github produced no candidates"
    rm -rf "$tmp_dir"
    return 0
  fi

  awk -F '\t' '
  function add_unique(existing, item,    n, i, arr) {
    if (existing == "") return item
    n = split(existing, arr, ",")
    for (i = 1; i <= n; i++) if (arr[i] == item) return existing
    return existing "," item
  }
  {
    ref=$1
    repo=$2
    skill=$3
    stars=$4 + 0
    updated=$5
    q=$6

    repos[ref]=repo
    skills[ref]=skill
    if (stars > max_stars[ref]) max_stars[ref] = stars
    if (updated > best_updated[ref]) best_updated[ref] = updated
    queries[ref] = add_unique(queries[ref], q)
  }
  END {
    for (ref in repos) print ref "\t" repos[ref] "\t" skills[ref] "\t" max_stars[ref] "\t" best_updated[ref] "\t" queries[ref]
  }
  ' "$raw" | sort -t $'\t' -k4,4nr -k1,1 >> "$out"

  log "Saved github candidates: $out"
  rm -rf "$tmp_dir"
}

load_query_tokens() {
  local query_file="$1"
  [[ -n "$query_file" && -f "$query_file" ]] || return 0
  awk '
  {
    line=tolower($0)
    gsub(/[^a-z0-9]/, " ", line)
    n=split(line, arr, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
      if (length(arr[i]) >= 3 && arr[i] !~ /^(and|the|for|with|from|that|this|you|are|not|all|top|run|use|via|into|your)$/) {
        if (!seen[arr[i]]++) print arr[i]
      }
    }
  }
  ' "$query_file"
}

any_token_match() {
  local text="$1"
  local query_file="$2"
  local token

  [[ -f "$query_file" ]] || return 0

  while IFS= read -r token; do
    token="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g; s/^ //; s/ $//')"
    [[ -n "$token" ]] || continue
    if [[ "$text" == *"$token"* ]]; then
      return 0
    fi
  done < <(load_query_tokens "$query_file")

  return 1
}

cmd_import_web() {
  require_cmd npx
  require_cmd awk
  require_cmd sort

  local out="/tmp/skills_candidates.web.tsv"
  local web_links_file=""
  local query_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        out="${2:-}"
        shift 2
        ;;
      --web-links-file)
        web_links_file="${2:-}"
        shift 2
        ;;
      --query-file)
        query_file="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option for import-web: $1"
        ;;
    esac
  done

  [[ -n "$web_links_file" && -f "$web_links_file" ]] || die "import-web requires --web-links-file PATH"

  write_web_header "$out"

  local tmp_dir raw link owner repo_name skill repo list_out text
  tmp_dir="$(mktemp -d)"
  raw="$tmp_dir/raw.tsv"
  : > "$raw"

  while IFS= read -r link; do
    link="$(sanitize_field "$link")"
    [[ -n "$link" ]] || continue
    [[ "$link" =~ ^# ]] && continue

    if [[ "$link" =~ skills\.sh/([^/]+)/([^/]+)/([^/?#]+) ]]; then
      owner="${BASH_REMATCH[1]}"
      repo_name="${BASH_REMATCH[2]}"
      skill="${BASH_REMATCH[3]}"
      repo="${owner}/${repo_name}"
      printf '%s\t%s\t%s\t%s\t%s\n' "${repo}@${skill}" "$repo" "$skill" "$link" "skills.sh" >> "$raw"
      continue
    fi

    if [[ "$link" =~ github\.com/([^/]+)/([^/#?]+) ]]; then
      owner="${BASH_REMATCH[1]}"
      repo_name="${BASH_REMATCH[2]}"
      repo_name="${repo_name%.git}"
      repo="${owner}/${repo_name}"
      list_out="$tmp_dir/$(printf '%s' "$repo" | tr '/.' '__').list.txt"

      if ! FORCE_COLOR=0 npx skills add "$repo" --list > "$list_out" 2>&1 < /dev/null; then
        warn "failed to list skills from web GitHub repo URL: $repo"
        continue
      fi

      while IFS= read -r skill; do
        [[ -n "$skill" ]] || continue
        text="$(printf '%s %s' "$repo" "$skill" | tr '[:upper:]' '[:lower:]')"
        if [[ -n "$query_file" && -f "$query_file" ]]; then
          any_token_match "$text" "$query_file" || continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "${repo}@${skill}" "$repo" "$skill" "$link" "github-url" >> "$raw"
      done < <(extract_skill_names_from_list_file "$list_out")
      continue
    fi

    warn "unsupported web link format: $link"
  done < "$web_links_file"

  if [[ ! -s "$raw" ]]; then
    warn "import-web produced no candidates"
    rm -rf "$tmp_dir"
    return 0
  fi

  awk -F '\t' '
  function add_unique(existing, item,    n, i, arr) {
    if (existing == "") return item
    n = split(existing, arr, ",")
    for (i = 1; i <= n; i++) if (arr[i] == item) return existing
    return existing "," item
  }
  {
    ref=$1
    repo=$2
    skill=$3
    source=$4
    origin=$5
    repos[ref]=repo
    skills[ref]=skill
    sources[ref]=add_unique(sources[ref], source)
    origins[ref]=add_unique(origins[ref], origin)
  }
  END {
    for (ref in repos) print ref "\t" repos[ref] "\t" skills[ref] "\t" sources[ref] "\t" origins[ref]
  }
  ' "$raw" | sort -t $'\t' -k1,1 >> "$out"

  log "Saved web candidates: $out"
  rm -rf "$tmp_dir"
}

init_recency_thresholds() {
  if date -u -v-1d +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    THRESHOLD_180="$(date -u -v-180d +%Y-%m-%dT%H:%M:%SZ)"
    THRESHOLD_365="$(date -u -v-365d +%Y-%m-%dT%H:%M:%SZ)"
    THRESHOLD_730="$(date -u -v-730d +%Y-%m-%dT%H:%M:%SZ)"
    return
  fi

  if date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    THRESHOLD_180="$(date -u -d '180 days ago' +%Y-%m-%dT%H:%M:%SZ)"
    THRESHOLD_365="$(date -u -d '365 days ago' +%Y-%m-%dT%H:%M:%SZ)"
    THRESHOLD_730="$(date -u -d '730 days ago' +%Y-%m-%dT%H:%M:%SZ)"
    return
  fi

  THRESHOLD_180=""
  THRESHOLD_365=""
  THRESHOLD_730=""
}

recency_score() {
  local updated_at="${1:-}"
  if [[ -z "$updated_at" ]]; then
    printf '30\n'
    return
  fi

  if [[ -z "${THRESHOLD_180:-}" ]]; then
    printf '50\n'
    return
  fi

  if [[ "$updated_at" > "$THRESHOLD_180" || "$updated_at" == "$THRESHOLD_180" ]]; then
    printf '100\n'
  elif [[ "$updated_at" > "$THRESHOLD_365" || "$updated_at" == "$THRESHOLD_365" ]]; then
    printf '70\n'
  elif [[ "$updated_at" > "$THRESHOLD_730" || "$updated_at" == "$THRESHOLD_730" ]]; then
    printf '40\n'
  else
    printf '10\n'
  fi
}

channel_count() {
  local channels="${1:-}"
  if [[ -z "$channels" ]]; then
    printf '0\n'
    return
  fi
  awk -v c="$channels" 'BEGIN{print split(c,a,",")}'
}

cmd_merge() {
  require_cmd awk
  require_cmd sort

  local find_file=""
  local top_file=""
  local github_file=""
  local web_file=""
  local query_file=""
  local out="/tmp/candidates.merged.tsv"
  local manifest="/tmp/review_manifest.tsv"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --find)
        find_file="${2:-}"
        shift 2
        ;;
      --top)
        top_file="${2:-}"
        shift 2
        ;;
      --github)
        github_file="${2:-}"
        shift 2
        ;;
      --web)
        web_file="${2:-}"
        shift 2
        ;;
      --query-file)
        query_file="${2:-}"
        shift 2
        ;;
      --out)
        out="${2:-}"
        shift 2
        ;;
      --manifest)
        manifest="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option for merge: $1"
        ;;
    esac
  done

  [[ -n "$find_file" || -n "$top_file" || -n "$github_file" || -n "$web_file" ]] || die "merge requires at least one channel file"

  local tmp_dir union agg merged_raw manifest_raw
  local skill_ref repo skill channels find_installs top_installs github_stars github_updated_at query_bag web_sources
  local q line installs rank stars updated web_line

  tmp_dir="$(mktemp -d)"
  union="$tmp_dir/union.tsv"
  agg="$tmp_dir/agg.tsv"
  merged_raw="$tmp_dir/merged_raw.tsv"
  manifest_raw="$tmp_dir/manifest_raw.tsv"
  : > "$union"
  : > "$merged_raw"
  : > "$manifest_raw"

  if [[ -n "$find_file" && -f "$find_file" ]]; then
    while IFS=$'\t' read -r skill_ref installs q; do
      [[ "$skill_ref" == "skill_ref" || -z "$skill_ref" ]] && continue
      is_skill_ref "$skill_ref" || continue
      repo="${skill_ref%@*}"
      skill="${skill_ref#*@}"
      printf '%s\t%s\t%s\tfind\t%s\t0\t0\t\t%s\t\n' \
        "$skill_ref" "$repo" "$skill" "${installs:-0}" "$(sanitize_field "${q:-}")" >> "$union"
    done < "$find_file"
  fi

  if [[ -n "$top_file" && -f "$top_file" ]]; then
    while IFS=$'\t' read -r skill_ref installs rank; do
      [[ "$skill_ref" == "skill_ref" || -z "$skill_ref" ]] && continue
      is_skill_ref "$skill_ref" || continue
      repo="${skill_ref%@*}"
      skill="${skill_ref#*@}"
      printf '%s\t%s\t%s\ttop\t0\t%s\t0\t\t\t\n' \
        "$skill_ref" "$repo" "$skill" "${installs:-0}" >> "$union"
    done < "$top_file"
  fi

  if [[ -n "$github_file" && -f "$github_file" ]]; then
    while IFS=$'\t' read -r skill_ref repo skill stars updated q; do
      [[ "$skill_ref" == "skill_ref" || -z "$skill_ref" ]] && continue
      is_skill_ref "$skill_ref" || continue
      repo="${repo:-${skill_ref%@*}}"
      skill="${skill:-${skill_ref#*@}}"
      printf '%s\t%s\t%s\tgithub\t0\t0\t%s\t%s\t%s\t\n' \
        "$skill_ref" "$repo" "$skill" "${stars:-0}" "$(sanitize_field "${updated:-}")" "$(sanitize_field "${q:-}")" >> "$union"
    done < "$github_file"
  fi

  if [[ -n "$web_file" && -f "$web_file" ]]; then
    while IFS=$'\t' read -r skill_ref repo skill web_line _origin; do
      [[ "$skill_ref" == "skill_ref" || -z "$skill_ref" ]] && continue
      is_skill_ref "$skill_ref" || continue
      repo="${repo:-${skill_ref%@*}}"
      skill="${skill:-${skill_ref#*@}}"
      printf '%s\t%s\t%s\tweb\t0\t0\t0\t\t\t%s\n' \
        "$skill_ref" "$repo" "$skill" "$(sanitize_field "${web_line:-}")" >> "$union"
    done < "$web_file"
  fi

  if [[ ! -s "$union" ]]; then
    rm -rf "$tmp_dir"
    die "merge found no candidates across channels"
  fi

  awk -F '\t' '
  function add_unique(existing, item,    n, i, arr) {
    if (item == "") return existing
    if (existing == "") return item
    n = split(existing, arr, ",")
    for (i = 1; i <= n; i++) if (arr[i] == item) return existing
    return existing "," item
  }
  {
    ref=$1
    repo=$2
    skill=$3
    channel=$4
    fi=$5 + 0
    ti=$6 + 0
    gs=$7 + 0
    upd=$8
    q=$9
    ws=$10

    if (ref == "") next

    if (repos[ref] == "") repos[ref] = repo
    if (skills[ref] == "") skills[ref] = skill
    channels[ref] = add_unique(channels[ref], channel)
    if (fi > find_installs[ref]) find_installs[ref] = fi
    if (ti > top_installs[ref]) top_installs[ref] = ti
    if (gs > github_stars[ref]) github_stars[ref] = gs
    if (upd > github_updated_at[ref]) github_updated_at[ref] = upd
    query_bag[ref] = add_unique(query_bag[ref], q)
    web_sources[ref] = add_unique(web_sources[ref], ws)
  }
  END {
    for (ref in channels) {
      updated = (github_updated_at[ref] == "" ? "__EMPTY__" : github_updated_at[ref])
      qbag = (query_bag[ref] == "" ? "__EMPTY__" : query_bag[ref])
      ws = (web_sources[ref] == "" ? "__EMPTY__" : web_sources[ref])
      print ref "\t" repos[ref] "\t" skills[ref] "\t" channels[ref] "\t" (find_installs[ref] + 0) "\t" \
            (top_installs[ref] + 0) "\t" (github_stars[ref] + 0) "\t" updated "\t" qbag "\t" ws
    }
  }
  ' "$union" | sort -t $'\t' -k1,1 > "$agg"

  if [[ ! -s "$agg" ]]; then
    rm -rf "$tmp_dir"
    die "merge aggregation produced zero rows"
  fi

  local -a query_tokens=()
  if [[ -n "$query_file" && -f "$query_file" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && query_tokens+=("$line")
    done < <(load_query_tokens "$query_file")
  fi

  local total_tokens
  total_tokens="${#query_tokens[@]}"

  local max_install max_stars candidate_install
  max_install="$(awk -F '\t' 'BEGIN{m=0} {x=($5>$6)?$5:$6; if (x>m) m=x} END{print m+0}' "$agg")"
  max_stars="$(awk -F '\t' 'BEGIN{m=0} {if ($7>m) m=$7} END{print m+0}' "$agg")"

  init_recency_thresholds

  local channel_cnt channel_diversity recency stars_norm repo_health install_signal
  local query_overlap matched token candidate_text auto_score risk_level notes

  while IFS=$'\t' read -r skill_ref repo skill channels find_installs top_installs github_stars github_updated_at query_bag web_sources; do
    [[ -n "$skill_ref" ]] || continue
    [[ "$github_updated_at" == "__EMPTY__" ]] && github_updated_at=""
    [[ "$query_bag" == "__EMPTY__" ]] && query_bag=""
    [[ "$web_sources" == "__EMPTY__" ]] && web_sources=""

    channel_cnt="$(channel_count "$channels")"
    channel_diversity="$(awk -v c="$channel_cnt" 'BEGIN{printf "%.2f", (c/4.0)*100}')"

    candidate_install="$find_installs"
    if [[ "$top_installs" -gt "$candidate_install" ]]; then
      candidate_install="$top_installs"
    fi

    if [[ "$max_install" -gt 0 ]]; then
      install_signal="$(awk -v v="$candidate_install" -v m="$max_install" 'BEGIN{printf "%.2f", (v/m)*100}')"
    else
      install_signal="0.00"
    fi

    if [[ "$max_stars" -gt 0 ]]; then
      stars_norm="$(awk -v v="$github_stars" -v m="$max_stars" 'BEGIN{printf "%.2f", (v/m)*100}')"
    else
      stars_norm="0.00"
    fi

    recency="$(recency_score "$github_updated_at")"
    if [[ "$github_stars" -gt 0 || -n "$github_updated_at" ]]; then
      repo_health="$(awk -v s="$stars_norm" -v r="$recency" 'BEGIN{printf "%.2f", (0.7*s) + (0.3*r)}')"
    else
      repo_health="30.00"
    fi

    matched=0
    if [[ "$total_tokens" -gt 0 ]]; then
      candidate_text="$(printf '%s %s %s %s %s %s' "$skill_ref" "$repo" "$skill" "$query_bag" "$channels" "$web_sources" | tr '[:upper:]' '[:lower:]')"
      for token in "${query_tokens[@]}"; do
        if [[ "$candidate_text" == *"$token"* ]]; then
          matched=$((matched + 1))
        fi
      done
      query_overlap="$(awk -v m="$matched" -v t="$total_tokens" 'BEGIN{printf "%.2f", (m/t)*100}')"
    else
      query_overlap="0.00"
    fi

    auto_score="$(awk -v qv="$query_overlap" -v iv="$install_signal" -v rv="$repo_health" -v cv="$channel_diversity" 'BEGIN{printf "%.2f", (0.40*qv) + (0.35*iv) + (0.15*rv) + (0.10*cv)}')"

    if awk -v s="$auto_score" -v cc="$channel_cnt" 'BEGIN{exit !((s>=70.0) && (cc>=2))}'; then
      risk_level="low"
    elif awk -v s="$auto_score" 'BEGIN{exit !(s>=45.0)}'; then
      risk_level="medium"
    else
      risk_level="high"
    fi

    notes="auto-generated; channels=${channels}; query_hits=${matched}/${total_tokens}"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$skill_ref" "$repo" "$skill" "$channels" "$find_installs" "$top_installs" "$github_stars" "$github_updated_at" \
      "$query_overlap" "$install_signal" "$repo_health" "$channel_diversity" "$auto_score" "$risk_level" >> "$merged_raw"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tpending\t%s\t\t\n' \
      "$skill_ref" "$repo" "$skill" "$channels" "$find_installs" "$top_installs" "$github_stars" "$github_updated_at" \
      "$query_overlap" "$auto_score" "$risk_level" "$(sanitize_field "$notes")" >> "$manifest_raw"
  done < "$agg"

  write_merged_header "$out"
  sort -t $'\t' -k13,13nr -k1,1 "$merged_raw" >> "$out"

  write_manifest_header "$manifest"
  sort -t $'\t' -k10,10nr -k1,1 "$manifest_raw" >> "$manifest"

  log "Saved merged candidates: $out"
  log "Saved review manifest: $manifest"
  rm -rf "$tmp_dir"
}

collect_existing_files() {
  local project_root="$1"
  find "$project_root" -maxdepth 3 -type f \( \
    -name 'README*' -o \
    -name 'PROJECT_*' -o \
    -name 'pyproject.toml' -o \
    -name 'package.json' -o \
    -name 'backlog*' \
  \) 2>/dev/null
}

analyze_project() {
  local project_root="$1"
  local signals_file="$2"
  local query_file="$3"

  ensure_parent_dir "$signals_file"
  ensure_parent_dir "$query_file"

  local -a files=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(collect_existing_files "$project_root")

  {
    printf '# Project Signals\n\n'
    printf -- '- generated_at: %s\n' "$(now_utc)"
    printf -- '- project_root: %s\n' "$project_root"
    printf -- '- scanned_file_count: %s\n\n' "${#files[@]}"
    printf '## Scanned Files\n\n'
    if [[ ${#files[@]} -eq 0 ]]; then
      printf -- '- (none found in default scan patterns)\n'
    else
      for f in "${files[@]}"; do
        printf -- '- %s\n' "$f"
      done
    fi
    printf '\n## Detected Signals\n\n'
  } > "$signals_file"

  : > "$query_file"

  add_signal_query() {
    local label="$1"
    local pattern="$2"
    local query="$3"
    local match=""

    if [[ ${#files[@]} -eq 0 ]]; then
      return
    fi

    match="$(rg -n -i -m 1 "$pattern" "${files[@]}" 2>/dev/null || true)"
    if [[ -n "$match" ]]; then
      printf -- '- %s: `%s`\n' "$label" "$(sanitize_field "$match")" >> "$signals_file"
      printf '%s\n' "$query" >> "$query_file"
    fi
  }

  add_signal_query "testing" 'pytest|unittest|test|e2e|integration' 'python testing'
  add_signal_query "queue-concurrency" 'queue|worker|concurrency|async|background|task' 'python concurrency'
  add_signal_query "observability" 'observability|logging|metrics|tracing|monitor|grafana|prometheus' 'python observability'
  add_signal_query "resilience" 'resilien|retry|timeout|fallback|recover|incident|slo' 'python resilience'
  add_signal_query "llm" 'llm|prompt|rag|agent|evaluation|inference' 'llm evaluation'
  add_signal_query "prompt" 'prompt|instruction|system prompt|few-shot' 'prompt engineering'
  add_signal_query "docs" 'readme|docs|changelog|release' 'documentation workflow'

  dedupe_lines_in_file "$query_file"

  if [[ ! -s "$query_file" ]]; then
    cat > "$query_file" <<'DEFAULT_QUERIES'
python testing
python observability
python resilience
python concurrency
prompt engineering
llm evaluation
DEFAULT_QUERIES
  fi

  {
    printf '\n## Query Seeds\n\n'
    while IFS= read -r f; do
      [[ -n "$f" ]] && printf -- '- %s\n' "$f"
    done < "$query_file"
  } >> "$signals_file"
}

cmd_run() {
  local project_root out_dir top web_links_file signals_file query_file
  local find_out top_out github_out web_out merged_out manifest_out
  local q cap
  local -a find_queries=()
  local -a github_queries=()
  local -a final_find_queries=()
  local -a github_args=()

  project_root="$(pwd)"
  out_dir=""
  top="20"
  web_links_file=""

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
      --top)
        top="${2:-}"
        shift 2
        ;;
      --find-query)
        find_queries+=("${2:-}")
        shift 2
        ;;
      --github-query)
        github_queries+=("${2:-}")
        shift 2
        ;;
      --web-links-file)
        web_links_file="${2:-}"
        shift 2
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

  if [[ -z "$out_dir" ]]; then
    out_dir="$project_root/.agents/skills-batch-ops/runs/$(now_stamp)"
  fi
  mkdir -p "$out_dir"

  signals_file="$out_dir/project_signals.md"
  query_file="$out_dir/query_seeds.txt"

  analyze_project "$project_root" "$signals_file" "$query_file"

  if [[ ${#find_queries[@]} -gt 0 ]]; then
    for q in "${find_queries[@]}"; do
      [[ -n "$q" ]] && printf '%s\n' "$q" >> "$query_file"
    done
  fi
  dedupe_lines_in_file "$query_file"

  while IFS= read -r q; do
    [[ -n "$q" ]] && final_find_queries+=("$q")
  done < "$query_file"

  [[ ${#final_find_queries[@]} -gt 0 ]] || die "run cannot proceed: no find queries available"

  find_out="$out_dir/candidates.find.tsv"
  top_out="$out_dir/candidates.top.tsv"
  github_out="$out_dir/candidates.github.tsv"
  web_out="$out_dir/candidates.web.tsv"
  merged_out="$out_dir/candidates.merged.tsv"
  manifest_out="$out_dir/review_manifest.tsv"

  if ! cmd_collect_find --out "$find_out" --top "$top" "${final_find_queries[@]}"; then
    warn "collect-find failed; writing empty channel"
    write_find_header "$find_out"
  fi

  if ! cmd_collect_top --out "$top_out" --top "$top"; then
    warn "collect-top failed; writing empty channel"
    write_top_header "$top_out"
  fi

  if [[ ${#github_queries[@]} -eq 0 ]]; then
    cap=0
    while IFS= read -r q; do
      [[ -n "$q" ]] || continue
      github_queries+=("$q")
      cap=$((cap + 1))
      [[ "$cap" -ge 5 ]] && break
    done < "$query_file"
  fi

  if [[ ${#github_queries[@]} -gt 0 ]]; then
    github_args=()
    for q in "${github_queries[@]}"; do
      github_args+=(--github-query "$q")
    done

    if ! cmd_collect_github --out "$github_out" --limit 6 "${github_args[@]}"; then
      warn "collect-github failed; writing empty channel"
      write_github_header "$github_out"
    fi
  else
    write_github_header "$github_out"
  fi

  if [[ -n "$web_links_file" ]]; then
    if ! cmd_import_web --web-links-file "$web_links_file" --query-file "$query_file" --out "$web_out"; then
      warn "import-web failed; writing empty channel"
      write_web_header "$web_out"
    fi
  fi

  if [[ -f "$web_out" ]]; then
    cmd_merge --find "$find_out" --top "$top_out" --github "$github_out" --web "$web_out" --query-file "$query_file" --out "$merged_out" --manifest "$manifest_out"
  else
    cmd_merge --find "$find_out" --top "$top_out" --github "$github_out" --query-file "$query_file" --out "$merged_out" --manifest "$manifest_out"
  fi

  log "Run complete: $out_dir"
}

cmd_install() {
  require_cmd npx
  require_cmd awk

  local file=""
  local dry_run="0"
  local yes="1"
  local -a skills=()
  local s

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

  while IFS= read -r s; do
    [[ -n "$s" ]] && skills+=("$s")
  done < <(
    awk -F '\t' '
    {
      cand=$1
      if (cand ~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+@[^[:space:]]+$/) {
        if (!seen[cand]++) print cand
      } else if ($0 ~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+@[^[:space:]]+$/) {
        if (!seen[$0]++) print $0
      }
    }
    ' "$file"
  )

  [[ ${#skills[@]} -gt 0 ]] || die "no installable skill entries found in $file"

  for s in "${skills[@]}"; do
    if [[ "$dry_run" == "1" ]]; then
      if [[ "$yes" == "1" ]]; then
        log "DRY-RUN: npx skills add $s -y"
      else
        log "DRY-RUN: npx skills add $s"
      fi
      continue
    fi

    if [[ "$yes" == "1" ]]; then
      npx skills add "$s" -y
    else
      npx skills add "$s"
    fi
  done
}

cmd_audit() {
  require_cmd npx

  local out=""

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

  if [[ -n "$out" ]]; then
    ensure_parent_dir "$out"
    {
      printf '# Audit Log\n\n'
      printf -- '- generated_at: %s\n\n' "$(now_utc)"
      printf '## npx skills list\n\n'
      npx skills list
      printf '\n## npx skills check\n\n'
      npx skills check || true
    } > "$out"
    log "Saved audit log: $out"
  else
    npx skills list
    npx skills check || true
  fi
}

cmd_install_approved() {
  require_cmd npx
  require_cmd awk
  require_cmd sort

  local manifest=""
  local report=""
  local dry_run="0"
  local yes="1"
  local tmp_dir approved_file now
  local current_repo=""
  local repo skill status cmd_str skills_csv
  local -a repo_skills=()

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

  tmp_dir="$(mktemp -d)"
  approved_file="$tmp_dir/approved.tsv"

  awk -F '\t' 'NR>1 && tolower($12)=="approved" {print $2"\t"$3}' "$manifest" | sort -u > "$approved_file"

  if [[ ! -s "$approved_file" ]]; then
    rm -rf "$tmp_dir"
    log "No approved skills found in manifest: $manifest"
    return 0
  fi

  now="$(now_utc)"

  flush_repo_group() {
    local repo_name="$1"
    shift || true
    local -a skills_arr=("$@")
    local -a cmd=(npx skills add "$repo_name")
    local item
    local local_status
    local local_cmd_str
    local local_skills_csv=""

    if [[ -z "$repo_name" || ${#skills_arr[@]} -eq 0 ]]; then
      return
    fi

    for item in "${skills_arr[@]}"; do
      [[ -n "$item" ]] || continue
      cmd+=(--skill "$item")
      local_skills_csv="$(append_csv_unique "$local_skills_csv" "$item")"
    done

    if [[ "$yes" == "1" ]]; then
      cmd+=(-y)
    fi

    local_cmd_str="$(printf '%q ' "${cmd[@]}")"
    local_cmd_str="${local_cmd_str% }"

    if [[ "$dry_run" == "1" ]]; then
      local_status="dry-run"
      log "DRY-RUN: $local_cmd_str"
    else
      if "${cmd[@]}" < /dev/null; then
        local_status="installed"
      else
        local_status="failed"
        warn "install failed for repo: $repo_name"
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$repo_name" "$local_skills_csv" "$local_status" "$local_cmd_str" >> "$report"
  }

  while IFS=$'\t' read -r repo skill; do
    [[ -n "$repo" && -n "$skill" ]] || continue

    if [[ -z "$current_repo" ]]; then
      current_repo="$repo"
      repo_skills=("$skill")
      continue
    fi

    if [[ "$repo" != "$current_repo" ]]; then
      flush_repo_group "$current_repo" "${repo_skills[@]}"
      current_repo="$repo"
      repo_skills=("$skill")
      continue
    fi

    repo_skills+=("$skill")
  done < "$approved_file"

  flush_repo_group "$current_repo" "${repo_skills[@]}"

  if [[ "$dry_run" == "0" ]]; then
    cmd_audit --out "$(dirname "$report")/audit.log" || warn "audit command reported issues"
  fi

  log "Saved install report: $report"
  rm -rf "$tmp_dir"
}

cmd_validate_content() {
  require_cmd npx
  require_cmd awk

  local manifest=""
  local out=""
  local query_file=""
  local status_filter="pending"
  local limit=""
  local manifest_dir=""
  local tmp_dir=""
  local list_cache_dir=""
  local processed=0
  local total_tokens=0
  local manifest_status_lc=""
  local skill_ref repo skill auto_score
  local list_out install_out skill_md_file sandbox_dir listed_skill
  local repo_cache_key list_cache_file list_cache_status_file cached_list_status
  local name_check install_check skill_md_check content_overlap review_status
  local title description body_preview content_text token notes
  local matched=0
  local preview_max=180
  local -a selected_refs=()
  local -a query_tokens=()

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
      --query-file)
        query_file="${2:-}"
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

  if [[ -z "$query_file" ]]; then
    if [[ -f "$manifest_dir/query_seeds.txt" ]]; then
      query_file="$manifest_dir/query_seeds.txt"
    fi
  fi

  if [[ -n "$query_file" && -f "$query_file" ]]; then
    while IFS= read -r token; do
      [[ -n "$token" ]] && query_tokens+=("$token")
    done < <(load_query_tokens "$query_file")
  fi
  total_tokens="${#query_tokens[@]}"

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

  while IFS=$'\037' read -r skill_ref repo skill manifest_status_lc auto_score; do
    [[ -n "$skill_ref" && -n "$repo" && -n "$skill" ]] || continue

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

    sandbox_dir="$tmp_dir/work_${processed}"
    mkdir -p "$sandbox_dir"
    install_out="$tmp_dir/install_${processed}.txt"
    if (cd "$sandbox_dir" && FORCE_COLOR=0 npx skills add "$repo" --skill "$skill" -y > "$install_out" 2>&1 < /dev/null); then
      install_check="installed"
      name_check="matched"
    else
      install_check="install_failed"
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
      if [[ "$cached_list_status" == "ok" ]]; then
        name_check="not_found"
        while IFS= read -r listed_skill; do
          if [[ "$listed_skill" == "$skill" ]]; then
            name_check="matched"
            break
          fi
        done < <(extract_skill_names_from_list_file "$list_cache_file")
      else
        name_check="list_failed"
      fi
    fi

    skill_md_file="$sandbox_dir/.agents/skills/$skill/SKILL.md"
    title=""
    description=""
    body_preview=""
    if [[ -f "$skill_md_file" ]]; then
      skill_md_check="present"
      description="$(
        awk '
        NR==1 && $0=="---" {in_front=1; next}
        in_front && $0=="---" {exit}
        in_front && $0 ~ /^description:[[:space:]]*/ {
          line=$0
          sub(/^description:[[:space:]]*/, "", line)
          gsub(/^"/, "", line)
          gsub(/"$/, "", line)
          print line
          exit
        }
        ' "$skill_md_file" 2>/dev/null || true
      )"
      title="$(
        awk '
        NR==1 && $0=="---" {in_front=1; next}
        in_front && $0=="---" {in_front=0; next}
        in_front {next}
        $0 ~ /^#[[:space:]]+/ {
          line=$0
          sub(/^#[[:space:]]+/, "", line)
          print line
          exit
        }
        ' "$skill_md_file" 2>/dev/null || true
      )"
      body_preview="$(
        awk '
        NR==1 && $0=="---" {in_front=1; next}
        in_front && $0=="---" {in_front=0; next}
        in_front {next}
        {
          line=$0
          gsub(/\r/, "", line)
          if (line ~ /^[[:space:]]*$/) next
          if (line ~ /^#/) next
          gsub(/[[:space:]]+/, " ", line)
          sub(/^ /, "", line)
          sub(/ $/, "", line)
          if (line == "") next
          printf "%s ", line
          count++
          if (count >= 3) exit
        }
        ' "$skill_md_file" 2>/dev/null || true
      )"
    else
      skill_md_check="missing"
    fi

    title="$(sanitize_field "$title")"
    description="$(sanitize_field "$description")"
    body_preview="$(sanitize_field "$body_preview")"
    if [[ ${#body_preview} -gt "$preview_max" ]]; then
      body_preview="${body_preview:0:177}..."
    fi

    matched=0
    if [[ "$total_tokens" -gt 0 ]]; then
      content_text="$(printf '%s %s %s %s %s' "$repo" "$skill" "$title" "$description" "$body_preview" | tr '[:upper:]' '[:lower:]')"
      for token in "${query_tokens[@]}"; do
        if [[ "$content_text" == *"$token"* ]]; then
          matched=$((matched + 1))
        fi
      done
      content_overlap="$(awk -v m="$matched" -v t="$total_tokens" 'BEGIN{printf "%.2f", (m/t)*100}')"
    else
      content_overlap="0.00"
    fi

    if [[ "$name_check" == "matched" && "$skill_md_check" == "present" ]]; then
      if [[ "$total_tokens" -eq 0 || "$matched" -gt 0 ]]; then
        review_status="verified"
        notes="name and SKILL.md verified; query token hits=${matched}/${total_tokens}"
      else
        review_status="manual"
        notes="name and SKILL.md verified but no query token hit"
      fi
    else
      review_status="failed"
      notes="verification failed: name_check=${name_check}, skill_md_check=${skill_md_check}, install_check=${install_check}"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$skill_ref" "$repo" "$skill" "$manifest_status_lc" "$auto_score" "$name_check" "$install_check" "$skill_md_check" \
      "$content_overlap" "$review_status" "$(sanitize_field "$title")" "$(sanitize_field "$description")" \
      "$(sanitize_field "$body_preview")" "$(sanitize_field "$notes")" >> "$out"
  done < <(
    awk -F '\t' '
    NR>1 {
      printf "%s\037%s\037%s\037%s\037%s\n", $1, $2, $3, tolower($12), $10
    }
    ' "$manifest"
  )

  if [[ "$processed" -eq 0 ]]; then
    warn "validate-content found no rows for the current filters"
  fi

  log "Saved content review report: $out"
  rm -rf "$tmp_dir"
}

cmd_merge_content_reviews() {
  require_cmd awk
  require_cmd sort

  local out=""
  local file
  local tmp_dir raw
  local -a inputs=()

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
        inputs+=("$1")
        shift
        ;;
    esac
  done

  [[ -n "$out" ]] || die "merge-content-reviews requires --out PATH"
  [[ ${#inputs[@]} -gt 0 ]] || die "merge-content-reviews requires at least one input report file"

  write_content_review_header "$out"
  tmp_dir="$(mktemp -d)"
  raw="$tmp_dir/raw.tsv"
  : > "$raw"

  for file in "${inputs[@]}"; do
    [[ -f "$file" ]] || die "content review input file does not exist: $file"
    awk 'NR>1' "$file" >> "$raw"
  done

  if [[ ! -s "$raw" ]]; then
    rm -rf "$tmp_dir"
    warn "merge-content-reviews found no rows in input reports"
    log "Saved merged content review report: $out"
    return 0
  fi

  awk -F '\t' '
  function rank(status) {
    s=tolower(status)
    if (s=="verified") return 1
    if (s=="manual") return 2
    if (s=="failed") return 3
    return 9
  }
  {
    ref=$1
    if (ref == "") next
    r=rank($10)
    if (!(ref in best_rank)) {
      best_rank[ref]=r
      best_line[ref]=$0
      next
    }
    if (r < best_rank[ref]) {
      best_rank[ref]=r
      best_line[ref]=$0
      next
    }
    if (r == best_rank[ref]) {
      split(best_line[ref], prev, FS)
      if (($5 + 0) > (prev[5] + 0)) {
        best_line[ref]=$0
      }
    }
  }
  END {
    for (ref in best_line) print best_rank[ref] "\t" best_line[ref]
  }
  ' "$raw" | sort -t $'\t' -k1,1n -k6,6nr -k2,2 | cut -f2- >> "$out"

  log "Saved merged content review report: $out"
  rm -rf "$tmp_dir"
}

cmd_prepare_ai_reviews() {
  require_cmd awk
  require_cmd sort

  local manifest=""
  local content_report=""
  local out=""
  local status_filter="pending"
  local limit=""
  local include_failed="0"
  local tmp_dir raw

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
      --include-failed)
        include_failed="1"
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

  if [[ -z "$out" ]]; then
    out="$(dirname "$content_report")/review_ai.queue.tsv"
  fi

  write_ai_review_header "$out"
  tmp_dir="$(mktemp -d)"
  raw="$tmp_dir/raw.tsv"

  awk -F '\t' -v OFS='\t' -v status_filter="$status_filter" -v include_failed="$include_failed" '
  FNR==NR {
    if (FNR == 1) next
    m_status[$1] = tolower($12)
    m_score[$1] = $10
    next
  }
  FNR==1 { next }
  {
    ref = $1
    if (!(ref in m_status)) next

    heuristic_status = tolower($10)
    if (status_filter != "all" && m_status[ref] != status_filter) next
    if (include_failed != "1" && heuristic_status == "failed") next

    print ref, $2, $3, m_status[ref], m_score[ref], $9, heuristic_status, $11, $12, $13, "", "", "", "", "", "", "", "", "", ""
  }
  ' "$manifest" "$content_report" > "$raw"

  if [[ ! -s "$raw" ]]; then
    rm -rf "$tmp_dir"
    warn "prepare-ai-reviews found no candidates for the current filters"
    log "Saved AI review queue: $out"
    return 0
  fi

  if [[ -n "$limit" ]]; then
    sort -t $'\t' -k5,5nr -k1,1 "$raw" | awk -v lim="$limit" 'NR<=lim' >> "$out"
  else
    sort -t $'\t' -k5,5nr -k1,1 "$raw" >> "$out"
  fi

  log "Saved AI review queue: $out"
  rm -rf "$tmp_dir"
}

cmd_merge_ai_reviews() {
  require_cmd awk
  require_cmd sort

  local out=""
  local file
  local tmp_dir raw
  local -a inputs=()

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
        inputs+=("$1")
        shift
        ;;
    esac
  done

  [[ -n "$out" ]] || die "merge-ai-reviews requires --out PATH"
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
    warn "merge-ai-reviews found no rows in input reports"
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
    ref=$1
    if (ref == "") next

    rr=rec_rank($16)
    dr=decision_rank($15)
    conf=($14=="" ? 0 : $14 + 0)
    score=($5=="" ? 0 : $5 + 0)

    if (!(ref in best_line)) {
      best_rec[ref]=rr
      best_dec[ref]=dr
      best_conf[ref]=conf
      best_score[ref]=score
      best_line[ref]=$0
      next
    }

    if (rr > best_rec[ref] ||
        (rr == best_rec[ref] && dr > best_dec[ref]) ||
        (rr == best_rec[ref] && dr == best_dec[ref] && conf > best_conf[ref]) ||
        (rr == best_rec[ref] && dr == best_dec[ref] && conf == best_conf[ref] && score > best_score[ref])) {
      best_rec[ref]=rr
      best_dec[ref]=dr
      best_conf[ref]=conf
      best_score[ref]=score
      best_line[ref]=$0
    }
  }
  END {
    for (ref in best_line) print best_line[ref]
  }
  ' "$raw" | sort -t $'\t' -k5,5nr -k1,1 >> "$out"

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
    ref=$1
    if (ref == "") next

    rec=tolower($16)
    if (rec!="approved" && rec!="pending" && rec!="rejected") next

    dec=tolower($15)
    rel=$11
    qual=$12
    risk=$13
    conf=$14
    summary=$17
    reviewer=$19
    reviewed_at=$20

    gsub(/[\t\r\n]+/, " ", summary)
    gsub(/[[:space:]]+/, " ", summary)
    sub(/^ /, "", summary)
    sub(/ $/, "", summary)
    if (length(summary) > 120) summary=substr(summary, 1, 117) "..."

    note="ai-review(recommended=" rec ", decision=" dec ", relevance=" rel ", quality=" qual ", risk=" risk ", confidence=" conf
    if (summary != "") note=note ", summary=" summary
    note=note ")"

    map_status[ref]=rec
    map_note[ref]=note
    map_reviewer[ref]=reviewer
    map_reviewed_at[ref]=reviewed_at
    next
  }
  FNR==1 { print; next }
  {
    ref=$1
    if (ref in map_status) {
      $12=map_status[ref]
      if (map_note[ref] != "") {
        if ($13 == "") $13=map_note[ref]
        else $13=$13 "; " map_note[ref]
      }
      if (map_reviewer[ref] != "") $14=map_reviewer[ref]
      if (map_reviewed_at[ref] != "") $15=map_reviewed_at[ref]
    }
    print
  }
  ' "$ai_reviews" "$manifest" > "$out"

  log "Saved AI-applied manifest: $out"
}

cmd_collect_legacy() {
  cmd_collect_find "$@"
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
    collect-find) cmd_collect_find "$@" ;;
    collect-top) cmd_collect_top "$@" ;;
    collect-github) cmd_collect_github "$@" ;;
    import-web) cmd_import_web "$@" ;;
    merge) cmd_merge "$@" ;;
    validate-content) cmd_validate_content "$@" ;;
    merge-content-reviews) cmd_merge_content_reviews "$@" ;;
    prepare-ai-reviews) cmd_prepare_ai_reviews "$@" ;;
    merge-ai-reviews) cmd_merge_ai_reviews "$@" ;;
    apply-ai-reviews) cmd_apply_ai_reviews "$@" ;;
    install-approved) cmd_install_approved "$@" ;;
    collect) cmd_collect_legacy "$@" ;;
    install) cmd_install "$@" ;;
    audit) cmd_audit "$@" ;;
    -h|--help) usage ;;
    *) die "unknown subcommand: $sub" ;;
  esac
}

main "$@"
