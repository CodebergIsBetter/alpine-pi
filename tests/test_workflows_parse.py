"""Every GitHub Actions workflow must be valid YAML.

Motivating incident: ``.github/workflows/lint.yml`` contained

    run: yamllint -d "{extends: relaxed, rules: {line-length: disable}}" ...

A plain YAML scalar may not contain ``": "``, so that line made the
whole file unparseable and GitHub would reject the workflow outright.
The bitter part: the offending file IS the workflow that runs yamllint,
so the very check that would have caught this could never execute.

A unit test does not depend on CI being healthy to notice CI being
broken, which is exactly the property needed here.
"""

from __future__ import annotations

from pathlib import Path

import pytest

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None

_WORKFLOW_DIR = Path(__file__).resolve().parents[1] / ".github" / "workflows"
_WORKFLOWS = sorted(_WORKFLOW_DIR.glob("*.yml")) + sorted(_WORKFLOW_DIR.glob("*.yaml"))


def test_workflow_dir_exists() -> None:
    assert _WORKFLOW_DIR.is_dir(), f"no workflow dir at {_WORKFLOW_DIR}"
    assert _WORKFLOWS, "no workflow files found"


@pytest.mark.skipif(yaml is None, reason="PyYAML not installed")
@pytest.mark.parametrize("wf", _WORKFLOWS, ids=lambda p: p.name)
def test_workflow_is_valid_yaml(wf: Path) -> None:
    try:
        doc = yaml.safe_load(wf.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        pytest.fail(f"{wf.name} is not valid YAML: {exc}")
    assert isinstance(doc, dict), f"{wf.name} did not parse to a mapping"
    # 'on' is the trigger key; YAML 1.1 turns a bare `on:` into True.
    assert "jobs" in doc, f"{wf.name} has no jobs"
    assert ("on" in doc) or (True in doc), f"{wf.name} has no triggers"


@pytest.mark.skipif(yaml is None, reason="PyYAML not installed")
@pytest.mark.parametrize("wf", _WORKFLOWS, ids=lambda p: p.name)
def test_workflow_steps_have_run_or_uses(wf: Path) -> None:
    """Catch a step that silently does nothing."""
    doc = yaml.safe_load(wf.read_text(encoding="utf-8"))
    for job_name, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict) or "steps" not in job:
            continue  # reusable-workflow call (`uses:` at job level)
        for i, step in enumerate(job["steps"]):
            assert "run" in step or "uses" in step, (
                f"{wf.name}: job {job_name!r} step {i} has neither "
                f"'run' nor 'uses': {step!r}"
            )
