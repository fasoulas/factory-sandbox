from pathlib import Path


def test_readme_has_usage_line():
    readme = Path(__file__).resolve().parent.parent / "README.md"
    assert "Run tests with `python -m pytest -q`" in readme.read_text()
