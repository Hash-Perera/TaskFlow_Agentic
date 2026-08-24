# TaskFlow Requirements

## 1. Project Purpose

TaskFlow is a small task management application created to practice
agentic software development, parallel AI agents, orchestration,
worktree isolation, automated verification, and human-in-the-loop review.

The application itself should remain intentionally simple.

---

## 2. Technology Stack

### Backend
- NestJS
- TypeScript
- Mongoose
- MongoDB

### Frontend
- React
- TypeScript
- Vite

### Testing
- Jest
- NestJS testing utilities

---

## 3. Functional Requirements

### FR-01 Create Task

A user must be able to create a task.

A task contains:

- id
- title
- description
- status
- createdAt
- updatedAt

Rules:

- title is required
- title must not contain only whitespace
- title maximum length is 150 characters
- description is optional
- description maximum length is 1000 characters
- status is optional when creating a task
- default status is Pending

---

### FR-02 View All Tasks

A user must be able to retrieve all tasks.

Each returned task must contain:

- id
- title
- description
- status
- createdAt
- updatedAt

The MongoDB `_id` field must not be exposed as the public API identifier.

---

### FR-03 View One Task

A user must be able to retrieve a task by its id.

If the id does not belong to an existing task:

- return HTTP 404

If the supplied id is not a valid MongoDB ObjectId:

- return HTTP 400

---

### FR-04 Update Task

A user must be able to update one or more of:

- title
- description
- status

Validation rules must also apply during updates.

If the task does not exist:

- return HTTP 404

---

### FR-05 Delete Task

A user must be able to delete a task by id.

If the task does not exist:

- return HTTP 404

After deletion, the task must no longer appear in task queries.

---

## 4. Task Statuses

Supported statuses are:

- Pending
- InProgress
- Completed

No other status value is valid.

---

## 5. API Requirements

The backend must provide:

GET /api/tasks

GET /api/tasks/:id

POST /api/tasks

PATCH /api/tasks/:id

DELETE /api/tasks/:id

---

## 6. Frontend Requirements

The frontend must provide:

- task list
- create task form
- edit task capability
- delete task capability
- status update capability
- loading state
- error state
- empty-state message when there are no tasks

The frontend must interact with the backend through a dedicated API client module.

API URLs must not be duplicated across components.

---

## 7. Validation Requirements

Backend validation is mandatory.

Frontend validation may improve usability but must never replace backend validation.

Invalid input must not reach MongoDB persistence.

---

## 8. Error Handling Requirements

Expected API behavior:

### Invalid request
HTTP 400

### Task not found
HTTP 404

### Successful creation
HTTP 201

### Successful retrieval/update
HTTP 200

### Successful deletion
HTTP 204

Unexpected server errors should not expose stack traces or sensitive implementation details to API clients.

---

## 9. Persistence Requirements

Task data must be persisted in MongoDB using Mongoose.

Mongoose timestamps should be used for:

- createdAt
- updatedAt

Database connection strings must come from environment configuration.

No credentials or secrets may be committed to Git.

---

## 10. Non-Functional Requirements

### Maintainability

- Follow normal NestJS conventions.
- Keep controllers thin.
- Put application logic in services.
- Avoid unnecessary architecture.

### Security

- Validate all external input.
- Do not hardcode secrets.
- Do not expose raw database errors unnecessarily.
- Do not expose MongoDB implementation details unnecessarily.

### Performance

For the initial project:

- avoid unnecessary database queries
- avoid unnecessary Mongoose populate operations
- do not load unrelated collections

Advanced optimization is outside the initial project scope.

### Testability

Important backend behavior must be covered by automated tests.

---

## 11. Out of Scope

The initial version will NOT include:

- authentication
- authorization
- user accounts
- role management
- notifications
- file uploads
- WebSockets
- microservices
- queues
- Redis
- Redux
- CQRS
- event sourcing
- production deployment

These may be introduced later only when they support a specific
agentic-development exercise.

---

## 12. Definition of Done

A feature is considered complete only when:

1. Requirements are satisfied.
2. API contract is preserved.
3. Relevant build succeeds.
4. Relevant automated tests pass.
5. No unrelated files are changed.
6. Generated code has been reviewed.
7. Known assumptions and limitations are documented.
8. Human approval is given before merging.