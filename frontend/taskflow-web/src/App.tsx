import { useCallback, useEffect, useState } from 'react'
import * as tasksApi from './api/tasksApi'
import { TaskForm } from './components/TaskForm'
import { TaskList } from './components/TaskList'
import type { CreateTaskInput, Task, UpdateTaskInput } from './types/task'
import './App.css'

const readableError = (error: unknown) => error instanceof Error ? error.message : 'Something went wrong. Please try again.'

function App() {
  const [tasks, setTasks] = useState<Task[]>([])
  const [isLoading, setIsLoading] = useState(true)
  const [isCreating, setIsCreating] = useState(false)
  const [busyTaskId, setBusyTaskId] = useState<string | null>(null)
  const [error, setError] = useState('')

  const loadTasks = useCallback(async () => {
    setIsLoading(true)
    setError('')
    try { setTasks(await tasksApi.getTasks()) }
    catch (loadError) { setError(readableError(loadError)) }
    finally { setIsLoading(false) }
  }, [])

  useEffect(() => {
    let isCurrent = true

    void tasksApi.getTasks()
      .then((loadedTasks) => {
        if (isCurrent) setTasks(loadedTasks)
      })
      .catch((loadError: unknown) => {
        if (isCurrent) setError(readableError(loadError))
      })
      .finally(() => {
        if (isCurrent) setIsLoading(false)
      })

    return () => { isCurrent = false }
  }, [])

  async function handleCreate(input: CreateTaskInput) {
    setIsCreating(true)
    setError('')
    try {
      const createdTask = await tasksApi.createTask(input)
      setTasks((current) => [createdTask, ...current])
      return true
    } catch (createError) {
      setError(readableError(createError))
      return false
    } finally { setIsCreating(false) }
  }

  async function handleUpdate(id: string, input: UpdateTaskInput) {
    setBusyTaskId(id)
    setError('')
    try {
      const updatedTask = await tasksApi.updateTask(id, input)
      setTasks((current) => current.map((task) => task.id === id ? updatedTask : task))
      return true
    } catch (updateError) {
      setError(readableError(updateError))
      return false
    } finally { setBusyTaskId(null) }
  }

  async function handleDelete(id: string) {
    setBusyTaskId(id)
    setError('')
    try {
      await tasksApi.deleteTask(id)
      setTasks((current) => current.filter((task) => task.id !== id))
    } catch (deleteError) { setError(readableError(deleteError)) }
    finally { setBusyTaskId(null) }
  }

  return (
    <main className="app-shell">
      <header className="app-header"><div className="brand-mark" aria-hidden="true">T</div><div><p className="eyebrow">TaskFlow</p><h1>Make progress visible.</h1><p className="subtitle">A simple place to capture work, move it forward, and finish well.</p></div></header>
      <TaskForm isSubmitting={isCreating} onSubmit={handleCreate} />
      {error && <div className="error-banner" role="alert"><span>{error}</span><button type="button" onClick={() => setError('')} aria-label="Dismiss error">×</button></div>}
      <section className="tasks-section" aria-labelledby="tasks-heading">
        <div className="section-heading list-heading"><div><p className="eyebrow">Your work</p><h2 id="tasks-heading">Tasks</h2></div>{!isLoading && <span className="task-count">{tasks.length} {tasks.length === 1 ? 'task' : 'tasks'}</span>}</div>
        {isLoading ? <div className="loading-state panel" role="status"><span className="spinner" aria-hidden="true" />Loading tasks…</div>
          : error && tasks.length === 0 ? <div className="load-error panel"><p>We couldn’t load your tasks.</p><button className="primary-button" type="button" onClick={() => void loadTasks()}>Try again</button></div>
          : <TaskList tasks={tasks} busyTaskId={busyTaskId} onUpdate={handleUpdate} onDelete={handleDelete} />}
      </section>
    </main>
  )
}

export default App
