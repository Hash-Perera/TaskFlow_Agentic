# TASK-002 — Frontend Task UI

## Goal

Implement the React TaskFlow UI against the documented REST API.

## Owner

Frontend Agent

## Scope

May modify:

```text
frontend/taskflow-web/**
```

Must not modify:

```text
backend/**
docs/**
AGENTS.md
```

## Important Dependency Rule

The frontend must implement against:

```text
docs/api-contract.md
```

It must not depend on reading unfinished backend implementation details.

## Required Functionality

Implement:

* display all tasks
* create task
* edit task
* update task status
* delete task
* loading state
* API error state
* empty state

## Target Structure

Recommended:

```text
src/
├── api/
│   └── tasksApi.ts
├── components/
│   ├── TaskForm.tsx
│   ├── TaskList.tsx
│   └── TaskCard.tsx
├── types/
│   └── task.ts
├── App.tsx
└── main.tsx
```

Small justified adjustments are allowed.

## API Rules

Use:

```text
VITE_API_BASE_URL
```

for backend configuration.

Do not duplicate full backend URLs in components.

Public task identifiers use:

```text
id
```

not:

```text
_id
```

## Task Status

Exactly:

```text
Pending
InProgress
Completed
```

## Type Safety

Define reusable TypeScript types for:

* Task
* TaskStatus
* CreateTaskInput
* UpdateTaskInput

## UI Requirements

The user should be able to:

* see existing tasks
* add a task
* edit a task
* change task status
* delete a task

The UI must provide:

* loading feedback
* error feedback
* empty-list feedback

## Out of Scope

Do not add:

* Redux
* Zustand
* React Query
* authentication
* routing libraries
* UI frameworks unless already present and necessary

Keep the UI simple.

## Verification

Run:

```bash
npm run build
```

If frontend tests already exist and are relevant, run them as well.

## Completion Report

Report:

* files changed
* implementation summary
* dependencies changed
* build result
* assumptions
* unresolved issues
* scope confirmation
