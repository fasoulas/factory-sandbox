#!/usr/bin/env bash
# Wrapper + push-log tests. Every case gets a throwaway base dir $B: repo/ (the workspace and, by default, the
# clone source), fakeclaude, log.jsonl, patch, stdout, stderr. Outside repo/ so the wrapper's own files never
# end up in the agent's patch.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
OK='echo "{\"subtype\":\"success\",\"total_cost_usd\":0.01,\"num_turns\":2}"'

# run_case NAME FAKE_CLAUDE_BODY TIMEOUT_SECS EXPECTED_STATUS_PREFIX   (sets $B; caller inspects, then rm -rf "$B")
# optional env: GITIGNORE=0 (repo without the lock ignore rule), PRE='shell run in repo before the first commit',
#               CLONE_URL=override for the clone source, DRY= (empty: use the real gh/push paths),
#               FAKE_GH=1 (fake gh first in PATH; logs "<physical cwd> :: <args> :: top=<git toplevel it can see>" to $B/gh.log),
#               DECOY=1 (the wrapper's TMPDIR is itself a git repo, like an agent-planted /tmp/.git)
run_case() {
  B=$(mktemp -d); local r=$B/repo; mkdir "$r"
  git -C "$r" init -q -b main
  [ "${GITIGNORE:-1}" = 1 ] && printf '.factory-running\n' > "$r/.gitignore"   # like the real repo
  [ -n "${PRE:-}" ] && ( cd "$r" && eval "$PRE" )
  git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$B/fakeclaude"; chmod +x "$B/fakeclaude"
  mkdir "$B/bin" "$B/tmp"; [ -n "${DECOY:-}" ] && git init -q "$B/tmp"
  if [ -n "${FAKE_GH:-}" ]; then
    printf '#!/usr/bin/env bash\necho "$(pwd -P) :: $* :: top=$(git rev-parse --show-toplevel 2>&1 | head -1)" >> "%s/gh.log"\ncase "$1 $2" in\n  "issue view") echo %s ;;\n  "pr create") echo https://example.invalid/pr/1 ;;\nesac\nexit 0\n' "$B" "'{\"title\":\"t\",\"body\":\"b\"}'" > "$B/bin/gh"; chmod +x "$B/bin/gh"
  fi
  local envs=(TMPDIR="$B/tmp" PATH="$B/bin:$PATH" GH_TOKEN=x GITHUB_REPOSITORY=o/r CLAUDE_BIN="$B/fakeclaude" FACTORY_CLONE_URL="${CLONE_URL:-$r}"
              FACTORY_TIMEOUT="$3" FACTORY_LOG="$B/log.jsonl" FACTORY_PATCH_OUT="$B/patch")
  [ "${DRY-1}" = 1 ] && envs+=(FACTORY_DRY=1 FACTORY_ISSUE_JSON='{"title":"t","body":"b"}')
  ( cd "$r" && env "${envs[@]}" "$here/scripts/factory-run.sh" 7 >"$B/stdout" 2>"$B/stderr" )
  check "$1: lock removed" "[ ! -e '$r/.factory-running' ]"
  check "$1: log line + status $4" "jq -e --arg s '$4' '.issue==7 and (.status|startswith(\$s)) and has(\"cost_usd\") and has(\"duration_s\") and has(\"turns\") and has(\"pr\")' '$B/log.jsonl' >/dev/null"
}

