// Drives the real client (js/api.js) against a real server, with the real demo dataset. Not part of `node --test` (it needs a server):
//
//   API_URL=http://localhost:3999 node demo/web/e2e/smoke.mjs
//
// Start the server like docs/demo.md says: a scratch database, DEMO_MODE=true, CORS_ORIGINS including the origin that serves demo/web.
import assert from "node:assert/strict"
import { createClient, ApiError } from "../js/api.js"

const baseUrl = process.env.API_URL ?? "http://localhost:3000"
let token = null
let demo = false
const api = createClient({ baseUrl, getToken: () => token, onDemoMode: () => { demo = true } })
const step = (name) => console.log(`ok  ${name}`)

const { data: session } = await api.signIn("demo@example.com", "password123")
token = session.token
assert.ok(token && session.user.name)
assert.equal(demo, true, "the server says it is a demo")
step(`signed in as ${session.user.name}; X-Demo-Mode seen`)

const { data: projects } = await api.projects()
assert.ok(projects.length >= 1)
const project = projects[0]
step(`${projects.length} projects; opening "${project.name}" (role ${project.role})`)

const [{ data: opened }, { data: tasks, meta }] = await Promise.all([api.project(project.id), api.tasks(project.id)])
assert.equal(opened.id, project.id)
assert.ok(tasks.length >= 1 && tasks.every((task) => ["todo", "in_progress", "done"].includes(task.status)))
step(`board of ${tasks.length} tasks (more pages: ${Boolean(meta?.next)})`)

const created = (await api.createTask(project.id, { title: "Created by the smoke test <b>bold</b>", priority: "low" })).data
assert.equal(created.status, "todo")
const moved = (await api.updateTask(created.id, { status: "in_progress", lock_version: created.lock_version })).data
assert.equal(moved.status, "in_progress")
step("created a task and moved it with its lock_version")

const stale = await api.updateTask(created.id, { status: "done", lock_version: created.lock_version }).catch((error) => error)
assert.ok(stale instanceof ApiError && stale.code === "stale_object" && stale.status === 409)
step("a stale lock_version is an ApiError stale_object (409)")

const blank = await api.createTask(project.id, { title: "" }).catch((error) => error)
assert.ok(blank instanceof ApiError && blank.code === "validation_failed")
step(`a blank title is "${blank.summary}"`)

await api.addComment(created.id, "A comment from the smoke test")
const { data: comments } = await api.comments(created.id)
assert.equal(comments.at(-1).body, "A comment from the smoke test")
step("commented")

const { data: notifications, meta: inbox } = await api.notifications()
assert.ok(Array.isArray(notifications) && Number.isInteger(inbox.unread_count))
if (notifications[0]) await api.markRead(notifications[0].id)
await api.markAllRead()
assert.equal((await api.notifications()).meta.unread_count, 0)
step(`inbox: ${notifications.length} notifications, all read now`)

const refused = await fetch(new URL("/api/v1/me", baseUrl), { method: "PATCH", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: "{}" })
assert.equal(refused.status, 403)
assert.equal((await refused.json()).error.code, "demo_mode")
step("the demo refuses editing the profile (403 demo_mode)")

await api.signOut()
const after = await api.me().catch((error) => error)
assert.ok(after instanceof ApiError && after.status === 401)
step("signed out; the token no longer works")
console.log("\nall steps passed")
