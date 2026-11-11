#!/usr/bin/env bash
# Wrapper test: .factory-running must be gone after success, failure and timeout; log line must be valid.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

run_case() {  # $1=name  $2=fake claude body  $3=timeout secs  $4=expected status prefix
  local d; d=$(mktemp -d)
  git -C "$d" init -q -b main && git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$d/fakeclaude"; chmod +x "$d/fakeclaude"
  ( cd "$d" && FACTORY_DRY=1 FACTORY_ISSUE_JSON='{"title":"t","body":"b"}' CLAUDE_BIN="$d/fakeclaude" \
      FACTORY_TIMEOUT="$3" FACTORY_LOG="$d/log.jsonl" "$here/scripts/factory-run.sh" 7 >/dev/null 2>&1 )
  check "$1: lock removed" "[ ! -e '$d/.factory-running' ]"
  check "$1: log line valid + status" "jq -e --arg s '$4' '.issue==7 and (.status|startswith(\$s)) and has(\"cost_usd\") and has(\"duration_s\") and has(\"turns\") and has(\"pr\")' '$d/log.jsonl' >/dev/null"
  rm -rf "$d"
}

run_case success 'echo hi > out.txt; echo "{\"subtype\":\"success\",\"total_cost_usd\":0.01,\"num_turns\":2}"' 10 ok
run_case failure 'echo "{\"subtype\":\"error_max_budget_usd\"}"; exit 1' 10 failed
run_case timeout 'sleep 30' 1 timeout
run_case protected 'mkdir -p .github/workflows; echo x > .github/workflows/verify.yml; echo "{\"subtype\":\"success\"}"' 10 touched-protected-paths
exit $fail
