import {
  IsEnum,
  IsNotEmpty,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
} from 'class-validator';
import { TaskStatus } from '../task-status.enum';

export class UpdateTaskDto {
  @IsOptional()
  @IsString()
  @IsNotEmpty()
  @Matches(/\S/, { message: 'title must not contain only whitespace' })
  @MaxLength(150)
  title?: string;

  @IsOptional()
  @IsString()
  @MaxLength(1000)
  description?: string;

  @IsOptional()
  @IsEnum(TaskStatus)
  status?: TaskStatus;
}
