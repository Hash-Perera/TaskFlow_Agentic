import { useState, type FormEvent } from 'react'
import { TASK_STATUSES, type CreateTaskInput, type TaskStatus } from '../types/task'

interface Props {
  isSubmitting: boolean
  onSubmit: (input: CreateTaskInput) => Promise<boolean>
}

export function TaskForm({ isSubmitting, onSubmit }: Props) {
  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [status, setStatus] = useState<TaskStatus>('Pending')
  const [validationError, setValidationError] = useState('')

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const trimmedTitle = title.trim()
    if (!trimmedTitle) {
      setValidationError('Please enter a task title.')
      return
    }
    setValidationError('')
    if (await onSubmit({ title: trimmedTitle, description, status })) {
      setTitle('')
      setDescription('')
      setStatus('Pending')
    }
  }

  return (
    <form className="task-form panel" onSubmit={handleSubmit}>
      <div className="section-heading"><div><p className="eyebrow">New task</p><h2>Add something to your flow</h2></div></div>
      <label>Title<input value={title} onChange={(event) => setTitle(event.target.value)} maxLength={150} placeholder="What needs to be done?" disabled={isSubmitting} required /></label>
      <label>Description <span className="optional">Optional</span><textarea value={description} onChange={(event) => setDescription(event.target.value)} maxLength={1000} placeholder="Add a little context" disabled={isSubmitting} rows={3} /></label>
      <div className="form-row">
        <label>Status<select value={status} onChange={(event) => setStatus(event.target.value as TaskStatus)} disabled={isSubmitting}>{TASK_STATUSES.map((value) => <option key={value} value={value}>{value}</option>)}</select></label>
        <button className="primary-button" type="submit" disabled={isSubmitting}>{isSubmitting ? 'Adding…' : 'Add task'}</button>
      </div>
      {validationError && <p className="field-error" role="alert">{validationError}</p>}
    </form>
  )
}
