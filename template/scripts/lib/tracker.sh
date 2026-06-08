#!/usr/bin/env bash
# Tracker abstraction. ONE set of verbs that route to `gh` (GitHub) or
# `glab` (GitLab) depending on `tracker:` in .afk/config.yml.
#
# Adding a new tracker (Forgejo, Gitea, Linear, …) means adding one new
# arm to every case statement here — and nothing else in the codebase.
# Prompts and skills speak abstract verbs; orchestrator scripts call
# these functions; nothing else knows what `gh` or `glab` is.
#
# Public verbs (all take repo from `$REPO` resolved at source time):
#   afk::tracker::issue_view_json   <N>
#   afk::tracker::issue_state       <N>
#   afk::tracker::issue_labels      <N>
#   afk::tracker::issue_add_label   <N> <label>
#   afk::tracker::issue_remove_label<N> <label>
#   afk::tracker::issue_comment     <N> <body>
#   afk::tracker::issue_close       <N> [reason]
#   afk::tracker::issue_create      <title> <body-file> <comma-labels>
#   afk::tracker::open_afk_children          # list "<N>\t<title>" for open afk-child issues
#   afk::tracker::open_afk_prds              # list "<N>" for open afk-prd issues
#   afk::tracker::blockers          <N>      # parse `## Blocked by` → blocker issue numbers
#   afk::tracker::blockers_resolved <N>      # rc=0 iff every blocker is closed
#   afk::tracker::pr_list_for_branch <branch> # → "<N>" of first open PR or empty
#   afk::tracker::pr_view_json      <PR>
#   afk::tracker::ci_status         <PR>     # GREEN | RED | PENDING | UNKNOWN
#   afk::tracker::pr_merged_for_issue <N>    # → PR number that closed the issue, or empty

TRACKER="$(afk::config tracker github)"
REPO="$(afk::config repo)"
DEFAULT_BRANCH="$(afk::config default_branch main)"

case "$TRACKER" in
  github) AFK_TRACKER_CLI=gh   ;;
  gitlab) AFK_TRACKER_CLI=glab ;;
  *)      afk::die "unknown tracker in config.yml: '$TRACKER' (expected: github | gitlab)" ;;
esac

# === Issue: fetch ============================================================

afk::tracker::issue_view_json() {
  local n="$1"
  case "$TRACKER" in
    github) gh issue view "$n" -R "$REPO" --json number,title,body,labels,state,assignees ;;
    gitlab) glab issue view "$n" -R "$REPO" --output json ;;
  esac
}

afk::tracker::issue_state() {
  case "$TRACKER" in
    github) gh   issue view "$1" -R "$REPO" --json state --jq '.state' ;;
    gitlab) glab issue view "$1" -R "$REPO" --output json | jq -r '.state' ;;
  esac
}

afk::tracker::issue_labels() {
  case "$TRACKER" in
    github) gh   issue view "$1" -R "$REPO" --json labels --jq '[.labels[].name] | join(",")' ;;
    gitlab) glab issue view "$1" -R "$REPO" --output json | jq -r '.labels | join(",")' ;;
  esac
}

# === Issue: mutate ===========================================================

afk::tracker::issue_add_label() {
  case "$TRACKER" in
    github) gh   issue edit   "$1" -R "$REPO" --add-label "$2" >/dev/null 2>&1 || true ;;
    gitlab) glab issue update "$1" -R "$REPO" --label    "$2" >/dev/null 2>&1 || true ;;
  esac
}

afk::tracker::issue_remove_label() {
  case "$TRACKER" in
    github) gh   issue edit   "$1" -R "$REPO" --remove-label "$2" >/dev/null 2>&1 || true ;;
    gitlab) glab issue update "$1" -R "$REPO" --unlabel      "$2" >/dev/null 2>&1 || true ;;
  esac
}

afk::tracker::issue_comment() {
  case "$TRACKER" in
    github) gh   issue comment "$1" -R "$REPO" --body    "$2" >/dev/null ;;
    gitlab) glab issue note    "$1" -R "$REPO" --message "$2" >/dev/null ;;
  esac
}

afk::tracker::issue_close() {
  local reason="${2:-}"
  case "$TRACKER" in
    github) gh   issue close "$1" -R "$REPO" ${reason:+--comment "$reason"} >/dev/null ;;
    gitlab) glab issue close "$1" -R "$REPO" >/dev/null ;;
  esac
}

# Create an issue. Args: <title> <body-file> <comma-separated labels>.
# Echoes the new issue NUMBER (not URL).
afk::tracker::issue_create() {
  local title="$1" body_file="$2" labels="$3"
  case "$TRACKER" in
    github)
      local url
      url="$(gh issue create -R "$REPO" --title "$title" --body-file "$body_file" --label "$labels")"
      printf '%s' "${url##*/}"
      ;;
    gitlab)
      local body json
      body="$(cat "$body_file")"
      # `glab issue create --label` accepts comma-separated.
      json="$(glab issue create -R "$REPO" --title "$title" --description "$body" --label "$labels" --output json 2>/dev/null \
              || glab issue create -R "$REPO" --title "$title" --description "$body" --label "$labels" --yes)"
      # First try JSON; fall back to scraping the URL (older glab versions).
      if jq -e . >/dev/null 2>&1 <<<"$json"; then
        jq -r '.iid // .number // (.web_url | split("/") | last)' <<<"$json"
      else
        printf '%s' "${json##*/}"
      fi
      ;;
  esac
}

# === Listings ================================================================

