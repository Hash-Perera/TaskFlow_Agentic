# TASK-003 — Backend API Tests

## Goal

Verify the TaskFlow backend API against documented acceptance criteria and API behavior.

## Owner

Testing Agent

## Scope

Primary scope:

```text
backend/taskflow-api/test/**
backend/taskflow-api/**/*.spec.ts
```

Production code should not be modified unless the orchestrator explicitly approves a confirmed production defect fix.

## Source of Truth

Tests must follow:

* `docs/acceptance-criteria.md`
* `docs/api-contract.md`

Tests must not simply mirror current production behavior if that behavior violates the documented contract.

## Required Test Areas

### Create Task

Test:

* valid task
* explicit status
* missing title
* empty title
* whitespace-only title
* title > 150
* description > 1000
* invalid status
* unknown input property

### Retrieve Tasks

Test:

* all tasks
* empty collection
* existing task
* invalid ObjectId
* missing task

### Update Task

Test:

* update title
* update description
* update status
* partial update
* invalid title
* invalid status
* invalid ObjectId
* missing task

### Delete Task

Test:

* delete existing task
* invalid ObjectId
* missing task
* deleted task is no longer returned

## Testing Rule

Do not weaken assertions simply to make tests pass.

If implementation differs from the approved API contract:

1. report the inconsistency
2. identify the relevant acceptance criterion
3. do not silently change the test expectation

## Verification

Run:

```bash
npm test
```

and any relevant e2e test command if configured.

## Completion Report

Report:

* tests added/changed
* test result
* production defects discovered
* contract mismatches
* assumptions
* unresolved issues
