# TaskFlow Acceptance Criteria

## AC-01 — Create a Valid Task

### Given

A valid request body:

```json
{
  "title": "Learn Codex",
  "description": "Practice agentic development"
}
```

### When

The client sends:

```http
POST /api/tasks
```

### Then

* Response status must be `201 Created`.
* A new task must be persisted in MongoDB.
* The response must contain the created task.
* The task must contain an `id`.
* The task must contain `createdAt`.
* The task must contain `updatedAt`.
* If `status` is not provided, it must default to `Pending`.
* The public response must expose `id`, not MongoDB `_id`.

---

## AC-02 — Create a Task with an Explicit Status

### Given

```json
{
  "title": "Build backend",
  "description": "Implement the NestJS API",
  "status": "InProgress"
}
```

### When

The client sends:

```http
POST /api/tasks
```

### Then

* Response status must be `201 Created`.
* The task must be persisted.
* The returned status must be `InProgress`.

---

## AC-03 — Reject a Missing Title

### Given

```json
{
  "description": "Task without a title"
}
```

### When

The client sends:

```http
POST /api/tasks
```

### Then

* Response status must be `400 Bad Request`.
* No task must be persisted.

---

## AC-04 — Reject an Empty Title

### Given

```json
{
  "title": ""
}
```

### When

The client sends:

```http
POST /api/tasks
```

### Then

* Response status must be `400 Bad Request`.
* No task must be persisted.

---

## AC-05 — Reject a Whitespace-Only Title

### Given

```json
{
  "title": "   "
}
```

### When

The client sends:

```http
POST /api/tasks
```

### Then

* Response status must be `400 Bad Request`.
* No task must be persisted.

---

## AC-06 — Reject a Title Longer Than 150 Characters

### Given

A task title containing more than 150 characters.

### When

The client sends:

```http
POST /api/tasks
```

### Then

* Response status must be `400 Bad Request`.
* No task must be persisted.

---

## AC-07 — Accept a 150-Character Title

### Given

A task title containing exactly 150 characters.

### When

The client sends:

```http
POST /api/tasks
```

### Then

* Response status must be `201 Created`.
* The task must be persisted.

---

## AC-08 — Description Is Optional

### Given

```json
{
  "title": "Task without description"
}
```

### When

The client sends:

```http
POST /api/tasks
```

### Then

* Response status must be `201 Created`.
* The task must be persisted successfully.

---

## AC-09 — Reject a Description Longer Than 1000 Characters

### Given

A task description containing more than 1000 characters.

### When

The client sends:

```http
POST /api/tasks
```

### Then

* Response status must be `400 Bad Request`.
* No task must be persisted.

---

## AC-10 — Default Task Status

### Given

```json
{
  "title": "Learn agentic development"
}
```

### When

The task is created without a `status`.

### Then

The stored and returned task status must be:

```text
Pending
```

---

## AC-11 — Accept Supported Status Values

The API must accept these status values:

```text
Pending
InProgress
Completed
```

For each supported value:

* Task creation must succeed.
* Task update must succeed.
* The stored value must match the requested value.

---

## AC-12 — Reject an Invalid Status

### Given

```json
{
  "title": "Invalid status test",
  "status": "Started"
}
```

### When

The client sends:

```http
POST /api/tasks
```

### Then

* Response status must be `400 Bad Request`.
* No task must be persisted.

---

## AC-13 — Reject Unexpected Properties

### Given

```json
{
  "title": "Test",
  "status": "Pending",
  "isAdmin": true
}
```

### When

The client sends the request to an endpoint that accepts task input.

### Then

The backend must reject properties that are not part of the supported task input contract.

Expected status:

```text
400 Bad Request
```

This assumes the NestJS validation configuration uses whitelist validation with unknown properties forbidden.

---

## AC-14 — Retrieve All Tasks

### Given

One or more tasks exist.

### When

The client sends:

```http
GET /api/tasks
```

