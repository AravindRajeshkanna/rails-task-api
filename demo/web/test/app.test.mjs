import { test } from "node:test"
import assert from "node:assert/strict"
import { parseRoute, start } from "../js/app.js"

test("routes hashes to screens, and anything unknown to the project list", () => {
  assert.deepEqual(parseRoute("#/projects/12"), { name: "project", id: 12 })
  assert.deepEqual(parseRoute("#/inbox"), { name: "inbox" })
  assert.deepEqual(parseRoute("#/projects"), { name: "projects" })
  assert.deepEqual(parseRoute(""), { name: "projects" })
  assert.deepEqual(parseRoute("#/projects/abc"), { name: "projects" })
  assert.deepEqual(parseRoute("#/projects/12/../../x"), { name: "project", id: 12 })
})

// --- the app against a fake page and a fake API ---------------------------------------------------------------------------------------

class FormDataStub {
  constructor(element) { this.values = element.values }
  get(name) { return this.values[name] }
}
globalThis.FormData = FormDataStub

function page() {
  const listeners = {}
  const root = { innerHTML: "", addEventListener: (type, handler) => { listeners[type] = handler } }
  const winListeners = {}
  const win = { location: { hash: "" }, document: { hidden: false }, addEventListener: (type, handler) => { winListeners[type] = handler }, setInterval: () => {} }
  const click = (action, data = {}) => listeners.click({ target: { closest: () => ({ dataset: { action, ...data } }) } })
  const submit = (form, values, data = {}) => listeners.submit({ preventDefault() {}, target: { closest: () => ({ dataset: { form, ...data }, values, reset() {} }) } })
  return { root, win, click, submit, navigate: (hash) => { win.location.hash = hash; return winListeners.hashchange() } }
}

const tick = () => new Promise((resolve) => setImmediate(resolve))
async function settle() { for (let i = 0; i < 6; i++) await tick() }

function fakeApi(handlers) {
  const calls = []
  const fetch = async (url, options) => {
    const u = new URL(url)
    const key = `${options.method} ${u.pathname}`
    calls.push({ key, body: options.body ? JSON.parse(options.body) : null, auth: options.headers.Authorization })
    const handler = handlers[key]
    const answer = handler ? handler(calls.at(-1)) : { status: 404, body: { error: { code: "not_found", message: "Resource not found" } } }
    const status = answer.status ?? 200
    return { status, ok: status < 300, headers: { get: (n) => (answer.headers ?? {})[n] ?? null }, json: async () => answer.body ?? {} }
  }
  return { fetch, calls }
}

const config = { apiUrl: "https://api.example.com", demoLogin: { email: "demo@example.com", password: "password123" } }
const memory = () => { const store = {}; return { getItem: (k) => store[k] ?? null, setItem: (k, v) => { store[k] = v }, removeItem: (k) => { delete store[k] }, store } }

const TASK = { id: 7, project_id: 1, title: "Land on the moon", status: "todo", priority: "high", lock_version: 3, comments_count: 0, tags: [], assignee: null, overdue: false }
const API = {
  "POST /api/v1/session": () => ({ status: 201, headers: { "X-Demo-Mode": "true" }, body: { data: { token: "tok", user: { id: 1, name: "Demo User" } } } }),
  "GET /api/v1/projects": () => ({ body: { data: [{ id: 1, name: "Apollo", description: "To the moon", role: "admin" }], meta: {} } }),
  "GET /api/v1/projects/1": () => ({ body: { data: { id: 1, name: "Apollo" } } }),
  "GET /api/v1/projects/1/tasks": () => ({ body: { data: [TASK], meta: { next: null } } }),
  "GET /api/v1/notifications": () => ({ body: { data: [], meta: { unread_count: 2 } } })
}

async function signedIn(extra = {}) {
  const p = page()
  const api = fakeApi({ ...API, ...extra })
  globalThis.fetch = api.fetch
  const storage = memory()
  const app = start({ root: p.root, config, storage, win: p.win })
  await p.submit("sign-in", { email_address: "demo@example.com", password: "password123" })
  await settle()
  return { p, api, app, storage }
}

test("starts at the sign-in form with the demo account offered", () => {
  const p = page()
  start({ root: p.root, config, storage: memory(), win: p.win })

  assert.match(p.root.innerHTML, /Sign in/)
  assert.match(p.root.innerHTML, /value="demo@example.com"/)
})

test("signs in, keeps the token for this tab, shows the projects, the demo banner and the unread count", async () => {
  const { p, api, storage } = await signedIn()

  assert.equal(storage.store.token, "tok")
  assert.match(p.root.innerHTML, /Demo User/)
  assert.match(p.root.innerHTML, /Apollo/)
  assert.match(p.root.innerHTML, /public demo/)
  assert.match(p.root.innerHTML, /class="count" aria-label="2 unread"/)
  assert.deepEqual(api.calls.find((call) => call.key === "POST /api/v1/session").body, { email_address: "demo@example.com", password: "password123" })
  assert.equal(api.calls.find((call) => call.key === "GET /api/v1/projects").auth, "Bearer tok")
})

