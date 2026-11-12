#!/usr/bin/env bash
# Install test: files land, test cmd + branch substituted, second run is a no-op.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
git init -q --bare -b main "$d/origin.git"
git clone -q "$d/origin.git" "$d/seed" 2>/dev/null
git -C "$d/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$d/seed" push -q origin main

run() { INSTALL_DRY=1 bash "$here/scripts/install.sh" "$d/origin.git" --test "npm test" -y 2>&1; }
out=$(run)
v=$(git -C "$d/origin.git" show chore/add-factory:.github/workflows/verify.yml 2>/dev/null)
check "factory files pushed"      "git -C '$d/origin.git' show chore/add-factory:scripts/factory-run.sh >/dev/null 2>&1"
check "test cmd substituted"      "echo \"\$v\" | grep -q 'run: npm test'"
check "CLAUDE.md has rules"       "git -C '$d/origin.git' show chore/add-factory:CLAUDE.md | grep -q 'npm test'"
check "runner files pushed"       "for f in scripts/install-runner.sh hooks/git-guard.sh hooks/env-guard.sh hooks/spec-approval-guard.sh config/managed-settings.json; do git -C '$d/origin.git' show chore/add-factory:\$f >/dev/null 2>&1 || exit 1; done"
check "dry run echoed label+PR"   "echo \"\$out\" | grep -q 'DRY gh label create agent-ready' && echo \"\$out\" | grep -q 'DRY gh pr create'"
before=$(git -C "$d/origin.git" rev-parse chore/add-factory)
out2=$(run)
check "second run is no-op"       "echo \"\$out2\" | grep -q 'already up to date' && [ \"\$before\" = \"\$(git -C '$d/origin.git' rev-parse chore/add-factory)\" ]"
exit $fail