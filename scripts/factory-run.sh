#!/usr/bin/env bash
# Usage: scripts/factory-run.sh <issue-number>
# One headless Claude run for one issue: patch from the agent, PR from root, log line, escalate on failure.
# PRIVILEGE SPLIT: this script runs as root and is the only holder of GH_TOKEN. The agent runs as
# FACTORY_AGENT_USER with a scrubbed env (ANTHROPIC_API_KEY only), writes a patch, and is killed.
# Root never runs git OR gh inside the agent-writable workspace (poisoned .git/config or hooks would run
# with the token; gh runs git in the cwd to find the repo). It applies the patch to a FRESH clone instead, runs from a
# root-owned temp dir, and tells gh the repo via GH_REPO. Never retries.
# Env: GH_TOKEN, ANTHROPIC_API_KEY, GITHUB_REPOSITORY, FACTORY_AGENT_USER (CI: agent; empty = same user, tests),
#      FACTORY_BUDGET_USD (2), FACTORY_TIMEOUT secs (900), FACTORY_LOG, CLAUDE_BIN,
#      FACTORY_DRY=1 (skip gh + push; FACTORY_ISSUE_JSON replaces the issue fetch; FACTORY_CLONE_URL overrides the clone source),
#      FACTORY_PATCH_OUT=path (copy the agent's patch there, root-chosen path; used by tests)
set -uo pipefail

