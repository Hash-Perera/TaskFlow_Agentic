import { INestApplication, ValidationPipe } from '@nestjs/common';
import { getConnectionToken } from '@nestjs/mongoose';
import { Test } from '@nestjs/testing';
import { Connection, Types } from 'mongoose';
import request from 'supertest';
import { App } from 'supertest/types';

type TaskStatus = 'Pending' | 'InProgress' | 'Completed';

interface TaskResponse {
  id: string;
  title: string;
  description?: string;
  status: TaskStatus;
  createdAt: string;
  updatedAt: string;
  _id?: unknown;
  __v?: unknown;
}

describe('Tasks API contract (e2e)', () => {
  let app: INestApplication<App>;
  let connection: Connection;

  beforeAll(async () => {
    const mongoUri = process.env.TEST_MONGODB_URI ?? process.env.MONGODB_URI;

    if (!mongoUri) {
      throw new Error(
        'Set TEST_MONGODB_URI (preferred) or MONGODB_URI to an isolated test database before running the Task API e2e suite.',
      );
    }

    process.env.MONGODB_URI = mongoUri;
    const { AppModule } = await import('../src/app.module');
    const moduleFixture = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();

    app = moduleFixture.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
      }),
    );
    await app.init();
    connection = app.get<Connection>(getConnectionToken());
  });

  beforeEach(async () => {
    await connection.collection('tasks').deleteMany({});
  });

  afterAll(async () => {
    if (app) {
      await connection.collection('tasks').deleteMany({});
      await app.close();
    }
  });

  const api = () => request(app.getHttpServer());
  const missingId = () => new Types.ObjectId().toHexString();

  const expectPublicTask = (task: TaskResponse) => {
    expect(task).toEqual(
      expect.objectContaining({
        id: expect.any(String),
        title: expect.any(String),
        status: expect.stringMatching(/^(Pending|InProgress|Completed)$/),
        createdAt: expect.any(String),
        updatedAt: expect.any(String),
      }),
    );
    expect(task).not.toHaveProperty('_id');
    expect(task).not.toHaveProperty('__v');
    expect(Number.isNaN(Date.parse(task.createdAt))).toBe(false);
    expect(Number.isNaN(Date.parse(task.updatedAt))).toBe(false);
  };

  const createTask = async (
    overrides: Partial<{
      title: string;
      description: string;
      status: TaskStatus;
    }> = {},
  ): Promise<TaskResponse> => {
    const response = await api()
      .post('/api/tasks')
      .send({
        title: 'Contract test task',
        description: 'Created by the TaskFlow e2e suite',
        ...overrides,
      })
      .expect(201);

    return response.body as TaskResponse;
  };

  const expectSafeError = (body: unknown, statusCode: 400 | 404) => {
    expect(body).toEqual(
      expect.objectContaining({
        statusCode,
        message: expect.anything(),
      }),
    );
    const serialized = JSON.stringify(body);
    expect(serialized).not.toMatch(/stack|mongodb:\/\/|mongoose|CastError/i);
  };

  describe('POST /api/tasks', () => {
    it('creates and persists a valid task with Pending as the default status', async () => {
      const response = await api()
        .post('/api/tasks')
        .send({
          title: 'Learn Codex',
          description: 'Practice agentic development',
        })
        .expect(201);

      const task = response.body as TaskResponse;
      expectPublicTask(task);
      expect(task).toEqual(
        expect.objectContaining({
          title: 'Learn Codex',
          description: 'Practice agentic development',
          status: 'Pending',
        }),
      );

      const persisted = await api().get(`/api/tasks/${task.id}`).expect(200);
      expect(persisted.body).toEqual(task);
    });

    it('creates a task with an explicit status', async () => {
      const task = await createTask({ status: 'InProgress' });
      expect(task.status).toBe('InProgress');
      expect(
        (await api().get(`/api/tasks/${task.id}`).expect(200)).body.status,
      ).toBe('InProgress');
    });

    it.each<TaskStatus>(['Pending', 'InProgress', 'Completed'])(
      'accepts the supported %s status',
      async (status) => {
        expect((await createTask({ status })).status).toBe(status);
      },
    );

    it('accepts a 150-character title and an omitted description', async () => {
      const response = await api()
        .post('/api/tasks')
        .send({ title: 't'.repeat(150) })
        .expect(201);
      expect(response.body.title).toHaveLength(150);
    });

    it.each([
      ['a missing title', { description: 'Task without a title' }],
      ['an empty title', { title: '' }],
      ['a whitespace-only title', { title: '   ' }],
      ['a title longer than 150 characters', { title: 't'.repeat(151) }],
      [
        'a description longer than 1000 characters',
        { title: 'Test', description: 'd'.repeat(1001) },
      ],
      ['an invalid status', { title: 'Test', status: 'Started' }],
      ['an unexpected property', { title: 'Test', isAdmin: true }],
    ])('rejects %s without persisting a task', async (_case, body) => {
      const response = await api().post('/api/tasks').send(body).expect(400);
      expectSafeError(response.body, 400);
      expect((await api().get('/api/tasks').expect(200)).body).toEqual([]);
    });
  });

  describe('GET /api/tasks', () => {
    it('returns all tasks using the public task structure', async () => {
      const first = await createTask({ title: 'First task' });
      const second = await createTask({
        title: 'Second task',
        status: 'Completed',
      });

      const response = await api().get('/api/tasks').expect(200);
      expect(Array.isArray(response.body)).toBe(true);
      expect(response.body).toHaveLength(2);
      response.body.forEach(expectPublicTask);
      expect(response.body.map((task: TaskResponse) => task.id)).toEqual(
        expect.arrayContaining([first.id, second.id]),
      );
    });

    it('returns an empty array when no tasks exist', async () => {
      expect((await api().get('/api/tasks').expect(200)).body).toEqual([]);
    });
  });

  describe('GET /api/tasks/:id', () => {
    it('returns an existing task', async () => {
      const created = await createTask({ title: 'Retrieve me' });
      const response = await api().get(`/api/tasks/${created.id}`).expect(200);
      expectPublicTask(response.body);
      expect(response.body).toEqual(created);
    });

    it('returns 400 for an invalid ObjectId without exposing internals', async () => {
      const response = await api().get('/api/tasks/not-a-valid-id').expect(400);
      expectSafeError(response.body, 400);
    });

    it('returns 404 for a syntactically valid missing task id', async () => {
      const response = await api().get(`/api/tasks/${missingId()}`).expect(404);
      expectSafeError(response.body, 404);
    });
  });

  describe('PATCH /api/tasks/:id', () => {
    it('updates the title and preserves unspecified fields', async () => {
      const created = await createTask({
        title: 'Old title',
        status: 'Pending',
      });
      const response = await api()
        .patch(`/api/tasks/${created.id}`)
        .send({ title: 'Updated task title' })
        .expect(200);

      expect(response.body).toEqual(
        expect.objectContaining({
          id: created.id,
          title: 'Updated task title',
          description: created.description,
          status: created.status,
          createdAt: created.createdAt,
        }),
      );
      expect(Date.parse(response.body.updatedAt)).toBeGreaterThanOrEqual(
        Date.parse(created.updatedAt),
      );
    });

    it('updates the description and preserves unspecified fields', async () => {
      const created = await createTask({ title: 'Keep title' });
      const response = await api()
        .patch(`/api/tasks/${created.id}`)
        .send({ description: 'Updated task description' })
        .expect(200);

      expect(response.body).toEqual(
        expect.objectContaining({
          id: created.id,
          title: created.title,
          description: 'Updated task description',
          status: created.status,
        }),
      );
    });

    it('updates the status and changes updatedAt', async () => {
      const created = await createTask({ status: 'Pending' });
      await new Promise((resolve) => setTimeout(resolve, 5));
      const response = await api()
        .patch(`/api/tasks/${created.id}`)
        .send({ status: 'Completed' })
        .expect(200);

      expect(response.body.status).toBe('Completed');
      expect(Date.parse(response.body.updatedAt)).toBeGreaterThan(
        Date.parse(created.updatedAt),
      );
    });

    it('supports a partial update without requiring other task fields', async () => {
      const created = await createTask({ title: 'Unchanged title' });
      const response = await api()
        .patch(`/api/tasks/${created.id}`)
        .send({ status: 'InProgress' })
        .expect(200);
      expect(response.body.title).toBe(created.title);
      expect(response.body.status).toBe('InProgress');
    });

    it.each([
      ['an empty title', { title: '' }],
      ['a whitespace-only title', { title: '   ' }],
      ['a title longer than 150 characters', { title: 't'.repeat(151) }],
      [
        'a description longer than 1000 characters',
        { description: 'd'.repeat(1001) },
      ],
      ['an invalid status', { status: 'Finished' }],
      ['an unexpected property', { isAdmin: true }],
    ])(
      'rejects %s and leaves the existing task unchanged',
      async (_case, body) => {
        const created = await createTask({
          title: 'Original title',
          status: 'Pending',
        });
        const response = await api()
          .patch(`/api/tasks/${created.id}`)
          .send(body)
          .expect(400);
        expectSafeError(response.body, 400);
        expect(
          (await api().get(`/api/tasks/${created.id}`).expect(200)).body,
        ).toEqual(created);
      },
    );

    it('returns 400 for an invalid ObjectId', async () => {
      const response = await api()
        .patch('/api/tasks/not-a-valid-id')
        .send({ title: 'Updated' })
        .expect(400);
      expectSafeError(response.body, 400);
    });

    it('returns 404 when updating a missing task', async () => {
      const response = await api()
        .patch(`/api/tasks/${missingId()}`)
        .send({ title: 'Updated' })
        .expect(404);
      expectSafeError(response.body, 404);
    });
  });

  describe('DELETE /api/tasks/:id', () => {
    it('deletes an existing task with an empty 204 response', async () => {
      const created = await createTask();
      const response = await api()
        .delete(`/api/tasks/${created.id}`)
        .expect(204);
      expect(response.text).toBe('');
    });

    it('returns 400 for an invalid ObjectId', async () => {
      const response = await api()
        .delete('/api/tasks/not-a-valid-id')
        .expect(400);
      expectSafeError(response.body, 400);
    });

    it('returns 404 when deleting a missing task', async () => {
      const response = await api()
        .delete(`/api/tasks/${missingId()}`)
        .expect(404);
      expectSafeError(response.body, 404);
    });

    it('does not return a deleted task from item or collection queries', async () => {
      const deleted = await createTask({ title: 'Delete me' });
      const retained = await createTask({ title: 'Keep me' });
      await api().delete(`/api/tasks/${deleted.id}`).expect(204);

      await api().get(`/api/tasks/${deleted.id}`).expect(404);
      const collection = (await api().get('/api/tasks').expect(200))
        .body as TaskResponse[];
      expect(collection.map((task) => task.id)).toEqual([retained.id]);
    });
  });
});
