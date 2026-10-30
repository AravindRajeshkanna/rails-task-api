// The demo front end: a hash-routed single page over the REST API, with no build step and no dependencies. State lives in one object;
// render() writes the whole screen from it (views.js), and clicks and form submissions are handled by delegation on data-action / data-form.
import { createClient, ApiError } from "./api.js"
import { layout, loginView, projectsView, boardView, taskPanelView, inboxView } from "./views.js"

export function parseRoute(hash) {
  const path = String(hash ?? "").replace(/^#\/?/, "").split("/").filter(Boolean)
  if (path[0] === "projects" && /^\d+$/.test(path[1] ?? "")) return { name: "project", id: Number(path[1]) }
  if (path[0] === "inbox") return { name: "inbox" }
  return { name: "projects" }
}

export function start({ root, config, storage = globalThis.sessionStorage, win = globalThis.window }) {
  const state = {
    token: safely(() => storage.getItem("token")), user: null, demo: false, route: parseRoute(win.location.hash),
    projects: [], project: null, tasks: [], truncated: false, openTask: null, comments: [],
    notifications: [], unread: 0, notice: "", busy: false
  }

  const api = createClient({
    baseUrl: config.apiUrl,
    getToken: () => state.token,
    onUnauthorized: () => signedOut("Your session ended. Please sign in again."),
    onDemoMode: () => { state.demo = true }
  })

  function safely(read) { try { return read() } catch { return null } }

  function render() {
    let content
    if (!state.user) {
      content = loginView({ busy: state.busy, demoLogin: config.demoLogin })
    } else if (state.route.name === "inbox") {
      content = inboxView({ notifications: state.notifications, unread: state.unread })
    } else if (state.route.name === "project" && state.project) {
      content = boardView({ project: state.project, tasks: state.tasks, truncated: state.truncated, busy: state.busy }) +
        (state.openTask ? taskPanelView({ task: state.openTask, comments: state.comments, busy: state.busy }) : "")
    } else if (state.route.name === "project") {
      content = '<p class="muted">Loading...</p>'
    } else {
      content = projectsView({ projects: state.projects })
    }
    root.innerHTML = layout({ user: state.user, demo: state.demo, unread: state.unread, route: state.route, content, notice: state.notice })
  }

  function fail(error) {
    // A rejected token already signed us out and said why (the notice is set); do not replace that with the API's terse "Authentication is required".
    if (error instanceof ApiError && error.status === 401 && !state.user && state.notice) return render()

    state.notice = error instanceof ApiError
      ? (error.code === "read_only" ? "The service is read-only for a moment. Try again shortly." : error.code === "demo_mode" ? "The public demo does not allow that." : error.summary)
      : "Something went wrong."
    if (!(error instanceof ApiError)) console.error(error)
    render()
  }

  async function run(work) {
    state.busy = true
    state.notice = ""
    try { await work() } catch (error) { fail(error) } finally { state.busy = false; render() }
  }

  function signedOut(notice = "") {
    safely(() => storage.removeItem("token"))
    Object.assign(state, { token: null, user: null, projects: [], project: null, tasks: [], openTask: null, notifications: [], unread: 0, notice })
    render()
  }

  async function refreshInbox() {
    const { data, meta } = await api.notifications()
    state.notifications = data
    state.unread = meta?.unread_count ?? 0
  }

  async function load() {
    if (!state.user) return
    state.openTask = null
    if (state.route.name === "project") {
      const [project, tasks] = await Promise.all([api.project(state.route.id), api.tasks(state.route.id)])
      state.project = project.data
      state.tasks = tasks.data
      state.truncated = Boolean(tasks.meta?.next)
    } else if (state.route.name === "projects") {
      state.projects = (await api.projects()).data
    }
    await refreshInbox()
  }

  const actions = {
    "sign-out": async () => { await api.signOut().catch(() => {}); signedOut() },
    "open-task": ({ id }) => run(async () => {
      state.openTask = state.tasks.find((task) => String(task.id) === id) ?? null
      state.comments = state.openTask ? (await api.comments(id)).data : []
    }),
    "close-task": () => { state.openTask = null; render() },
    move: ({ id, status }) => run(async () => {
      const task = state.tasks.find((candidate) => String(candidate.id) === id)
      try {
        const { data } = await api.updateTask(id, { status, lock_version: task.lock_version })
        state.tasks = state.tasks.map((candidate) => (candidate.id === data.id ? data : candidate))
      } catch (error) {
        if (error.code === "stale_object") { await load(); throw new ApiError(409, "stale_object", "Someone changed that task first. It has been reloaded.") }
        throw error
      }
    }),
    read: ({ id }) => run(async () => { await api.markRead(id); await refreshInbox() }),
    "read-all": () => run(async () => { await api.markAllRead(); await refreshInbox() })
  }

  const forms = {
    "sign-in": (form) => run(async () => {
      const { data } = await api.signIn(form.get("email_address"), form.get("password"))
      state.token = data.token
      safely(() => storage.setItem("token", data.token))
      state.user = data.user
      await load()
    }),
    "new-task": (form, element) => run(async () => {
      const { data } = await api.createTask(state.project.id, { title: form.get("title"), priority: form.get("priority") })
      state.tasks = [data, ...state.tasks]
      element.reset?.()
    }),
    "new-comment": (form, element) => run(async () => {
      const { data } = await api.addComment(element.dataset.id, form.get("body"))
      state.comments = [...state.comments, data]
      state.tasks = state.tasks.map((task) => (String(task.id) === element.dataset.id ? { ...task, comments_count: task.comments_count + 1 } : task))
      state.openTask = state.tasks.find((task) => String(task.id) === element.dataset.id) ?? state.openTask
    })
  }

  root.addEventListener("click", (event) => {
    const target = event.target.closest?.("[data-action]")
    if (target && actions[target.dataset.action]) actions[target.dataset.action]({ ...target.dataset })
  })
  root.addEventListener("submit", (event) => {
    const element = event.target.closest?.("[data-form]")
    if (!element || !forms[element.dataset.form]) return
    event.preventDefault()
    forms[element.dataset.form](new FormData(element), element)
  })
  win.addEventListener("hashchange", () => {
    state.route = parseRoute(win.location.hash)
    state.project = null
    render()
    run(load)
  })

  // The inbox, kept roughly current while the tab is in use: a poll, because a static site holds no WebSocket (the API also pushes over Action Cable).
  win.setInterval?.(() => {
    if (state.user && !win.document?.hidden && !state.busy) refreshInbox().then(render).catch(() => {})
  }, 30_000)

  // Resume a session kept in this tab, otherwise show the sign-in form.
  render()
  if (state.token) {
    api.me().then(async ({ data }) => { state.user = data; await run(load) }).catch(() => signedOut())
  }
  return { state, render }
}
