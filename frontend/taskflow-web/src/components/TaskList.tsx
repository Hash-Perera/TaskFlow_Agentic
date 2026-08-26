import type { Task, UpdateTaskInput } from '../types/task'
import { TaskCard } from './TaskCard'

interface Props {
  tasks: Task[]
  busyTaskId: string | null
  onUpdate: (id: string, input: UpdateTaskInput) => Promise<boolean>
  onDelete: (id: string) => Promise<void>
}

export function TaskList({ tasks, busyTaskId, onUpdate, onDelete }: Props) {
  if (tasks.length === 0) return <div className="empty-state panel"><span aria-hidden="true">✓</span><h3>Your task list is clear</h3><p>Add a task above when you’re ready to get moving.</p></div>
  return <ul className="task-list">{tasks.map((task) => <TaskCard key={task.id} task={task} isBusy={busyTaskId === task.id} onUpdate={onUpdate} onDelete={onDelete} />)}</ul>
}