test("says why a sign-in failed and stays on the form", async () => {
  const p = page()
  globalThis.fetch = fakeApi({ "POST /api/v1/session": () => ({ status: 401, body: { error: { code: "invalid_credentials", message: "Invalid email address or password" } } }) }).fetch
  start({ root: p.root, config, storage: memory(), win: p.win })

  await p.submit("sign-in", { email_address: "x@example.com", password: "nope" })
  await settle()

  assert.match(p.root.innerHTML, /Invalid email address or password/)
  assert.match(p.root.innerHTML, /<h1>Sign in<\/h1>/)
})

test("opens a project as a board, moves a task with its lock_version, and shows the server's version", async () => {
  const { p, api } = await signedIn({
    "PATCH /api/v1/tasks/7": () => ({ body: { data: { ...TASK, status: "in_progress", lock_version: 4 } } })
  })

  await p.navigate("#/projects/1")
  await settle()
  assert.match(p.root.innerHTML, /Land on the moon/)

  await p.click("move", { id: "7", status: "in_progress" })
  await settle()

  assert.deepEqual(api.calls.find((call) => call.key === "PATCH /api/v1/tasks/7").body, { status: "in_progress", lock_version: 3 })
  assert.match(p.root.innerHTML, /aria-label="In progress"[\s\S]*Land on the moon/)
})

test("reloads and says so when someone else changed the task first (409)", async () => {
  let reads = 0
  const { p } = await signedIn({
    "GET /api/v1/projects/1/tasks": () => { reads++; return { body: { data: [{ ...TASK, lock_version: 9 + reads }], meta: {} } } },
    "PATCH /api/v1/tasks/7": () => ({ status: 409, body: { error: { code: "stale_object", message: "stale" } } })
  })
  await p.navigate("#/projects/1")
  await settle()
  const before = reads

  await p.click("move", { id: "7", status: "done" })
  await settle()

  assert.ok(reads > before)
  assert.match(p.root.innerHTML, /Someone changed that task first/)
})

test("adds a task and a comment, and refuses nothing silently", async () => {
  const { p, api } = await signedIn({
    "POST /api/v1/projects/1/tasks": () => ({ status: 201, body: { data: { ...TASK, id: 8, title: "Write the docs" } } }),
    "GET /api/v1/tasks/7/comments": () => ({ body: { data: [] } }),
    "POST /api/v1/tasks/7/comments": () => ({ status: 201, body: { data: { id: 1, body: "On it", user: { name: "Demo User" }, created_at: "2026-11-03T10:00:00Z" } } })
  })
  await p.navigate("#/projects/1")
  await settle()

  await p.submit("new-task", { title: "Write the docs", priority: "low" })
  await settle()
  assert.match(p.root.innerHTML, /Write the docs/)
  assert.deepEqual(api.calls.find((call) => call.key === "POST /api/v1/projects/1/tasks").body, { title: "Write the docs", priority: "low" })

  await p.click("open-task", { id: "7" })
  await settle()
  await p.submit("new-comment", { body: "On it" }, { id: "7" })
  await settle()
  assert.match(p.root.innerHTML, /On it/)
})

test("explains a read-only service and the demo's refusals in words", async () => {
  const { p } = await signedIn({
    "POST /api/v1/projects/1/tasks": () => ({ status: 503, body: { error: { code: "read_only", message: "x" } } })
  })
  await p.navigate("#/projects/1")
  await settle()

  await p.submit("new-task", { title: "Late", priority: "low" })
  await settle()

  assert.match(p.root.innerHTML, /read-only for a moment/)
})

test("signs out when the server stops accepting the token, and says why", async () => {
  const handlers = { ...API }
  const p = page()
  const api = fakeApi(handlers)
  globalThis.fetch = api.fetch
  const storage = memory()
  start({ root: p.root, config, storage, win: p.win })
  await p.submit("sign-in", { email_address: "demo@example.com", password: "password123" })
  await settle()
  assert.equal(storage.store.token, "tok")

  handlers["PATCH /api/v1/notifications/5"] = () => ({ status: 401, body: { error: { code: "unauthenticated", message: "Authentication is required" } } })
  await p.click("read", { id: "5" })
  await settle()

  assert.equal(storage.store.token, undefined)
  assert.match(p.root.innerHTML, /Your session ended\. Please sign in again/)
  assert.match(p.root.innerHTML, /<h1>Sign in<\/h1>/)
  assert.doesNotMatch(p.root.innerHTML, /Apollo/)
})

test("signs out when asked, and forgets the token", async () => {
  const { p, storage } = await signedIn({ "DELETE /api/v1/session": () => ({ status: 204 }) })

  await p.click("sign-out")
  await settle()

  assert.equal(storage.store.token, undefined)
  assert.match(p.root.innerHTML, /<h1>Sign in<\/h1>/)
})

test("marks a notification read", async () => {
  const { p, api } = await signedIn({
    "PATCH /api/v1/notifications/5": () => ({ body: { data: { id: 5, read: true } } })
  })

  await p.click("read", { id: "5" })
  await settle()

  assert.deepEqual(api.calls.find((call) => call.key === "PATCH /api/v1/notifications/5").body, { read: true })
})
