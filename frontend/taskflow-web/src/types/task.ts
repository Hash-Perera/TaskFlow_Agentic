export const TASK_STATUSES = ['Pending', 'InProgress', 'Completed'] as const

export type TaskStatus = (typeof TASK_STATUSES)[number]

export interface Task {
  id: string
  title: string
  description?: string
  status: TaskStatus
  createdAt: string
  updatedAt: string
}

export interface CreateTaskInput {
  title: string
  description?: string
  status?: TaskStatus
}

export interface UpdateTaskInput {
  title?: string
  description?: string
  status?: TaskStatus
}
