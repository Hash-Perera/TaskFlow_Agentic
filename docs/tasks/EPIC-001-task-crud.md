# EPIC-001 — Task CRUD

## Goal

Implement the complete TaskFlow task-management CRUD flow across backend, frontend, testing, and review.

## Functional Scope

The system must support:

* create task
* retrieve all tasks
* retrieve one task
* update task
* update task status
* delete task

## Shared Contracts

All implementation must follow:

* `docs/requirements.md`
* `docs/acceptance-criteria.md`
* `docs/api-contract.md`
* `docs/architecture.md`
* `AGENTS.md`

## Workstreams

This epic is divided into:

1. TASK-001 — Backend CRUD API
2. TASK-002 — Frontend Task UI
3. TASK-003 — Backend API Tests
4. TASK-004 — Integration Review

## Orchestration Rule

Independent tasks may run in parallel.

Tasks that depend on unfinished implementation must wait for the required synchronization point.

## Definition of Done

The epic is complete when:

* backend CRUD works
* frontend works against the agreed API
* backend tests pass
* frontend build passes
* contract compliance is verified
* reviewer findings are resolved
* human review approves the integrated result
