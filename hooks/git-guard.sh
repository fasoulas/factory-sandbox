#!/usr/bin/env bash
# PreToolUse hook: block destructive git operations.
# Hooks > skills for safety gates — skills require Claude to remember to invoke them.

INPUT=$(cat)
CMD=$(jq -r '.tool_input.command // ""' <<< "$INPUT" 2>/dev/null)

# G = "git" plus optional global options (-C dir, -c k=v, --git-dir=x), then the subcommand follows.
# ponytail: regex, not a shell parser; aliases, variables and eval still get through.
G='git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--[a-zA-Z-]+(=[^[:space:]]+)?|-[a-zA-Z]))*[[:space:]]+'
S='[^;|&]*'
PATTERNS=(
  # push: -f / combined short flags / --force* / +refspec / --delete / :ref (remote delete)
  "${G}push${S}([[:space:]]-[a-zA-Z]*f|[[:space:]]--force|[[:space:]]\\+[^[:space:]]|[[:space:]]--delete|[[:space:]]:[^[:space:]])"
  "${G}reset${S}--hard"
  "${G}clean[[:space:]]+${S}-[a-zA-Z]*f"
  "${G}branch[[:space:]]+(${S}[[:space:]])?(-[a-zA-Z]*[Dd][a-zA-Z]*|--delete)([[:space:]]|\$)"
  "${G}(checkout|restore)[[:space:]]+(--[[:space:]]+)?\\.([[:space:]]|\$)"
)

for p in "${PATTERNS[@]}"; do
  if grep -qE -- "$p" <<< "$CMD"; then
    jq -cn '{decision: "block", reason: "Destructive git operation blocked by git-guard. State explicitly why this is needed and re-run."}'
    exit 2
  fi
done

exit 0
# sync test
