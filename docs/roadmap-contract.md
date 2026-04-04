# Roadmap Contract

`ROADMAP.json` is the only canonical active roadmap for this project.

This is an execution contract, not an essay.
If a roadmap is active, it must be structured JSON and it must satisfy the project roadmap schema.

## Rules

- Active roadmaps use JSON only.
- Markdown roadmap files are historical snapshots or supporting notes.
- Historical snapshots live under `docs/archive/roadmaps/`.
- Tasks are done only when their acceptance criteria and evidence requirements are satisfied.

## Update Discipline

- Update `updated_at` whenever task state changes.
- Keep exactly one canonical active file: `ROADMAP.json`.
- Keep `current_focus` pointed at the next execution slice, not a stale milestone.
- If a markdown roadmap is retired, archive it with an ISO date in the filename.

## Field Meanings

- `baseline`: completed facts already true in the codebase
- `rules`: always-on execution constraints
- `execution_order`: the intended main execution order
- `current_focus`: the immediate slice that should move next
- `acceptance_criteria`: what must be true before a task is done
- `evidence_required`: what proof must exist before a task is done

## Why JSON

JSON is useful here because it removes ambiguity about:

- status
- dependencies
- acceptance criteria
- evidence requirements
- current focus