N=${1:?usage: factory-run.sh <issue-number>}
CLAUDE_BIN=${CLAUDE_BIN:-claude}
BUDGET=${FACTORY_BUDGET_USD:-2}
TMO=${FACTORY_TIMEOUT:-900}
AGENT_USER=${FACTORY_AGENT_USER:-}
BRANCH=agent/issue-$N
WS=$PWD                                   # agent workspace (checkout), agent-writable
LOG=${FACTORY_LOG:-$WS/factory-runs.jsonl}   # absolute: we cd into a throwaway clone later. CI sets it outside WS
AGENT_HOME=${AGENT_USER:+$(getent passwd "$AGENT_USER" | cut -d: -f6)}
CLONE_URL=${FACTORY_CLONE_URL:-https://github.com/${GITHUB_REPOSITORY:-}.git}
LOCK=$WS/.factory-running
OUTDIR=$(mktemp -d "${TMPDIR:-/tmp}/factory-out.XXXXXX"); WORK=$(mktemp -d "${TMPDIR:-/tmp}/factory-work.XXXXXX")   # explicit template: BSD mktemp ignores TMPDIR without one
OUT=$OUTDIR/out.json
start=$(date +%s)
# Leave the agent-writable workspace for good: every root-side gh/git call runs from a root-owned dir.
# (Removing root's safe.directory entry made `gh issue view` fail with "dubious ownership": gh runs git in the cwd.)
cd "$WORK" || exit 1
# git walks UP to find a repo, and the agent can write /tmp: never look above our own temp dir (no planted /tmp/.git)
export GIT_CEILING_DIRECTORIES=$(dirname "$WORK")
[ -n "${GITHUB_REPOSITORY:-}" ] && export GH_REPO=$GITHUB_REPOSITORY

# OUTDIR stays root-owned and root-only: the agent never gets a path there, so it cannot plant a symlink
# that root would follow. Root opens every output file; the agent writes through inherited fds.
touch "$LOCK"
trap 'rm -f "$LOCK"; rm -rf "$OUTDIR" "$WORK"' EXIT   # lock must go on every exit path
trap 'exit 143' TERM INT HUP                          # make signals run the EXIT trap

ghx() { if [ -n "${FACTORY_DRY:-}" ]; then echo "DRY gh $*" >&2; else gh "$@"; fi; }

# run a command as the agent with a scrubbed env; no token, no inherited secrets
as_agent() {
  local envs=(env -i "HOME=${AGENT_HOME:-${HOME:-/tmp}}" "PATH=$PATH" "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}")
  if [ -n "$AGENT_USER" ]; then runuser -u "$AGENT_USER" -- "${envs[@]}" "$@"; else "${envs[@]}" "$@"; fi
}
kill_agent() { [ -n "$AGENT_USER" ] && pkill -KILL -u "$AGENT_USER" 2>/dev/null; return 0; }

ghauth() {  # git with the bot token, for root-side fresh-clone operations only
  local auth; auth=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')
  git -c core.hooksPath=/dev/null -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" "$@"
}

# Everything the agent can influence (stderr, result text, git output) is printed through here, so it cannot inject
# Actions workflow commands (::error::, ::add-mask::, ...) into the job log: they are inert between stop-commands tokens.
untrusted() {  # $1=label; text on stdin
  local tok; tok=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  echo "::stop-commands::$tok"; echo "--- $1"; cat; echo; echo "::$tok::"   # echo first: text may lack a trailing newline (head -c cuts mid-line)
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
    # surface why in the job log (issue text is public already; Actions masks secrets)
    { tail -n 20 "$OUTDIR/err" 2>/dev/null | untrusted "claude stderr (tail)"
      jq -r '.result // empty' "$OUT" 2>/dev/null | head -c 800 | untrusted "claude result"; } >&2
    ghx issue comment "$N" --body "factory run stopped: \`$status\`. No retry. Fix the issue or rerun by re-adding the label." || true
    ghx issue edit "$N" --remove-label agent-ready || true
    exit 1
  fi
  exit 0
}

if [ -n "${FACTORY_ISSUE_JSON:-}" ]; then issue=$FACTORY_ISSUE_JSON
else issue=$(gh issue view "$N" --json title,body) || log_and_exit "issue-fetch-failed"; fi
title=$(jq -r .title <<<"$issue"); body=$(jq -r '.body // ""' <<<"$issue")

prompt="Implement GitHub issue #$N in this repo. Follow CLAUDE.md. Smallest change that works; add or update tests and run them. Do not run git commit or push.

Title: $title

$body"

# ponytail: dollars + wall clock only; --max-turns is not in claude 2.1.322
( cd "$WS" && as_agent timeout "$TMO" "$CLAUDE_BIN" -p "$prompt" \
    --max-budget-usd "$BUDGET" --output-format json --dangerously-skip-permissions \
    >"$OUT" 2>"$OUTDIR/err" )
rc=$?
# agent-side git: patch comes back on stdout (root-opened file), no agent-writable path is ever written/read by root
gitstep_ok=1
# lock file: never in the patch. NOT a ':!' pathspec: naming a gitignored path makes `git add` exit non-zero (runs 43107136642, 43108374953).
# `git reset -- path` (not `git rm --cached`): unstages our addition but keeps a lock file that is tracked in HEAD from being deleted by the PR.
( cd "$WS" && as_agent git add -A && as_agent git reset -q -- .factory-running \
  && as_agent git diff --cached --binary --no-renames ) \
  >"$OUTDIR/patch" 2>"$OUTDIR/gitlog" || gitstep_ok=0
# agent steps are over: no leftover agent process may touch anything while root reads its output
kill_agent

[ "$rc" -eq 124 ] && log_and_exit "timeout"
sub=$(jq -r '.subtype // "none"' "$OUT" 2>/dev/null || echo none)
[ "$rc" -ne 0 ] || [ "$sub" != success ] && log_and_exit "failed:rc=$rc,subtype=$sub"
if [ "$gitstep_ok" -eq 0 ]; then tail -n 20 "$OUTDIR/gitlog" | untrusted "agent git step failed" >&2; log_and_exit "patch-step-failed"; fi
[ -n "${FACTORY_PATCH_OUT:-}" ] && cp "$OUTDIR/patch" "$FACTORY_PATCH_OUT"
[ -s "$OUTDIR/patch" ] || log_and_exit "no-changes"

# root side: patch is DATA. Apply to a fresh clone; no repo config/hook from the workspace is ever executed.
if [ -n "${FACTORY_DRY:-}" ]; then git clone -q "$CLONE_URL" "$WORK/c" || log_and_exit "clone-failed"
else ghauth clone -q "$CLONE_URL" "$WORK/c" || log_and_exit "clone-failed"; fi
cd "$WORK/c" || log_and_exit "clone-failed"
git checkout -q -b "$BRANCH" || log_and_exit "branch-failed"
git -c core.hooksPath=/dev/null apply --index "$OUTDIR/patch" || log_and_exit "patch-failed"
# the agent must not be able to weaken its own judge (CI, wrapper, config)
git diff --cached --name-only --no-renames | grep -qE '^(\.github/|scripts/|\.claude/|CLAUDE\.md$)' && log_and_exit "touched-protected-paths"
git -c core.hooksPath=/dev/null -c user.name=factory-bot -c user.email=factory-bot@users.noreply.github.com \
  commit -q -m "agent: $title (#$N)" || log_and_exit "commit-failed"

if [ -n "${FACTORY_DRY:-}" ]; then pr="dry-run"
else
  ghauth push -q origin "$BRANCH" || log_and_exit "push-failed"
  pr=$(gh pr create --head "$BRANCH" --base main --title "agent: $title" \
    --body "Closes #$N

Automated run. Human review required.") || log_and_exit "pr-failed"
fi
log_and_exit ok "$pr"
