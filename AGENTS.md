# TaskFlow Agent Instructions

## 1. Project Purpose

TaskFlow is a small task-management application used to practice professional AI-assisted and agentic software development.

The project intentionally focuses on:

* agent task decomposition
* parallel agent development
* orchestration
* Git worktree isolation
* contract-first development
* automated verification
* AI-assisted code review
* human-in-the-loop approval

The application itself should remain intentionally simple.

---

## 2. Technology Stack

### Backend

* NestJS
* TypeScript
* Mongoose
* MongoDB
* class-validator
* class-transformer
* @nestjs/config
* Jest

### Frontend

* React
* TypeScript
* Vite

---

## 3. Repository Structure

Primary repository areas:

```text
backend/
frontend/
docs/
```

Backend implementation is located under:

```text
backend/
```

Frontend implementation is located under:

```text
frontend/
```

Project requirements and architecture documentation are located under:

```text
docs/
```

---

## 4. Important Documentation

Before modifying relevant functionality, inspect the appropriate documents.

### Business requirements

```text
docs/requirements.md
```

Defines what TaskFlow must do.

### Acceptance criteria

```text
docs/acceptance-criteria.md
```

Defines how required behavior is verified.

### API contract

```text
docs/api-contract.md
```

Defines communication between backend, frontend, and automated tests.

### Architecture

```text
docs/architecture.md
```

Defines approved application architecture and engineering boundaries.

---

## 5. Source-of-Truth Rules

Use the following precedence when implementation assumptions conflict:

1. Explicit task instructions from the human orchestrator
2. Approved API contract
3. Approved requirements
4. Approved architecture
5. Existing implementation conventions

If two approved documents appear to conflict:

* do not guess
* do not silently choose one
* report the conflict
* explain the impact
* wait for human direction when the conflict affects behavior

---

## 6. Architecture Rules

Approved backend flow:

```text
HTTP Request
→ Controller
→ DTO Validation
→ Service
→ Mongoose Model
→ MongoDB
```

Approved frontend flow:

```text
React Components
→ Task API Client
→ REST API
```

Do not introduce unnecessary architectural layers.

Do not introduce any of the following unless explicitly approved:

* custom repository abstraction
* CQRS
* event sourcing
* microservices
* message queues
* Redis
* GraphQL
* WebSockets
* Redux
* complex domain-driven design layers
* unit-of-work abstraction

Prefer the simplest implementation that satisfies the current requirements.

---

## 7. Backend Engineering Rules

When modifying backend code:

* follow NestJS module/controller/provider conventions
* use dependency injection
* keep controllers thin
* place application behavior in services
* use DTO classes for external input
* use `class-validator` for request validation
* use Mongoose through `@nestjs/mongoose`
* use asynchronous APIs for I/O
* validate MongoDB ObjectIds before database operations when required by the API contract
* return correct HTTP status codes
* preserve the public API contract
* do not expose internal MongoDB implementation details unnecessarily
* do not expose `_id` as the public task identifier
* do not hardcode database connection strings
* do not commit secrets

---

## 8. Validation Rules

Backend validation is mandatory.

Global NestJS validation should provide behavior equivalent to:

```typescript
new ValidationPipe({
  whitelist: true,
  forbidNonWhitelisted: true,
  transform: true,
})
```

Unsupported request properties must be rejected.

Frontend validation may improve user experience but does not replace backend validation.

---

## 9. Mongoose Rules

When working with MongoDB/Mongoose:

* define schemas explicitly
* use Mongoose timestamps for `createdAt` and `updatedAt`
* constrain task status using the approved status values
* avoid unnecessary `populate`
* avoid unnecessary database queries
* do not expose raw Mongoose/database errors to API clients
* do not hardcode MongoDB credentials or connection strings

Supported task statuses:

```text
Pending
InProgress
Completed
```

Do not introduce additional statuses without approved contract changes.

---

## 10. Frontend Engineering Rules

When modifying frontend code:

* use React function components
* use TypeScript
* use the public API contract defined in `docs/api-contract.md`
* centralize API communication
* do not duplicate backend URLs across components
* use `VITE_API_BASE_URL` for backend configuration
* maintain type-safe task models
* handle loading states
* handle API failures
* provide an empty-state UI
* keep components focused
* do not introduce global state-management libraries unless explicitly approved

Frontend components must use:

```text
id
```

and must not depend on MongoDB:

```text
_id
```

---

## 11. API Contract Governance

The API contract is defined by:

```text
docs/api-contract.md
```

Implementation agents must not silently change:

* endpoint paths
* HTTP methods
* request fields
* response fields
* status values
* error behavior
* expected HTTP status codes

If a contract change appears necessary:

1. identify the conflicting requirement
2. explain why the existing contract is insufficient
3. describe the proposed change
4. describe affected agents/components
5. wait for human approval

---

## 12. Architecture Governance

Implementation agents do not independently own architecture decisions.

If the approved architecture prevents a required implementation:

1. explain the current limitation
2. propose the smallest architecture change
3. explain consequences
4. do not perform the architecture change without approval

