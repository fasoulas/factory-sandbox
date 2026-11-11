"""Regression cases for the safety hooks in hooks/ (copies of the claude-hooks guards).

Cases live in hook_cases.jsonl. Set HOOKS_DIR to test another copy.
"""

import json
import os
import subprocess
from pathlib import Path

import pytest

HOOKS = Path(
    os.environ.get("HOOKS_DIR", Path(__file__).resolve().parent.parent / "hooks")
)
CASES = [
    json.loads(line)
    for line in (Path(__file__).parent / "hook_cases.jsonl").read_text().splitlines()
    if line
]


def run(case, tmp):
    for rel, text in case["files"].items():
        p = tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    stdin = json.dumps(case["stdin"]).replace("{tmp}", str(tmp))
    return subprocess.run(
        ["bash", str(HOOKS / case["hook"])],
        input=stdin,
        capture_output=True,
        text=True,
        cwd=tmp,
        timeout=60,
    )


@pytest.mark.parametrize("case", [pytest.param(c, id=c["id"]) for c in CASES])
def test_hook(case, tmp_path):
    r = run(case, tmp_path)
    assert r.returncode == case["expect_exit"], (case["criteria"], r.stdout, r.stderr)
    for s in case.get("expect_stdout_contains", []):
        assert s in r.stdout, (case["criteria"], r.stdout)
    if case.get("expect_stdout_empty"):
        assert r.stdout.strip() == "", (case["criteria"], r.stdout)
