# ORCHESTRATION-001 — TaskFlow CRUD

## Objective

Coordinate the parallel implementation of the TaskFlow CRUD epic using isolated Codex agent worktrees.

## Shared Baseline

All worker branches must start from the same approved `main` commit.

## Workers

### Worker A — Backend

Task:

`TASK-001-backend-crud.md`

Branch:

`agent/task-001-backend-crud`

Worktree:

`TaskFlow-agent-backend`

Primary ownership:

`backend/taskflow-api/**`

Initial state:

READY

---

### Worker B — Frontend

Task:

`TASK-002-frontend-ui.md`

Branch:

`agent/task-002-frontend-ui`

Worktree:

`TaskFlow-agent-frontend`

Primary ownership:

`frontend/taskflow-web/**`

Initial state:

READY

---

### Worker C — Testing

Task:

`TASK-003-backend-tests.md`

Branch:

`agent/task-003-tests`

Worktree:

`TaskFlow-agent-tests`

Primary ownership:

* `backend/taskflow-api/test/**`
* backend test files explicitly required by the task

Initial state:

READY for test design.

Test execution may remain blocked until backend implementation is available.

---

## Dependencies

Backend CRUD:

Depends on approved shared documentation and existing Task model/module structure.

Frontend UI:

Depends on approved shared API contract.

Testing:

Test design depends on acceptance criteria and API contract.

Executable backend tests depend on backend implementation.

Reviewer:

Depends on integrated backend, frontend, and test results.

---

## Parallel Execution Wave 1

Start concurrently:

* Backend Agent
* Frontend Agent
* Test Design Agent

## Synchronization Point A

When Backend Agent and Test Design Agent are ready:

* make backend implementation available to the testing workflow
* execute relevant tests
* report implementation defects separately from test defects

Frontend may continue independently if unfinished.

## Synchronization Point B

Before independent review:

Required:

* backend implementation approved/integrated
* frontend implementation approved/integrated
* relevant tests executed
* known failures classified

## Review Wave

Run independent Reviewer Agent using `TASK-004-review.md`.

Reviewer is read-only.

## Fix Wave

Only human-approved findings are assigned to implementation/fix agents.

Do not automatically implement every reviewer suggestion.

## Shared File Governance

Worker agents must not modify:

* `AGENTS.md`
* `docs/api-contract.md`
* `docs/architecture.md`
* `docs/requirements.md`
* `docs/acceptance-criteria.md`

If a shared contract change is required:

1. worker reports blocker
2. orchestrator reviews proposal
3. change is made on `main`
4. change is committed
5. impacted workers synchronize with updated `main`
6. work resumes

## Task States

Use:

* BACKLOG
* READY
* RUNNING
* BLOCKED
* REVIEW
* DONE

Initial state:

| Task                    | State   |
| ----------------------- | ------- |
| TASK-001 Backend CRUD   | DONE    |
| TASK-002 Frontend UI    | DONE    |
| TASK-003 Test Design    | DONE    |
| TASK-003 Test Execution | DONE    |
| TASK-004 Review         | REVIEW  |

## Integration Gate

Worker output must not enter `main` solely because the agent reports success.

Before integration:

1. inspect scope
2. inspect diff
3. confirm contract compliance
4. confirm architecture compliance
5. review verification results
6. perform human approval

## Completion

The orchestration run is complete when:

* all required worker tasks are DONE
* integrated builds succeed
* required tests pass
* blocking review findings are resolved
* human approval is complete
