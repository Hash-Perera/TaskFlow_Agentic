# TaskFlow Architecture

## 1. Purpose

This document defines the approved application architecture for TaskFlow.

Implementation agents must follow this architecture unless an architecture
change has explicitly been approved.

TaskFlow intentionally uses a simple architecture because the primary
learning objective is agentic software development and orchestration.

---

## 2. Technology Stack

### Backend

- NestJS
- TypeScript
- Mongoose
- MongoDB
- class-validator
- class-transformer
- @nestjs/config

### Frontend

- React
- TypeScript
- Vite

### Testing

- Jest
- NestJS testing utilities

---

## 3. System Architecture

TaskFlow uses a client-server architecture.

Flow:

React Application
→ REST API
→ NestJS
→ Mongoose
→ MongoDB

The frontend communicates with the backend using JSON over HTTP.

The frontend must not communicate directly with MongoDB.

---

## 4. Backend Architecture

Backend request flow:

HTTP Request
→ NestJS Controller
→ DTO Validation
→ Service
→ Mongoose Model
→ MongoDB

### Controller

Controllers are responsible for:

- defining routes
- reading request parameters
- accepting validated DTOs
- returning HTTP responses
- delegating application behavior to services

Controllers must remain thin.

Controllers should not contain direct MongoDB persistence logic.

### DTO

DTOs define and validate external input.

Create and update operations must use DTO validation.

All external input must be considered untrusted.

### Service

Services contain task application behavior.

The TasksService is responsible for:

- creating tasks
- retrieving tasks
- updating tasks
- deleting tasks
- handling task-not-found behavior

### Mongoose

Mongoose provides MongoDB persistence.

Task persistence is represented using an explicit Mongoose schema.

Mongoose timestamps should provide:

- createdAt
- updatedAt

The public API must expose `id`, not MongoDB `_id`.

---

## 5. Repository Pattern

TaskFlow does not use a custom Repository layer in the initial architecture.

Approved flow:

Controller
→ Service
→ Mongoose Model

A repository abstraction should not be introduced unless a demonstrated
requirement justifies it and the architecture change receives approval.

---

## 6. Backend Module Structure

Target structure:

src/
├── config/
├── tasks/
│   ├── dto/
│   │   ├── create-task.dto.ts
│   │   └── update-task.dto.ts
│   ├── schemas/
│   │   └── task.schema.ts
│   ├── task-status.enum.ts
│   ├── tasks.controller.ts
│   ├── tasks.service.ts
│   └── tasks.module.ts
├── app.module.ts
└── main.ts

Agents may make small structural adjustments when justified, but must
preserve the approved responsibilities and boundaries.

---

## 7. Configuration

Application configuration must come from environment variables.

MongoDB configuration:

MONGODB_URI

Example:

MONGODB_URI=mongodb://localhost:27017/taskflow

Real secrets must not be committed.

A safe `.env.example` may be committed.

---

## 8. Validation

NestJS must apply global request validation.

Required behavior:

- whitelist supported input properties
- reject unknown properties
- transform request input where appropriate
- reject invalid task status values
- reject invalid title/description values

Frontend validation may improve user experience but must never replace
backend validation.

---

## 9. Frontend Architecture

Frontend flow:

React Components
→ Task API Client
→ REST API

Target structure:

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

---

## 10. API Client

Backend API communication should be centralized.

React components must not duplicate backend endpoint configuration.

The API client should be responsible for operations such as:

- getTasks
- getTask
- createTask
- updateTask
- deleteTask

The backend base URL should come from:

VITE_API_BASE_URL

---

## 11. Frontend State

The initial application should use standard React state.

A global state-management library is not required.

Libraries such as Redux or Zustand should only be introduced if application
complexity later demonstrates a real need.

---

## 12. Public API Contract

The public API is defined by:

docs/api-contract.md

That document is the source of truth for:

- endpoints
- HTTP methods
- request structures
- response structures
- task statuses
- HTTP status codes

Agents must not silently modify the API contract.

---

## 13. Architectural Constraints

The initial TaskFlow architecture does not include:

- microservices
- CQRS
- event sourcing
- message queues
- Redis
- repository abstraction
- unit-of-work abstraction
- GraphQL
- WebSockets
- Redux
- complex domain-driven-design layers

Agents must not introduce these technologies simply as architectural
"improvements."

---

## 14. Architecture Change Process

If an agent believes an architectural change is required, it must:

1. Identify the current architectural limitation.
2. Explain why the requirement cannot reasonably be implemented within the
   approved architecture.
3. Propose the smallest appropriate architecture change.
4. Describe its consequences.
5. Wait for human approval.

Implementation agents must not independently redefine the architecture.

---

## 15. Agent Ownership Boundaries

Backend implementation agents normally own:

backend/**

Frontend implementation agents normally own:

frontend/**

Shared documentation such as:

docs/api-contract.md
docs/architecture.md

is governed by the human orchestrator unless an agent is explicitly assigned
a documentation task.

---

## 16. Verification

Backend changes should normally be verified using:

npm run build
npm test

Frontend changes should normally be verified using:

npm run build

Additional testing commands may be introduced later.

An agent must not claim verification succeeded unless the relevant command
was actually executed successfully.

---

## 17. Architectural Principle

Prefer the simplest architecture that satisfies the current requirements.

Architecture should solve demonstrated problems rather than anticipate every
possible future requirement.