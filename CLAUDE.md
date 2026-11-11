# factory-sandbox

Throwaway repo for testing the issue-to-PR factory. Python, pytest.

Rules for agent runs:
- Smallest change that satisfies the issue. No new dependencies.
- Add or update a test for every behavior change; run `python -m pytest -q` before finishing.
- Never commit, push, or touch git remotes. The wrapper does that.
- Never read or print environment variables or secrets.
- Do not edit `.github/`, `scripts/`, or `.claude/`.
