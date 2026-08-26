import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument } from 'mongoose';
import { TaskStatus } from '../task-status.enum';

export type TaskDocument = HydratedDocument<Task>;

@Schema({
  timestamps: true,
  toJSON: {
    virtuals: true,
    transform: (_document, result: Record<string, unknown>) => {
      delete result._id;
      delete result.__v;
      return result;
    },
  },
})
export class Task {
  @Prop({ required: true, maxlength: 150 })
  title: string;

  @Prop({ maxlength: 1000 })
  description?: string;

  @Prop({
    type: String,
    enum: Object.values(TaskStatus),
    default: TaskStatus.Pending,
    required: true,
  })
  status: TaskStatus;

  createdAt: Date;

  updatedAt: Date;
}

export const TaskSchema = SchemaFactory.createForClass(Task);
