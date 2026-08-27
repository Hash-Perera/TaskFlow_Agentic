import { BadRequestException, NotFoundException } from '@nestjs/common';
import { Model, Types } from 'mongoose';
import { TaskStatus } from './task-status.enum';
import { Task, TaskDocument } from './schemas/task.schema';
import { TasksService } from './tasks.service';

describe('TasksService', () => {
  let service: TasksService;
  let taskModel: {
    create: jest.Mock;
    find: jest.Mock;
    findById: jest.Mock;
    findByIdAndUpdate: jest.Mock;
    findByIdAndDelete: jest.Mock;
  };

  const task = { _id: new Types.ObjectId() } as TaskDocument;

  beforeEach(() => {
    taskModel = {
      create: jest.fn(),
      find: jest.fn(),
      findById: jest.fn(),
      findByIdAndUpdate: jest.fn(),
      findByIdAndDelete: jest.fn(),
    };
    service = new TasksService(taskModel as unknown as Model<Task>);
  });

  it('creates a task', async () => {
    taskModel.create.mockResolvedValue(task);

    await expect(
      service.create({ title: 'Build backend', status: TaskStatus.Pending }),
    ).resolves.toBe(task);
  });

  it('returns all tasks', async () => {
    taskModel.find.mockReturnValue({ exec: jest.fn().mockResolvedValue([task]) });

    await expect(service.findAll()).resolves.toEqual([task]);
  });

  it('rejects an invalid ObjectId before querying MongoDB', async () => {
    await expect(service.findOne('not-a-valid-id')).rejects.toBeInstanceOf(
      BadRequestException,
    );
    expect(taskModel.findById).not.toHaveBeenCalled();
  });

  it('returns 404 when a task does not exist', async () => {
    taskModel.findById.mockReturnValue({ exec: jest.fn().mockResolvedValue(null) });

    await expect(
      service.findOne(new Types.ObjectId().toString()),
    ).rejects.toBeInstanceOf(NotFoundException);
  });

  it('updates only supplied fields and returns the updated task', async () => {
    const exec = jest.fn().mockResolvedValue(task);
    taskModel.findByIdAndUpdate.mockReturnValue({ exec });
    const id = task._id.toString();
    const update = { status: TaskStatus.Completed };

    await expect(service.update(id, update)).resolves.toBe(task);
    expect(taskModel.findByIdAndUpdate).toHaveBeenCalledWith(id, update, {
      new: true,
      runValidators: true,
    });
  });

  it('deletes an existing task', async () => {
    taskModel.findByIdAndDelete.mockReturnValue({
      exec: jest.fn().mockResolvedValue(task),
    });

    await expect(service.remove(task._id.toString())).resolves.toBeUndefined();
  });

  it('returns 404 when deleting a missing task', async () => {
    taskModel.findByIdAndDelete.mockReturnValue({
      exec: jest.fn().mockResolvedValue(null),
    });

    await expect(
      service.remove(new Types.ObjectId().toString()),
    ).rejects.toBeInstanceOf(NotFoundException);
  });
});
