from pathlib import Path

README = Path(__file__).resolve().parent.parent / "README.md"


def test_readme_has_app_test_command():
    assert "Run the app tests with: python3 -m pytest -q" in README.read_text().splitlines()
