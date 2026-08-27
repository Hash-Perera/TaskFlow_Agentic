import type { CreateTaskInput, Task, UpdateTaskInput } from '../types/task'

const apiBaseUrl = (import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:3000').replace(/\/$/, '')
const tasksUrl = `${apiBaseUrl}/api/tasks`

interface ApiErrorBody {
  message?: string | string[]
}

async function getErrorMessage(response: Response): Promise<string> {
  const fallback = `Request failed (${response.status})`

  try {
    const body = (await response.json()) as ApiErrorBody
    return Array.isArray(body.message) ? body.message.join('. ') : body.message || fallback
  } catch {
    return fallback
  }
}

async function request<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, init)
  if (!response.ok) throw new Error(await getErrorMessage(response))
  if (response.status === 204) return undefined as T
  return (await response.json()) as T
}

export const getTasks = () => request<Task[]>(tasksUrl)
export const getTask = (id: string) => request<Task>(`${tasksUrl}/${encodeURIComponent(id)}`)

export function createTask(input: CreateTaskInput) {
  return request<Task>(tasksUrl, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input),
  })
}

export function updateTask(id: string, input: UpdateTaskInput) {
  return request<Task>(`${tasksUrl}/${encodeURIComponent(id)}`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input),
  })
}

export function deleteTask(id: string) {
  return request<void>(`${tasksUrl}/${encodeURIComponent(id)}`, { method: 'DELETE' })
}
