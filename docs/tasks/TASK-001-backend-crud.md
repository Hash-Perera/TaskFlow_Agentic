# TASK-001 — Backend CRUD API

## Goal

Implement TaskFlow CRUD REST endpoints in the NestJS backend.

## Owner

Backend Agent

## Scope

May modify:

```text
backend/taskflow-api/**
```

Must not modify:

```text
frontend/**
docs/**
AGENTS.md
```

## Required Functionality

Implement:

```text
GET    /api/tasks
GET    /api/tasks/:id
POST   /api/tasks
PATCH  /api/tasks/:id
DELETE /api/tasks/:id
```

## Required Components

Expected components include:

* `TasksController`
* `TasksService`
* registration in the appropriate NestJS module
* ObjectId validation behavior
* not-found behavior
* public response mapping from `_id` to `id`

## Contract

Follow:

```text
docs/api-contract.md
```

exactly.

Do not introduce new endpoint names, response shapes, or task status values.

## Important Behavior

### Create

* valid task → 201
* missing/invalid title → 400
* invalid status → 400
* default status → Pending

### Retrieve

* all tasks → 200 array
* empty collection → 200 []
* existing id → 200
* invalid ObjectId → 400
* missing task → 404

### Update

* partial update supported
* invalid ObjectId → 400
* missing task → 404
* invalid input → 400

### Delete

* existing task → 204
* invalid ObjectId → 400
* missing task → 404

## Architecture Constraints

Approved flow:

```text
Controller
→ DTO validation
→ Service
→ Mongoose
```

Do not introduce:

* repository abstraction
* CQRS
* event sourcing
* additional architecture layers

## Verification

Run from backend project:

```bash
npm run build
npm test
```

## Completion Report

Report:

* files changed
* implementation summary
* packages changed
* build result
* test result
* assumptions
* unresolved issues
* scope confirmation
