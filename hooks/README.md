# hooks/

Copies of the claude-hooks guards (env-guard, git-guard, spec-approval-guard). Source commit: uncommitted.
Installed root-owned to /opt/factory/hooks by scripts/install-runner.sh and wired by config/managed-settings.json.
Re-copy with scripts/sync-hooks.sh --apply (claude-setup) and update this file when the originals change.

```
999d56324c91d82af78829a49bf82a32f681febcb55dd98ce1d04dd92f34f897  hooks/env-guard.sh
e4217dab842fe987c671601a37e819e1ccd5f46d9f78e565092cb691059085a0  hooks/git-guard.sh
171e437157842e1eeafd7c1dd87010189dc173be1776122544d174ce5cca3868  hooks/spec-approval-guard.sh
```