### Then

* Response status must be `200 OK`.
* Response body must be an array.
* Every task must follow the documented public task structure.

Example:

```json
[
  {
    "id": "68abc123",
    "title": "Learn Codex",
    "description": "Practice agentic development",
    "status": "Pending",
    "createdAt": "2026-08-24T02:30:00.000Z",
    "updatedAt": "2026-08-24T02:30:00.000Z"
  }
]
```

---

## AC-15 — Retrieve Tasks When None Exist

### Given

There are no tasks in the database.

### When

The client sends:

```http
GET /api/tasks
```

### Then

* Response status must be `200 OK`.
* Response body must be:

```json
[]
```

An empty task collection must not result in `404`.

---

## AC-16 — Do Not Expose MongoDB `_id`

### Given

A task exists in MongoDB.

### When

The task is returned from any public API endpoint.

### Then

The public response must contain:

```json
{
  "id": "..."
}
```

and must not expose MongoDB's `_id` field as the public identifier.

---

## AC-17 — Retrieve One Existing Task

### Given

A task exists with a valid identifier.

### When

The client sends:

```http
GET /api/tasks/:id
```

### Then

* Response status must be `200 OK`.
* The correct task must be returned.
* The returned `id` must match the requested task.
* The response must follow the documented task response format.

---

## AC-18 — Reject an Invalid MongoDB ObjectId

### Given

An invalid identifier such as:

```text
not-a-valid-id
```

### When

The client sends:

```http
GET /api/tasks/not-a-valid-id
```

### Then

* Response status must be `400 Bad Request`.
* The application must not expose an internal Mongoose stack trace or raw database error.

---

## AC-19 — Return 404 for a Missing Task

### Given

A syntactically valid MongoDB ObjectId that does not correspond to a task.

### When

The client sends:

```http
GET /api/tasks/:id
```

### Then

Response status must be:

```text
404 Not Found
```

---

## AC-20 — Update a Task Title

### Given

An existing task.

### When

The client sends:

```http
PATCH /api/tasks/:id
```

with:

```json
{
  "title": "Updated task title"
}
```

### Then

* Response status must be `200 OK`.
* The title must be updated.
* Other task properties must remain unchanged unless explicitly supplied.
* `updatedAt` must reflect the update.

---

## AC-21 — Update a Task Description

### Given

An existing task.

### When

The client sends:

```http
PATCH /api/tasks/:id
```

with:

```json
{
  "description": "Updated task description"
}
```

### Then

* Response status must be `200 OK`.
* The description must be updated.
* Unspecified fields must remain unchanged.

---

## AC-22 — Update Task Status

### Given

An existing task with:

```text
Pending
```

### When

The client sends:

```http
PATCH /api/tasks/:id
```

with:

```json
{
  "status": "Completed"
}
```

### Then

* Response status must be `200 OK`.
* The status must become `Completed`.
* `updatedAt` must change.

---

## AC-23 — Support Partial Updates

### Given

An existing task.

### When

The client sends only one supported field:

```json
{
  "status": "InProgress"
}
```

### Then

The API must not require:

* title
* description
* other task fields

A `PATCH` operation must support partial modification.

---

## AC-24 — Reject Invalid Status During Update

### Given

An existing task.

### When

The client sends:

```json
{
  "status": "Finished"
}
```

to:

```http
PATCH /api/tasks/:id
```

### Then

* Response status must be `400 Bad Request`.
* The existing task must not be changed.

---

## AC-25 — Reject an Empty Title During Update

### Given

An existing task.

### When

The client sends:

```json
{
  "title": ""
}
```

### Then

* Response status must be `400 Bad Request`.
* The existing title must remain unchanged.

---

## AC-26 — Reject a Whitespace-Only Title During Update

### Given

An existing task.

### When

The client sends:

```json
{
  "title": "   "
}
```

### Then

* Response status must be `400 Bad Request`.
* The existing task must remain unchanged.