# Print "<number>\t<title>" for every open afk-child issue.
afk::tracker::open_afk_children() {
  local lbl; lbl="$(afk::config_nested labels child afk-child)"
  case "$TRACKER" in
    github)
      gh issue list -R "$REPO" --state open --label "$lbl" \
        --limit 200 --json number,title \
        --jq '.[] | "\(.number)\t\(.title)"'
      ;;
    gitlab)
      glab issue list -R "$REPO" --label "$lbl" \
        --per-page 200 --output json \
        | jq -r '.[] | "\(.iid)\t\(.title)"'
      ;;
  esac
}

# Print "<number>" for every open afk-prd issue.
afk::tracker::open_afk_prds() {
  local lbl; lbl="$(afk::config_nested labels prd afk-prd)"
  case "$TRACKER" in
    github)
      gh issue list -R "$REPO" --state open --label "$lbl" \
        --limit 100 --json number --jq '.[].number'
      ;;
    gitlab)
      glab issue list -R "$REPO" --label "$lbl" \
        --per-page 100 --output json | jq -r '.[].iid'
      ;;
  esac
}

# === Blocker parsing =========================================================

# Parse the issue body's `## Blocked by` section and print blocker issue
# numbers, one per line.
#
# Why scoped to that section: a naive grep over the whole body picks up
# the `Parent: #N` line, the AFK footer attribution, and any incidental
# `#N` mentioned in prose — which made every child issue look blocked by
# its own PRD and starved the orchestrator's pool. The awk state machine
# enters at `## Blocked by`, leaves at the next `## ` heading or the
# horizontal rule before the footer.
afk::tracker::blockers() {
  local n="$1"
  local body
  case "$TRACKER" in
    github) body="$(gh   issue view "$n" -R "$REPO" --json body --jq '.body' 2>/dev/null || true)" ;;
    gitlab) body="$(glab issue view "$n" -R "$REPO" --output json | jq -r '.description // .body // ""' 2>/dev/null || true)" ;;
  esac
  printf '%s\n' "$body" \
    | awk '
        BEGIN { in_section=0 }
        /^## *[Bb]locked [Bb]y[[:space:]]*$/ { in_section=1; next }
        /^## / && in_section            { exit }
        /^---[[:space:]]*$/ && in_section { exit }
        in_section                       { print }
      ' \
    | { grep -oE '#[0-9]+' || true; } \
    | tr -d '#' \
    | sort -u
}

afk::tracker::blockers_resolved() {
  local n="$1"
  local b s
  for b in $(afk::tracker::blockers "$n"); do
    [[ "$b" == "$n" ]] && continue
    s="$(afk::tracker::issue_state "$b" 2>/dev/null || echo "")"
    case "$s" in
      CLOSED|closed) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# === PRs / MRs ==============================================================

afk::tracker::pr_list_for_branch() {
  local branch="$1"
  case "$TRACKER" in
    github)
      gh pr list -R "$REPO" --head "$branch" --state open \
        --json number --jq '.[0].number // empty' 2>/dev/null
      ;;
    gitlab)
      glab mr list -R "$REPO" --source-branch "$branch" \
        --output json 2>/dev/null | jq -r '.[0].iid // empty'
      ;;
  esac
}

afk::tracker::pr_view_json() {
  case "$TRACKER" in
    github) gh   pr view "$1" -R "$REPO" --json state,mergeable,mergeStateStatus,statusCheckRollup,title,headRefName,baseRefName ;;
    gitlab) glab mr view "$1" -R "$REPO" --output json ;;
  esac
}

# Echo "GREEN" / "RED" / "PENDING" / "UNKNOWN" for the PR's CI summary.
#
# Design choice: "no checks configured" → GREEN, not UNKNOWN. Many repos
# (especially internal ones) disable Actions/Pipelines entirely; treating
# that as RED would prevent AFK from working there at all. The agent-side
# pr_review phase still gates on diff quality even when CI is silent.
afk::tracker::ci_status() {
  local pr="$1"
  case "$TRACKER" in
    github)
      local raw
      raw="$(gh pr checks "$pr" -R "$REPO" --json bucket,name,status,conclusion 2>/dev/null || echo '[]')"
      if [[ "$raw" == "[]" || -z "$raw" ]]; then echo "GREEN"; return; fi
      if jq -e '[.[] | select(.bucket=="fail")] | length > 0' <<<"$raw" >/dev/null; then echo "RED"; return; fi
      if jq -e '[.[] | select(.bucket=="pending")] | length > 0' <<<"$raw" >/dev/null; then echo "PENDING"; return; fi
      if jq -e '[.[] | select(.bucket=="pass")] | length > 0' <<<"$raw" >/dev/null; then echo "GREEN"; return; fi
      echo "UNKNOWN"
      ;;
    gitlab)
      local status
      status="$(glab mr view "$pr" -R "$REPO" --output json 2>/dev/null \
                 | jq -r '.head_pipeline.status // .pipeline.status // "none"')"
      case "$status" in
        success|manual)        echo "GREEN"   ;;
        failed|canceled)       echo "RED"     ;;
        running|pending|created|preparing|scheduled|waiting_for_resource) echo "PENDING" ;;
        none|null|"")          echo "GREEN"   ;;  # no pipeline = nothing to gate on
        *)                     echo "UNKNOWN" ;;
      esac
      ;;
  esac
}

# Find the merged PR that closed an issue. Echoes the PR number or empty.
afk::tracker::pr_merged_for_issue() {
  local n="$1"
  case "$TRACKER" in
    github)
      gh issue view "$n" -R "$REPO" --json closedByPullRequestsReferences \
        --jq '.closedByPullRequestsReferences[0].number // empty' 2>/dev/null || true
      ;;
    gitlab)
      glab issue view "$n" -R "$REPO" --output json \
        | jq -r '.merge_requests_count as $c | if ($c // 0) > 0 then (.closed_by[0].iid // empty) else empty end' 2>/dev/null \
        || true
      ;;
  esac
}