# true if a line matching regex $2 sits between a ::stop-commands::<tok> line and its closing ::<tok>:: line in file $1
wrapped() { awk -v pat="$2" '
  /^::stop-commands::/ { tok=substr($0,18); open=1; next }
  open && $0=="::" tok "::" { open=0; next }
  open && $0 ~ pat { hit=1 }
  END { exit !hit }' "$1"; }

run_case success "echo hi > out.txt; $OK" 10 ok; rm -rf "$B"
GITIGNORE=0 run_case success-no-gitignore "echo hi > out.txt; $OK" 10 ok
check "success-no-gitignore: lock not in patch" "grep -q out.txt '$B/patch' && ! grep -q '.factory-running' '$B/patch'"; rm -rf "$B"
# lock committed in HEAD: the PR must not delete it
GITIGNORE=0 PRE=': > .factory-running' run_case lock-tracked "echo hi > out.txt; $OK" 10 ok
check "lock-tracked: patch has the change, no deletion" "grep -q out.txt '$B/patch' && ! grep -q 'deleted file' '$B/patch'"; rm -rf "$B"
run_case no-changes "$OK" 10 no-changes; rm -rf "$B"
run_case failure 'echo "{\"subtype\":\"error_max_budget_usd\"}"; exit 1' 10 failed; rm -rf "$B"
run_case timeout 'sleep 30' 1 timeout; rm -rf "$B"
# a failed agent git step: status + the git error in the job log
run_case gitstep 'rm -rf .git; echo "{\"subtype\":\"success\"}"' 10 patch-step-failed
check "gitstep: message + git error shown" "grep -q 'agent git step failed' '$B/stderr' && grep -qi 'not a git repository' '$B/stderr'"; rm -rf "$B"
# failure output must reach stderr (the job log)
run_case failure-output 'echo BOOM-ERR >&2; echo "{\"subtype\":\"error\",\"result\":\"BOOM-RESULT\"}"; exit 1' 10 failed
check "failure-output: stderr tail + result shown" "grep -q BOOM-ERR '$B/stderr' && grep -q BOOM-RESULT '$B/stderr'"; rm -rf "$B"
# agent-controlled text must not be able to inject Actions workflow commands
run_case stop-commands 'echo "::error::pwn" >&2; echo "{\"subtype\":\"error\",\"result\":\"::warning::pwn2\"}"; exit 1' 10 failed
check "stop-commands: stderr line wrapped" "wrapped '$B/stderr' '^::error::pwn\$'"
check "stop-commands: result line wrapped" "wrapped '$B/stderr' '^::warning::pwn2\$'"; rm -rf "$B"
# text with NO trailing newline (what head -c produces): the closing token must still sit on its own line
run_case stop-commands-nonl 'printf "::error::nonl" >&2; echo "{\"subtype\":\"error\"}"; exit 1' 10 failed
check "stop-commands-nonl: unterminated line wrapped, close token intact" "wrapped '$B/stderr' '^::error::nonl\$'"; rm -rf "$B"
# root must never run gh (which runs git to find the repo) inside the agent-writable workspace. Fake gh logs its cwd.
# Failure path: issue view (before the agent) + escalation comment/edit (after the agent). Success path: pr create.
DRY= FAKE_GH=1 DECOY=1 run_case gh-cwd-fail 'echo "{\"subtype\":\"error\"}"; exit 1' 10 failed
rp=$(cd "$B/repo" && pwd -P); bp=$(cd "$B" && pwd -P)   # physical paths: /tmp or /var may be symlinks (macOS)
check "gh-cwd-fail: gh called for view, comment, edit" "[ \"\$(wc -l < '$B/gh.log')\" -ge 3 ]"
check "gh-cwd-fail: no gh call ran inside the workspace" "! grep -q '^$rp ::' '$B/gh.log'"
check "gh-cwd-fail: gh cannot see a planted parent repo (GIT_CEILING_DIRECTORIES)" "! grep -q 'top=$bp/tmp' '$B/gh.log'"; rm -rf "$B"
DRY= FAKE_GH=1 run_case gh-cwd-ok "echo hi > out.txt; $OK" 10 ok
rp=$(cd "$B/repo" && pwd -P)
check "gh-cwd-ok: gh pr create ran, not inside the workspace" "grep -q ':: pr create' '$B/gh.log' && ! grep -q '^$rp ::' '$B/gh.log'"; rm -rf "$B"
# mktemp failure must abort BEFORE the agent runs (an empty WORK would make `cd ""` a no-op and leave root in the workspace)
B=$(mktemp -d); mkdir "$B/repo"; git -C "$B/repo" init -q -b main
printf '#!/usr/bin/env bash\ntouch "%s/ran"\n' "$B" > "$B/fakeclaude"; chmod +x "$B/fakeclaude"
( cd "$B/repo" && env TMPDIR=/nonexistent/none FACTORY_DRY=1 FACTORY_ISSUE_JSON='{"title":"t","body":"b"}' CLAUDE_BIN="$B/fakeclaude" \
    "$here/scripts/factory-run.sh" 7 >"$B/o" 2>"$B/e" ); rc=$?
check "mktemp failure: aborts non-zero before running the agent" "[ $rc -ne 0 ] && [ ! -e '$B/ran' ] && grep -q 'mktemp failed' '$B/e'"
check "mktemp failure: workspace untouched" "[ -z \"\$(ls -A '$B/repo' | grep -v '^.git\$')\" ] && [ ! -e '$B/repo/.factory-running' ]"; rm -rf "$B"
# patch does not apply to the clone source
o=$(mktemp -d); git -C "$o" init -q -b main; echo different > "$o/a.txt"; git -C "$o" add -A; git -C "$o" -c user.name=t -c user.email=t@t commit -q -m other
PRE='echo base > a.txt' CLONE_URL="$o" run_case patch-failed "echo changed > a.txt; $OK" 10 patch-failed; rm -rf "$B" "$o"
CLONE_URL=/nonexistent/nowhere run_case clone-failed "echo hi > out.txt; $OK" 10 clone-failed; rm -rf "$B"
# the agent must not weaken its own judge: touching protected paths, including via rename
run_case protected 'mkdir -p .github/workflows; echo x > .github/workflows/verify.yml; echo "{\"subtype\":\"success\"}"' 10 touched-protected-paths; rm -rf "$B"
# rename a protected file OUT of .github: with rename detection only the destination would be listed and the deletion hidden
PRE='mkdir -p .github && echo x > .github/ok.txt' run_case rename-protected "git mv .github/ok.txt moved.txt; $OK" 10 touched-protected-paths; rm -rf "$B"

# push-log.sh: honours FACTORY_LOG, appends each run to the agent-logs branch (local bare repo as origin)
B=$(mktemp -d); git init -q --bare "$B/origin.git"
echo '{"issue":1,"status":"ok"}' > "$B/a.jsonl"; echo '{"issue":2,"status":"timeout"}' > "$B/b.jsonl"; : > "$B/empty.jsonl"
pl() { ( cd "$B" && FACTORY_LOG="$1" FACTORY_LOGS_URL="$B/origin.git" GH_TOKEN=x GITHUB_REPOSITORY=o/r "$here/scripts/push-log.sh" >/dev/null 2>&1 ); }
pl "$B/a.jsonl"; pl "$B/b.jsonl"
git clone -q --branch agent-logs "$B/origin.git" "$B/check" 2>/dev/null
check "push-log: both runs appended from FACTORY_LOG" "[ \"\$(wc -l < '$B/check/factory-runs.jsonl')\" -eq 2 ] && grep -q '\"issue\":1' '$B/check/factory-runs.jsonl' && grep -q '\"issue\":2' '$B/check/factory-runs.jsonl'"
check "push-log: empty log is a clean no-op" "pl '$B/empty.jsonl'"; rm -rf "$B"

exit $fail
