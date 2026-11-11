#!/usr/bin/env bash
# Append this run's factory-runs.jsonl to the agent-logs branch. Needs GH_TOKEN, GITHUB_REPOSITORY.
# Runs are serialized by the workflow concurrency group, so no push race.
set -euo pipefail
[ -s factory-runs.jsonl ] || { echo "no log line to push"; exit 0; }
url=https://github.com/$GITHUB_REPOSITORY.git
auth=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')
g() { git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" "$@"; }
tmp=$(mktemp -d)
if g clone -q --branch agent-logs --single-branch "$url" "$tmp" 2>/dev/null; then :
else git init -q "$tmp"; git -C "$tmp" checkout -q -b agent-logs; git -C "$tmp" remote add origin "$url"; fi
cat factory-runs.jsonl >> "$tmp/factory-runs.jsonl"
git -C "$tmp" add factory-runs.jsonl
git -C "$tmp" -c user.name=factory-bot -c user.email=factory-bot@users.noreply.github.com commit -q -m "log: run $(date -u +%FT%TZ)"
g -C "$tmp" push -q origin agent-logs
