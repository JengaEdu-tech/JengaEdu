import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app as solver_app


def payload(**overrides):
    base = {
        "school_id": "00000000-0000-0000-0000-000000000001",
        "year": "2026",
        "term": "Term 3",
        "days": ["Monday", "Tuesday"],
        "slots": ["08:00–08:40", "08:40–09:20", "09:20–10:00"],
        "lessons": [{"id": "G4-MATH-1", "class": "Grade 4", "subject": "Mathematics", "teacherIds": ["T1"], "weekly_lessons": 1}],
    }
    base.update(overrides)
    return solver_app.SolveRequest(**base)


def test_payload_requires_class_and_subject():
    p = payload(lessons=[{"id": "bad"}])
    try:
        solver_app.validate_payload(p)
        assert False, "expected validation error"
    except ValueError as exc:
        assert "class and subject" in str(exc)


def test_payload_rejects_duration_longer_than_school_day_slots():
    p = payload(lessons=[{"class": "Grade 4", "subject": "Math", "duration": 4}])
    try:
        solver_app.validate_payload(p)
        assert False, "expected validation error"
    except ValueError as exc:
        assert "Invalid duration" in str(exc)


def test_teacher_allow_list_blocks_unlisted_periods():
    availability = {"T1": ["Monday|08:00–08:40"]}
    assert solver_app._availability_allows(availability, "T1", "Monday", "08:00–08:40")
    assert not solver_app._availability_allows(availability, "T1", "Monday", "08:40–09:20")
    assert solver_app._availability_allows(availability, "T2", "Monday", "08:40–09:20")


def test_solver_requires_ortools_dependency_when_not_installed():
    if solver_app.cp_model is not None:
        return
    try:
        solver_app.solve(payload())
        assert False, "expected missing dependency error"
    except RuntimeError as exc:
        assert "OR-Tools is not installed" in str(exc)


def test_cp_sat_places_double_periods_consecutively_when_available():
    if solver_app.cp_model is None:
        import pytest
        pytest.skip("OR-Tools is installed by the timetable-solver deployment requirements")
    p = payload(lessons=[{"id": "G4-SCI-1", "class": "Grade 4", "subject": "Science", "teacherIds": ["T1"], "weekly_lessons": 1, "duration": 2}])
    result = solver_app.solve(p)
    assert result["tasks_scheduled"] == 1
    rows = result["lessons"]
    assert len(rows) == 2
    assert rows[0]["day"] == rows[1]["day"]
    assert rows[0]["block_id"] == rows[1]["block_id"]
    assert rows[0]["block_position"] == 1 and rows[1]["block_position"] == 2
