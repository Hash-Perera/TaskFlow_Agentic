import { model, Types } from 'mongoose';
import { TaskStatus } from '../task-status.enum';
import { Task, TaskSchema } from './task.schema';

describe('TaskSchema', () => {
  const TaskModel = model<Task>(`TaskSchemaTest${Date.now()}`, TaskSchema);

  it('maps MongoDB _id to the public id and removes internal fields', () => {
    const _id = new Types.ObjectId();
    const task = new TaskModel({
      _id,
      title: 'Public response',
      status: TaskStatus.Pending,
    });

    const result = task.toJSON();

    expect(result.id).toBe(_id.toString());
    expect(result).not.toHaveProperty('_id');
    expect(result).not.toHaveProperty('__v');
  });
});
