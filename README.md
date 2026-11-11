# factory-sandbox

Throwaway repo for testing the **issue-to-PR factory**: label a GitHub issue `agent-ready`, a headless Claude run implements it, a bot opens a PR, an independent CI judge checks it, a human merges.

The app itself is trivial (`app.py`: `add(a, b)`). The factory is the point.

## Flow

```mermaid
flowchart TD
    A[Issue labeled agent-ready] --> B{Gate: sender has<br/>admin/write/maintain?}
    B -- no --> X1[Refuse, stop]
    B -- yes --> C[factory.yml: run job<br/>concurrency=factory, 30 min cap]
    C --> D[scripts/factory-run.sh N]
    D --> E[Agent run: claude -p<br/>no GH token, budget + timeout caps]
    E --> F{Run ok and<br/>diff non-empty?}
    F -- no --> X2[Comment on issue,<br/>remove label, log, exit 1]
    F -- yes --> G{Diff touches<br/>protected paths?}
    G -- yes --> X2
    G -- no --> H[Wrapper commits as factory-bot,<br/>pushes agent/issue-N, opens PR]
    H --> I[verify.yml on PR:<br/>tests, semgrep, fresh-context review]
    I --> J{All green?}
    J -- yes --> K[Human review and merge]
    J -- no --> L[PR stays open, human decides]
    C --> M[push-log.sh: append run to<br/>agent-logs branch, always]
```

## Components

| File | Role |
|------|------|
| `.github/workflows/factory.yml` | Trigger on `labeled`. `gate` job checks sender permission; `run` job calls the wrapper, then pushes the log. |
| `scripts/factory-run.sh` | Wrapper. Branch, run the agent under caps, check diff, commit, push, open PR, write log line. Never retries. |
| `scripts/push-log.sh` | Appends `factory-runs.jsonl` to the `agent-logs` branch. |
| `scripts/test-factory-run.sh` | Wrapper test with a fake `claude` (dry mode): lock cleanup, log line shape, timeout, protected paths. |
| `.github/workflows/verify.yml` | Independent judge on every PR to `main`. |
| `CLAUDE.md` | Rules the agent follows. |
| `.claude/settings.json` | Denies `git push`, `gh`, and edits to `.github/`, `scripts/`, `.claude/`. |

## Who holds which power

The agent can edit code and run tests. It cannot touch git remotes or GitHub. The wrapper does that.

```mermaid
sequenceDiagram
    participant H as Human
    participant GH as GitHub
    participant W as factory-run.sh
    participant C as Claude (agent)
    participant V as verify.yml

    H->>GH: add label agent-ready
    GH->>W: factory.yml (FACTORY_PAT, API key)
    W->>GH: gh issue view N
    W->>W: git checkout -b agent/issue-N
    W->>C: claude -p (GH_TOKEN unset, budget + timeout)
    C->>C: edit code, add tests, run pytest
    C-->>W: JSON result (cost, turns, subtype)
    W->>W: guards: success? changes? protected paths?
    W->>GH: commit, push, open PR "Closes #N"
    GH->>V: pull_request event
    V-->>GH: tests, semgrep, review verdict
    H->>GH: review and merge
```

## Guardrails

```mermaid
flowchart LR
    subgraph Before
        P1[Permission gate on label sender]
        P2[Single run at a time: concurrency=factory]
    end
    subgraph During
        D1[Budget cap: FACTORY_BUDGET_USD, default 2]
        D2[Wall-clock cap: FACTORY_TIMEOUT, default 900s]
        D3[Agent has no GH token]
        D4[settings.json denies push, gh, protected edits]
    end
    subgraph After
        A1[Protected-path diff check:<br/>.github/ scripts/ .claude/ CLAUDE.md]
        A2[verify.yml: pytest cov ≥ 70, semgrep, LLM diff review]
        A3[Human merge]
    end
    Before --> During --> After
```

Why the protected-path check matters: the agent must not weaken its own judge (CI, wrapper, config).

## Run statuses

Every run appends one JSON line to `factory-runs.jsonl`:

```json
{"issue":7,"duration_s":42,"turns":5,"cost_usd":0.31,"status":"ok","pr":"https://github.com/.../pull/8"}
```

| `status` | Meaning |
|----------|---------|
| `ok` | PR opened |
| `issue-fetch-failed` | `gh issue view` failed |
| `branch-exists` | `agent/issue-N` already exists |
| `timeout` | Hit `FACTORY_TIMEOUT` |
| `failed:rc=…,subtype=…` | Agent errored or hit budget |
| `no-changes` | Agent produced no diff |
| `touched-protected-paths` | Diff edits `.github/`, `scripts/`, `.claude/` or `CLAUDE.md` |
| `commit-failed` / `push-failed` / `pr-failed` | Git or `gh` step failed |

Any non-`ok` status: wrapper comments on the issue, removes `agent-ready`, exits 1. No retry. Fix the issue and re-add the label to rerun.

## Config

| Env var | Default | Where set |
|---------|---------|-----------|
| `FACTORY_BUDGET_USD` | `2` | `factory.yml` |
| `FACTORY_TIMEOUT` | `900` | `factory.yml` |
| `FACTORY_LOG` | `factory-runs.jsonl` | wrapper |
| `CLAUDE_BIN` | `claude` | wrapper (tests override) |
| `FACTORY_DRY` | unset | tests: skip `gh` and push |

Secrets: `FACTORY_PAT` (bot PAT: push, PR, comment), `ANTHROPIC_API_KEY`.

## Local dev

```bash
pip install -r requirements-dev.txt
python -m pytest -q                 # app tests
bash scripts/test-factory-run.sh    # wrapper tests (needs jq, git)
```