Do not describe unnecessary architectural additions as improvements merely because they are common patterns.

---

## 13. Agent Scope

Agents should primarily modify only the scope assigned in their task.

Typical ownership:

### Backend Agent

```text
backend/**
```

### Frontend Agent

```text
frontend/**
```

### Testing Agent

Testing-related files explicitly assigned by the orchestrator.

### Reviewer Agent

Read-only unless explicitly assigned fixes.

Shared files such as:

```text
docs/api-contract.md
docs/architecture.md
AGENTS.md
```

must not be modified unless the task explicitly grants permission.

---

## 14. Scope Expansion Rule

If completing a task appears to require changes outside assigned scope:

Do not immediately modify the additional area.

Instead:

1. identify the required out-of-scope change
2. explain why it is needed
3. explain the likely impact
4. request approval or report it as a blocker

Small changes strictly required for compilation may be proposed, but should still be reported.

---

## 15. Before Coding

Before making modifications:

1. Read this `AGENTS.md`.
2. Read documentation relevant to the task.
3. Inspect the existing implementation.
4. Identify affected files.
5. Confirm the requested behavior.
6. Determine the smallest appropriate implementation.

Do not begin by rewriting large sections of the repository.

---

## 16. Implementation Principle

Prefer:

```text
smallest correct change
```

over:

```text
largest comprehensive rewrite
```

Preserve existing working behavior unless requirements explicitly change it.

Do not refactor unrelated code during feature implementation.

---

## 17. Verification

An implementation is not complete simply because code was written.

### Backend

Run the appropriate commands from the backend project:

```bash
npm run build
npm test
```

Run additional relevant tests when available.

### Frontend

Run the appropriate commands from the frontend project:

```bash
npm run build
```

Run frontend tests when such tests exist and are relevant.

Agents must not state that a command passed unless the command was actually executed successfully.

---

## 18. Handling Test Failures

If a test fails after an agent change:

1. investigate the failure
2. determine whether the implementation or test is incorrect
3. do not automatically weaken or delete tests
4. preserve documented behavior
5. fix failures caused by the assigned change when possible
6. report unresolved failures

Never modify a correct contract test merely to make an incorrect implementation pass.

---

## 19. Error Handling

Expected errors should be represented using appropriate NestJS HTTP exceptions or equivalent behavior.

Do not expose:

* stack traces
* credentials
* MongoDB connection strings
* internal file-system paths
* sensitive environment data

to normal API clients.

---

## 20. Security Rules

Agents must not:

* commit secrets
* hardcode credentials
* disable validation to make tests pass
* weaken security behavior without explicit approval
* expose internal errors unnecessarily
* execute destructive production commands
* assume production access is available

This repository should be treated as a development environment unless explicitly stated otherwise.

---

## 21. Git Rules

Do not:

* force-push branches
* rewrite unrelated history
* delete branches without instruction
* commit unrelated changes
* modify another agent's worktree
* commit generated secrets or environment files

Keep changes scoped and reviewable.

When working in a dedicated agent branch/worktree, operate only within that assigned worktree.

---

## 22. Parallel Agent Rules

When multiple agents are working concurrently:

* respect assigned ownership boundaries
* do not modify shared contracts unless explicitly authorized
* do not assume another agent's unfinished implementation
* rely on approved shared documentation for integration behavior
* report dependencies or blockers
* avoid touching files owned by another active agent

Independent tasks may run in parallel.

Dependent tasks must synchronize before integration.

---

## 23. Human-in-the-Loop Rule

Agents may:

* inspect code
* propose solutions
* modify assigned files
* run approved development commands
* execute tests/builds
* review changes

Agents do not have final authority to:

* redefine requirements
* change shared API contracts
* redefine architecture
* merge into the protected primary branch
* deploy to production

Final acceptance belongs to the human engineer/orchestrator.

---

## 24. Review Expectations

Agent-generated changes should be reviewed for:

* correctness
* API contract compliance
* architecture compliance
* security
* input validation
* database behavior
* performance
* maintainability
* unnecessary complexity
* test quality
* unrelated changes

Passing tests alone does not prove a change is production-ready.

---

## 25. Completion Report

At the end of an assigned implementation task, report:

### Files changed

List modified files.

### Implementation summary

Explain what was implemented.

### Verification

List commands actually executed.

Example:

```text
npm run build — passed
npm test — passed
```

### Assumptions

List assumptions made during implementation.

### Unresolved issues

List blockers, failures, risks, or follow-up work.

### Scope

Confirm whether any files outside the assigned scope were modified.

---

## 26. Definition of Done for Agent Work

Agent work is considered ready for human review when:

1. Assigned functionality has been implemented.
2. Relevant requirements have been followed.
3. API contract has been preserved.
4. Architecture has been preserved.
5. Relevant build succeeds.
6. Relevant tests pass or failures are clearly reported.
7. No unnecessary scope expansion occurred.
8. No secrets were introduced.
9. Changed files are summarized.
10. Assumptions and unresolved issues are reported.

Human review and approval are still required before merge.
