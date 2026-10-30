// A small client for the Task API (REST, /api/v1). It never throws anything but ApiError, so a screen has one thing to catch:
// a refusal from the server (a 4xx/5xx in the API's error envelope) and "could not reach it at all" look alike to the caller.
//
//   const api = createClient({ baseUrl: "https://api.example.com", getToken: () => token, onUnauthorized: signOut, onDemoMode: showBanner })
//   const { data: projects } = await api.projects()

export class ApiError extends Error {
  // status 0 means no answer at all (offline, DNS, CORS refused, a timeout).
  constructor(status, code, message, { details = null, requestId = null, retryAfter = null } = {}) {
    super(message)
    this.name = "ApiError"
    this.status = status
    this.code = code
    this.details = details
    this.requestId = requestId
    this.retryAfter = retryAfter
  }

  // "title: can't be blank" for a validation failure, the message otherwise.
  get summary() {
    if (this.code !== "validation_failed" || !this.details) return this.message
    return Object.entries(this.details).map(([field, problems]) => `${field.replace(/_/g, " ")} ${[].concat(problems).join(", ")}`).join("; ")
  }
}

export function createClient({ baseUrl, fetch: fetchImpl = globalThis.fetch.bind(globalThis), getToken = () => null, onUnauthorized = () => {}, onDemoMode = () => {} }) {
  async function request(method, path, { query, body } = {}) {
    const url = new URL(path, baseUrl)
    for (const [key, value] of Object.entries(query ?? {})) {
      if (value !== undefined && value !== null && value !== "") url.searchParams.set(key, value)
    }
    const headers = { Accept: "application/json" }
    const token = getToken()
    if (token) headers.Authorization = `Bearer ${token}`
    if (body !== undefined) headers["Content-Type"] = "application/json"

    let response
    try {
      response = await fetchImpl(url, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) })
    } catch {
      throw new ApiError(0, "network_error", "Could not reach the server. Check your connection and try again.")
    }

    if (response.headers.get("X-Demo-Mode") === "true") onDemoMode()
    if (response.status === 204) return { data: null, meta: null }

    let json = null
    try {
      json = await response.json()
    } catch {
      // not JSON (a gateway error page): handled below
    }

    if (!response.ok) {
      const error = json?.error
      if (response.status === 401 && token) onUnauthorized()
      throw new ApiError(response.status, error?.code ?? "http_error", error?.message ?? `The server answered ${response.status}`, {
        details: error?.details ?? null, requestId: error?.request_id ?? null, retryAfter: Number(response.headers.get("Retry-After")) || null
      })
    }
    return { data: json?.data ?? null, meta: json?.meta ?? null }
  }

  return {
    signIn: (emailAddress, password) => request("POST", "/api/v1/session", { body: { email_address: emailAddress, password } }),
    signOut: () => request("DELETE", "/api/v1/session"),
    me: () => request("GET", "/api/v1/me"),
    projects: () => request("GET", "/api/v1/projects", { query: { limit: 100 } }),
    project: (id) => request("GET", `/api/v1/projects/${id}`),
    tasks: (projectId, query = {}) => request("GET", `/api/v1/projects/${projectId}/tasks`, { query: { limit: 100, sort: "-created_at", ...query } }),
    createTask: (projectId, attributes) => request("POST", `/api/v1/projects/${projectId}/tasks`, { body: attributes }),
    updateTask: (id, attributes) => request("PATCH", `/api/v1/tasks/${id}`, { body: attributes }),
    comments: (taskId) => request("GET", `/api/v1/tasks/${taskId}/comments`, { query: { limit: 100 } }),
    addComment: (taskId, body) => request("POST", `/api/v1/tasks/${taskId}/comments`, { body: { body } }),
    notifications: (query = {}) => request("GET", "/api/v1/notifications", { query: { limit: 50, ...query } }),
    markRead: (id, read = true) => request("PATCH", `/api/v1/notifications/${id}`, { body: { read } }),
    markAllRead: () => request("POST", "/api/v1/notifications/read_all", { body: {} }),
    search: (term) => request("GET", "/api/v1/search", { query: { q: term, limit: 25 } })
  }
}
