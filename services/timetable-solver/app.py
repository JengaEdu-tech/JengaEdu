"""JengaEdu timetable optimization service using Google OR-Tools CP-SAT.

The service is intentionally stateless. Authentication and school authorization
are enforced by the Supabase Edge Function before a request reaches this API.
"""
from __future__ import annotations

import os
import time
from collections import defaultdict
from typing import Any

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

try:
    from ortools.sat.python import cp_model
except ImportError:  # allows health/docs to load before dependencies are installed
    cp_model = None

app = FastAPI(title="JengaEdu Timetable Solver", version="5.0.0")


class SolveRequest(BaseModel):
    school_id: str
    year: str
    term: str
    days: list[str] = Field(min_length=1)
    slots: list[str] = Field(min_length=1)
    lessons: list[dict[str, Any]] = Field(default_factory=list)
    fixed: list[dict[str, Any]] = Field(default_factory=list)
    teacher_availability: dict[str, Any] = Field(default_factory=dict)
    rooms: list[dict[str, Any]] = Field(default_factory=list)
    options: dict[str, Any] = Field(default_factory=dict)


def _availability_allows(availability: dict[str, Any], teacher_id: str, day: str, slot: str) -> bool:
    """No entry means unrestricted; an entry is an allow-list of day|slot keys."""
    raw = availability.get(teacher_id)
    if raw is None:
        return True
    if isinstance(raw, dict):
        day_slots = raw.get(day)
        if day_slots is None:
            return False
        return slot in day_slots
    if isinstance(raw, list):
        return f"{day}|{slot}" in raw
    return False


def validate_payload(payload: SolveRequest) -> None:
    if len(set(payload.days)) != len(payload.days):
        raise ValueError("days contains duplicate values")
    if len(set(payload.slots)) != len(payload.slots):
        raise ValueError("slots contains duplicate values")
    if not payload.lessons:
        raise ValueError("No weekly lesson requirements were supplied")
    if len(payload.days) > 7 or len(payload.slots) > 24:
        raise ValueError("The solver accepts at most 7 school days and 24 periods per day")
    if len(payload.lessons) > 500 or len(payload.fixed) > 5000 or len(payload.rooms) > 200:
        raise ValueError("Timetable request exceeds the supported input size")
    total_units = sum(max(0, min(20, int(x.get("weekly_lessons", 1)))) for x in payload.lessons)
    if total_units > 1500:
        raise ValueError("Timetable request contains too many weekly lesson units")
    for i, lesson in enumerate(payload.lessons):
        if not lesson.get("class") or not lesson.get("subject"):
            raise ValueError(f"Lesson requirement {i + 1} needs class and subject")
        duration = int(lesson.get("duration", 1))
        if duration < 1 or duration > len(payload.slots):
            raise ValueError(f"Invalid duration for {lesson.get('class')} / {lesson.get('subject')}")


