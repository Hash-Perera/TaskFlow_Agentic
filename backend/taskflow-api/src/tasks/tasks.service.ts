import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import { CreateTaskDto } from './dto/create-task.dto';
import { UpdateTaskDto } from './dto/update-task.dto';
import { Task, TaskDocument } from './schemas/task.schema';

@Injectable()
export class TasksService {
  constructor(
    @InjectModel(Task.name) private readonly taskModel: Model<Task>,
  ) {}

  create(createTaskDto: CreateTaskDto): Promise<TaskDocument> {
    return this.taskModel.create(createTaskDto);
  }

  findAll(): Promise<TaskDocument[]> {
    return this.taskModel.find().exec();
  }

  async findOne(id: string): Promise<TaskDocument> {
    this.validateObjectId(id);

    const task = await this.taskModel.findById(id).exec();
    return this.requireTask(task);
  }

  async update(
    id: string,
    updateTaskDto: UpdateTaskDto,
  ): Promise<TaskDocument> {
    this.validateObjectId(id);

    const task = await this.taskModel
      .findByIdAndUpdate(id, updateTaskDto, {
        new: true,
        runValidators: true,
      })
      .exec();
    return this.requireTask(task);
  }

  async remove(id: string): Promise<void> {
    this.validateObjectId(id);

    const task = await this.taskModel.findByIdAndDelete(id).exec();
    this.requireTask(task);
  }

  private validateObjectId(id: string): void {
    if (!Types.ObjectId.isValid(id)) {
      throw new BadRequestException('Invalid task id');
    }
  }

  private requireTask(task: TaskDocument | null): TaskDocument {
    if (!task) {
      throw new NotFoundException('Task not found');
    }

    return task;
  }
}
