import { useState, type FormEvent } from 'react'
import { TASK_STATUSES, type Task, type TaskStatus, type UpdateTaskInput } from '../types/task'

interface Props {
  task: Task
  isBusy: boolean
  onUpdate: (id: string, input: UpdateTaskInput) => Promise<boolean>
  onDelete: (id: string) => Promise<void>
}

export function TaskCard({ task, isBusy, onUpdate, onDelete }: Props) {
  const [isEditing, setIsEditing] = useState(false)
  const [title, setTitle] = useState(task.title)
  const [description, setDescription] = useState(task.description ?? '')
  const [validationError, setValidationError] = useState('')

  async function handleEdit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const trimmedTitle = title.trim()
    if (!trimmedTitle) {
      setValidationError('Please enter a task title.')
      return
    }
    setValidationError('')
    if (await onUpdate(task.id, { title: trimmedTitle, description })) setIsEditing(false)
  }

  function cancelEdit() {
    setTitle(task.title)
    setDescription(task.description ?? '')
    setValidationError('')
    setIsEditing(false)
  }

  if (isEditing) return (
    <li className="task-card panel"><form className="edit-form" onSubmit={handleEdit}>
      <label>Title<input value={title} onChange={(event) => setTitle(event.target.value)} maxLength={150} disabled={isBusy} required /></label>
      <label>Description <span className="optional">Optional</span><textarea value={description} onChange={(event) => setDescription(event.target.value)} maxLength={1000} rows={3} disabled={isBusy} /></label>
      {validationError && <p className="field-error" role="alert">{validationError}</p>}
      <div className="card-actions"><button className="primary-button" type="submit" disabled={isBusy}>{isBusy ? 'Saving…' : 'Save'}</button><button className="text-button" type="button" onClick={cancelEdit} disabled={isBusy}>Cancel</button></div>
    </form></li>
  )

  return (
    <li className="task-card panel">
      <div className="task-content"><div><h3>{task.title}</h3>{task.description && <p className="task-description">{task.description}</p>}</div>
        <label className="status-control"><span className="sr-only">Status for {task.title}</span><select className={`status status-${task.status.toLowerCase()}`} value={task.status} onChange={(event) => void onUpdate(task.id, { status: event.target.value as TaskStatus })} disabled={isBusy}>{TASK_STATUSES.map((value) => <option key={value} value={value}>{value}</option>)}</select></label>
      </div>
      <div className="task-meta"><span>Updated {new Date(task.updatedAt).toLocaleString()}</span><div className="card-actions"><button className="text-button" type="button" onClick={() => setIsEditing(true)} disabled={isBusy}>Edit</button><button className="danger-button" type="button" onClick={() => void onDelete(task.id)} disabled={isBusy}>{isBusy ? 'Working…' : 'Delete'}</button></div></div>
    </li>
  )
}
