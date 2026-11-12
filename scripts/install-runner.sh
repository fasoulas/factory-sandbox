#!/usr/bin/env bash
# Root-only runner setup. Run from the trusted checkout BEFORE the agent exists. No secrets in here.
# Used by factory.yml (prepare step) and hooks-integration.yml, so the integration test exercises the same install.
set -euo pipefail
WS=${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}

# uid 5000, NOT the default 1001: 1001 is the host runner user, which owns the mounted /__w/_temp, /__w/_actions
# (runner step control files, e.g. GITHUB_ENV). A colliding uid let the agent plant env changes for later root steps.
getent group agent >/dev/null || groupadd -g 5000 agent
id -u agent >/dev/null 2>&1 || useradd -m -u 5000 -g 5000 agent
[ "$(id -u agent)" = 5000 ] || { echo "agent must be uid 5000 (host runner is 1001)"; exit 1; }

# Everything that governs the agent is root-owned and not agent-writable: the wrapper scripts, the safety hooks,
# and the managed settings (highest-precedence settings tier; wires the hooks and forbids any other hook source).
install -d -m 755 /opt/factory /opt/factory/hooks /opt/factory-out /etc/claude-code
cp -r scripts /opt/factory/
install -m 755 hooks/*.sh /opt/factory/hooks/
install -m 644 config/managed-settings.json /etc/claude-code/managed-settings.json
chmod -R go-w /opt/factory /etc/claude-code
chown -R agent:agent "$WS"

# Fail the step if the agent could change any of it.
for p in /etc/claude-code /etc/claude-code/managed-settings.json /opt/factory /opt/factory/hooks \
         /opt/factory/hooks/git-guard.sh /opt/factory/hooks/env-guard.sh /opt/factory/hooks/spec-approval-guard.sh \
         /opt/factory/scripts/factory-run.sh; do
  if runuser -u agent -- test -w "$p"; then echo "agent can write $p"; exit 1; fi
done
echo "install ok: agent uid $(id -u agent); managed settings, hooks and scripts are root-owned and not agent-writable"
