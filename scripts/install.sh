#!/usr/bin/env bash
# Install the factory into an existing GitHub repo via a PR. Idempotent: re-run to update.
# Usage: scripts/install.sh OWNER/REPO [--test "CMD"] [-y]
#   --test CMD  test command for verify.yml + CLAUDE.md (default: python -m pytest -q)
#   -y          skip the confirmation prompt
# Needs: gh (admin on the target repo), git. Files come from THIS checkout, so run it from a good commit.
# Env: INSTALL_DRY=1  echo gh calls instead of running them; OWNER/REPO may be a local git path (tests).
# Not portable to non-Python stacks without editing the setup-python/pip/semgrep steps in verify.yml.
set -euo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd)
repo=${1:?usage: install.sh OWNER/REPO [--test CMD] [-y]}; shift
test_cmd="python -m pytest -q"; yes=
while [ $# -gt 0 ]; do
  case $1 in --test) test_cmd=${2:?--test needs a command}; shift ;; -y) yes=1 ;; *) echo "bad arg: $1" >&2; exit 2 ;; esac
  shift
done
dry=${INSTALL_DRY:-}
ghx() { if [ -n "$dry" ]; then echo "DRY gh $*" >&2; else gh "$@"; fi; }

base=main
[ -n "$dry" ] || base=$(gh repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name)

if [ -z "$yes" ]; then
  echo "Will open a PR on $repo (base $base) adding the factory, create label agent-ready,"
  echo "prompt for missing secrets, and set branch protection on $base (PR + tests/semgrep/review)."
  read -r -p "Continue? [y/N] " a; [ "$a" = y ] || exit 1
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -n "$dry" ]; then git clone -q "$repo" "$tmp/r"; else gh repo clone "$repo" "$tmp/r" -- -q; fi
cd "$tmp/r"
if git rev-parse -q --verify origin/chore/add-factory >/dev/null; then   # re-run: continue the open branch
  git checkout -q -B chore/add-factory origin/chore/add-factory
else git checkout -q -B chore/add-factory; fi

for f in .github/workflows/factory.yml .github/workflows/verify.yml scripts/factory-run.sh scripts/push-log.sh; do
  mkdir -p "$(dirname "$f")"; cp "$SRC/$f" "$f"
done
chmod +x scripts/*.sh

if [ "$base" != main ]; then
  sed -i.bak -e "s/\[main\]/[$base]/" -e "s#origin/main#origin/$base#" .github/workflows/verify.yml
  sed -i.bak "s/--base main/--base $base/" scripts/factory-run.sh
fi
if [ "$test_cmd" != "python -m pytest -q" ]; then
  T="$test_cmd" awk '/run: python -m pytest/{print "      - run: " ENVIRON["T"]; next} 1' \
    .github/workflows/verify.yml > v.tmp && mv v.tmp .github/workflows/verify.yml
fi
rm -f .github/workflows/*.bak scripts/*.bak

if ! grep -q 'factory-rules' CLAUDE.md 2>/dev/null; then
  cat >> CLAUDE.md <<EOF

<!-- factory-rules -->
## Rules for agent runs
- Smallest change that satisfies the issue. No new dependencies.
- Add or update a test for every behavior change; run \`$test_cmd\` before finishing.
- Never commit, push, or touch git remotes. The wrapper does that.
- Never read or print environment variables or secrets.
- Do not edit \`.github/\`, \`scripts/\`, or \`.claude/\`.
EOF
fi

git add -A
if [ -n "$(git status --porcelain)" ]; then
  git -c user.name="${GIT_AUTHOR_NAME:-factory-install}" -c user.email="${GIT_AUTHOR_EMAIL:-factory-install@localhost}" \
    commit -q -m "chore: add issue-to-PR factory"
  git push -q -f -u origin chore/add-factory
  ghx pr create --repo "$repo" --base "$base" --head chore/add-factory \
    --title "chore: add issue-to-PR factory" --body "Adds factory workflows and scripts. Review before merging." \
    || echo "PR not created (already open?)" >&2
else
  echo "factory files already up to date"
fi

ghx label create agent-ready --repo "$repo" --force
for s in ANTHROPIC_API_KEY FACTORY_PAT; do
  if [ -z "$dry" ] && gh secret list --repo "$repo" | grep -q "^$s"; then echo "secret $s exists"; else ghx secret set "$s" --repo "$repo"; fi
done
printf '{"required_status_checks":{"strict":false,"contexts":["tests","semgrep","review"]},"enforce_admins":false,"required_pull_request_reviews":{"required_approving_review_count":0},"restrictions":null}' \
  | ghx api -X PUT "repos/$repo/branches/$base/protection" --input - >/dev/null \
  || echo "WARN: branch protection failed (plan/permissions?) - set it by hand" >&2
echo "done. Use a low-limit ANTHROPIC_API_KEY and a fine-grained FACTORY_PAT scoped to $repo."