def solve(payload: SolveRequest) -> dict[str, Any]:
    if cp_model is None:
        raise RuntimeError("OR-Tools is not installed. Install services/timetable-solver/requirements.txt")
    validate_payload(payload)
    started = time.monotonic()
    model = cp_model.CpModel()
    days, slots = payload.days, payload.slots
    slot_index = {value: i for i, value in enumerate(slots)}
    day_index = {value: i for i, value in enumerate(days)}
    rooms = [r for r in payload.rooms if r.get("active", True)]
    availability = payload.teacher_availability or {}
    teacher_limits = payload.options.get("teacher_limits", {}) or {}

    # Existing lessons outside the regeneration target and protected lessons
    # reserve their resources and are never moved by this optimization run.
    fixed_occupancy: dict[tuple[str, str, str], set[str]] = defaultdict(set)
    for row in payload.fixed:
        d, sl = str(row.get("day", "")), str(row.get("time", ""))
        if d not in day_index or sl not in slot_index:
            continue
        class_resource = f"group:{row.get('groupId')}" if row.get("groupId") else row.get("class")
        for resource, value in (("class", class_resource), ("teacher", row.get("teacherId")), ("room", row.get("room"))):
            if value:
                fixed_occupancy[(resource, str(value), d)].add(sl)
        for learner in row.get("learnerIds") or []:
            fixed_occupancy[("learner", str(learner), d)].add(sl)

    # Expand weekly counts into independent units. duration=2 creates a true
    # consecutive double-period interval within one school day.
    tasks: list[dict[str, Any]] = []
    for req in payload.lessons:
        count = max(0, min(20, int(req.get("weekly_lessons", 1))))
        for ordinal in range(count):
            tasks.append({**req, "unit": ordinal + 1, "duration": int(req.get("duration", 1))})
    if not tasks:
        raise ValueError("No schedulable lesson units were generated")

    # Each assignment option represents a task, day, start slot, teacher and room.
    variables: dict[int, list[dict[str, Any]]] = defaultdict(list)
    resource_at_slot: dict[tuple[str, str, str, str], list[Any]] = defaultdict(list)
    day_vars: dict[tuple[int, str], Any] = {}
    unassigned_vars: dict[int, Any] = {}
    teacher_slot_vars: dict[tuple[str, str, str], list[Any]] = defaultdict(list)
    objective: list[Any] = []
    option_count = 0

    for ti, task in enumerate(tasks):
        duration = int(task["duration"])
        class_name = str(task["class"])
        learner_ids = [str(x) for x in task.get("learnerIds", [])]
        teacher_ids = [str(x) for x in (task.get("teacherIds") or []) if x]
        class_size = int(task.get("class_size", len(learner_ids)))
        room_options: list[dict[str, Any] | None]
        if task.get("room_required"):
            room_options = [r for r in rooms if int(r.get("capacity") or 0) >= class_size]
        else:
            room_options = [None] + [r for r in rooms if int(r.get("capacity") or 0) >= class_size]
        if not room_options:
            room_options = []

        by_day: dict[str, list[Any]] = defaultdict(list)
        for di, day in enumerate(days):
            for si in range(0, len(slots) - duration + 1):
                occupied_slots = slots[si:si + duration]
                for teacher_id in teacher_ids:
                    if teacher_id and any(not _availability_allows(availability, teacher_id, day, sl) for sl in occupied_slots):
                        continue
                    class_resource = f"group:{task.get('groupId')}" if task.get("groupId") else class_name
                    if any(sl in fixed_occupancy[("class", class_resource, day)] for sl in occupied_slots):
                        continue
                    if teacher_id and any(sl in fixed_occupancy[("teacher", teacher_id, day)] for sl in occupied_slots):
                        continue
                    if any(any(sl in fixed_occupancy[("learner", learner, day)] for sl in occupied_slots) for learner in learner_ids):
                        continue
                    for room in room_options:
                        room_name = str(room.get("name") or room.get("id")) if room else ""
                        if room_name and any(sl in fixed_occupancy[("room", room_name, day)] for sl in occupied_slots):
                            continue
                        var = model.NewBoolVar(f"x_{ti}_{di}_{si}_{len(variables[ti])}")
                        option = {"var": var, "day": day, "start": si, "slots": occupied_slots,
                                  "teacher_id": teacher_id, "room": room_name}
                        variables[ti].append(option)
                        by_day[day].append(var)
                        option_count += 1
                        if option_count > 250000:
                            raise ValueError("Timetable model is too large. Reduce class count, candidate teachers or room resources.")
                        for sl in occupied_slots:
                            resource_at_slot[("class", class_resource, day, sl)].append(var)
                            if teacher_id:
                                resource_at_slot[("teacher", teacher_id, day, sl)].append(var)
                                teacher_slot_vars[(teacher_id, day, sl)].append(var)
                            if room_name:
                                resource_at_slot[("room", room_name, day, sl)].append(var)
                            for learner in learner_ids:
                                resource_at_slot[("learner", learner, day, sl)].append(var)
                        preferred_room = str(task.get("preferred_room") or "")
                        if room is None:
                            objective.append(var * (3 if preferred_room else 2))
                        elif preferred_room and room_name != preferred_room:
                            objective.append(var * 1)
        unassigned = model.NewBoolVar(f"unassigned_{ti}")
        unassigned_vars[ti] = unassigned
        model.Add(sum(o["var"] for o in variables[ti]) + unassigned == 1)
        objective.append(unassigned * 1_000_000)
        for day, vars_for_day in by_day.items():
            used = model.NewBoolVar(f"day_{ti}_{day_index[day]}")
            model.Add(sum(vars_for_day) == used)
            day_vars[(ti, day)] = used

    # No resource may be used by two assignments at the same day/period.
    for vars_for_resource in resource_at_slot.values():
        if len(vars_for_resource) > 1:
            model.Add(sum(vars_for_resource) <= 1)

    # Optional school-configured teacher workload and consecutive-period limits.
    for teacher_id, limits in teacher_limits.items():
        if not isinstance(limits, dict):
            continue
        weekly_limit = int(limits.get("max_weekly_periods", 0) or 0)
        consecutive_limit = int(limits.get("max_consecutive_periods", 0) or 0)
        if weekly_limit > 0:
            assigned_periods = []
            for day in days:
                for slot in slots:
                    assigned_periods.extend(teacher_slot_vars.get((str(teacher_id), day, slot), []))
            fixed_count = sum(len(fixed_occupancy[("teacher", str(teacher_id), day)]) for day in days)
            if assigned_periods or fixed_count:
                model.Add(sum(assigned_periods) + fixed_count <= weekly_limit)
        if consecutive_limit > 0:
            window = consecutive_limit + 1
            for day in days:
                for start in range(0, len(slots) - window + 1):
                    window_slots = slots[start:start + window]
                    terms = []
                    fixed_count = 0
                    for slot in window_slots:
                        terms.extend(teacher_slot_vars.get((str(teacher_id), day, slot), []))
                        if slot in fixed_occupancy[("teacher", str(teacher_id), day)]:
                            fixed_count += 1
                    if terms or fixed_count:
                        model.Add(sum(terms) + fixed_count <= consecutive_limit)

    # Soft preference: spread the same class/subject across different days.
    if payload.options.get("spread_subjects", True):
        by_subject: dict[tuple[str, str], list[int]] = defaultdict(list)
        for ti, task in enumerate(tasks):
            by_subject[(str(task["class"]), str(task["subject"]))].append(ti)
        for task_ids in by_subject.values():
            for pos, a in enumerate(task_ids):
                for b in task_ids[pos + 1:]:
                    for day in days:
                        va, vb = day_vars.get((a, day)), day_vars.get((b, day))
                        if va is None or vb is None:
                            continue
                        same_day = model.NewBoolVar(f"spread_{a}_{b}_{day_index[day]}")
                        model.Add(same_day <= va)
                        model.Add(same_day <= vb)
                        model.Add(same_day >= va + vb - 1)
                        objective.append(same_day * 30)

    model.Minimize(sum(objective))
    solver = cp_model.CpSolver()
    solver.parameters.max_time_in_seconds = max(1.0, min(60.0, float(payload.options.get("time_limit_seconds", 20))))
    solver.parameters.num_search_workers = max(1, min(8, int(payload.options.get("workers", 8))))
    status = solver.Solve(model)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        raise ValueError("The constraint model is infeasible. Review locked lessons, teacher availability, class sizes and weekly lesson requirements.")

    scheduled: list[dict[str, Any]] = []
    unplaced: list[dict[str, Any]] = []
    for ti, task in enumerate(tasks):
        chosen = next((o for o in variables[ti] if solver.Value(o["var"])), None)
        if not chosen:
            reason = "No eligible teacher is assigned to this lesson requirement" if not task.get("teacherIds") else "No conflict-free slot remained under the hard constraints"
            unplaced.append({"class": task["class"], "subject": task["subject"], "unit": task["unit"],
                             "reason": reason})
            continue
        block_id = f"{task['class']}::{task['subject']}::{task['unit']}"
        for offset, slot in enumerate(chosen["slots"]):
            scheduled.append({"lesson_id": block_id, "class": task["class"], "subject": task["subject"],
                              "teacher_id": chosen["teacher_id"], "room": chosen["room"],
                              "day": chosen["day"], "time": slot, "duration": 1,
                              "block_id": block_id, "block_position": offset + 1,
                              "group_id": task.get("groupId") or "",
                              "learner_ids": [str(x) for x in task.get("learnerIds", [])],
                              "room_required": bool(task.get("room_required", False))})

    return {"status": "OPTIMAL" if status == cp_model.OPTIMAL else "FEASIBLE",
            "lessons": scheduled, "unplaced": unplaced,
            "wall_time_seconds": solver.WallTime(), "objective_value": solver.ObjectiveValue(),
            "tasks_requested": len(tasks), "tasks_scheduled": len(tasks) - len(unplaced),
            "solver": "Google OR-Tools CP-SAT", "elapsed_seconds": round(time.monotonic() - started, 3)}


@app.get("/health")
def health():
    return {"ok": True, "solver_available": cp_model is not None, "version": "5.0.0"}


@app.post("/solve")
def solve_endpoint(payload: SolveRequest, x_jenga_solver_key: str | None = Header(default=None)):
    expected = os.getenv("TIMETABLE_SOLVER_API_KEY")
    if not expected or x_jenga_solver_key != expected:
        raise HTTPException(status_code=401, detail="Unauthorized solver request")
    try:
        return solve(payload)
    except (ValueError, RuntimeError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
