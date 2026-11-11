#!/usr/bin/env bash
# PreToolUse (Edit|Write): in a project that has specs/, block code edits until the right spec is approved.
# Approved = a spec containing the line "Status: approved" (human sets it). Opt-in: no specs/ dir -> no-op.
# Per-feature: if the edited file's basename appears in backticks in one or more specs, at least one of THOSE
# specs must be approved (so a draft spec for feature B is not unlocked by approved feature A).
# Files no spec names fall back to: any approved spec unlocks.
in=$(cat)
cwd=$(jq -r '.cwd // empty' <<< "$in"); file=$(jq -r '.tool_input.file_path // ""' <<< "$in")
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
[ -d "$root/specs" ] || exit 0
case "$file" in
  "$root"/specs/*|*.md|*/.gitignore|*/.claude/*|*/.remember/*|"$HOME"/.claude/*) exit 0 ;;
esac
APPROVED='^[[:space:]]*(\*\*)?Status:?(\*\*)?[[:space:]]*approved'
base=$(basename "$file")
named=$(grep -lF -- "\`$base\`" "$root"/specs/*.md 2>/dev/null)
if [ -n "$named" ]; then
  # shellcheck disable=SC2086
  grep -qlE "$APPROVED" $named 2>/dev/null && exit 0
  jq -cn --arg b "$base" --arg s "$(echo "$named" | xargs -n1 basename | paste -sd, -)" \
    '{decision:"block",reason:("\($b) is named only by unapproved spec(s): \($s). Get that spec to \"Status: approved\" before editing it.")}'
  exit 2
fi
grep -qlE "$APPROVED" "$root"/specs/*.md 2>/dev/null && exit 0
jq -cn '{decision:"block",reason:"specs/ exists but no spec has \"Status: approved\". Draft the spec and get it approved before editing code."}'
exit 2