---

## AC-27 — Reject an Oversized Description During Update

### Given

An existing task.

### When

A description containing more than 1000 characters is submitted.

### Then

* Response status must be `400 Bad Request`.
* Existing persisted data must remain unchanged.

---

## AC-28 — Reject Invalid ObjectId During Update

### When

The client sends:

```http
PATCH /api/tasks/not-a-valid-id
```

### Then

Response status must be:

```text
400 Bad Request
```

---

## AC-29 — Return 404 When Updating a Missing Task

### Given

A valid MongoDB ObjectId that does not correspond to a task.

### When

The client sends:

```http
PATCH /api/tasks/:id
```

### Then

Response status must be:

```text
404 Not Found
```

---

## AC-30 — Delete an Existing Task

### Given

An existing task.

### When

The client sends:

```http
DELETE /api/tasks/:id
```

### Then

* Response status must be `204 No Content`.
* The task must be removed from MongoDB.
* The response must not contain a task body.

---

## AC-31 — Deleted Task Must No Longer Be Returned

### Given

A task was successfully deleted.

### When

The client subsequently sends:

```http
GET /api/tasks/:id
```

### Then

Response status must be:

```text
404 Not Found
```

The deleted task must also no longer appear in:

```http
GET /api/tasks
```

---

## AC-32 — Reject Invalid ObjectId During Delete

### When

The client sends:

```http
DELETE /api/tasks/not-a-valid-id
```

### Then

Response status must be:

```text
400 Bad Request
```

---

## AC-33 — Return 404 When Deleting a Missing Task

### Given

A valid MongoDB ObjectId that does not correspond to an existing task.

### When

The client sends:

```http
DELETE /api/tasks/:id
```

### Then

Response status must be:

```text
404 Not Found
```

---

# Frontend Acceptance Criteria

## AC-34 — Display Task List

### Given

Tasks are returned by the backend.

### When

The user opens TaskFlow.

### Then

The frontend must display the tasks.

Each task should visibly provide at least:

* title
* description when available
* status

---

## AC-35 — Display Empty State

### Given

The backend returns:

```json
[]
```

### When

The task list loads.

### Then

The frontend must display a clear empty-state message rather than rendering an error.

---

## AC-36 — Display Loading State

### Given

A request to the API is currently pending.

### Then

The frontend must provide a visible loading state.

---

## AC-37 — Display API Error State

### Given

A task request fails.

### Then

The frontend must display a user-understandable error state.

The UI must not expose raw server stack traces.

---

## AC-38 — Create Task from Frontend

### Given

The user enters valid task information.

### When

The user submits the create-task form.

### Then

* The frontend must send the correct `POST /api/tasks` request.
* The created task must appear in the UI after successful creation.
* The user must receive appropriate feedback if creation fails.

---

## AC-39 — Frontend Must Prevent Obviously Invalid Task Creation

### Given

The task title is missing or empty.

### When

The user attempts to submit the create form.

### Then

The frontend should prevent submission and show an appropriate validation message.

Backend validation remains mandatory regardless of frontend validation.

---

## AC-40 — Edit Task from Frontend

### Given

A task exists.

### When

The user edits its supported fields.

### Then

* The frontend must send the appropriate `PATCH /api/tasks/:id` request.
* The updated values must appear after a successful response.

---

## AC-41 — Change Status from Frontend

The user must be able to change a task between:

```text
Pending
InProgress
Completed
```

After a successful backend response, the new status must be reflected in the UI.

---

## AC-42 — Delete Task from Frontend

### Given

A task exists.

### When

The user chooses to delete it.

### Then

* The frontend must call `DELETE /api/tasks/:id`.
* After successful deletion, the task must disappear from the displayed list.
* An API failure must not silently remove the task from the UI.

---

## AC-43 — Centralized API Communication

Frontend components must not duplicate backend URLs throughout the codebase.

API communication must be handled through a dedicated API module such as:

```text
src/api/tasksApi.ts
```

---

## AC-44 — Type-Safe Task Contract

The React application must define a TypeScript representation of a task containing:

```text
id
title
description
status
createdAt
updatedAt
```

Supported task status values must be type-safe.

---

# Persistence and Configuration Acceptance Criteria

## AC-45 — MongoDB Persistence

Tasks created through the API must be persisted in MongoDB through Mongoose.

Application restart must not remove successfully persisted tasks.

---

## AC-46 — Mongoose Timestamps

Task documents must use Mongoose-managed timestamps.

The application must expose:

```text
createdAt
updatedAt
```

---

## AC-47 — Environment-Based Database Configuration

The MongoDB connection string must be obtained from environment configuration.

It must not be hardcoded into application source code.

Example development variable:

```env
MONGODB_URI=mongodb://localhost:27017/taskflow
```

---

## AC-48 — Secrets Must Not Be Committed

Files containing real secrets or environment-specific credentials must not be committed to Git.

The project may provide:

```text
.env.example
```

with safe placeholder/example configuration.

---

# Engineering Acceptance Criteria

## AC-49 — NestJS Responsibility Separation

The backend should follow the normal flow:

```text
Request
   ↓
Controller
   ↓
DTO validation
   ↓
Service
   ↓
Mongoose Model
   ↓
MongoDB
```

Controllers should not directly contain database persistence logic.

---

## AC-50 — DTO Validation

External create/update input must be represented by DTOs and validated using NestJS-compatible validation.

The backend must not rely only on frontend validation.

---

## AC-51 — Global Validation

NestJS must apply validation consistently to incoming requests.

The validation configuration should:

* transform input where appropriate
* whitelist known properties
* reject unsupported properties

---

## AC-52 — No Unnecessary Architecture

The initial implementation must not introduce unnecessary infrastructure such as:

* CQRS
* event sourcing
* microservices
* Redis
* message queues
* repository abstraction solely for abstraction's sake

unless the project requirements are explicitly changed.

---

## AC-53 — Backend Build Verification

After backend implementation changes:

```bash
npm run build
```

must complete successfully.

---

## AC-54 — Backend Automated Tests

Relevant automated tests must pass:

```bash
npm test
```

An agent must not claim tests passed unless it actually executed the test command.

---

## AC-55 — Frontend Build Verification

After frontend implementation changes:

```bash
npm run build
```

must complete successfully.

---

## AC-56 — No Unrelated Agent Changes

An agent assigned to a specific project area must not unnecessarily modify unrelated areas.

Examples:

Backend Agent:

```text
backend/**
```

should not modify frontend implementation without explicit authorization.

Frontend Agent:

```text
frontend/**
```

should not modify backend behavior to solve a frontend problem.

---

## AC-57 — API Contract Must Not Be Changed Silently

If implementation conflicts with the agreed API contract, an agent must report the conflict.

The agent must not silently alter:

* endpoint paths
* status values
* request structures
* response structures
* expected status codes

simply because another implementation seems easier.

---

## AC-58 — Human Review Before Merge

Agent-generated implementation must be reviewed before it is merged into the primary branch.

Successful compilation or passing tests alone are not sufficient approval.

Human review should consider:

* correctness
* maintainability
* security
* data integrity
* architecture
* unnecessary changes
* quality of tests

---

# Definition of Done

A TaskFlow feature is considered complete only when all applicable conditions below are satisfied:

1. The relevant functional requirement is implemented.
2. Applicable acceptance criteria pass.
3. API behavior follows the agreed contract.
4. Backend input validation is present where required.
5. Relevant build commands succeed.
6. Relevant automated tests succeed.
7. No unrelated files were modified.
8. No secrets were introduced.
9. Agent-generated code has been reviewed.
10. Known assumptions and limitations have been reported.
11. Review findings classified as blocking have been resolved.
12. A human engineer approves the change before merge.
