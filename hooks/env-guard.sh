#!/usr/bin/env bash
# PreToolUse hook: block writes to .env and secrets files (Edit/Write AND Bash)
INPUT=$(cat)

# One jq call per field: values may contain spaces, so never split them with read.
TOOL_NAME=$(jq -r '.tool_name // ""' <<< "$INPUT" 2>/dev/null)
FILE=$(jq -r '.tool_input.file_path // ""' <<< "$INPUT" 2>/dev/null)
CMD=$(jq -r '.tool_input.command // ""' <<< "$INPUT" 2>/dev/null)

BLOCKED='{"decision":"block","reason":"Writes to .env root or secrets files are blocked. Use .env.local for local secrets (in .gitignore)."}'

# Edit / Write: block .env root and secrets files, allow .env.local and .env.template
if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "MultiEdit" ]]; then
  BASENAME=$(basename "$FILE")
  # Block only: .env root, and files with "secrets" or "credentials" in name
  if [[ "$BASENAME" == ".env" || "$BASENAME" == *secrets* || "$BASENAME" == *credentials* ]]; then
    echo "$BLOCKED"; exit 2
  fi
  # Allow: .env.local, .env.template, and other .env.* variants
fi

# Bash: block writes to .env root, allow .env.local and .env.template.
# ENV matches the file ".env" only (next char must be a separator, so .env.local does not match).
# ponytail: regex, not a shell parser; variable/eval indirection still gets through.
if [[ "$TOOL_NAME" == "Bash" ]]; then
  ENV='["'"'"']?([^[:space:];|&]*/)?\.env["'"'"']?'
  SEP='([[:space:];|&]|$)'
  LAST='[[:space:]]*(;|&|\||$)'
  PATTERNS=(
    '(>>|>|tee\s)[^/]*\.env\s|/\.env\s|/\.env$|[^;|&]*(secrets|credentials)[^;|&]*(>>|>|tee)'
    ">>?[[:space:]]*${ENV}${SEP}"
    "tee[[:space:]]+(-[a-z]+[[:space:]]+)*${ENV}${SEP}"
    ">>?[[:space:]]*[\"']?[^[:space:];|&]*(secrets|credentials)"
    "tee[[:space:]]+(-[a-z]+[[:space:]]+)*[\"']?[^[:space:];|&]*(secrets|credentials)"
    "(cp|mv|install|ln)[[:space:]]([^;|&]*[[:space:]])?${ENV}${LAST}"
    "sed[[:space:]]+(-[a-zA-Z]*i[a-zA-Z]*|--in-place)[^;|&]*[[:space:]]${ENV}${SEP}"
  )
  for p in "${PATTERNS[@]}"; do
    if grep -qE -- "$p" <<< "$CMD"; then
      echo "$BLOCKED"; exit 2
    fi
  done
fi

exit 0
