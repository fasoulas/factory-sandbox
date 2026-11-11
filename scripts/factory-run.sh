#!/usr/bin/env bash
# Usage: scripts/factory-run.sh <issue-number>
# One headless Claude run for one issue: branch, run under caps, PR, log line, escalate on failure.
# Never retries. The agent runs WITHOUT the GitHub token; only this wrapper pushes/opens PRs.
# Env: GH_TOKEN (bot PAT), ANTHROPIC_API_KEY, GITHUB_REPOSITORY,
#      FACTORY_BUDGET_USD (2), FACTORY_TIMEOUT secs (900), FACTORY_LOG, CLAUDE_BIN,
#      FACTORY_DRY=1 (skip gh + push; FACTORY_ISSUE_JSON replaces the issue fetch; used by tests)
set -uo pipefail

N=${1:?usage: factory-run.sh <issue-number>}
CLAUDE_BIN=${CLAUDE_BIN:-claude}
BUDGET=${FACTORY_BUDGET_USD:-2}
TMO=${FACTORY_TIMEOUT:-900}
LOG=${FACTORY_LOG:-factory-runs.jsonl}
LOCK=.factory-running
BRANCH=agent/issue-$N
OUT=$(mktemp)
start=$(date +%s)

touch "$LOCK"
trap 'rm -f "$LOCK" "$OUT" "$OUT.err"' EXIT   # lock must go on every exit path
trap 'exit 143' TERM INT HUP                  # make signals run the EXIT trap

ghx() { if [ -n "${FACTORY_DRY:-}" ]; then echo "DRY gh $*" >&2; else gh "$@"; fi; }

push_branch() {
  [ -n "${FACTORY_DRY:-}" ] && { echo "DRY push $BRANCH" >&2; return 0; }
  local auth
  auth=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')
  git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" \
    push -q "https://github.com/$GITHUB_REPOSITORY.git" "$BRANCH"
}

log_and_exit() {  # $1=status  $2=pr url (may be empty)
  local status=$1 pr=${2:-} cost turns
  cost=$(jq -r '.total_cost_usd // 0' "$OUT" 2>/dev/null || echo 0)
  turns=$(jq -r '.num_turns // 0' "$OUT" 2>/dev/null || echo 0)
  jq -nc --argjson issue "$N" --argjson duration_s "$(( $(date +%s) - start ))" \
    --argjson turns "${turns:-0}" --argjson cost_usd "${cost:-0}" \
    --arg status "$status" --arg pr "$pr" \
    '{issue:$issue,duration_s:$duration_s,turns:$turns,cost_usd:$cost_usd,status:$status,pr:$pr}' >> "$LOG"
  if [ "$status" != ok ]; then
    ghx issue comment "$N" --body "factory run stopped: \`$status\`. No retry. Fix the issue or rerun by re-adding the label." || true
    ghx issue edit "$N" --remove-label agent-ready || true
    exit 1
  fi
  exit 0
}

if [ -n "${FACTORY_ISSUE_JSON:-}" ]; then issue=$FACTORY_ISSUE_JSON
else issue=$(gh issue view "$N" --json title,body) || log_and_exit "issue-fetch-failed"; fi
title=$(jq -r .title <<<"$issue"); body=$(jq -r '.body // ""' <<<"$issue")

git checkout -q -b "$BRANCH" || log_and_exit "branch-exists"

prompt="Implement GitHub issue #$N in this repo. Follow CLAUDE.md. Smallest change that works; add or update tests and run them. Do not run git commit or push.

Title: $title

$body"

# ponytail: dollars + wall clock only; --max-turns is not in claude 2.1.322
env -u GH_TOKEN -u GITHUB_TOKEN timeout "$TMO" "$CLAUDE_BIN" -p "$prompt" \
  --max-budget-usd "$BUDGET" --output-format json --dangerously-skip-permissions \
  >"$OUT" 2>"$OUT.err"
rc=$?

[ "$rc" -eq 124 ] && log_and_exit "timeout"
sub=$(jq -r '.subtype // "none"' "$OUT" 2>/dev/null || echo none)
[ "$rc" -ne 0 ] || [ "$sub" != success ] && log_and_exit "failed:rc=$rc,subtype=$sub"

git add -A
git diff --cached --quiet && log_and_exit "no-changes"
# the agent must not be able to weaken its own judge (CI, wrapper, config)
git diff --cached --name-only | grep -qE '^(\.github/|scripts/|\.claude/|CLAUDE\.md$)' && log_and_exit "touched-protected-paths"
git -c user.name=factory-bot -c user.email=factory-bot@users.noreply.github.com \
  commit -q -m "agent: $title (#$N)" || log_and_exit "commit-failed"
push_branch || log_and_exit "push-failed"

if [ -n "${FACTORY_DRY:-}" ]; then pr="dry-run"
else pr=$(gh pr create --head "$BRANCH" --base main --title "agent: $title" \
  --body "Closes #$N

Automated run. Human review required.") || log_and_exit "pr-failed"; fi
log_and_exit ok "$pr"
